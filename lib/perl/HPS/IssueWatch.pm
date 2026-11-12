package HPS::IssueWatch;
# hps-issue-watch (docs/ISSUES.md): follows the IPS's incoming syslog files of
# every node (<log>/<sender ip>/<YYYY-MM-DD>.log, HPS::Log) from their end,
# applies the trigger rules (lib/hps-issue-rules.conf) to each new line and
# opens or resolves issues in the register (HPS::Issues).
#
# Rules file: one rule per line, "#" comments, blank lines ignored.
#   marker <kind> <severity> <key fields>
#       how an "HPS-ISSUE open|resolve kind=<kind> k=v ..." marker line of that
#       kind is keyed (fields comma-separated, e.g. host,mirror) and its default
#       severity. A marker of a kind with no marker rule is keyed by host,
#       severity warning. A marker's own severity=urgent|warning wins.
#   open <kind> <severity> <key fields> [after=N/S] <regex>
#   resolve <kind> - <key fields> <regex>
#       a Perl regex matched against "<tag>: <message>" of a line; its named
#       captures, plus host (the line's host, short name), are the fields.
#       after=N/S: open only at the Nth match of the same key within S seconds.
#
# Following: the newest file of each sender directory, from a byte offset. The
# offsets are saved in a state file (<issues dir>/.watch-state.json) after each
# poll that read something. On start a state file younger than `catchup`
# seconds (default 300) is resumed, so a restart misses nothing it had not
# read; an older or missing one is ignored and every file is followed from its
# current end: lines written while the watcher was down longer than that are
# never read (no replay of old problems; the trade-off is that a problem
# reported in that gap is not caught until it is reported again). A directory
# or day file that appears after the start is read from its beginning (it is
# new). Only complete lines are read; at most max_read bytes per file per poll.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(SEEK_SET);
use FindBin ();
use JSON::PP ();
use HPS::Log ();
use HPS::Issues ();
use HPS::Registry ();

use constant CATCHUP  => 300;
use constant MAX_READ => 4 * 1024 * 1024;

my $IP_RE  = qr/\A[0-9]{1,3}(?:\.[0-9]{1,3}){3}\z/;
my $DAY_RE = qr/\A([0-9]{4})-([0-9]{2})-([0-9]{2})\.log\z/;

#=== rules =====================================================================

