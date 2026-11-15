package HPS::BootReady;
# Boot readiness of this IPS (docs/BOOT-RELIABILITY.md, layer 3): do the boot
# services answer? A node or a VM that is started into a deaf IPS gets one
# DHCP/PXE pass, fails, and (a VM) sits in the firmware shell for ever (IPS-40).
#
# check(%opt) runs four read-only checks and gives a verdict:
#   dnsmasq  a dnsmasq process exists
#   dhcp     UDP port 67 is bound on the provisioning address (or the wildcard)
#   tftp     UDP port 69 is bound, and the first-stage files (snponly.efi for
#            UEFI, undionly.kpxe for BIOS) exist, non-empty, in the TFTP root
#   http     the HTTP boot path answers: boot_manager.sh?cmd=cluster_variable
#            (read-only; cmd=init is never probed, it registers the caller)
# Each check is pass, fail or unknown (could not be looked at). The verdict is
#   not_ready  at least one check failed
#   unknown    none failed, at least one could not be looked at
#   ready      every check passed
# A check that cannot be looked at is never "pass".
#
# wait_ready(%opt) repeats check for up to wait seconds. gate(%opt) is what
# hps-workload start and hps-bmc call: ready proceeds, not_ready refuses naming
# what does not answer, unknown proceeds with a warning (the gate guards against
# a known failure; a check that cannot run must not block power).
#
# Everything outside the process is injectable (proc_net_udp, proc_dir, tftp_dir,
# http_get, now, sleep) so the tests need no live services.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HPS::Registry ();

our @FIRST_STAGE = qw(snponly.efi undionly.kpxe);
use constant DEFAULT_WAIT => 60;
use constant EXIT_READY   => 0;
use constant EXIT_NOT     => 1;
use constant EXIT_UNKNOWN => 3;

sub exit_code ($verdict) {
    return $verdict eq 'ready' ? EXIT_READY : $verdict eq 'not_ready' ? EXIT_NOT : EXIT_UNKNOWN;
}

# int_setting($raw, $default, $min, $max, $name): (value, warning). Unset or
# empty gives the default silently; 0 is allowed when $min is 0; a value out of
# range or not a number gives the default and a warning text.
sub int_setting ($raw, $default, $min, $max, $name) {
    return ($default, undef) unless defined $raw && length $raw;
    my $v = $raw;
    $v =~ s/\A\s+|\s+\z//g;
    return ($v + 0, undef) if $v =~ /\A(?:0|[1-9][0-9]*)\z/ && $v >= $min && $v <= $max;
    return ($default, "$name='$raw' is not an integer $min..$max; using $default");
}

