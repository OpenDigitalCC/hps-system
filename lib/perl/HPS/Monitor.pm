package HPS::Monitor;
# Resource monitor (docs/MONITORING.md): turns the answer of the node script
# nagios-check (ctrl-exec agent plugin, JSON) into log lines, and holds the pure
# rules of hps-monitor: the interval key, the tick schedule, the target list.
# The IPS names the checks (--all) and decides when; the node's checks.conf
# decides how. No I/O to syslog here: hps-monitor writes what this returns.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use HPS::Registry;

use constant DEFAULT_INTERVAL => 60;
use constant MIN_INTERVAL     => 10;
use constant MAX_INTERVAL     => 86400;

my %RANK = (OK => 0, UNKNOWN => 1, WARNING => 2, CRITICAL => 3);
my %PRIO = (OK => 'info', WARNING => 'warning', CRITICAL => 'err', UNKNOWN => 'err', UNREACHABLE => 'err');

sub priority ($state) { return $PRIO{$state} // 'err' }

# interval($raw): (seconds, warning). $raw is the stored value (undef = unset).
# 0 disables; 10..86400 is used; unset gives the default silently; anything else
# gives the default and a warning text.
sub interval ($raw) {
    return (DEFAULT_INTERVAL, undef) unless defined $raw && length $raw;
    my $v = $raw;
    $v =~ s/\A\s+|\s+\z//g;
    return (0, undef) if $v =~ /\A0+\z/;
    return ($v + 0, undef) if $v =~ /\A[1-9][0-9]*\z/ && $v >= MIN_INTERVAL && $v <= MAX_INTERVAL;
    return (DEFAULT_INTERVAL, "monitor_interval_seconds='$raw' is not 0 or " . MIN_INTERVAL . '..' . MAX_INTERVAL . '; using ' . DEFAULT_INTERVAL);
}

# missed_ticks($elapsed, $interval): how many whole ticks a run of $elapsed
# seconds overran (0 when it finished inside its own interval).
sub missed_ticks ($elapsed, $interval) {
    return 0 if $elapsed < $interval;
    return int($elapsed / $interval);
}

sub _one_line ($text, $max = 200) {
    my $t = $text // '';
    $t =~ s/[\x00-\x1f\x7f]+/ /g;
    $t =~ s/\s+/ /g;
    $t =~ s/\A | \z//g;
    return length($t) > $max ? substr($t, 0, $max) : $t;
}

# perf_text(\@perfdata): "label=value[unit] ..." (thresholds left out).
sub perf_text ($perf) {
    my @out;
    for my $p (@{ $perf // [] }) {
        next unless ref $p eq 'HASH' && defined $p->{label};
        (my $label = $p->{label}) =~ s/\s+/_/g;
        next unless defined $p->{value};
        push @out, $label . '=' . $p->{value} . ($p->{uom} // '');
    }
    return join ' ', @out;
}

# parse_reply($rc, $text): the answer of `hps-run.sh --json <host> nagios-check
# --all` (ctrl-exec-cli JSON: {ok, results:[{exit, stdout, stderr, error}]}, the
# stdout being the nagios-check document). Returns { checks => [...] } or
# { unreachable => reason }.
sub parse_reply ($rc, $text, $err = '') {
    my $why = sub ($m) { return { unreachable => _one_line($m) } };
    if ($rc != 0) {
        my $e = _one_line($err);
        return $why->($rc == 124 ? 'timed out' : length $e ? "hps-run exit $rc: $e" : "hps-run exit $rc");
    }
    my $d = eval { JSON::PP::decode_json($text // '') };
    return $why->('no readable reply from ctrl-exec-cli') unless ref $d eq 'HASH';
    return $why->($d->{error} // 'ctrl-exec-cli reported failure') unless $d->{ok};
    my $r = ref $d->{results} eq 'ARRAY' ? $d->{results}[0] : undef;
    return $why->('no result for the host') unless ref $r eq 'HASH';
    my $w = eval { JSON::PP::decode_json($r->{stdout} // '') };
    unless (ref $w eq 'HASH' && ref $w->{checks} eq 'ARRAY') {
        return $why->((ref $w eq 'HASH' && $w->{error}) || $r->{error} || $r->{stderr}
                      || 'exit ' . ($r->{exit} // '?') . ': no readable nagios-check reply');
    }
    my @checks;
    for my $c (@{ $w->{checks} }) {
        next unless ref $c eq 'HASH' && defined $c->{name};
        my $s = $c->{state} // '';
        $s = 'UNKNOWN' unless exists $RANK{$s};
        push @checks, { name => $c->{name}, state => $s, summary => _one_line($c->{summary}), perf => perf_text($c->{perfdata}) };
    }
    return { checks => \@checks };
}

# host_lines($host, $parsed, $duration): list of [priority, line] for one host.
sub host_lines ($host, $parsed, $duration) {
    my $dur = sprintf '%.1f', $duration;
    if (defined $parsed->{unreachable}) {
        return ([ priority('UNREACHABLE'), "hps-monitor: host=$host state=UNREACHABLE $parsed->{unreachable}" ]);
    }
    my @out;
    my $worst = 'OK';
    for my $c (@{ $parsed->{checks} }) {
        my $line = "hps-monitor: host=$host check=$c->{name} state=$c->{state} $c->{summary}";
        $line .= " | $c->{perf}" if length $c->{perf};
        push @out, [ priority($c->{state}), $line ];
        $worst = $c->{state} if $RANK{ $c->{state} } > $RANK{$worst};
    }
    my $n = @{ $parsed->{checks} };
    $worst = 'UNKNOWN' if $n == 0;
    push @out, [ priority($worst), "hps-monitor: host=$host checks=$n worst=$worst duration=$dur" ];
    return @out;
}

# targets($agents, $registry): the paired nodes to check: agent names known to
# the dispatcher that are also hosts of the registry (by FQDN). The IPS and
# anything else that is not a registered host is never a target.
sub targets ($agents, $reg) {
    my %agent = map { lc($_) => 1 } grep { defined && length && !/\Astale-/ } @$agents;
    my @out;
    for my $mac (sort $reg->host_list_all) {
        my $f = eval { $reg->fqdn($mac) };
        push @out, $f if defined $f && $agent{$f};
    }
    my %seen;
    return grep { !$seen{$_}++ } sort @out;
}

1;