# parse_rules($text, $where): {marker => {kind => {severity, key_fields}}, rules => [...]};
# dies (HPS::Issues::Error usage) naming the line of the first bad rule.
sub parse_rules ($text, $where = 'rules') {
    my (%marker, @rules);
    my $n = 0;
    for my $line (split /\n/, $text // '') {
        $n++;
        next if $line =~ /\A\s*(?:#|\z)/;
        my $bad = sub ($msg) { HPS::Issues::_fail(usage => "$where line $n: $msg") };
        $line =~ s/\A\s+|\s+\z//g;
        my ($action, $kind, $sev, $keys, $rest) = split /\s+/, $line, 5;
        $bad->('a rule is: <marker|open|resolve> <kind> <severity|-> <key fields> [regex]')
            unless defined $keys && $action =~ /\A(?:marker|open|resolve)\z/;
        eval { HPS::Issues::check_kind($kind); 1 } or $bad->("kind '$kind' must be lower-case a-z 0-9 -");
        my @kf = split /,/, $keys;
        $bad->("key fields '$keys' must be comma-separated lower-case names")
            if !@kf || grep { !/\A[a-z][a-z0-9_]{0,31}\z/ } @kf;
        if ($action eq 'resolve') {
            $bad->('a resolve rule has severity -') unless $sev eq '-';
        } else {
            $bad->("severity '$sev' must be urgent or warning") unless $sev =~ /\A(?:urgent|warning)\z/;
        }
        if ($action eq 'marker') {
            $bad->('a marker rule takes no regex') if defined $rest && length $rest;
            $marker{$kind} = { severity => $sev, key_fields => \@kf };
            next;
        }
        my ($an, $as);
        if (defined $rest && $rest =~ s/\Aafter=([0-9]+)\/([0-9]+)\s+//) {
            ($an, $as) = ($1 + 0, $2 + 0);
            $bad->('after=N/S needs N >= 1 and S >= 1') unless $an >= 1 && $as >= 1;
            $bad->('after= is for open rules') unless $action eq 'open';
        }
        $bad->('the rule has no regex') unless defined $rest && length $rest;
        my $re = eval { qr/$rest/ };
        $bad->("the regex does not compile: " . ($@ =~ s/ at \S+ line \d+.*//sr)) unless $re;
        push @rules, { action => $action, kind => $kind, severity => ($sev eq '-' ? undef : $sev),
            key_fields => \@kf, re => $re, after_n => $an, after_s => $as, n => $n };
    }
    return { marker => \%marker, rules => \@rules };
}

sub load_rules ($path) {
    open(my $fh, '<', $path) or HPS::Issues::_fail(failed => "cannot read the rules $path: $!");
    my $text = do { local $/; <$fh> };
    close $fh;
    return parse_rules($text, $path);
}

sub default_rules_path () {
    return $ENV{HPS_ISSUE_RULES} if defined $ENV{HPS_ISSUE_RULES} && length $ENV{HPS_ISSUE_RULES};
    my $base = $ENV{HPS_SYSTEM_BASE} // "$FindBin::RealBin/..";
    return "$base/lib/hps-issue-rules.conf";
}

# marker_keys($rules, $kind): (severity, key fields) for a marker of that kind.
sub marker_keys ($rules, $kind) {
    my $m = $rules->{marker}{$kind};
    return $m ? ($m->{severity}, @{ $m->{key_fields} }) : ('warning', 'host');
}

# match($rules, $rec): the actions a parsed line asks for, each
# {action, kind, severity, key_fields, fields} or {action => 'bad', reason}.
# $rec is HPS::Log::parse_syslog's {host, tag, message}.
sub match ($rules, $rec) {
    my $host = HPS::Registry::short_name($rec->{host} // '');
    my $msg  = $rec->{message} // '';
    my @out;
    if ($msg =~ /\bHPS-ISSUE (open|resolve)(?: (.*))?\z/) {
        my ($action, $rest) = ($1, $2 // '');
        my %f;
        for my $tok (split /\s+/, $rest) {
            next unless length $tok;
            my ($k, $v) = $tok =~ /\A([a-z][a-z0-9_]{0,31})=(.+)\z/
                or return { action => 'bad', reason => "marker token '$tok' is not k=v" };
            $f{$k} = $v;
        }
        my $kind = delete $f{kind};
        return { action => 'bad', reason => 'marker has no kind=' } unless defined $kind;
        my $own = delete $f{severity};
        my ($sev, @kf) = marker_keys($rules, $kind);
        $sev = $own if defined $own && $own =~ /\A(?:urgent|warning)\z/;
        $f{host} //= $host;
        push @out, { action => $action, kind => $kind, severity => $sev, key_fields => \@kf, fields => \%f };
    }
    my $text = length($rec->{tag} // '') ? "$rec->{tag}: $msg" : $msg;
    for my $r (@{ $rules->{rules} }) {
        next unless $text =~ $r->{re};
        my %f = %+;
        $f{host} //= $host;
        push @out, { action => $r->{action}, kind => $r->{kind}, severity => $r->{severity},
            key_fields => $r->{key_fields}, fields => \%f, rule => $r };
    }
    return @out;
}

#=== the watcher ==================================================================

# new(issues => HPS::Issues, rules => parsed, log_dir, state_file, now => sub,
#     logger => sub ($level, $msg), catchup, max_read)
sub new ($class, %o) {
    my $issues = $o{issues} // HPS::Issues->new;
    return bless {
        issues     => $issues,
        rules      => $o{rules} // load_rules(default_rules_path()),
        log_dir    => $o{log_dir} // $ENV{HPS_LOG} // '/srv/hps-log',
        state_file => $o{state_file},
        now        => $o{now} // sub { time },
        logger     => $o{logger} // sub ($l, $m) { $issues->_log($l, $m) },
        catchup    => $o{catchup} // CATCHUP,
        max_read   => $o{max_read} // MAX_READ,
        pos        => {},      # ip => {file, offset}
        counts     => {},      # after=N/S: "<rule n>|<key>" => [epochs]
        started    => 0,
    }, $class;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

sub state_file ($self) { return $self->{state_file} //= $self->{issues}->dir . '/.watch-state.json' }

sub _dirs ($self) {
    opendir(my $dh, $self->{log_dir}) or return ();
    my @d = sort grep { $_ =~ $IP_RE && -d "$self->{log_dir}/$_" } readdir $dh;
    closedir $dh;
    return @d;
}

# _days($ip): the day files of a sender, oldest first.
sub _days ($self, $ip) {
    my $dir = "$self->{log_dir}/$ip";
    opendir(my $dh, $dir) or return ();
    my @f = sort grep { $_ =~ $DAY_RE && -f "$dir/$_" } readdir $dh;
    closedir $dh;
    return @f;
}

# start(): resume from a fresh state file, else from the end of every file.
sub start ($self) {
    my $st;
    if (open(my $fh, '<', $self->state_file)) {
        local $/;
        $st = eval { JSON::PP::decode_json(<$fh>) };
        close $fh;
    }
    my $now = $self->{now}->();
    my $fresh = ref $st eq 'HASH' && ($st->{saved_at} // 0) >= $now - $self->{catchup} && ref $st->{files} eq 'HASH';
    my %pos;
    if ($fresh) {
        for my $ip (keys %{ $st->{files} }) {
            my $p = $st->{files}{$ip};
            next unless $ip =~ $IP_RE && ref $p eq 'HASH' && defined $p->{file} && $p->{file} =~ $DAY_RE
                && defined $p->{offset} && $p->{offset} =~ /\A[0-9]+\z/;
            $pos{$ip} = { file => $p->{file}, offset => $p->{offset} + 0 };
        }
    }
    for my $ip ($self->_dirs) {
        next if $pos{$ip};
        my @days = $self->_days($ip) or next;
        $pos{$ip} = { file => $days[-1], offset => -s "$self->{log_dir}/$ip/$days[-1]" // 0 };
    }
    $self->{pos} = \%pos;
    $self->{started} = 1;
    $self->_log('info', $fresh
        ? sprintf('hps-issue: watch started, resuming %d file(s) from the state of %ds ago', scalar keys %pos, $now - $st->{saved_at})
        : sprintf('hps-issue: watch started at the end of %d file(s)%s', scalar keys %pos,
            ref $st eq 'HASH' ? ' (the saved state is older than ' . $self->{catchup} . 's: lines in between are not read)' : ''));
    $self->save;
    return;
}

sub save ($self) {
    my $f = $self->state_file;
    my $dir = $f =~ s{/[^/]+\z}{}r;
    HPS::Registry::mkdir_p($dir) unless -d $dir;
    my $tmp = "$f.$$.tmp";
    open(my $fh, '>', $tmp) or do { $self->_log('err', "hps-issue: cannot write $tmp: $!"); return };
    print {$fh} JSON::PP->new->canonical->encode({ saved_at => $self->{now}->(), files => $self->{pos} });
    close $fh;
    rename($tmp, $f) or unlink $tmp;
    return;
}

# _read_new($ip, $file, $offset): (new offset, lines) of the complete lines after $offset.
sub _read_new ($self, $ip, $file, $offset) {
    my $path = "$self->{log_dir}/$ip/$file";
    my $size = -s $path // 0;
    $offset = 0 if $offset > $size;    # truncated or replaced
    return ($offset) if $offset == $size;
    open(my $fh, '<:raw', $path) or return ($offset);
    seek($fh, $offset, SEEK_SET) or return ($offset);
    my $want = $size - $offset;
    $want = $self->{max_read} if $want > $self->{max_read};
    my $got = read($fh, my $buf, $want) // 0;
    close $fh;
    my $end = rindex($buf, "\n");
    return ($offset) if $end < 0;
    my @lines = split /\n/, substr($buf, 0, $end);
    return ($offset + $end + 1, @lines);
}

# poll(): reads what is new in every sender's files and acts on it. Returns the
# number of lines read.
sub poll ($self) {
    $self->start unless $self->{started};
    my $lines = 0;
    for my $ip ($self->_dirs) {
        my @days = $self->_days($ip) or next;
        my $p = $self->{pos}{$ip} //= { file => $days[-1], offset => 0 };    # new sender: its newest file, whole
        my @todo = grep { $_ ge $p->{file} } @days;
        @todo = ($days[-1]) unless @todo;
        for my $i (0 .. $#todo) {
            my $file = $todo[$i];
            my $off = $file eq $p->{file} ? $p->{offset} : 0;
            my ($new, @l) = $self->_read_new($ip, $file, $off);
            my ($y, $m) = $file =~ $DAY_RE;
            for my $l (@l) { $self->line($l, $y, $m) }
            $lines += @l;
            $p->{file} = $file;
            $p->{offset} = $new;
            last if $new < (-s "$self->{log_dir}/$ip/$file" // 0);    # more next poll: keep order
        }
    }
    $self->save if $lines;
    return $lines;
}

# line($text, $year, $month): one syslog line through the rules.
sub line ($self, $text, $y = undef, $m = undef) {
    my @t = gmtime $self->{now}->();
    my $rec = HPS::Log::parse_syslog($text, $y // $t[5] + 1900, $m // $t[4] + 1) or return;
    for my $a (match($self->{rules}, $rec)) {
        my $ok = eval { $self->_act($a, $rec); 1 };
        $self->_log('warning', 'hps-issue: ignored a line from ' . ($rec->{host} // '?') . ': '
            . ($ok ? $a->{reason} : ref $@ ? $@->message : $@ =~ s/\s+\z//r)) if !$ok || $a->{action} eq 'bad';
    }
    return;
}

sub _act ($self, $a, $rec) {
    return if $a->{action} eq 'bad';
    my $issues = $self->{issues};
    my $fields = HPS::Issues::check_fields($a->{fields});
    my $key = HPS::Issues::make_key($a->{kind}, $fields, @{ $a->{key_fields} });
    my $detail = 'log ' . ($rec->{host} // '?') . ' ' . ($rec->{tag} // '') . ': ' . ($rec->{message} // '');
    if ($a->{action} eq 'resolve') {
        $issues->resolve_key($key, $detail);
        return;
    }
    if (my $r = $a->{rule}) {
        if ($r->{after_n} && $r->{after_n} > 1) {
            my $now = $self->{now}->();
            my $c = $self->{counts}{"$r->{n}|$key"} //= [];
            push @$c, $now;
            @$c = grep { $_ > $now - $r->{after_s} } @$c;
            return if @$c < $r->{after_n} && !$issues->find_open($key);
        }
    }
    my $summary = join ' ', $a->{kind}, map { "$_=$fields->{$_}" } sort keys %$fields;
    $issues->open_issue(kind => $a->{kind}, fields => $fields, key_fields => $a->{key_fields},
        severity => $a->{severity}, summary => $summary, detail => $detail);
    return;
}

# loop(%o): poll every `interval` seconds until stop; $o{tick} is called after
# each poll (the healer), $o{max_polls} ends it (tests).
sub loop ($self, %o) {
    my $stop = 0;
    local $SIG{TERM} = sub { $stop = 1 };
    local $SIG{INT}  = sub { $stop = 1 };
    my $interval = $o{interval} // 2;
    my $n = 0;
    $self->start;
    while (!$stop) {
        eval { $self->poll; 1 } or $self->_log('err', 'hps-issue: poll failed: ' . (ref $@ ? $@->message : $@ =~ s/\s+/ /gr));
        if ($o{tick}) {
            eval { $o{tick}->(); 1 } or $self->_log('err', 'hps-issue: heal failed: ' . (ref $@ ? $@->message : $@ =~ s/\s+/ /gr));
        }
        last if defined $o{max_polls} && ++$n >= $o{max_polls};
        my $end = time + $interval;
        while (!$stop && time < $end) { sleep 1 }
    }
    $self->_log('info', 'hps-issue: watch stopped');
    return 0;
}

1;
