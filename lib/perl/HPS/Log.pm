package HPS::Log;
# Read-only access to the IPS's syslog tree (docs/LOGGING.md), for hps-log.
#
# rsyslog on the IPS (lib/functions.d/create-config-rsyslog.sh) writes
#   <log>/<sender ip>/<YYYY-MM-DD>.log    every remote sender, one dir per address
#   <log>/ips/<YYYY-MM-DD>.log            the IPS's own messages (not a listed service)
# in the format "%TIMESTAMP% %fromhost-ip% [%HOSTNAME%] %syslogtag% %msg%", and
# three views beside that tree: <log>/events.log (the event lines, HPS::Event),
# <log>/audit.log (ctrl-exec and operator-call records) and <log>/metrics.log
# (hps-monitor's results). hps-log-rotate renames a view to <name>-<date>.log
# each day and compresses older files (.gz); every read here follows the
# rotated and compressed files. This module finds the newest lines of a host
# (all the addresses the registry knows for it), of the IPS, of the events or
# of the audit view, newest last, answers "is anything wrong" from the events
# (attention), and never returns the text of a line that looks like it carries
# a secret.
#
# Nothing here writes, and no path is built from caller text: an address is a
# dotted IPv4 and a file name is a date.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(SEEK_SET);
use JSON::PP ();
use List::Util ();
use Time::Local qw(timegm);
use POSIX qw(strftime);
use HPS::ClusterConfig ();
use HPS::Event ();
use HPS::Registry ();

use constant DEFAULT_LINES  => 50;
use constant MAX_LINES      => 500;
use constant MAX_SINCE      => 43200;              # minutes (30 days)
use constant MAX_SCAN_BYTES => 64 * 1024 * 1024;   # per source (a host address, ips/, ips/hps/, a view), over its files
use constant BLOCK          => 65536;
use constant GZ_WINDOW      => 64 * 1024 * 1024;   # of a .gz file, the newest bytes kept in memory
use constant ATTENTION_SINCE => 60;                # minutes: longer than the emitters' reminder (50 min)
use constant ATTENTION_ROWS  => 20;                # problems listed (a screenful)

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
my $DAY_RE  = qr/\A([0-9]{4})-([0-9]{2})-([0-9]{2})\.log(\.gz)?\z/;
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
    if (my $ev = HPS::Event::parse($message)) {    # an event line says its own priority
        return $ev->{pri} eq 'urgent' ? 'error' : $ev->{pri} eq 'warning' ? 'warning' : 'info';
    }
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

# _rfc3339($line): (epoch, rest of the line) of a line that starts with an
# RFC 3339 time; () when it does not.
sub _rfc3339 ($line) {
    my ($y, $mo, $d, $hh, $mm, $ss, $tz, $rest) =
        $line =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2}) (.*)\z/s
        or return ();
    my $t = eval { timegm($ss, $mm, $hh, $d, $mo - 1, $y) };
    return () unless defined $t;
    if ($tz =~ /\A([+-])([0-9]{2}):([0-9]{2})\z/) {
        my $off = ($2 * 3600 + $3 * 60) * ($1 eq '+' ? 1 : -1);
        $t -= $off;
    }
    return ($t, $rest);
}

# The event words of the lab collector's old events.log and metrics.log
# ("<rfc3339> <event> <host> <tag> <msg>", lab/syslog-lab.pl). metrics.log keeps
# that form (event "metric").
my %LAB_EVENT = map { $_ => 1 } qw(dhcp ipxe boot up init pair held job bmc node storage down off metric error);

