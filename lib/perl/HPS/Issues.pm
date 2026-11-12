package HPS::Issues;
# The issue register (docs/ISSUES.md): problems the IPS has seen and has to see
# addressed, one JSON record per issue in the cluster config tree:
#   <cluster dir>/issues/<id>.json      id = <YYYYMMDD>-<seq>, e.g. 20261112-001
#   <cluster dir>/issues/.lock          flock for every read-modify-write
# An issue is keyed (key = <kind>:<value>:<value>..., the values of its key
# fields in order): a second open of a key that has an unresolved issue adds to
# that issue's trail, never a new issue. Resolved issues are kept; the next
# open of the same key is a new issue naming the previous one. The trail is
# append-only: {at, event, detail}, an entry equal to the one before it (same
# event and detail) counts up instead ({count, last_at}).
#
# Nothing secret is stored: a text that HPS::Log::is_secret flags is refused
# from a caller (summary, note, --by) and replaced by "[redacted]" from a log
# line.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(:flock);
use JSON::PP ();
use POSIX qw(strftime);
use HPS::Registry ();
use HPS::Log ();

use constant SEEN_TRAIL => 5;      # repeats of an open recorded in the trail; later ones only counted
use constant TRAIL_MAX  => 300;    # entries; past it the last entry counts what was not kept
use constant TEXT_MAX   => 300;    # characters of a summary, detail or note

our @STATES     = qw(open healing needs-human resolved);
our @SEVERITIES = qw(urgent warning);
my %STATE    = map { $_ => 1 } @STATES;
my %SEVERITY = map { $_ => 1 } @SEVERITIES;
my $KIND_RE  = qr/\A[a-z][a-z0-9-]{0,31}\z/;
my $FIELD_RE = qr/\A[a-z][a-z0-9_]{0,31}\z/;
my $VALUE_RE = qr/\A[A-Za-z0-9_.:@+\/-]{1,128}\z/;
my $ID_RE    = qr/\A[0-9]{8}-[0-9]{3,6}\z/;

{
    package HPS::Issues::Error;
    use feature qw(signatures);
    no warnings 'experimental::signatures';
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

sub _fail ($kind, $msg) { die HPS::Issues::Error->new($kind, $msg) }

# new(registry, cluster, dir, now => sub, logger => sub ($level, $msg))
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new;
    my $self = bless {
        registry => $reg,
        cluster  => $opt{cluster},
        dir      => $opt{dir},
        now      => $opt{now} // sub { time },
        logger   => $opt{logger} // \&_default_logger,
    }, $class;
    return $self;
}

sub _default_logger ($level, $msg) {
    return if $ENV{HPS_ISSUES_NO_SYSLOG};
    local $SIG{__WARN__} = sub { };
    system('logger', '-t', 'hps', '-p', "local0.$level", '--', $msg);
    return;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }
sub now ($self) { return $self->{now}->() }
sub registry ($self) { return $self->{registry} }

sub dir ($self) {
    return $self->{dir} //= $self->{registry}->issues_dir($self->{cluster});
}

sub iso ($epoch) { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $epoch) }

#--- text --------------------------------------------------------------------------

# clean_text($text): one line, at most TEXT_MAX characters; "[redacted]" when it
# looks like it carries a secret.
sub clean_text ($text) {
    $text //= '';
    $text =~ s/[\x00-\x1f\x7f]+/ /g;
    $text =~ s/\A\s+|\s+\z//g;
    return '[redacted]' if HPS::Log::is_secret($text);
    $text = substr($text, 0, TEXT_MAX - 3) . '...' if length $text > TEXT_MAX;
    return $text;
}

# caller_text($what, $text): a caller's summary, note or --by: refused (usage)
# when empty or secret-looking.
sub caller_text ($what, $text) {
    _fail(usage => "$what is empty") unless defined $text && $text =~ /\S/;
    _fail(usage => "$what looks like it carries a secret (a key, token, password or credential): not stored")
        if HPS::Log::is_secret($text);
    return clean_text($text);
}

