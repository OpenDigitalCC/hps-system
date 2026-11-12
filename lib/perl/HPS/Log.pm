package HPS::Log;
# Read-only access to the IPS's syslog tree (docs/LOGGING.md), for hps-log.
#
# rsyslog on the IPS (lib/functions.d/create-config-rsyslog.sh) writes
#   <log>/<sender ip>/<YYYY-MM-DD>.log    every remote sender, one dir per address
#   <log>/ips/<YYYY-MM-DD>.log            the IPS's own messages (not a listed service)
# in the format "%TIMESTAMP% %fromhost-ip% [%HOSTNAME%] %syslogtag% %msg%", and
# the lab's collector adds <log>/events.log ("<rfc3339> <event> <host> <tag>
# <msg>", lab/syslog-lab.pl). This module finds the newest lines of a host (all
# the addresses the registry knows for it) or of the IPS, newest last, and
# never returns the text of a line that looks like it carries a secret.
#
# Nothing here writes, and no path is built from caller text: an address is a
# dotted IPv4 and a file name is a date.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(SEEK_SET);
use JSON::PP ();
use Time::Local qw(timegm);
use POSIX qw(strftime);
use HPS::ClusterConfig ();
use HPS::Registry ();

use constant DEFAULT_LINES  => 50;
use constant MAX_LINES      => 500;
use constant MAX_SINCE      => 43200;              # minutes (30 days)
use constant MAX_SCAN_BYTES => 64 * 1024 * 1024;   # per call, over all files
use constant BLOCK          => 65536;

{
    package HPS::Log::Error;
    use feature qw(signatures);
    no warnings 'experimental::signatures';
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

sub _fail ($kind, $msg) { die HPS::Log::Error->new($kind, $msg) }

my %MON = (Jan => 1, Feb => 2, Mar => 3, Apr => 4, May => 5, Jun => 6,
           Jul => 7, Aug => 8, Sep => 9, Oct => 10, Nov => 11, Dec => 12);
my $IP_RE   = qr/\A(?:(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\z/;
my $DAY_RE  = qr/\A([0-9]{4})-([0-9]{2})-([0-9]{2})\.log\z/;
my $WORD_RE = qr/\A[A-Za-z0-9_.,:=@+-]{1,64}\z/;

#--- the secret rule -------------------------------------------------------------
# A line is withheld (its message becomes "[redacted]") when any word of it is a
# secret name by HPS::ClusterConfig::secret_name_re (secret, passw, token,
# credential, psk, private, key as a word or _key_ part), or it holds a PEM
# block marker, an operator token (hpsop_...), or a run of 64 or more hex
# digits (a raw key, as the keysafe hands them out). Words are the runs of
# A-Z a-z 0-9 _ (so "api_key=..." and "ssh_key" match, "keys" and "monkey" do not).
my $SECRET_NAME_RE = HPS::ClusterConfig::secret_name_re();

sub is_secret ($text) {
    return 0 unless defined $text && length $text;
    return 1 if $text =~ /-----BEGIN [A-Z0-9 ]+-----/;
    return 1 if $text =~ /hpsop_[0-9A-Za-z]/;
    return 1 if $text =~ /[0-9A-Fa-f]{64}/;
    for my $w (split /[^A-Za-z0-9_]+/, $text) {
        return 1 if length $w && $w =~ $SECRET_NAME_RE;
    }
    return 0;
}

#--- levels -------------------------------------------------------------------------
# The files keep no syslog priority, so the level is read from the text (and from
# the event column of events.log): error, warning or info. A word after "0 " or
# before "=0" ("0 failed", "fail=0") is a count, not an error.
my $ERR_RE  = qr/(?:(?<!\b0 )\b(?:error|err|fail|failed|failure|fatal|critical|crit|emerg|alert|segfault|denied|refused|unreachable)\b(?!=0\b)|kernel panic|no space left|out of memory|state=(?:CRITICAL|UNKNOWN|UNREACHABLE))/i;
my $WARN_RE = qr/(?:(?<!\b0 )\b(?:warn|warning|degraded|timeout|retrying)\b(?!=0\b)|timed out|state=WARNING)/i;

sub level ($message, $event = '') {
    $event //= '';
    return 'error'   if $event eq 'error' || $message =~ $ERR_RE;
    return 'warning' if $event eq 'warning' || $message =~ $WARN_RE;
    return 'info';
}

#--- line parsing -----------------------------------------------------------------------

sub _iso ($epoch) { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $epoch) }

# _split_tag($rest): (tag, message) from "%syslogtag% %msg%"; the tag loses its
# trailing ":" and "[pid]".
sub _split_tag ($rest) {
    my ($tag, $msg) = $rest =~ /\A(\S+)\s?(.*)\z/s ? ($1, $2) : ('', $rest);
    $tag =~ s/:\z//;
    $tag =~ s/\[[0-9]+\]\z//;
    $msg =~ s/\A\s+//;
    $msg =~ s/#033\[[0-9;]*[A-Za-z]//g;    # terminal colours, as rsyslog escapes them
    return ($tag, $msg);
}

# parse_syslog($line, $y, $m): one line of a <date>.log file of year $y, month $m
# (from its file name); undef when it is not in the HPS format. RFC 3164 time
# has no year: a December line in a January file is the year before.
sub parse_syslog ($line, $fy, $fm) {
    my ($mon, $d, $hh, $mm, $ss, $ip, $host, $rest) =
        $line =~ /\A([A-Z][a-z]{2}) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) (\S+) \[([^\]]*)\] ?(.*)\z/s
        or return undef;
    my $m = $MON{$mon} or return undef;
    my $y = $fy;
    $y-- if $m == 12 && $fm == 1;
    my $t = eval { timegm($ss, $mm, $hh, $d, $m - 1, $y) };
    return undef unless defined $t;
    my ($tag, $msg) = _split_tag($rest);
    return { epoch => $t, from => $ip, host => $host, tag => $tag, message => $msg, event => '' };
}