# udp_bound($proc_net_udp_text, $port, \@addresses): true when a UDP socket is
# bound to $port on the wildcard address or on one of @addresses (dotted quads).
# The text is /proc/net/udp: "sl local_address rem_address st ..." with the
# local address as hex IP:PORT, the IP in host byte order of the kernel
# (little-endian on x86: 0100007F is 127.0.0.1).
sub udp_bound ($text, $port, $addrs = []) {
    my %want = map { $_ => 1 } map { _hex_ip($_) // () } @$addrs;
    my $hexport = sprintf('%04X', $port);
    for my $line (split /\n/, $text // '') {
        my ($ip, $p) = $line =~ /\A\s*\d+:\s+([0-9A-Fa-f]{8}):([0-9A-Fa-f]{4})\s/ or next;
        next unless uc $p eq $hexport;
        return 1 if $ip eq '00000000' || $want{ uc $ip };
    }
    return 0;
}

sub _hex_ip ($dotted) {
    my @o = ($dotted // '') =~ /\A([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\z/ or return undef;
    return undef if grep { $_ > 255 } @o;
    return uc sprintf('%02X%02X%02X%02X', reverse @o);
}

# process_running($proc_dir, $name): true when a /proc/<pid>/comm equals $name;
# undef when the process table cannot be read.
sub process_running ($proc_dir, $name) {
    opendir(my $dh, $proc_dir) or return undef;
    my @pids = grep { /\A[0-9]+\z/ } readdir $dh;
    closedir $dh;
    for my $pid (@pids) {
        open(my $fh, '<', "$proc_dir/$pid/comm") or next;
        my $comm = <$fh>;
        close $fh;
        next unless defined $comm;
        chomp $comm;
        return 1 if $comm eq $name;
    }
    return 0;
}

sub _slurp ($file) {
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

sub _result ($name, $status, $reason) { return { name => $name, status => $status, reason => $reason } }

# The context this IPS runs in: {ips_ip, tftp_dir}; each undef when it cannot be
# found (the check that needs it is then unknown).
sub context (%opt) {
    my $reg = $opt{registry} // eval { HPS::Registry->new };
    my %c = (ips_ip => $opt{ips_ip}, tftp_dir => $opt{tftp_dir});
    if ($reg) {
        if (!defined $c{ips_ip}) {
            my $cl = eval { $reg->active_cluster };
            $c{ips_ip} = eval { $reg->cluster_get($cl, 'network_dhcp_ip') } if defined $cl;
            $c{ips_ip} = undef unless defined $c{ips_ip} && $c{ips_ip} =~ /\A[0-9.]+\z/;
        }
        $c{tftp_dir} //= eval { $reg->config_base . '/tftp' };
    }
    return \%c;
}

# http_get($url): ($code, $body); the default is HTTP::Tiny with a 5 s timeout.
sub _default_http_get ($url) {
    require HTTP::Tiny;
    my $r = HTTP::Tiny->new(timeout => 5)->get($url);
    # 599 is HTTP::Tiny's own: nothing answered (the content is its error text).
    return (undef, $r->{content} // '') if $r->{status} == 599;
    return ($r->{status}, $r->{content} // '');
}

# check(%opt): {verdict, checks => [{name, status, reason}]}. Options: registry,
# ips_ip, tftp_dir, proc_dir (/proc), proc_net_udp (/proc/net/udp), http_get.
sub check (%opt) {
    my $ctx = context(%opt);
    # The HPS_BOOT_READY_* variables point the check at fixtures (the tests of the CLIs).
    my $proc = $opt{proc_dir} // $ENV{HPS_BOOT_READY_PROC} // '/proc';
    my $udp_file = $opt{proc_net_udp} // $ENV{HPS_BOOT_READY_UDP} // '/proc/net/udp';
    my $get = $opt{http_get} // \&_default_http_get;
    my @c;

    my $up = process_running($proc, 'dnsmasq');
    push @c, !defined $up ? _result(dnsmasq => 'unknown', "cannot read the process table $proc")
        : $up ? _result(dnsmasq => 'pass', 'dnsmasq is running')
        : _result(dnsmasq => 'fail', 'dnsmasq is not running');

    my $udp = _slurp($udp_file);
    if (!defined $udp) {
        push @c, _result(dhcp => 'unknown', "cannot read $udp_file");
    }
    elsif (!defined $ctx->{ips_ip}) {
        push @c, _result(dhcp => 'unknown', 'no provisioning address (cluster key network_dhcp_ip) to look for');
    }
    else {
        push @c, udp_bound($udp, 67, [ $ctx->{ips_ip} ])
            ? _result(dhcp => 'pass', "UDP 67 is bound on $ctx->{ips_ip}")
            : _result(dhcp => 'fail', "nothing listens for DHCP (UDP 67) on $ctx->{ips_ip}");
    }

    my @tftp;
    if (!defined $udp) { push @tftp, [ 'unknown', "cannot read $udp_file" ] }
    elsif (!udp_bound($udp, 69, defined $ctx->{ips_ip} ? [ $ctx->{ips_ip} ] : [])) {
        push @tftp, defined $ctx->{ips_ip} ? [ 'fail', 'nothing listens for TFTP (UDP 69)' ] : [ 'unknown', 'no provisioning address to look for TFTP on' ];
    }
    if (!defined $ctx->{tftp_dir}) { push @tftp, [ 'unknown', 'no TFTP root to look in' ] }
    else {
        my @missing = grep { !-s "$ctx->{tftp_dir}/$_" } @FIRST_STAGE;
        push @tftp, [ 'fail', 'first-stage file missing or empty in ' . "$ctx->{tftp_dir}: " . join(' ', @missing) ] if @missing;
    }
    if (grep { $_->[0] eq q(fail) } @tftp) {
        push @c, _result(tftp => 'fail', join('; ', map { $_->[1] } grep { $_->[0] eq 'fail' } @tftp));
    }
    elsif (@tftp) {
        push @c, _result(tftp => 'unknown', join('; ', map { $_->[1] } @tftp));
    }
    else {
        push @c, _result(tftp => 'pass', "UDP 69 is bound; @FIRST_STAGE present in $ctx->{tftp_dir}");
    }

    if (!defined $ctx->{ips_ip}) {
        push @c, _result(http => 'unknown', 'no IPS address (cluster key network_dhcp_ip) to ask');
    }
    else {
        my $url = 'http://' . ($ENV{HPS_BOOT_READY_HTTP} // $ctx->{ips_ip}) . "/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=network_dns_domain";
        my ($code, $body) = eval { $get->($url) };
        if (!defined $code) { push @c, _result(http => 'fail', "no HTTP answer from $url" . (defined $body && length $body ? ' (' . ($body =~ s/\s+/ /gr) . ')' : '')) }
        elsif ($code != 200) { push @c, _result(http => 'fail', "HTTP $code from $url") }
        elsif (!length(($body // '') =~ s/\s+//gr)) { push @c, _result(http => 'fail', "HTTP 200 from $url but the answer is empty") }
        else { push @c, _result(http => 'pass', "HTTP 200 from $url") }
    }

    return { verdict => verdict(\@c), checks => \@c };
}

# verdict(\@checks): not_ready when any failed, else unknown when any could not
# be looked at, else ready. No checks at all is unknown.
sub verdict ($checks) {
    return 'unknown' unless @$checks;
    return 'not_ready' if grep { $_->{status} eq 'fail' } @$checks;
    return 'unknown' if grep { $_->{status} ne 'pass' } @$checks;
    return 'ready';
}

# wait_ready(%opt, wait => S, interval => 2, now => sub, sleep => sub): check
# until the verdict is ready or S seconds passed. Not ready and unknown are both
# waited out; the last result is returned with waited (seconds) added.
sub wait_ready (%opt) {
    my $wait = $opt{wait} // DEFAULT_WAIT;
    my $every = $opt{interval} // 2;
    my $now = $opt{now} // sub { time };
    my $sleep = $opt{sleep} // sub { sleep $_[0] };
    my $t0 = $now->();
    my $r;
    while (1) {
        $r = check(%opt);
        last if $r->{verdict} eq 'ready';
        my $left = $wait - ($now->() - $t0);
        last if $left <= 0;
        $sleep->($left < $every ? $left : $every);
    }
    $r->{waited} = $now->() - $t0;
    return $r;
}

# not_answering($result): "dhcp: ...; http: ..." for the checks that are not a pass.
sub not_answering ($r) {
    return join('; ', map { "$_->{name}: $_->{reason}" } grep { $_->{status} ne 'pass' } @{ $r->{checks} });
}

# wait_seconds($raw): (seconds, warning) of the cluster key boot_ready_wait_seconds.
sub wait_seconds ($raw) { return int_setting($raw, DEFAULT_WAIT, 0, 600, 'boot_ready_wait_seconds') }

# configured_wait(registry => $reg): the key's value now.
sub configured_wait (%opt) {
    my $reg = $opt{registry} // eval { HPS::Registry->new } or return (DEFAULT_WAIT, undef);
    my $cl = eval { $reg->active_cluster };
    my $raw = defined $cl ? eval { $reg->cluster_get($cl, 'boot_ready_wait_seconds') } : undef;
    return wait_seconds($raw);
}

# gate(%opt): wait (the cluster key unless wait => S is given) for the boot
# services, then {ok, verdict, waited, message, warnings}. ok is false only for
# not_ready; message names what does not answer. wait 0 checks once.
sub gate (%opt) {
    # HPS_BOOT_READY_SKIP: the test suites, which have no dnsmasq to look at.
    return { ok => 1, verdict => 'skipped', waited => 0, checks => [], warnings => [] } if $ENV{HPS_BOOT_READY_SKIP};
    my ($wait, $warn) = defined $opt{wait} ? ($opt{wait}, undef) : configured_wait(%opt);
    my $r = wait_ready(%opt, wait => $wait);
    my @warnings = defined $warn ? ($warn) : ();
    my $msg;
    if ($r->{verdict} eq 'not_ready') {
        $msg = "this IPS's boot services do not answer after $r->{waited} s (" . not_answering($r)
            . '); a node started now would miss its one PXE pass. Fix it, wait, or skip the check with --no-boot-wait';
    }
    elsif ($r->{verdict} eq 'unknown') {
        push @warnings, 'boot readiness could not be checked (' . not_answering($r) . '); going ahead';
    }
    return { ok => ($r->{verdict} eq 'not_ready' ? 0 : 1), verdict => $r->{verdict}, waited => $r->{waited},
        checks => $r->{checks}, (defined $msg ? (message => $msg) : ()), warnings => \@warnings };
}

1;
