package HPS::BMC;
# Out-of-band power control: driver selection from the audit, the operator
# override, the credential hand-over and the call with its retry policy.
# Drivers are executables under lib/bmc/drivers (contract in docs/BMC.md).
#
# Host keys: bmc_driver, bmc_driver_source (audit | operator), bmc_addr,
# bmc_options (json), bmc_evidence (json), bmc_last (json). Cluster key:
# power_devices (json {name: {addr, options}}). Credentials live in the keysafe
# (HPS::Keysafe secrets) as "user\npassword\n", named <mac12> for a host and
# device-<name> for a power device; they are written to the driver's stdin and
# nowhere else.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use File::Basename qw(dirname);
use File::Spec;
use IPC::Open3 qw(open3);
use IO::Select;
use Symbol qw(gensym);
use POSIX qw(strftime dup2);
use Fcntl qw(F_GETFD F_SETFD);
use HPS::Registry;
use HPS::Keysafe;

package HPS::BMC::Error {
    # kind: usage, notfound, refused, failed
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

my $LIBBMC = File::Spec->catdir(dirname(dirname(dirname(File::Spec->rel2abs(__FILE__)))), 'bmc');
my %ACTIONS = map { $_ => 1 } qw(status on off force-off reset pxe-once identify);
my $NAME_RE = qr/^[a-z0-9][a-z0-9_-]*$/;
my $OPT_RE  = qr/^[a-z][a-z0-9_]*$/;

sub _fail ($kind, $msg) { die HPS::BMC::Error->new($kind, $msg) }

# new(registry => $reg, keysafe => $ks, drivers_dir =>, map_file =>, logger => sub($level,$msg),
#     sleep => sub($seconds), tries => 4, retry_delay => 20, timeout => 90)
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    return bless {
        registry    => $reg,
        keysafe     => $opt{keysafe} // HPS::Keysafe->new(registry => $reg),
        drivers_dir => $opt{drivers_dir} // "$LIBBMC/drivers",
        map_file    => $opt{map_file} // "$LIBBMC/drivers.map",
        logger      => $opt{logger} // \&_default_logger,
        sleep       => $opt{sleep} // sub ($s) { select(undef, undef, undef, $s) },
        tries       => $opt{tries} // 4,
        retry_delay => $opt{retry_delay} // $ENV{HPS_BMC_RETRY_DELAY} // 20,
        timeout     => $opt{timeout} // 90,
    }, $class;
}

sub registry ($self) { return $self->{registry} }
sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

sub _default_logger ($level, $msg) {
    print STDERR "hps-bmc: $msg\n" if $level ne 'info' || $ENV{HPS_BMC_VERBOSE};
    return if $ENV{HPS_BMC_NO_SYSLOG};
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-bmc: $msg");
    };
    return;
}

#--- host and device lookup ---------------------------------------------------------

# A MAC in any format, else a registry HOSTNAME (whole value or first label).
sub resolve_host ($self, $host) {
    _fail('usage', 'a host (MAC or HOSTNAME) is required') unless defined $host && length $host;
    my $reg = $self->{registry};
    my $mac = eval { $reg->resolve_mac($host) };
    if (defined $mac) {
        _fail('notfound', "No such host: $host") unless $reg->host_exists($mac);
        return $mac;
    }
    for my $m ($reg->host_list_all) {
        my $name = $reg->host_exists($m, 'HOSTNAME') ? $reg->host_get($m, 'HOSTNAME') : undef;
        next unless defined $name;
        (my $first = $name) =~ s/\..*//;
        return $m if $name eq $host || $first eq $host;
    }
    _fail('notfound', "No host in the registry matches: $host");
}

sub _cluster ($self) { return $self->{registry}->active_cluster }

sub devices ($self) {
    my $d = $self->{registry}->cluster_get_json($self->_cluster, 'power_devices');
    return ref $d eq 'HASH' ? $d : {};
}

sub driver_path ($self, $name) { return "$self->{drivers_dir}/$name" }

sub driver_exists ($self, $name) {
    return defined $name && $name =~ $NAME_RE && -f $self->driver_path($name) && -x _ ? 1 : 0;
}

sub drivers ($self) {
    opendir(my $dh, $self->{drivers_dir}) or return ();
    my @d = sort grep { !/^\./ && $self->driver_exists($_) } readdir $dh;
    closedir $dh;
    return @d;
}