# parse_event($line): one line of events.log or metrics.log; undef when in
# neither form. An event line (docs/LOGGING.md) is
#   <rfc3339> <host> HPS-EVENT|HPS-ALERT pri= kind= subject= state= <text>
# and gives event "event", ev (HPS::Event::parse), message (the line from its
# marker on) and tag (of a line rsyslog derived: the tag of the line it was
# derived from, the first word of the text). A line of the lab collector's old
# form gives its event word, and never ev.
sub parse_event ($line) {
    my ($t, $rest) = _rfc3339($line) or return undef;
    my ($w1, $after) = $rest =~ /\A(\S+) ?(.*)\z/s or return undef;
    if ($LAB_EVENT{$w1}) {
        my ($host, $body) = $after =~ /\A(\S+) ?(.*)\z/s or return undef;
        my ($tag, $msg) = _split_tag($body);
        return { epoch => $t, from => '', host => $host, tag => $tag, message => $msg, event => $w1 };
    }
    my $at = index($after, 'HPS-');
    return undef if $at < 0;
    my $msg = substr($after, $at);
    $msg =~ s/#033\[[0-9;]*[A-Za-z]//g;
    my $ev = HPS::Event::parse($msg) or return undef;
    my $tag = $ev->{text} =~ /\A(\S+?)(?:\[[0-9]+\])?: / ? $1 : '';
    return { epoch => $t, from => '', host => $w1, tag => $tag, message => $msg, event => 'event', ev => $ev };
}

# parse_audit($line): one line of audit.log
# ("<rfc3339> <sender ip> [<host>] <tag> <msg>"); undef when not in its form.
sub parse_audit ($line) {
    my ($t, $rest) = _rfc3339($line) or return undef;
    my ($ip, $host, $body) = $rest =~ /\A(\S+) \[([^\]]*)\] ?(.*)\z/s or return undef;
    my ($tag, $msg) = _split_tag($body);
    return { epoch => $t, from => $ip, host => $host, tag => $tag, message => $msg, event => '' };
}

#--- reading ---------------------------------------------------------------------------

sub new ($class, %opt) {
    my $self = bless {
        log_dir  => $opt{log_dir} // $ENV{HPS_LOG} // '/srv/hps-log',
        registry => $opt{registry},
        now      => $opt{now},
        max_scan => $opt{max_scan} // MAX_SCAN_BYTES,    # bytes per call (HPS::Metrics reads more)
        scanned  => 0,
        gz_window => $opt{gz_window},
        (exists $opt{domain} ? (domain => $opt{domain}) : ()),    # tests: network_dns_domain, or undef for unreadable
    }, $class;
    return $self;
}