#--- keys ----------------------------------------------------------------------------

sub check_kind ($kind) {
    _fail(usage => "kind must match $KIND_RE") unless defined $kind && $kind =~ $KIND_RE;
    return $kind;
}

sub check_severity ($sev) {
    _fail(usage => 'severity must be urgent or warning') unless defined $sev && $SEVERITY{$sev};
    return $sev;
}

# check_fields(\%f): every name and value plain; a host value is its short name.
sub check_fields ($f) {
    my %out;
    for my $k (sort keys %$f) {
        _fail(usage => "field name '$k' must match $FIELD_RE") unless $k =~ $FIELD_RE;
        my $v = $f->{$k};
        _fail(usage => "field $k: value must be 1 to 128 of A-Z a-z 0-9 _ . : @ + / -")
            unless defined $v && !ref $v && $v =~ $VALUE_RE && $v !~ /\.\./;
        _fail(usage => "field $k looks like it carries a secret: not stored") if HPS::Log::is_secret("$k=$v");
        $v = HPS::Registry::short_name($v) if $k eq 'host';
        $out{$k} = $v;
    }
    return \%out;
}

# make_key($kind, \%fields, @key_fields): "<kind>:<v1>:<v2>..."; every key field
# must be present.
sub make_key ($kind, $fields, @key_fields) {
    check_kind($kind);
    _fail(usage => 'an issue needs at least one key field') unless @key_fields;
    my @v;
    for my $k (@key_fields) {
        _fail(usage => "kind $kind is keyed by " . join(',', @key_fields) . ": $k is missing")
            unless defined $fields->{$k} && length $fields->{$k};
        push @v, $fields->{$k};
    }
    return join ':', $kind, @v;
}

#--- storage ---------------------------------------------------------------------------

sub _path ($self, $id) {
    _fail(usage => "issue id must look like 20261112-001") unless defined $id && $id =~ $ID_RE;
    return $self->dir . "/$id.json";
}

# with_lock($cb): $cb->() under the register's exclusive lock.
sub with_lock ($self, $cb) {
    HPS::Registry::mkdir_p($self->dir) unless -d $self->dir;
    open(my $lk, '>>', $self->dir . '/.lock') or _fail(failed => 'cannot open ' . $self->dir . "/.lock: $!");
    flock($lk, LOCK_EX) or _fail(failed => "cannot lock the issue register: $!");
    my @r = eval { $cb->() };
    my $err = $@;
    close $lk;
    die $err if $err;
    return wantarray ? @r : $r[0];
}

sub _read ($self, $path) {
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    my $rec = eval { JSON::PP->new->utf8->decode($text) };
    return ref $rec eq 'HASH' ? $rec : undef;
}

sub _write ($self, $rec) {
    my $path = $self->_path($rec->{id});
    my $tmp  = "$path.$$.tmp";
    open(my $fh, '>:raw', $tmp) or _fail(failed => "cannot write $tmp: $!");
    print {$fh} JSON::PP->new->utf8->canonical->pretty->indent_length(2)->encode($rec);
    close $fh or _fail(failed => "cannot write $tmp: $!");
    rename($tmp, $path) or do { unlink $tmp; _fail(failed => "cannot rename $tmp: $!") };
    return $rec;
}

sub _ids ($self) {
    opendir(my $dh, $self->dir) or return ();
    my @ids = sort grep { $_ =~ $ID_RE } map { /\A(.+)\.json\z/ ? $1 : () } readdir $dh;
    closedir $dh;
    return @ids;
}

# all(): every record, oldest id first.
sub all ($self) {
    return grep { defined } map { $self->_read($self->_path($_)) } $self->_ids;
}

# get($id): the record; dies notfound.
sub get ($self, $id) {
    my $rec = $self->_read($self->_path($id));
    _fail(notfound => "no issue $id") unless $rec;
    return $rec;
}