#--- selection from the audit -------------------------------------------------------

# The rule table: [{driver, conds => {field => regex}, line}], in order.
sub rules ($self) {
    my $file = $self->{map_file};
    open(my $fh, '<', $file) or _fail('failed', "Cannot read $file: $!");
    my (@rules, $n);
    $n = 0;
    while (my $l = <$fh>) {
        $n++;
        chomp $l;
        $l =~ s/^\s+|\s+$//g;
        next if $l eq '' || $l =~ /^#/;
        my ($driver, @conds) = split /\s+/, $l;
        my %c;
        for my $c (@conds) {
            my ($k, $re) = split /=/, $c, 2;
            _fail('failed', "$file line $n: bad condition '$c'") unless defined $re && length $re && $k =~ /^[a-z_0-9]+$/;
            $c{$k} = $re;
        }
        push @rules, { driver => $driver, conds => \%c, line => $n };
    }
    close $fh;
    return @rules;
}

# evidence($audit): the BMC facts of an hps-audit/1 document.
sub evidence ($self, $audit) {
    $audit = {} unless ref $audit eq 'HASH';
    my $dmi = ref $audit->{dmi} eq 'HASH' ? $audit->{dmi} : {};
    my $bmc = ref $audit->{bmc} eq 'HASH' ? $audit->{bmc} : {};
    my $lan = ref $bmc->{lan} eq 'HASH' ? $bmc->{lan} : {};
    my $mc  = ref $bmc->{mc}  eq 'HASH' ? $bmc->{mc}  : {};
    my $d42 = $bmc->{dmi42} // 0;
    my $d38 = $bmc->{dmi38} // 0;
    my $mcid = $mc->{manufacturer_id} // '';
    my $ipmi = ($bmc->{ipmi_device} && $bmc->{ipmi_device} ne 'false') || $d38 > 0 || length $mcid ? 'true' : 'false';
    my $ip = $lan->{ip} // '';
    $ip = '' unless $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/ && $ip ne '0.0.0.0';
    return {
        vendor             => $dmi->{sys_vendor} // '',
        product            => $dmi->{product_name} // '',
        mc_manufacturer_id => $mcid,
        mc_firmware        => $mc->{firmware} // '',
        bmc_mac            => $lan->{mac} // '',
        bmc_ip_source      => $lan->{ip_source} // '',
        bmc_ip             => $ip,
        redfish_host_if    => $d42 > 0 ? 'true' : 'false',
        ipmi               => $ipmi,
    };
}

# map_audit($audit): {driver, rule (line number), evidence}. Pure.
sub map_audit ($self, $audit) {
    my $ev = $self->evidence($audit);
    for my $r ($self->rules) {
        my $ok = 1;
        for my $k (sort keys %{ $r->{conds} }) {
            my $re = $r->{conds}{$k};
            my $v = $ev->{$k} // '';
            my $m = eval { $v =~ /$re/i } ;
            _fail('failed', "drivers.map line $r->{line}: bad pattern '$re'") if $@;
            unless ($m) { $ok = 0; last }
        }
        return { driver => $r->{driver}, rule => $r->{line}, evidence => $ev } if $ok;
    }
    return { driver => undef, rule => undef, evidence => $ev };
}

# select_from_audit($host): record the driver the stored audit selects. An
# operator choice (bmc_driver_source = operator) is never replaced. Returns
# {mac, changed, driver, source, reason}.
sub select_from_audit ($self, $host, %o) {
    my $reg = $self->{registry};
    my $mac = $self->resolve_host($host);
    my $src = $reg->host_exists($mac, 'bmc_driver_source') ? $reg->host_get($mac, 'bmc_driver_source') : '';
    my $cur = $reg->host_exists($mac, 'bmc_driver') ? $reg->host_get($mac, 'bmc_driver') : undef;
    if ($src eq 'operator' && !$o{force}) {
        return { mac => $mac, changed => 0, driver => $cur, source => 'operator', reason => 'operator choice kept' };
    }
    my $audit = $reg->host_get_json($mac, 'audit');
    _fail('notfound', "Host $mac has no stored audit") unless ref $audit eq 'HASH';
    my $m = $self->map_audit($audit);
    _fail('failed', 'drivers.map matched no rule (it should end with a catch-all)') unless defined $m->{driver};
    _fail('failed', "drivers.map names a driver that is not installed: $m->{driver}")
        unless $self->driver_exists($m->{driver});
    my $ev = { %{ $m->{evidence} }, rule => $m->{rule} };
    $reg->host_set($mac, 'bmc_driver', $m->{driver});
    $reg->host_set($mac, 'bmc_driver_source', 'audit');
    if (length $ev->{bmc_ip}) { $reg->host_set($mac, 'bmc_addr', $ev->{bmc_ip}) }
    elsif ($reg->host_exists($mac, 'bmc_addr')) { $reg->host_unset($mac, 'bmc_addr') }
    $reg->host_set($mac, 'bmc_evidence', $ev);
    $self->_log('info', "select host=$mac driver=$m->{driver} source=audit rule=$m->{rule}");
    return { mac => $mac, changed => 1, driver => $m->{driver}, source => 'audit', reason => "rule $m->{rule}" };
}

