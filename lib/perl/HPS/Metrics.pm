package HPS::Metrics;
# Read-only access to hps-monitor's results (docs/MONITORING.md), for
# hps-metrics: each host's latest result per check, and per-resource
# utilisation series bucketed in time.
#
# Sources, the first that exists:
#   <log>/metrics.log         the lab collector's file (lab/syslog-lab.pl):
#                             "<rfc3339> metric <syslog host> <tag> <msg>"; on a
#                             collector it also holds the lines forwarded from
#                             inner IPSs, which are left out (see own hosts)
#   <log>/ips/hps/<date>.log  the product file every IPS writes (hps-monitor
#                             logs with logger -t hps): RFC 3164 time, seconds
#
# Own hosts: a line counts when its host= is <label>.<this cluster's DNS domain>
# exactly (a forwarded inner cluster's hosts are in another domain). With no
# domain configured every host counts.
#
# Utilisation, in percent (0..100), from the check's perfdata (or its text):
#   cpu    = busy%                                     (check cpu)
#   mem    = 100 - available_pct                       (check mem)
#   load   = scaled_load1 (load per core) x 100, capped at 100   (check load)
#   disk   = the worst used% of disk_* (space or inodes: *used_pct, *inode_pct;
#            disk_root, a plain check_disk, gives free% in its text: 100 - free)
#   pool   = the worst <pool>_cap%                     (check zpool or zpool_cap)
#   diskio = the busiest device's <dev>_busy%          (check diskio): shown, but
#            not in the compound: busy is the share of time a request was in
#            flight, not of the device's capacity (an SSD or a pool member is
#            often 100% busy far below its throughput)
#   net    = throughput is recorded (raw net_rx_Bps, net_tx_Bps) but no link
#            capacity is known anywhere (the audit's speed is null), so net has
#            no utilisation and stays out of the compound
#   compound = the max of cpu, mem, load, disk and pool: anything high
#            makes it high.
# In a series a bucket keeps the max of each utilisation and raw value, and the
# last state of each check.
#
# Nothing here writes, and no path is built from caller text.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use POSIX qw(floor ceil strftime);
use Time::Local ();
use JSON::PP ();
use HPS::Log ();
use HPS::Registry ();
use HPS::Monitor ();
use HPS::ClusterConfig ();

use constant DEFAULT_HOURS  => 24;
use constant MAX_HOURS      => 168;
use constant DEFAULT_STEP   => 300;
use constant MIN_STEP       => 30;
use constant MAX_STEP       => 86400;
use constant MAX_BUCKETS    => 10080;              # 168 h at 60 s
use constant MAX_SCAN_BYTES => 512 * 1024 * 1024;  # per call
use constant LAST_WINDOW    => 900;                # seconds `last` looks back, at least
use constant WARN_PCT       => 70;
use constant CRIT_PCT       => 90;

our @COMPOUND   = qw(cpu mem load disk pool);            # in the compound, in this order
our @RESOURCES  = (@COMPOUND, 'diskio');                # every utilisation
our @RAW        = qw(cpu_busy_pct mem_available_pct load1 net_rx_Bps net_tx_Bps diskio_rd_Bps diskio_wr_Bps);
our %RAW_UNIT   = (cpu_busy_pct => '%', mem_available_pct => '%', load1 => '', net_rx_Bps => 'B/s',
                   net_tx_Bps => 'B/s', diskio_rd_Bps => 'B/s', diskio_wr_Bps => 'B/s');