# parse_event($line): one line of events.log; undef when not in its format.
sub parse_event ($line) {
    my ($y, $mo, $d, $hh, $mm, $ss, $tz, $ev, $host, $rest) =
        $line =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2}) (\S+) (\S+) ?(.*)\z/s
        or return undef;
    my $t = eval { timegm($ss, $mm, $hh, $d, $mo - 1, $y) };
    return undef unless defined $t;
    if ($tz =~ /\A([+-])([0-9]{2}):([0-9]{2})\z/) {
        my $off = ($2 * 3600 + $3 * 60) * ($1 eq '+' ? 1 : -1);
        $t -= $off;
    }
    my ($tag, $msg) = _split_tag($rest);
    return { epoch => $t, from => '', host => $host, tag => $tag, message => $msg, event => $ev };
}

#--- reading ---------------------------------------------------------------------------

sub new ($class, %opt) {
    my $self = bless {
        log_dir  => $opt{log_dir} // $ENV{HPS_LOG} // '/srv/hps-log',
        registry => $opt{registry},
        now      => $opt{now},
        scanned  => 0,
    }, $class;
    return $self;
}

sub log_dir ($self) { return $self->{log_dir} }
sub _now ($self)    { return $self->{now} // time }
sub registry ($self) { return $self->{registry} //= HPS::Registry->new }

# _day_files($dir): [path, year, month] of the <date>.log files, newest first.
sub _day_files ($dir) {
    opendir(my $dh, $dir) or return ();
    my @f;
    for my $n (readdir $dh) {
        my @ymd = $n =~ $DAY_RE or next;
        next unless -f "$dir/$n";
        push @f, [ "$dir/$n", $ymd[0] + 0, $ymd[1] + 0, "$ymd[0]$ymd[1]$ymd[2]" ];
    }
    closedir $dh;
    return map { [ @$_[0 .. 2] ] } sort { $b->[3] cmp $a->[3] } @f;
}

# _each_line_backwards($file, $cb): calls $cb->($line) for each line, last line
# first, until $cb returns false or the call's byte budget is spent. Returns
# false when it stopped early (the caller stops reading older files too).
sub _each_line_backwards ($self, $file, $cb) {
    open(my $fh, '<:raw', $file) or return 1;
    my $pos = -s $fh // 0;
    my $tail = '';
    while ($pos > 0) {
        if ($self->{scanned} >= MAX_SCAN_BYTES) { $self->{budget_spent} = 1; close $fh; return 0 }
        my $len = $pos < BLOCK ? $pos : BLOCK;
        $pos -= $len;
        seek($fh, $pos, SEEK_SET) or last;
        my $got = read($fh, my $buf, $len) // 0;
        $self->{scanned} += $got;
        $buf .= $tail;
        my @lines = split /\n/, $buf, -1;
        $tail = $pos > 0 ? shift @lines : '';
        for my $l (reverse @lines) {
            next unless length $l;
            unless ($cb->($l)) { close $fh; return 0 }
        }
    }
    close $fh;
    return 1;
}

# _entry($rec, $source): the record as the caller sees it, redacted.
sub _entry ($rec, $source) {
    my $raw = join ' ', $rec->{host}, $rec->{tag}, $rec->{message};
    my %e = (time => _iso($rec->{epoch}), epoch => $rec->{epoch}, host => $rec->{host},
             tag => $rec->{tag}, source => $source);
    if (is_secret($raw)) {
        $e{tag}      = '[redacted]' if is_secret($rec->{tag});
        $e{message}  = '[redacted]';
        $e{level}    = 'info';
        $e{redacted} = JSON::PP::true();
    } else {
        $e{message} = $rec->{message};
        $e{level}   = level($rec->{message}, $rec->{event});
    }
    return \%e;
}

sub _matches ($e, $opt) {
    return 1 unless defined $opt->{grep};
    my $w = lc $opt->{grep};
    return index(lc("$e->{host} $e->{tag} $e->{message}"), $w) >= 0 ? 1 : 0;
}

# _collect($files, $parse, $source, $opt, $keep): the newest $opt->{lines}
# entries of one source (its files newest first) that pass $keep and the
# filters, newest first.
sub _collect ($self, $files, $parse, $source, $opt, $keep = undef) {
    my @out;
    my $cutoff = defined $opt->{since} ? $self->_now - $opt->{since} * 60 : undef;
    for my $f (@$files) {
        my ($path, @ym) = @$f;
        my $more = $self->_each_line_backwards($path, sub ($line) {
            my $rec = $parse->($line, @ym) or return 1;
            return 0 if defined $cutoff && $rec->{epoch} < $cutoff;
            return 1 if $keep && !$keep->($rec);
            my $e = _entry($rec, $source);
            push @out, $e if _matches($e, $opt);
            return @out < $opt->{lines};
        });
        last unless $more;
    }
    return @out;
}

# _merge(@lists): one list, oldest first, the newest $n kept. Equal times keep
# each source's own order.
sub _merge ($n, @lists) {
    my @all;
    for my $i (0 .. $#lists) {
        my $list = $lists[$i];
        my $k = 0;
        push @all, map { [ $_, $i, $k++ ] } reverse @$list;    # oldest first per source
    }
    @all = sort { $a->[0]{epoch} <=> $b->[0]{epoch} || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @all;
    splice(@all, 0, @all - $n) if @all > $n;
    return map { $_->[0] } @all;
}

# options(%raw): checked {lines, since, grep}; dies (usage) naming the bad one.
sub options (%raw) {
    my %o = (lines => DEFAULT_LINES);
    if (defined $raw{lines}) {
        _fail(usage => "--lines must be a whole number from 1 to " . MAX_LINES)
            unless $raw{lines} =~ /\A[1-9][0-9]{0,3}\z/ && $raw{lines} <= MAX_LINES;
        $o{lines} = $raw{lines} + 0;
    }
    if (defined $raw{since}) {
        _fail(usage => "--since must be a whole number of minutes from 1 to " . MAX_SINCE)
            unless $raw{since} =~ /\A[1-9][0-9]{0,5}\z/ && $raw{since} <= MAX_SINCE;
        $o{since} = $raw{since} + 0;
    }
    if (defined $raw{grep}) {
        _fail(usage => '--grep takes one word: 1 to 64 of A-Z a-z 0-9 _ . , : = @ + -')
            unless $raw{grep} =~ $WORD_RE;
        $o{grep} = $raw{grep};
    }
    return \%o;
}

#--- hosts -------------------------------------------------------------------------------

# find_host($name): the host key (12-hex MAC) of a MAC in any form, a registry
# HOSTNAME or an FQDN; dies (notfound) when no host matches.
sub find_host ($self, $name) {
    my $reg = $self->registry;
    _fail(usage => 'host needs a MAC or a host name') unless defined $name && length $name;
    my $mac = eval { HPS::Registry::normalise_mac($name) };
    if (defined $mac) {
        my $k = $reg->resolve_mac($mac);
        return $k if $reg->host_exists($k);
        _fail(notfound => "no host with MAC $name");
    }
    my $want = HPS::Registry::short_name($name);
    for my $k (sort $reg->host_list_all) {
        my $h = eval { $reg->host_get($k, 'HOSTNAME') };
        return $k if defined $h && HPS::Registry::short_name($h) eq $want;
    }
    _fail(notfound => "no host named $name");
}

# host_addresses($mac): the addresses the host has sent syslog from: its
# current IP first, then each IPv4 address its stored audit (audit.json, the
# audit boot's `ip addr`) recorded, loopback left out, no repeats.
sub host_addresses ($self, $mac) {
    my $reg = $self->registry;
    my @out;
    my $add = sub ($ip) {
        return unless defined $ip && !ref $ip;
        $ip =~ s/\A"|"\z//g;
        return unless $ip =~ $IP_RE && $ip !~ /\A127\./;
        push @out, $ip unless grep { $_ eq $ip } @out;
    };
    $add->(scalar eval { $reg->host_get($mac, 'IP') });
    my $audit = eval { $reg->host_exists($mac, 'audit') ? $reg->host_get_json($mac, 'audit') : undef };
    if (ref $audit eq 'HASH' && ref $audit->{net} eq 'HASH' && ref $audit->{net}{addr} eq 'ARRAY') {
        for my $if (@{ $audit->{net}{addr} }) {
            next unless ref $if eq 'HASH' && ref $if->{addr_info} eq 'ARRAY';
            for my $a (@{ $if->{addr_info} }) {
                next unless ref $a eq 'HASH' && ($a->{family} // 'inet') eq 'inet';
                $add->($a->{local});
            }
        }
    }
    return @out;
}

# host_log($name, %opt): {target, host, mac, addresses, sources, lines, count,
# redacted, truncated}. lines: [{time, epoch, host, tag, message, level,
# source, redacted?}], oldest first, at most $opt{lines}.
sub host_log ($self, $name, %raw) {
    my $opt  = options(%raw);
    my $mac  = $self->find_host($name);
    my $reg  = $self->registry;
    my $hn   = eval { $reg->host_get($mac, 'HOSTNAME') } // '';
    my @addr = $self->host_addresses($mac);
    my (@lists, @sources);
    for my $ip (@addr) {
        my $dir = $self->log_dir . "/$ip";
        my @files = _day_files($dir);
        next unless @files;
        push @sources, $ip;
        push @lists, [ $self->_collect(\@files, \&parse_syslog, $ip, $opt) ];
    }
    return $self->_result({ target => 'host', host => $hn, mac => $mac, addresses => \@addr }, \@sources, $opt, @lists);
}

# ips_log(%opt): the IPS's own lines: ips/<date>.log (rsyslogd, OpenSVC, the
# auth hook: everything local that is not a listed service), ips/hps/<date>.log
# (hps_log: the CGI, API scripts and tools), and the events.log lines whose host
# is "ips". Left out: hps-monitor's results (a line per check per node every
# tick; metrics.log keeps them), and the events.log lines tagged hps, which are
# copies of ips/hps lines.
sub _not_monitor ($r) { return $r->{message} !~ /\Ahps-monitor: (?:host=|tick )/ }

sub ips_log ($self, %raw) {
    my $opt = options(%raw);
    my (@lists, @sources);
    for my $src ([ 'ips', '/ips' ], [ 'ips/hps', '/ips/hps' ]) {
        my @files = _day_files($self->log_dir . $src->[1]);
        next unless @files;
        push @sources, $src->[0];
        push @lists, [ $self->_collect(\@files, \&parse_syslog, $src->[0], $opt, \&_not_monitor) ];
    }
    my $ev = $self->log_dir . '/events.log';
    if (-f $ev) {
        push @sources, 'events';
        push @lists, [ $self->_collect([ [$ev] ], sub ($l, @x) { parse_event($l) }, 'events', $opt,
            sub ($r) { $r->{host} eq 'ips' && $r->{event} ne 'metric' && $r->{tag} ne 'hps' && _not_monitor($r) }) ];
    }
    return $self->_result({ target => 'ips', host => 'ips', addresses => [] }, \@sources, $opt, @lists);
}

sub _result ($self, $head, $sources, $opt, @lists) {
    my @lines = _merge($opt->{lines}, @lists);
    return {
        %$head,
        sources   => $sources,
        lines     => \@lines,
        count     => scalar @lines,
        redacted  => scalar(grep { $_->{redacted} } @lines),
        truncated => $self->{budget_spent} ? JSON::PP::true() : JSON::PP::false(),
        limit     => $opt->{lines},
        (defined $opt->{since} ? (since_minutes => $opt->{since}) : ()),
        (defined $opt->{grep}  ? (grep => $opt->{grep}) : ()),
    };
}

1;