#--- operator configuration ---------------------------------------------------------

sub _check_options ($opts) {
    for my $k (keys %$opts) {
        _fail('usage', "Invalid option name '$k' (lower-case letters, digits, underscore)") unless $k =~ $OPT_RE;
        _fail('usage', "Option $k: the value must be one line") unless defined $opts->{$k} && $opts->{$k} !~ /[\r\n]/;
    }
    return 1;
}

sub _split_outlet ($outlet) {
    _fail('usage', "outlet must be <device>:<outlet>, got '" . ($outlet // '') . "'")
        unless defined $outlet && $outlet =~ /^([a-z0-9][a-z0-9_-]*):(\S+)$/;
    return ($1, $2);
}

# set($host, driver => NAME|'auto', addr => A, options => {k => v}): operator
# configuration; sets bmc_driver_source = operator. driver 'auto' returns the
# host to audit selection.
sub set ($self, $host, %o) {
    my $reg = $self->{registry};
    my $mac = $self->resolve_host($host);
    my $driver = $o{driver};
    _fail('usage', 'set needs --driver') unless defined $driver && length $driver;
    my $opts = $o{options} // {};
    _check_options($opts);
    if ($driver eq 'auto') {
        _fail('usage', '--driver auto takes no --addr or --option') if defined $o{addr} || %$opts;
        my $r = $self->select_from_audit($mac, force => 1);
        $reg->host_unset($mac, 'bmc_options') if $reg->host_exists($mac, 'bmc_options');
        return { mac => $mac, driver => $r->{driver}, source => 'audit' };
    }
    _fail('notfound', "No such driver: $driver (installed: " . join(', ', $self->drivers) . ')')
        unless $self->driver_exists($driver);
    if ($driver eq 'external') {
        my ($dev) = _split_outlet($opts->{outlet} // ($reg->host_get_json($mac, 'bmc_options') // {})->{outlet});
        _fail('notfound', "No power device '$dev' (hps-bmc device set $dev ...)") unless exists $self->devices->{$dev};
    }
    my $have = $reg->host_get_json($mac, 'bmc_options');
    my %merged = (ref $have eq 'HASH' && ($reg->host_get($mac, 'bmc_driver') // '') eq $driver ? %$have : (), %$opts);
    $reg->host_set($mac, 'bmc_driver', $driver);
    $reg->host_set($mac, 'bmc_driver_source', 'operator');
    if (defined $o{addr}) {
        _fail('usage', 'Invalid address') unless $o{addr} =~ /^[A-Za-z0-9._:\[\]-]+$/;
        $reg->host_set($mac, 'bmc_addr', $o{addr});
    }
    if (%merged) { $reg->host_set($mac, 'bmc_options', \%merged) }
    elsif ($reg->host_exists($mac, 'bmc_options')) { $reg->host_unset($mac, 'bmc_options') }
    $self->_log('info', "set host=$mac driver=$driver source=operator");
    return { mac => $mac, driver => $driver, source => 'operator' };
}

# device_set($name, addr => A, options => {cmd => ...}): the cluster-level
# power device (PDU, smart plug) hosts refer to by outlet=<name>:<n>.
sub device_set ($self, $name, %o) {
    _fail('usage', "Invalid device name '" . ($name // '') . "'") unless defined $name && $name =~ $NAME_RE;
    my $opts = $o{options} // {};
    _check_options($opts);
    my $all = $self->devices;
    my $cur = $all->{$name} // { addr => '', options => {} };
    $cur->{addr} = $o{addr} if defined $o{addr};
    $cur->{options} = { %{ $cur->{options} // {} }, %$opts };
    $all->{$name} = $cur;
    $self->{registry}->cluster_set($self->_cluster, 'power_devices', $all);
    $self->_log('info', "device-set device=$name");
    return { name => $name, %$cur };
}

sub device_delete ($self, $name) {
    my $all = $self->devices;
    _fail('notfound', "No power device '$name'") unless exists $all->{$name};
    for my $m ($self->{registry}->host_list_all) {
        my $o = $self->{registry}->host_get_json($m, 'bmc_options');
        _fail('refused', "Power device '$name' is used by host $m")
            if ref $o eq 'HASH' && defined $o->{outlet} && $o->{outlet} =~ /^\Q$name\E:/;
    }
    delete $all->{$name};
    $self->{registry}->cluster_set($self->_cluster, 'power_devices', $all);
    return 1;
}

# credential_set($target, $user, $password): target is a host, or "device:NAME".
sub credential_name ($self, $target) {
    return 'device-' . $1 if $target =~ /^device:([a-z0-9][a-z0-9_-]*)$/;
    return $self->resolve_host($target);
}

sub credential_set ($self, $target, $user, $pass) {
    _fail('usage', 'A user and a password are required') unless defined $user && length $user && defined $pass && length $pass;
    _fail('usage', 'The user and password must be one line each') if $user =~ /[\r\n]/ || $pass =~ /[\r\n]/;
    my $name = $self->credential_name($target);
    if ($target =~ /^device:(.+)$/) {
        _fail('notfound', "No power device '$1'") unless exists $self->devices->{$1};
    }
    $self->{keysafe}->put_secret($name, "$user\n$pass\n");
    $self->_log('info', "credential-set target=$name");
    return { name => $name };
}

#--- resolution and execution -------------------------------------------------------

# resolve($host): what a call needs, or undef driver when none is recorded.
sub resolve ($self, $host) {
    my $reg = $self->{registry};
    my $mac = $self->resolve_host($host);
    my $driver = $reg->host_exists($mac, 'bmc_driver') ? $reg->host_get($mac, 'bmc_driver') : undef;
    my $opts = $reg->host_get_json($mac, 'bmc_options');
    $opts = {} unless ref $opts eq 'HASH';
    my $r = {
        mac     => $mac,
        driver  => $driver,
        source  => ($reg->host_exists($mac, 'bmc_driver_source') ? $reg->host_get($mac, 'bmc_driver_source') : ''),
        addr    => ($reg->host_exists($mac, 'bmc_addr') ? $reg->host_get($mac, 'bmc_addr') : ''),
        options => { %$opts },
        cred    => $mac,
    };
    if (defined $driver && $driver eq 'external') {
        my ($dev, $outlet) = _split_outlet($opts->{outlet});
        my $d = $self->devices->{$dev} or _fail('notfound', "Power device '$dev' is not defined");
        $r->{addr}    = $d->{addr} // '';
        $r->{options} = { %{ $d->{options} // {} }, %$opts, outlet => $outlet };
        $r->{cred}    = "device-$dev";
        $r->{device}  = $dev;
    }
    return $r;
}

sub _driver_env ($self, $r) {
    my %env = (
        PATH       => $ENV{PATH} // '/usr/bin:/bin',
        LANG       => 'C',
        BMC_HOST   => $r->{mac},
        BMC_DRIVER => $r->{driver},
        BMC_ADDR   => $r->{addr},
    );
    $env{HOME} = $ENV{HOME} if defined $ENV{HOME};
    # The driver gets a clean environment. HPS_BMC_ENV_PASS names extra variables to
    # pass (a test and lab aid: PATH shims read their fixtures from the environment).
    for my $k (grep { /^[A-Z][A-Z0-9_]*$/ } split ' ', ($ENV{HPS_BMC_ENV_PASS} // '')) {
        $env{$k} = $ENV{$k} if defined $ENV{$k};
    }
    for my $k (sort keys %{ $r->{options} }) {
        $env{"BMC_OPT_$k"} = $r->{options}{$k};
    }
    return %env;
}

# One driver call: {rc, stdout, stderr}. The credential goes to stdin only.
sub _exec ($self, $r, $action, $cred) {
    my $path = $self->driver_path($r->{driver});
    local $SIG{PIPE} = 'IGNORE';
    my %env = $self->_driver_env($r);
    my ($in, $out, $err) = (undef, undef, gensym);
    my $pid;
    {
        local %ENV = %env;
        $pid = open3($in, $out, $err, $path, $action);
    }
    if (defined $cred && length $cred) { syswrite($in, $cred) }
    close $in;
    my %buf = (out => '', err => '');
    my $sel = IO::Select->new($out, $err);
    my $deadline = time + $self->{timeout};
    my $killed = 0;
    while ($sel->count) {
        my $left = $deadline - time;
        if ($left <= 0) { kill 'KILL', $pid; $killed = 1; last }
        for my $fh ($sel->can_read($left)) {
            my $n = sysread($fh, my $chunk, 8192);
            if (!$n) { $sel->remove($fh); next }
            $buf{ $fh == $out ? 'out' : 'err' } .= $chunk;
        }
    }
    waitpid($pid, 0);
    my $rc = $killed ? 4 : ($? >> 8);
    $buf{err} .= "driver timed out\n" if $killed;
    $rc = 1 if $? & 127 && !$killed;
    return { rc => $rc, stdout => $buf{out}, stderr => $buf{err} };
}

sub _scrub ($text, $cred) {
    return $text unless defined $cred && length $cred;
    my (undef, $pass) = split /\n/, $cred;
    $text =~ s/\Q$pass\E/***/g if defined $pass && length($pass) >= 4;
    return $text;
}

# run($host, $action): the driver call with the retry policy (exit 4 is
# retried: tries over (tries-1)*retry_delay seconds; 3 and 5 never). Returns
# {rc, host, mac, driver, action, tries, stdout, stderr, status (hash, for
# status)}. Logs action, host, driver, exit; never the credential.
sub run ($self, $host, $action) {
    _fail('usage', "Unknown action '" . ($action // '') . "'") unless defined $action && $ACTIONS{$action};
    my $r = $self->resolve($host);
    my $res = { host => $host, mac => $r->{mac}, action => $action, driver => $r->{driver}, tries => 0 };
    unless (defined $r->{driver} && length $r->{driver}) {
        @$res{qw(rc stdout stderr)} = (5, '', "No BMC driver is recorded for $r->{mac} (hps-bmc set)\n");
        $self->_log('warn', "action=$action host=$r->{mac} driver=- exit=5");
        return $res;
    }
    unless ($self->driver_exists($r->{driver})) {
        @$res{qw(rc stdout stderr)} = (1, '', "Driver $r->{driver} is not installed\n");
        $self->_log('error', "action=$action host=$r->{mac} driver=$r->{driver} exit=1");
        return $res;
    }
    my $cred = $self->{keysafe}->get_secret($r->{cred});
    for my $try (1 .. $self->{tries}) {
        $res->{tries} = $try;
        my $x = $self->_exec($r, $action, $cred);
        @$res{qw(rc stdout stderr)} = ($x->{rc}, _scrub($x->{stdout}, $cred), _scrub($x->{stderr}, $cred));
        last unless $x->{rc} == 4 && $try < $self->{tries};
        $self->_log('warn', "action=$action host=$r->{mac} driver=$r->{driver} exit=4 try=$try; retrying");
        $self->{sleep}->($self->{retry_delay});
    }
    $self->_log($res->{rc} == 0 ? 'info' : 'warn',
        "action=$action host=$r->{mac} driver=$r->{driver} exit=$res->{rc} tries=$res->{tries}");
    if ($action eq 'status' && $res->{rc} == 0) {
        my $st = eval { JSON::PP::decode_json($res->{stdout}) };
        if (ref $st eq 'HASH') {
            $res->{status} = { map { $_ => ($st->{$_} // '') } qw(power model serial bmc_firmware) };
            $res->{status}{power} = 'unknown' unless $res->{status}{power} =~ /^(?:on|off)$/;
        }
        else {
            @$res{qw(rc)} = (1);
            $res->{stderr} .= "Driver $r->{driver} printed no valid status JSON\n";
        }
    }
    $self->_record($r->{mac}, $res);
    return $res;
}

sub _record ($self, $mac, $res) {
    my $last = { action => $res->{action}, rc => $res->{rc}, at => strftime('%Y-%m-%d %H:%M:%S UTC', gmtime) };
    $last->{power} = $res->{status}{power} if $res->{status};
    eval { $self->{registry}->host_set($mac, 'bmc_last', $last) };
    return;
}

# console($host, seconds => N): attach the host's serial console through its
# driver. Interactive: the driver inherits stdin (keystrokes in) and stdout
# (console out); the credential goes in on file descriptor 3, never argv and
# never stdin. N is an integer 1..3600 (default 600); the driver ends the
# session after N seconds or when the far end closes. No retry. Logs action,
# host, driver, exit and seconds, never content. Returns {rc, ...}.
sub console ($self, $host, %o) {
    my $secs = $o{seconds} // 600;
    _fail('usage', '--seconds must be an integer from 1 to 3600')
        unless $secs =~ /^[0-9]{1,4}$/ && $secs >= 1 && $secs <= 3600;
    $secs += 0;
    my $r = $self->resolve($host);
    my $res = { host => $host, mac => $r->{mac}, action => 'console', driver => $r->{driver}, seconds => $secs };
    unless (defined $r->{driver} && length $r->{driver}) {
        print STDERR "No BMC driver is recorded for $r->{mac} (hps-bmc set)\n";
        $self->_log('warn', "action=console host=$r->{mac} driver=- exit=5 seconds=$secs");
        $res->{rc} = 5;
        return $res;
    }
    unless ($self->driver_exists($r->{driver})) {
        print STDERR "Driver $r->{driver} is not installed\n";
        $self->_log('error', "action=console host=$r->{mac} driver=$r->{driver} exit=1 seconds=$secs");
        $res->{rc} = 1;
        return $res;
    }
    my $cred = $self->{keysafe}->get_secret($r->{cred});
    my $kh = $self->_known_hosts($r->{mac});
    my %env = $self->_driver_env($r);
    $env{BMC_CONSOLE_SECONDS} = $secs;
    $env{BMC_KNOWN_HOSTS}     = $kh;
    my $path = $self->driver_path($r->{driver});
    pipe(my $rd, my $wr) or _fail('failed', "pipe: $!");
    STDOUT->flush;
    STDERR->flush;
    my $pid = fork();
    _fail('failed', "fork: $!") unless defined $pid;
    if (!$pid) {
        close $wr;
        if (fileno($rd) == 3) {
            fcntl($rd, F_SETFD, (fcntl($rd, F_GETFD, 0) // 0) & ~1);
        }
        else {
            dup2(fileno($rd), 3) or exit 126;
        }
        %ENV = %env;
        exec { $path } $path, 'console';
        exit 127;
    }
    close $rd;
    {
        local $SIG{PIPE} = 'IGNORE';
        syswrite($wr, $cred) if defined $cred && length $cred;
    }
    close $wr;
    local @SIG{qw(INT TERM HUP)} = map { my $s = $_; sub { kill $s, $pid } } qw(INT TERM HUP);
    my $w;
    do { $w = waitpid($pid, 0) } while ($w == -1 && $!{EINTR});
    my $rc = $? & 127 ? 1 : $? >> 8;
    $res->{rc} = $rc;
    $self->_log($rc == 0 ? 'info' : 'warn', "action=console host=$r->{mac} driver=$r->{driver} exit=$rc seconds=$secs");
    $self->_record($r->{mac}, $res);
    return $res;
}

# The per-BMC known_hosts file (ssh console drivers): <cluster>/bmc/known_hosts-<mac>.
sub _known_hosts ($self, $mac) {
    my $dir = $self->{registry}->cluster_dir($self->_cluster) . '/bmc';
    unless (-d $dir) {
        mkdir $dir, 0700 or -d $dir or _fail('failed', "Cannot create $dir: $!");
    }
    return "$dir/known_hosts-$mac";
}

# list(): [{mac, hostname, driver, source, addr, last}] for hosts with a driver.
sub list ($self) {
    my $reg = $self->{registry};
    my @rows;
    for my $m ($reg->host_list_all) {
        next unless $reg->host_exists($m, 'bmc_driver');
        push @rows, {
            mac      => $m,
            hostname => ($reg->host_exists($m, 'HOSTNAME') ? $reg->host_get($m, 'HOSTNAME') : ''),
            driver   => $reg->host_get($m, 'bmc_driver'),
            source   => ($reg->host_exists($m, 'bmc_driver_source') ? $reg->host_get($m, 'bmc_driver_source') : ''),
            addr     => ($reg->host_exists($m, 'bmc_addr') ? $reg->host_get($m, 'bmc_addr') : ''),
            last     => $reg->host_get_json($m, 'bmc_last'),
        };
    }
    return @rows;
}

1;