sub log_dir ($self) { return $self->{log_dir} }
sub _now ($self)    { return $self->{now} // time }
sub registry ($self) { return $self->{registry} //= HPS::Registry->new }

#--- whose lines ------------------------------------------------------------------------
# The event, audit and metrics views hold this cluster's lines (rsyslog gates them: lib/functions.d/
# create-config-rsyslog.sh, docs/LOGGING.md "Whose lines"): this IPS, and hosts named as the cluster
# names them, a single label or <label>.<network_dns_domain>. A line another cluster's IPS forwarded
# here has the host name <prefix>.<hostname>. Older files may still hold such lines, and the reader
# leaves them out of attention, events and audit.

# own_host($host, $domain): true when a line of that host name is this cluster's. $domain undef
# (the registry cannot be read): cannot tell, so the line is kept, never hidden on a guess.
sub own_host ($host, $domain) {
    return 1 unless defined $domain;
    my $h = lc($host // '');
    return 1 unless $h =~ /\./;
    return length($domain) && $h =~ /\A[a-z0-9_-]+\.\Q$domain\E\z/ ? 1 : 0;
}

# _domain(): network_dns_domain of the active cluster, lower case; '' when it is unset; undef when
# it cannot be read. Given with new(domain => ...) in tests.
sub _domain ($self) {
    return $self->{domain} if exists $self->{domain};
    my $d = eval { lc($self->registry->cluster_dns_domain // '') };
    return $self->{domain} = defined $d ? $d : undef;
}

# _own_keep(): the $keep callback of _collect for a view: this cluster's lines only.
sub _own_keep ($self) {
    my $dom = $self->_domain;
    return sub ($rec) { return own_host($rec->{host}, $dom) };
}

# _day_files($dir): [path, year, month] of the <date>.log and <date>.log.gz
# files, newest first. Of a day that has both (hps-log-rotate is compressing
# it) the plain file is taken.
sub _day_files ($dir) {
    opendir(my $dh, $dir) or return ();
    my %f;
    for my $n (readdir $dh) {
        my @ymd = $n =~ $DAY_RE or next;
        next unless -f "$dir/$n";
        my $day = "$ymd[0]$ymd[1]$ymd[2]";
        next if $f{$day} && $ymd[3];    # the plain file is already there
        $f{$day} = [ "$dir/$n", $ymd[0] + 0, $ymd[1] + 0 ];
    }
    closedir $dh;
    return map { $f{$_} } sort { $b cmp $a } keys %f;
}

# view_files($log_dir, $name): [path] of a view (events, audit, metrics),
# newest first: <name>.log, then the rotated <name>-<date>[.<n>].log[.gz]
# (hps-log-rotate). Of a rotated file that is there plain and compressed the
# plain one is taken.
sub view_files ($log_dir, $name) {
    my @out;
    push @out, ["$log_dir/$name.log"] if -f "$log_dir/$name.log";
    opendir(my $dh, $log_dir) or return @out;
    my %f;
    for my $n (readdir $dh) {
        my ($y, $m, $d, $seq, $gz) = $n =~ /\A\Q$name\E-([0-9]{4})-([0-9]{2})-([0-9]{2})(?:\.([0-9]{1,3}))?\.log(\.gz)?\z/ or next;
        next unless -f "$log_dir/$n";
        my $k = sprintf '%s%s%s.%03d', $y, $m, $d, $seq // 0;
        next if $f{$k} && $gz;
        $f{$k} = "$log_dir/$n";
    }
    closedir $dh;
    push @out, map { [ $f{$_} ] } sort { $b cmp $a } keys %f;
    return @out;
}

# _each_line_backwards($file, $cb, $needle, $epoch_of): calls $cb->($line) for each line,
# last line first, until $cb returns false or the byte budget is spent. Returns false when
# it stopped early (the caller stops reading older files too).
# $needle (lower case): a block that holds no such text has no line that can match, so its
# lines are not split or parsed (a grep over a day file of many MiB); of such a block
# $epoch_of->($line) reads the time of one line, so that the caller can say how far back the
# scan got. The caller leaves it out when it stops at a time (--since).
sub _each_line_backwards ($self, $file, $cb, $needle = undef, $epoch_of = undef) {
    return $self->_each_line_backwards_gz($file, $cb) if $file =~ /\.gz\z/;
    my $fh;
    unless (open($fh, '<:raw', $file)) {
        push @{ $self->{unreadable} }, $file if -e $file;    # there, and not readable: said, never "no lines"
        return 1;
    }
    my $pos = -s $fh // 0;
    my $tail = '';
    while ($pos > 0) {
        if ($self->{scanned} >= $self->{max_scan}) { $self->{budget_spent} = 1; close $fh; return 0 }
        my $len = $pos < BLOCK ? $pos : BLOCK;
        $pos -= $len;
        seek($fh, $pos, SEEK_SET) or last;
        my $got = read($fh, my $buf, $len) // 0;
        $self->{scanned} += $got;
        $buf .= $tail;
        if (defined $needle && index(lc $buf, $needle) < 0) {
            # no line of this block can match: only the cut first line goes on to the next block
            my $nl = index($buf, "\n");
            if ($nl >= 0 && $epoch_of) {
                my $end = index($buf, "\n", $nl + 1);
                my $e = $epoch_of->($end >= 0 ? substr($buf, $nl + 1, $end - $nl - 1) : substr($buf, $nl + 1));
                $self->{back_epoch} = $e if defined $e;
            }
            $tail = $pos > 0 ? ($nl >= 0 ? substr($buf, 0, $nl) : $buf) : '';
            next;
        }
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

# _each_line_backwards_gz($file, $cb): the same for a compressed file. gzip has
# no way to read from the end, so the file is read through once and its newest
# bytes are kept (what is left of the call's budget, at most GZ_WINDOW); when
# the file holds more, its older lines are not read and the call is truncated.
sub _each_line_backwards_gz ($self, $file, $cb) {
    my $left = $self->{max_scan} - $self->{scanned};
    if ($left <= 0) { $self->{budget_spent} = 1; return 0 }
    my $cap = $self->{gz_window} // GZ_WINDOW;
    my $window = $left < $cap ? $left : $cap;
    require IO::Uncompress::Gunzip;
    my $z = IO::Uncompress::Gunzip->new($file, MultiStream => 1, Transparent => 0);
    unless ($z) {
        push @{ $self->{unreadable} }, $file if -e $file;
        return 1;
    }
    my (@chunks, $dropped);
    my $kept = 0;
    while (1) {
        my $got = $z->read(my $buf, BLOCK);
        if (!defined $got || $got < 0) {    # a damaged file: what was read stands, and it is said
            push @{ $self->{unreadable} }, $file;
            last;
        }
        last if $got == 0;
        push @chunks, $buf;
        $kept += $got;
        while (@chunks > 1 && $kept - length($chunks[0]) >= $window) {
            $kept -= length(shift @chunks);
            $dropped = 1;
        }
    }
    $z->close;
    my $text = join '', @chunks;
    @chunks = ();
    if (length $text > $window) { $text = substr($text, -$window); $dropped = 1 }
    $self->{scanned} += length $text;
    my @lines = split /\n/, $text, -1;
    shift @lines if $dropped;    # the first kept line may be cut
    for my $l (reverse @lines) {
        next unless length $l;
        return 0 unless $cb->($l);
    }
    if ($dropped) { $self->{budget_spent} = 1; return 0 }
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
        if (my $ev = $rec->{ev}) {    # an event line: its fields, for the compact view and --json
            @e{qw(pri kind subject state)} = @$ev{qw(pri kind subject state)};
            $e{text} = $ev->{text};
        }
    }
    return \%e;
}

# --min-level: a line passes at its level or worse. A redacted line is info (its
# text, and so its level, is withheld), so a filtered read never shows one.
my %RANK = (info => 0, warning => 1, error => 2);

sub _matches ($e, $opt) {
    return 0 if defined $opt->{min_level} && $RANK{ $e->{level} } < $RANK{ $opt->{min_level} };
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
    # One byte budget per source: the big day file of one source (the IPS's own lines) must
    # not use up the budget the others (the DHCP leases) are searched with.
    @$self{qw(scanned budget_spent back_epoch)} = (0, 0, undef);
    # The word is looked for in the block first, unless it could match the redaction marker
    # (--grep is matched after redaction, so "redacted" finds lines whose text is withheld).
    my $needle = defined $opt->{grep} && !defined $cutoff && index('[redacted]', lc $opt->{grep}) < 0 ? lc $opt->{grep} : undef;
    for my $f (@$files) {
        my ($path, @ym) = @$f;
        my $more = $self->_each_line_backwards($path, sub ($line) {
            my $rec = $parse->($line, @ym) or return 1;
            $self->{back_epoch} = $rec->{epoch};
            return 0 if defined $cutoff && $rec->{epoch} < $cutoff;
            return 1 if $keep && !$keep->($rec);
            my $e = _entry($rec, $source);
            push @out, $e if _matches($e, $opt);
            return @out < $opt->{lines};
        }, $needle, sub ($line) { my $r = $parse->($line, @ym); return $r ? $r->{epoch} : undef });
        last unless $more;
    }
    # Stopped for want of budget before N lines were found: remember how far back it got.
    push @{ $self->{truncated_at} }, ($self->{back_epoch} // $self->_now) if $self->{budget_spent};
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

# options(%raw): checked {lines, since, grep, min_level}; dies (usage) naming the bad one.
sub options (%raw) {
    my %o = (lines => DEFAULT_LINES);
    if (defined $raw{lines}) {
        _fail(usage => "--lines must be a whole number from 1 to " . MAX_LINES)
            unless $raw{lines} =~ /\A[1-9][0-9]{0,3}\z/ && $raw{lines} <= MAX_LINES;
        $o{lines} = $raw{lines} + 0;
    }
    if (defined $raw{since}) {
        my ($n, $u) = $raw{since} =~ /\A([1-9][0-9]{0,5})([mhd]?)\z/ ? ($1, $2) : (0, '');
        my $min = $n * ($u eq 'd' ? 1440 : $u eq 'h' ? 60 : 1);
        _fail(usage => "--since must be a number of minutes from 1 to " . MAX_SINCE . ", or a number with m, h or d (1h, 2d)")
            unless $n && $min <= MAX_SINCE;
        $o{since} = $min;
    }
    if (defined $raw{grep}) {
        _fail(usage => '--grep takes one word: 1 to 64 of A-Z a-z 0-9 _ . , : = @ + -')
            unless $raw{grep} =~ $WORD_RE;
        $o{grep} = $raw{grep};
    }
    if (defined $raw{min_level}) {
        _fail(usage => '--min-level must be warning or error')
            unless $raw{min_level} =~ /\A(?:warning|error)\z/;
        $o{min_level} = $raw{min_level};
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

# ips_log(%opt): the IPS's own lines: ips/<date>.log (rsyslogd, OpenSVC: every
# local program that has no file of its own), ips/hps/<date>.log (hps_log: the
# CGI, API scripts and tools) and ips/dnsmasq-dhcp/<date>.log (the DHCP leases
# the browser greps for). Left out: hps-monitor's results (a line per check per
# node every tick; metrics.log keeps them). The events and the audit records
# are their own verbs (events_log, audit_log).
sub _not_monitor ($r) { return $r->{message} !~ /\Ahps-monitor: (?:host=|tick )/ }

sub ips_log ($self, %raw) {
    my $opt = options(%raw);
    my (@lists, @sources);
    for my $src ([ 'ips', '/ips' ], [ 'ips/hps', '/ips/hps' ], [ 'ips/dnsmasq-dhcp', '/ips/dnsmasq-dhcp' ]) {
        my @files = _day_files($self->log_dir . $src->[1]);
        next unless @files;
        push @sources, $src->[0];
        push @lists, [ $self->_collect(\@files, \&parse_syslog, $src->[0], $opt, \&_not_monitor) ];
    }
    return $self->_result({ target => 'ips', host => 'ips', addresses => [] }, \@sources, $opt, @lists);
}

# _view_log($name, $parse, %opt): the newest lines of a view (events, audit).
sub _view_log ($self, $name, $parse, %raw) {
    my $opt   = options(%raw);
    my @files = view_files($self->log_dir, $name);
    my @lists = @files ? ([ $self->_collect(\@files, sub ($l, @x) { $parse->($l) }, $name, $opt, $self->_own_keep) ]) : ();
    my $r = $self->_result({ target => $name, host => $name, addresses => [] }, [ @files ? $name : () ], $opt, @lists);
    $r->{unreadable} = [ @{ $self->{unreadable} // [] } ];
    return $r;
}

# events_log(%opt): the event lines (HPS-EVENT, HPS-ALERT) of events.log and its
# rotated files, newest last.
sub events_log ($self, %raw) { return $self->_view_log('events', \&parse_event, %raw) }

# audit_log(%opt): the audit records of audit.log and its rotated files.
sub audit_log ($self, %raw) { return $self->_view_log('audit', \&parse_audit, %raw) }

#--- attention ----------------------------------------------------------------------------

# attention(since => 1h|minutes): is anything wrong, from the events view alone.
# The newest event line of each (kind, subject) decides: a line whose priority
# needs attention and whose state is not a clearing one (docs/LOGGING.md) is an
# open problem; a later line of the same kind and subject that does not need
# attention (resolved, ok, an info or notice line) closes it. Emitters repeat a
# standing problem every HPS::Event::REMIND seconds, so one hour holds it.
# Returns {status, window_minutes, events, counts => {urgent, warning},
# problems => [{pri, kind, subject, state, time, first, host, text, lines}],
# more, newest, reason?}. status is
#   clear       the file was read, has lines in the window, none open a problem
#   attention   at least one problem
#   absent      no events.log (nor a rotated file)
#   empty       it exists and holds no line at all
#   unreadable  a file could not be opened or decompressed
#   silent      readable, but no event line in the window (the emitters repeat
#               a heartbeat, so something is not running)
# Never "clear" when the answer could not be read.
sub attention ($self, %raw) {
    my $since = defined $raw{since} ? options(since => $raw{since})->{since} : ATTENTION_SINCE;
    my $now   = $self->_now;
    my $cutoff = $now - $since * 60;
    my %r = (window_minutes => $since, events => 0, counts => { urgent => 0, warning => 0 },
             problems => [], more => 0, newest => undef);
    my @files = view_files($self->log_dir, 'events');
    unless (@files) { $r{status} = 'absent'; $r{reason} = 'no events.log in ' . $self->log_dir; return \%r }
    my $bytes = 0;
    $bytes += (-s $_->[0]) // 0 for @files;
    $self->{unreadable} = [];
    my $dom = $self->_domain;
    my (%seen, @order);
    for my $f (@files) {
        my $more = $self->_each_line_backwards($f->[0], sub ($line) {
            my $rec = parse_event($line) or return 1;
            return 0 if $rec->{epoch} < $cutoff;
            return 1 unless own_host($rec->{host}, $dom);    # another cluster's line, forwarded here
            $r{events}++;
            $r{newest} //= _iso($rec->{epoch});
            my $ev = $rec->{ev} or return 1;
            my $key = "$ev->{kind} $ev->{subject}";
            my $p = $seen{$key};
            my $open = $ev->{attention} && $ev->{class} ne 'clearing';
            if (!$p) {
                $p = $seen{$key} = { open => $open, closed => !$open };
                if ($open) {
                    push @order, $key;
                    @$p{qw(pri kind subject state host epoch first text lines)} =
                        ($ev->{pri}, $ev->{kind}, $ev->{subject}, $ev->{state}, $rec->{host}, $rec->{epoch}, $rec->{epoch}, $ev->{text}, 1);
                }
            } elsif ($p->{open} && !$p->{closed}) {
                if ($open) { $p->{first} = $rec->{epoch}; $p->{lines}++ }
                else       { $p->{closed} = 1 }    # an older line that was fine: the run started after it
            }
            return 1;
        });
        last unless $more;
    }
    if (@{ $self->{unreadable} }) {
        $r{status} = 'unreadable';
        $r{reason} = 'cannot read ' . join(', ', map { s{.*/}{}r } @{ $self->{unreadable} });
        return \%r;
    }
    if (!$bytes)         { $r{status} = 'empty';  $r{reason} = 'events.log holds no lines'; return \%r }
    if (!$r{events})     { $r{status} = 'silent'; $r{reason} = "no event line in the last $since minutes"; return \%r }
    my @open = sort { HPS::Event::rank($b->{pri}) <=> HPS::Event::rank($a->{pri}) || $b->{epoch} <=> $a->{epoch} || $a->{kind} cmp $b->{kind} || $a->{subject} cmp $b->{subject} }
               map { $seen{$_} } @order;
    $r{counts}{ $_->{pri} }++ for @open;
    $r{more} = @open > ATTENTION_ROWS ? @open - ATTENTION_ROWS : 0;
    splice(@open, ATTENTION_ROWS) if @open > ATTENTION_ROWS;
    for my $p (@open) {
        my $text = is_secret(join ' ', $p->{subject}, $p->{text}) ? '[redacted]' : $p->{text};
        $text = substr($text, 0, 117) . '...' if length $text > 120;
        push @{ $r{problems} }, { pri => $p->{pri}, kind => $p->{kind}, subject => $p->{subject}, state => $p->{state},
            host => $p->{host}, time => _iso($p->{epoch}), first => _iso($p->{first}), lines => $p->{lines}, text => $text };
    }
    $r{status} = ($r{counts}{urgent} || $r{counts}{warning}) ? 'attention' : 'clear';
    return \%r;
}

sub _result ($self, $head, $sources, $opt, @lists) {
    my @lines = _merge($opt->{lines}, @lists);
    my $cut = delete $self->{truncated_at};
    return {
        %$head,
        sources   => $sources,
        lines     => \@lines,
        count     => scalar @lines,
        redacted  => scalar(grep { $_->{redacted} } @lines),
        truncated => $cut && @$cut ? JSON::PP::true() : JSON::PP::false(),
        # of the sources that ran out of budget, the newest point they reached: every line
        # newer than this was searched in every source
        ($cut && @$cut ? (scanned_back_to => _iso(List::Util::max(@$cut))) : ()),
        limit     => $opt->{lines},
        (defined $opt->{since} ? (since_minutes => $opt->{since}) : ()),
        (defined $opt->{grep}  ? (grep => $opt->{grep}) : ()),
        (defined $opt->{min_level} ? (min_level => $opt->{min_level}) : ()),
    };
}

1;