# list(all => 0|1): unresolved issues (open, healing, needs-human), or every one.
sub list ($self, %o) {
    my @r = $self->all;
    @r = grep { $_->{state} ne 'resolved' } @r unless $o{all};
    return @r;
}

# find_open($key): the unresolved issue with that key, or undef.
sub find_open ($self, $key) {
    my ($r) = grep { $_->{key} eq $key && $_->{state} ne 'resolved' } reverse $self->all;
    return $r;
}

sub _last_resolved ($self, $key) {
    my ($r) = grep { $_->{key} eq $key && $_->{state} eq 'resolved' } reverse $self->all;
    return $r;
}

sub _next_id ($self) {
    my $day = strftime('%Y%m%d', gmtime $self->now);
    my $max = 0;
    for my $id ($self->_ids) {
        my ($d, $n) = split /-/, $id;
        $max = $n + 0 if $d eq $day && $n > $max;
    }
    return sprintf('%s-%03d', $day, $max + 1);
}

#--- the trail ---------------------------------------------------------------------------

# trail($rec, $event, $detail): append; an entry equal to the last one counts up.
sub trail ($self, $rec, $event, $detail = '') {
    my $t = $rec->{trail} //= [];
    $detail = clean_text($detail);
    my $at = iso($self->now);
    my $last = $t->[-1];
    if ($last && $last->{event} eq $event && ($last->{detail} // '') eq $detail) {
        $last->{count} = ($last->{count} // 1) + 1;
        $last->{last_at} = $at;
        return;
    }
    if (@$t >= TRAIL_MAX) {
        if ($last->{event} ne 'trail-full') {
            push @$t, { at => $at, event => 'trail-full', detail => 'later events are counted here, not kept', count => 1 };
        } else {
            $last->{count}++;
            $last->{last_at} = $at;
        }
        return;
    }
    push @$t, { at => $at, event => $event, detail => $detail };
    return;
}

#--- verbs ---------------------------------------------------------------------------------

# open_issue(kind, fields => {..}, key_fields => [..], severity, summary, detail, by,
# urgent_after => S): ($record, $is_new). The detail goes in the trail (the log
# line, or "by <who>"). urgent_after: a new issue records urgent_at (epoch,
# now + S); hps-issue-watch makes it urgent once that passes while unresolved.
sub open_issue ($self, %a) {
    my $kind   = check_kind($a{kind});
    my $fields = check_fields($a{fields} // {});
    my $key    = make_key($kind, $fields, @{ $a{key_fields} // [] });
    my $sev    = check_severity($a{severity} // 'warning');
    my $summary = clean_text($a{summary} // '');
    $summary = $key unless length $summary;
    my $detail = $a{detail} // '';
    return $self->with_lock(sub {
        my $rec = $self->find_open($key);
        my $now = $self->now;
        if ($rec) {
            $rec->{seen} = ($rec->{seen} // 1) + 1;
            $rec->{last_seen_at} = iso($now);
            if ($rec->{seen} <= SEEN_TRAIL + 1) {
                $self->trail($rec, 'seen', $detail);
            }
            if ($sev eq 'urgent' && $rec->{severity} ne 'urgent') {
                $rec->{severity} = 'urgent';
                $self->trail($rec, 'escalated', 'reported as urgent');
            }
            $self->_write($rec);
            return ($rec, 0);
        }
        my $prev = $self->_last_resolved($key);
        $rec = {
            id => $self->_next_id, key => $key, kind => $kind, severity => $sev, state => 'open',
            opened_at => iso($now), resolved_at => undef, summary => $summary,
            fields => $fields, seen => 1, last_seen_at => iso($now), trail => [],
            ($prev ? (previous => $prev->{id}) : ()),
            ($a{urgent_after} ? (urgent_at => $now + $a{urgent_after}) : ()),
        };
        $self->trail($rec, 'opened', $detail);
        $self->trail($rec, 'reoccurred', "previous issue $prev->{id} (resolved $prev->{resolved_at})") if $prev;
        $self->_write($rec);
        $self->_log($sev eq 'urgent' ? 'err' : 'warning', "hps-issue: opened $rec->{id} $key");
        return ($rec, 1);
    });
}

# update($id, $cb): $cb->($record) under the lock, then written. Returns the record.
sub update ($self, $id, $cb) {
    return $self->with_lock(sub {
        my $rec = $self->get($id);
        $cb->($rec);
        $self->_write($rec);
        return $rec;
    });
}

# resolve($id, $by, resolution => {by, action, result}): the issue resolved;
# dies notfound / refused (already resolved). $by is the trail's text. The
# record keeps resolution {at, by (healer, operator <who>, log, monitor),
# action (what fixed it), result (the evidence that it is fixed)}. Without an
# action the healer's last successful action on the issue (heal.last_action)
# is named, else "-"; without a resolution: by operator, action and result $by.
sub resolve ($self, $id, $by, %o) {
    $by = clean_text($by);
    my $res = $o{resolution} // { by => 'operator', action => $by, result => $by };
    my $rec = $self->update($id, sub ($rec) {
        _fail(refused => "issue $id is already resolved ($rec->{resolved_at})") if $rec->{state} eq 'resolved';
        my $h = ref $rec->{heal} eq 'HASH' ? $rec->{heal} : {};
        $rec->{state} = 'resolved';
        $rec->{resolved_at} = iso($self->now);
        $rec->{resolution} = {
            at     => $rec->{resolved_at},
            by     => clean_text($res->{by} // 'operator'),
            action => clean_text($res->{action} // $h->{last_action} // '-') || '-',
            result => clean_text($res->{result} // $by) || '-',
        };
        delete $rec->{heal}{next_at} if ref $rec->{heal} eq 'HASH';
        $self->trail($rec, 'resolved', "by $by");
    });
    my $r = $rec->{resolution};
    $self->_log('notice', "hps-issue: resolved $id by $by; issue: $rec->{key}: $rec->{summary}; "
        . "resolution by $r->{by}: $r->{action}; result: $r->{result}");
    return $rec;
}

# resolve_key($key, $by, %o): resolves the unresolved issue of that key (as
# resolve); undef when none.
sub resolve_key ($self, $key, $by, %o) {
    my $rec = $self->find_open($key) or return undef;
    return $self->resolve($rec->{id}, $by, %o);
}

# resolution_line($rec): "by <by>: <action>" of a resolved issue, "-" without one.
sub resolution_line ($rec) {
    my $r = $rec->{resolution};
    return '-' unless ref $r eq 'HASH';
    return "by $r->{by}: $r->{action}";
}

# retry($id, $who): an unresolved issue (needs-human, or open or healing) back
# to open with its heal backoff reset: no attempts counted, the next attempt at
# once (the healer's next tick). Refused (refused) when it is resolved.
sub retry ($self, $id, $who) {
    my $rec = $self->update($id, sub ($rec) {
        _fail(refused => "issue $id is resolved ($rec->{resolved_at}): open a new one") if $rec->{state} eq 'resolved';
        $self->trail($rec, 'retry', 'retry by operator ' . clean_text($who));
        $self->set_state($rec, 'open', 'back to open for a retry') if $rec->{state} ne 'open';
        $rec->{heal} = { attempts => 0, next_at => $self->now };
    });
    $self->_log('notice', "hps-issue: retry $id by $who");
    return $rec;
}

# note($id, $text): a note in the trail.
sub note ($self, $id, $text, $by = undef) {
    return $self->update($id, sub ($rec) {
        $self->trail($rec, 'note', (defined $by ? "$by: " : '') . $text);
    });
}

# set_state($rec, $state, $detail): in a callback of update(); trail entry named after the state.
sub set_state ($self, $rec, $state, $detail = '') {
    _fail(usage => "unknown state $state") unless $STATE{$state};
    $self->trail($rec, $state, $detail) if $rec->{state} ne $state;
    $rec->{state} = $state;
    return;
}

1;