{
    package HPS::Metrics::Error;
    use feature qw(signatures);
    no warnings 'experimental::signatures';
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

sub _fail ($kind, $msg) { die HPS::Metrics::Error->new($kind, $msg) }

#--- one line --------------------------------------------------------------------

# parse_perf($text): {label => {value, uom}} from "label=value[uom][;w;c;min;max] ...".
# A token cut short (syslog truncates long lines) is left out.
sub parse_perf ($text) {
    my %p;
    for my $tok (split /\s+/, $text // '') {
        my ($l, $v, $u) = $tok =~ /\A([^=\s]+)=(-?[0-9]+(?:\.[0-9]+)?)([A-Za-z%\/]*)(?:;|\z)/ or next;
        $p{$l} = { value => $v + 0, uom => $u };
    }
    return \%p;
}

# parse_message($msg): the hps-monitor line as a record, or undef:
#   {kind => check,  host, check, state, text, perf}
#   {kind => summary, host, checks, worst}
#   {kind => unreachable | pair_failed | reachable, host, text}
sub parse_message ($msg) {
    return undef unless defined $msg;
    my ($host, $rest) = $msg =~ /\Ahps-monitor: host=(\S+) (.*)\z/s or return undef;
    if (my ($check, $state, $tail) = $rest =~ /\Acheck=(\S+) state=([A-Z_]+) ?(.*)\z/s) {
        my ($text, $perf) = split / \| /, $tail, 2;
        return { kind => 'check', host => $host, check => $check, state => $state,
                 text => $text // '', perf => parse_perf($perf) };
    }
    if (my ($n, $worst) = $rest =~ /\Achecks=([0-9]+) worst=([A-Z_]+)/) {
        return { kind => 'summary', host => $host, checks => $n + 0, worst => $worst };
    }
    if (my ($st, $text) = $rest =~ /\Astate=(UNREACHABLE|PAIR_FAILED|REACHABLE) ?(.*)\z/s) {
        return { kind => lc $st, host => $host, text => $text };
    }
    return undef;
}

sub _max (@v) {
    my $m;
    for (@v) { $m = $_ if defined $_ && (!defined $m || $_ > $m) }
    return $m;
}

sub _pct ($v) { return undef unless defined $v; $v = 0 if $v < 0; $v = 100 if $v > 100; return 0 + sprintf('%.1f', $v) }

sub _pct_label ($perf, $re) {
    return _max(map { $perf->{$_}{value} } grep { $_ =~ $re && $perf->{$_}{uom} eq '%' } keys %$perf);
}

# utilisation($check_record): ({resource => pct}, {raw name => value}) of one
# check line (the formulas in the header).
sub utilisation ($r) {
    my (%u, %raw);
    my $c = $r->{check} // '';
    my $p = $r->{perf} // {};
    if ($c eq 'cpu' && $p->{busy}) {
        $u{cpu} = _pct($p->{busy}{value});
        $raw{cpu_busy_pct} = $p->{busy}{value};
    }
    elsif ($c eq 'mem' && $p->{available_pct}) {
        $u{mem} = _pct(100 - $p->{available_pct}{value});
        $raw{mem_available_pct} = $p->{available_pct}{value};
    }
    elsif ($c eq 'load' && $p->{scaled_load1}) {
        $u{load} = _pct($p->{scaled_load1}{value} * 100);
        $raw{load1} = $p->{load1}{value} if $p->{load1};
    }
    elsif ($c =~ /\Adisk_/) {
        my $used = _pct_label($p, qr/(?:\A|_)(?:used_pct|inode_pct)\z/);
        if (!defined $used && ($r->{text} // '') =~ /\(([0-9]+(?:\.[0-9]+)?)% inode=([0-9]+(?:\.[0-9]+)?)%\)/) {
            $used = 100 - ($1 < $2 ? $1 : $2);    # check_disk prints free space and free inodes
        }
        $u{disk} = _pct($used) if defined $used;
    }
    elsif ($c eq 'zpool' || $c eq 'zpool_cap') {
        my $cap = _pct_label($p, qr/_cap\z/);
        $u{pool} = _pct($cap) if defined $cap;
    }
    elsif ($c eq 'diskio') {
        my $busy = _pct_label($p, qr/_busy\z/);
        $u{diskio} = _pct($busy) if defined $busy;
        my ($rd, $wr) = (0, 0);
        for my $l (keys %$p) { $rd += $p->{$l}{value} if $l =~ /_rd_Bps\z/; $wr += $p->{$l}{value} if $l =~ /_wr_Bps\z/ }
        @raw{qw(diskio_rd_Bps diskio_wr_Bps)} = ($rd, $wr);
    }
    elsif ($c eq 'net') {
        # the busiest interface each way (a bridge and its port carry the same bytes)
        $raw{net_rx_Bps} = _max(0, map { $p->{$_}{value} } grep { /_rx_Bps\z/ } keys %$p);
        $raw{net_tx_Bps} = _max(0, map { $p->{$_}{value} } grep { /_tx_Bps\z/ } keys %$p);
    }
    return (\%u, \%raw);
}

# compound(\%util): the max of the resources in the compound; undef when none.
sub compound ($u) { return _max(map { $u->{$_} } @COMPOUND) }

# level($pct): ok below 70, warning below 90, critical from 90; undef for undef.
sub level ($pct) {
    return undef unless defined $pct;
    return $pct >= CRIT_PCT ? 'critical' : $pct >= WARN_PCT ? 'warning' : 'ok';
}

#--- options ---------------------------------------------------------------------

sub options (%raw) {
    my %o = (hours => DEFAULT_HOURS, step => DEFAULT_STEP);
    if (defined $raw{hours}) {
        _fail(usage => '--hours must be a whole number from 1 to ' . MAX_HOURS)
            unless $raw{hours} =~ /\A[1-9][0-9]{0,2}\z/ && $raw{hours} <= MAX_HOURS;
        $o{hours} = $raw{hours} + 0;
    }
    if (defined $raw{step}) {
        _fail(usage => '--step must be a whole number of seconds from ' . MIN_STEP . ' to ' . MAX_STEP)
            unless $raw{step} =~ /\A[1-9][0-9]{0,4}\z/ && $raw{step} >= MIN_STEP && $raw{step} <= MAX_STEP;
        $o{step} = $raw{step} + 0;
    }
    _fail(usage => '--hours / --step gives more than ' . MAX_BUCKETS . ' buckets')
        if ceil($o{hours} * 3600 / $o{step}) > MAX_BUCKETS;
    return \%o;
}

#--- reading ---------------------------------------------------------------------

sub new ($class, %opt) {
    return bless {
        log_dir     => $opt{log_dir} // $ENV{HPS_LOG} // '/srv/hps-log',
        registry    => $opt{registry},
        now         => $opt{now},
        last_window => $opt{last_window},
        domain      => $opt{domain},
        scanned     => 0,
    }, $class;
}

sub log_dir ($self)  { return $self->{log_dir} }
sub _now ($self)     { return $self->{now} // time }
sub registry ($self) { return $self->{registry} //= HPS::Registry->new }

sub domain ($self) {
    $self->{domain} //= eval { $self->registry->cluster_dns_domain } // '';
    return $self->{domain};
}

# own($fqdn): 1 when the host is this cluster's (its domain is exactly ours).
sub own ($self, $fqdn) {
    my $d = $self->domain;
    return 1 unless length $d;
    my ($dom) = lc($fqdn) =~ /\A[^.]+\.(.+)\z/ or return 0;
    return $dom eq $d ? 1 : 0;
}

# source(): (name, [[path, year, month], ...] newest first, parser).
sub source ($self) {
    my $m = $self->log_dir . '/metrics.log';
    if (-f $m) {
        return ('metrics.log', [ [$m] ], sub ($l, @x) {
            my $r = HPS::Log::parse_event($l) or return undef;
            return $r->{event} eq 'metric' ? $r : undef;
        });
    }
    my @files = HPS::Log::_day_files($self->log_dir . '/ips/hps');
    return ('syslog ips/hps', \@files, sub ($l, @ym) {
        my $r = HPS::Log::parse_syslog($l, @ym) or return undef;
        return $r->{tag} eq 'hps' ? $r : undef;
    }) if @files;
    return ('none', [], undef);
}

# _scan($since, $cb): calls $cb->($epoch, $record) for each hps-monitor host
# line of an own host, newest first, until a line is older than $since, $cb
# returns false, or the byte budget is spent. Returns the source name.
sub _scan ($self, $since, $cb) {
    my ($name, $files, $parse) = $self->source;
    my $reader = HPS::Log->new(log_dir => $self->log_dir, max_scan => MAX_SCAN_BYTES);
    my %own;
    for my $f (@$files) {
        my ($path, @ym) = @$f;
        if (@ym && $path =~ /([0-9]{4})-([0-9]{2})-([0-9]{2})\.log\z/) {
            # a day file wholly before $since (a day of margin for time zones)
            my $end = eval { Time::Local::timegm(0, 0, 0, $3, $2 - 1, $1) } // 0;
            last if $end + 2 * 86400 < $since;
        }
        my $more = $reader->_each_line_backwards($path, sub ($line) {
            return 1 if index($line, 'hps-monitor: host=') < 0;
            my $rec = $parse->($line, @ym) or return 1;
            return 0 if $rec->{epoch} < $since;
            my $m = parse_message($rec->{message}) or return 1;
            return 1 unless $own{ $m->{host} } //= $self->own($m->{host});
            return $cb->($rec->{epoch}, $m);
        });
        last unless $more;
    }
    $self->{truncated} = 1 if $reader->{budget_spent};
    return $name;
}

# The hosts: name -> {fqdn, name, mac}; 'all' -> undef (every own host).
sub _hostmap ($self) {
    return $self->{hostmap} if $self->{hostmap};
    my $reg = $self->registry;
    my %m;
    for my $mac (eval { $reg->host_list_all }) {
        my $f = eval { $reg->fqdn($mac) } // next;
        $m{ lc $f } = $mac;
    }
    return $self->{hostmap} = \%m;
}

sub ips_fqdn ($self) { my $d = $self->domain; return length $d ? "ips.$d" : 'ips' }

sub target ($self, $name) {
    _fail(usage => 'needs a MAC, a host name, ips or all') unless defined $name && length $name;
    return undef if $name eq 'all';
    return { fqdn => $self->ips_fqdn, name => 'ips', mac => undef, ips => 1 } if lc $name eq 'ips';
    my $mac = HPS::Log->new(registry => $self->registry)->find_host($name);    # dies notfound
    my $f = eval { $self->registry->fqdn($mac) };
    _fail(notfound => "host $name has no HOSTNAME: hps-monitor has no results for it") unless defined $f;
    return { fqdn => lc $f, name => HPS::Registry::short_name($f), mac => $mac };
}

sub _who ($self, $fqdn) {
    return { host => $fqdn, name => 'ips', mac => undef, ips => JSON::PP::true() } if $fqdn eq $self->ips_fqdn;
    return { host => $fqdn, name => HPS::Registry::short_name($fqdn), mac => $self->_hostmap->{ lc $fqdn } };
}

sub _iso ($e) { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $e) }

# latest($name): {target, source, now, window, hosts => [{host, name, mac, ips?,
# time, epoch, worst, checks => [{check, state, text, epoch, perf}], util,
# compound, level, unreachable?, unreachable_at?}], truncated}. A host's checks
# are those of its newest complete run (the lines before its newest summary
# line); a newer UNREACHABLE or PAIR_FAILED line is given as unreachable.
sub latest ($self, $name) {
    my $t = $self->target($name);
    my $window = $self->{last_window} // do {
        my ($iv) = HPS::Monitor::interval(scalar eval { HPS::ClusterConfig->new(logger => sub { })->get('monitor_interval_seconds') });
        _max(LAST_WINDOW, 3 * ($iv || 0));
    };
    my %h;
    my $newest;
    my $since = 0;
    my $src = $self->_scan(0, sub ($e, $m) {
        if (!defined $newest) { $newest = $e; $since = $e - $window }
        return 0 if $e < $since;
        return 1 if $t && $m->{host} ne $t->{fqdn};
        my $s = $h{ $m->{host} } //= { checks => [], seen => {}, run => 0 };
        if ($m->{kind} eq 'summary') {
            if (!$s->{run}) { @$s{qw(run epoch worst)} = (1, $e, $m->{worst}) }
            elsif ($s->{run} == 1) { $s->{run} = 2 }
        }
        elsif ($m->{kind} eq 'check') {
            if ($s->{run} == 1 && !$s->{seen}{ $m->{check} }++) {
                unshift @{ $s->{checks} }, { check => $m->{check}, state => $m->{state}, text => $m->{text},
                                             epoch => $e, perf => { map { $_ => $m->{perf}{$_}{value} } keys %{ $m->{perf} } } , _r => $m };
            }
        }
        elsif ($m->{kind} eq 'unreachable' || $m->{kind} eq 'pair_failed') {
            $s->{unreachable} //= { text => ($m->{kind} eq 'pair_failed' ? 'PAIR_FAILED ' : '') . $m->{text}, epoch => $e }
                unless $s->{run};
        }
        return 1;
    });
    my @hosts;
    for my $fqdn (sort keys %h) {
        my $s = $h{$fqdn};
        my (%u, %raw);
        for my $c (@{ $s->{checks} }) {
            my ($cu, $cr) = utilisation(delete $c->{_r});
            $u{$_} = _max($u{$_}, $cu->{$_}) for keys %$cu;
            $raw{$_} = $cr->{$_} for keys %$cr;
        }
        my $epoch = _max($s->{epoch}, $s->{unreachable} ? $s->{unreachable}{epoch} : undef);
        my $cmp = compound(\%u);
        push @hosts, {
            %{ $self->_who($fqdn) },
            epoch    => $epoch,
            time     => _iso($epoch),
            worst    => $s->{unreachable} ? 'UNREACHABLE' : $s->{worst} // 'UNKNOWN',
            checks   => $s->{checks},
            util     => \%u,
            raw      => \%raw,
            compound => $cmp,
            level    => level($cmp),
            ($s->{unreachable} ? (unreachable => $s->{unreachable}{text}, unreachable_at => _iso($s->{unreachable}{epoch})) : ()),
        };
    }
    _fail(notfound => "no hps-monitor result for $t->{fqdn} in the newest ${window}s") if $t && !@hosts;
    return {
        target    => $t ? $t->{fqdn} : 'all',
        source    => $src,
        now       => $self->_now,
        newest    => $newest,
        window    => $window,
        hosts     => \@hosts,
        truncated => $self->{truncated} ? JSON::PP::true() : JSON::PP::false(),
    };
}

# _grid($opt): (start, n): n buckets of step seconds, the last holding now.
sub _grid ($self, $opt) {
    my $step = $opt->{step};
    my $n = ceil($opt->{hours} * 3600 / $step);
    my $end = floor($self->_now / $step) * $step;
    return ($end - ($n - 1) * $step, $n);
}

# series($name, %opt): per-bucket utilisation of one host:
#   {target, host, name, mac, source, hours, step, start, t => [bucket starts],
#    util => {resource => [pct|null]}, compound => [...], raw => {name => [...]},
#    units => {raw name => unit}, state => {check => [state|null], _host =>
#    [worst|UNREACHABLE|null]}, current, level, lines, truncated}
# all: {target => all, ..., t, hosts => [{host, name, mac, ips?, compound,
#    current, level}]} (the compound only).
sub series ($self, $name, %raw) {
    my $opt = options(%raw);
    my $t = $self->target($name);
    my ($start, $n) = $self->_grid($opt);
    my $step = $opt->{step};
    my (%util, %rawv, %state, %all, $lines);
    my $put_max = sub ($arr, $b, $v) { $arr->[$b] = $v if defined $v && (!defined $arr->[$b] || $v > $arr->[$b]) };
    my $src = $self->_scan($start, sub ($e, $m) {
        return 1 if $t && $m->{host} ne $t->{fqdn};
        my $b = int(($e - $start) / $step);
        return 1 if $b < 0 || $b >= $n;
        if (!$t) {
            return 1 unless $m->{kind} eq 'check';
            my ($u) = utilisation($m);
            my $c = compound($u);
            $put_max->($all{ $m->{host} } //= [], $b, $c);
            return 1;
        }
        $lines++;
        if ($m->{kind} eq 'check') {
            my ($u, $r) = utilisation($m);
            $put_max->($util{$_} //= [], $b, $u->{$_}) for keys %$u;
            $put_max->($rawv{$_} //= [], $b, $r->{$_}) for keys %$r;
            ($state{ $m->{check} } //= [])->[$b] //= $m->{state};    # newest first: the first seen is the last
        }
        elsif ($m->{kind} eq 'summary') { ($state{_host} //= [])->[$b] //= $m->{worst} }
        elsif ($m->{kind} eq 'unreachable') { ($state{_host} //= [])->[$b] //= 'UNREACHABLE' }
        return 1;
    });
    my $pad = sub ($a) { $#$a = $n - 1; return $a };
    my @t = map { $start + $_ * $step } 0 .. $n - 1;
    my %head = (source => $src, hours => $opt->{hours}, step => $step, start => $start, t => \@t,
                truncated => $self->{truncated} ? JSON::PP::true() : JSON::PP::false());
    my $current = sub ($a) { for (my $i = $#$a; $i >= 0; $i--) { return $a->[$i] if defined $a->[$i] } return undef };
    if (!$t) {
        my @hosts;
        for my $fqdn (sort keys %all) {
            my $c = $pad->($all{$fqdn});
            my $cur = $current->($c);
            push @hosts, { %{ $self->_who($fqdn) }, compound => $c, current => $cur, level => level($cur) };
        }
        return { target => 'all', %head, hosts => \@hosts };
    }
    $pad->($_) for values %util, values %rawv, values %state;
    my @cmp = map { my $i = $_; _max(map { $util{$_} ? $util{$_}[$i] : undef } @COMPOUND) } 0 .. $n - 1;
    my $cur = $current->(\@cmp);
    return {
        target   => $t->{fqdn},
        %{ $self->_who($t->{fqdn}) },
        %head,
        util     => \%util,
        compound => \@cmp,
        in_compound => [ grep { $util{$_} } @COMPOUND ],
        raw      => \%rawv,
        units    => { map { $_ => $RAW_UNIT{$_} } keys %rawv },
        state    => \%state,
        current  => $cur,
        level    => level($cur),
        lines    => $lines // 0,
    };
}

1;
