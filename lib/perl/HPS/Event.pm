package HPS::Event;
# The normalised event line (docs/LOGGING.md "Event lines").
#
# An event is one syslog line whose message carries a marker and four fixed
# fields, in this order, then free text:
#
#   HPS-EVENT pri=<info|notice> kind=<kind> subject=<subject> state=<state> <text>
#   HPS-ALERT pri=<warning|urgent> kind=<kind> subject=<subject> state=<state> <text>
#
# The marker follows from the priority: HPS-ALERT is every line that needs
# attention, so `grep -F HPS-ALERT` is the whole filter. rsyslog on the IPS
# copies the marker lines of the IPS's own programs to <log>/events.log
# (lib/functions.d/create-config-rsyslog.sh). The words are a fixed list: a
# line with any other priority, kind or state is not an event (line() dies,
# parse() returns undef).
#
# Nothing here writes to syslog: a tool hands the text to its own logger with
# syslog_level() as the level.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use constant EVENT => 'HPS-EVENT';
use constant ALERT => 'HPS-ALERT';
use constant REMIND => 3000;    # seconds between the repeats of a standing problem (50 minutes)

# priority => [rank, syslog level, needs attention]
my %PRI = (
    urgent  => [ 3, 'err',     1 ],
    warning => [ 2, 'warning', 1 ],
    notice  => [ 1, 'notice',  0 ],
    info    => [ 0, 'info',    0 ],
);

# what the line is about
my %KIND = map { $_ => 1 } qw(issue monitor workload storage node power job pairing boot auth service log);

# state => class. standing: the problem holds until a clearing line of the same
# kind and subject (the emitter repeats it while it holds); clearing: the
# subject is well again; point: something that happened once.
my %STATE = (
    (map { $_ => 'standing' } qw(open escalated needs-human warning critical unknown unreachable pair-failed boot-stalled gave-up unreadable reset-failed tripped)),
    (map { $_ => 'clearing' } qw(resolved ok reachable stopped booted cleared)),
    (map { $_ => 'point' } qw(started ended done failed refused error requested defined created destroyed
        on off up down paired held rotated reset bad-setting)),
);

my $SUBJECT_RE = qr/\A(?:-|[A-Za-z0-9][A-Za-z0-9_.:@\/+-]{0,127})\z/;

sub priorities ()         { return sort { $PRI{$b}[0] <=> $PRI{$a}[0] } keys %PRI }
sub kinds ()              { return sort keys %KIND }
sub states ()             { return sort keys %STATE }
sub is_priority ($p)      { return defined $p && exists $PRI{$p} ? 1 : 0 }
sub rank ($p)             { return $PRI{$p} ? $PRI{$p}[0] : -1 }
sub syslog_level ($p)     { return $PRI{$p} ? $PRI{$p}[1] : 'info' }
sub needs_attention ($p)  { return $PRI{$p} ? $PRI{$p}[2] : 0 }
sub marker ($p)           { return needs_attention($p) ? ALERT : EVENT }
sub state_class ($s)      { return defined $s ? $STATE{$s} : undef }

# subject_token($text): the text as a subject (no space, no "="): other
# characters become "_", an empty one "-".
sub subject_token ($text) {
    $text //= '';
    $text =~ s/[^A-Za-z0-9_.:@\/+-]/_/g;
    $text =~ s/\A[^A-Za-z0-9]+//;
    $text = substr($text, 0, 128);
    return length $text ? $text : '-';
}

# line(pri =>, kind =>, subject =>, state =>, text =>): the message text.
# Dies on a word outside the vocabulary: that is a bug in the caller.
sub line (%f) {
    my ($pri, $kind, $state) = @f{qw(pri kind state)};
    die "HPS::Event: unknown priority '" . ($pri // '') . "'\n" unless is_priority($pri);
    die "HPS::Event: unknown kind '" . ($kind // '') . "'\n" unless defined $kind && $KIND{$kind};
    die "HPS::Event: unknown state '" . ($state // '') . "'\n" unless defined $state && $STATE{$state};
    my $subject = subject_token($f{subject});
    my $text = $f{text} // '';
    $text =~ s/[\x00-\x1f\x7f]+/ /g;
    $text =~ s/\A\s+|\s+\z//g;
    my $line = marker($pri) . " pri=$pri kind=$kind subject=$subject state=$state";
    $line .= " $text" if length $text;
    return $line;
}

# parse($message): {pri, kind, subject, state, text, class, attention} of the
# first marker in the text; undef when there is none or its words are not of
# the vocabulary. The priority decides attention, never the marker word.
sub parse ($message) {
    return undef unless defined $message;
    my ($pri, $kind, $subject, $state, $text) =
        $message =~ /\bHPS-(?:EVENT|ALERT) pri=(\S+) kind=(\S+) subject=(\S+) state=(\S+)(?: (.*))?\z/s
        or return undef;
    return undef unless is_priority($pri) && $KIND{$kind} && $STATE{$state} && $subject =~ $SUBJECT_RE;
    return {
        pri => $pri, kind => $kind, subject => $subject, state => $state, text => $text // '',
        class => $STATE{$state}, attention => needs_attention($pri),
    };
}

# log_event($logger, pri =>, kind =>, subject =>, state =>, text =>): hands the
# event line to a tool's logger (sub ($level, $message), the form the tools
# already have) at the syslog level its priority maps to. Dies as line() does.
sub log_event ($logger, %f) {
    $logger->(syslog_level($f{pri}), line(%f));
    return;
}

# remind_due(\%memo, $key, $now, $period): true when the line for $key was not
# logged in the last $period seconds (default REMIND), and notes $now. A
# standing problem is logged on change and again whenever this is true, so the
# newest events.log lines always hold it (hps-log attention reads one hour).
sub remind_due ($memo, $key, $now, $period = REMIND) {
    my $t = $memo->{$key};
    return 0 if defined $t && $now - $t < $period;
    $memo->{$key} = $now;
    return 1;
}

1;
