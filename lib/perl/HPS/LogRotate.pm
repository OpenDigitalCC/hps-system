package HPS::LogRotate;
# Daily rotation, compression and retention of the IPS's log tree
# (docs/LOGGING.md "Rotation"); bin/hps-log-rotate runs it under supervisor.
#
# The tree (HPS::Log reads every file named here, plain or .gz):
#   events.log metrics.log audit.log   the three views, one file each
#   <name>-<date>[.<n>].log[.gz]       a view after its rotation
#   <dir>/<date>.log[.gz]              rsyslog's day files, <dir> one or two
#                                      levels down (<ip>, ips, ips/<program>)
#
# Three jobs, in this order:
#   rotate    once per local day (and once at the first run): each view file
#             that holds lines is renamed to <name>-<yesterday>.log, then
#             rsyslogd is sent HUP so it opens a fresh file. The day is noted in
#             <log>/.log-rotate-state only when the HUP succeeded.
#   compress  a rotated view file, and a day file of an earlier day, that has
#             been untouched for QUIET_SECONDS is gzipped (written beside it,
#             renamed into place, then the plain file removed).
#   prune     a file whose date is more than the retention days before today is
#             deleted: per view (events 365, metrics 30, audit 14), 7 for the
#             day files; the cluster keys log_*_retention_days.
#
# The date of a file is the date in its name, never its mtime. The clock and
# the HUP are injectable: now (epoch seconds), hup (sub, true on success).
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use IO::Compress::Gzip qw(gzip $GzipError);
use POSIX qw(strftime);
use Time::Local qw(timelocal);

use constant QUIET_SECONDS => 600;
use constant STATE_FILE    => '.log-rotate-state';

our @VIEWS = qw(events metrics audit);
our %DEFAULT_KEEP = (events => 365, metrics => 30, audit => 14, other => 7);
my %KEY = (events => 'log_events_retention_days', metrics => 'log_metrics_retention_days',
           audit => 'log_audit_retention_days', other => 'log_retention_days');

# keep_days($getter): {events, metrics, audit, other} from the cluster keys.
# $getter->($key) gives the stored value or undef. A value that is not a whole
# number from 1 to 3650 is replaced by the default and named in the second
# result (a list of texts).
sub keep_days ($getter) {
    my (%keep, @bad);
    for my $k (sort keys %KEY) {
        my $raw = eval { $getter->($KEY{$k}) };
        if (defined $raw && length $raw) {
            my $v = $raw =~ s/\A\s+|\s+\z//gr;
            if ($v =~ /\A[1-9][0-9]{0,3}\z/ && $v <= 3650) { $keep{$k} = $v + 0; next }
            push @bad, "$KEY{$k}='$raw' is not 1..3650; using $DEFAULT_KEEP{$k}";
        }
        $keep{$k} = $DEFAULT_KEEP{$k};
    }
    return (\%keep, @bad);
}

sub new ($class, %o) {
    die "HPS::LogRotate: log_dir needed\n" unless defined $o{log_dir} && length $o{log_dir};
    return bless {
        log_dir => $o{log_dir},
        now     => $o{now},
        hup     => $o{hup} // \&_default_hup,
        keep    => { %DEFAULT_KEEP, %{ $o{keep} // {} } },
        dry_run => $o{dry_run} ? 1 : 0,
        quiet   => $o{quiet} // QUIET_SECONDS,
    }, $class;
}

sub _default_hup () { return system('pkill', '-HUP', '-x', 'rsyslogd') == 0 ? 1 : 0 }

sub now ($self) { return ref $self->{now} eq 'CODE' ? $self->{now}->() : $self->{now} // time }

# date_of($epoch, $days_back): the local date YYYY-MM-DD of $epoch, minus whole
# days (counted from local noon, so a daylight-saving change cannot skip a day).
sub date_of ($epoch, $days_back = 0) {
    my @t = localtime $epoch;
    my $noon = timelocal(0, 0, 12, @t[3, 4, 5]);
    return strftime('%Y-%m-%d', localtime($noon - 86400 * $days_back));
}

sub today ($self) { return date_of($self->now) }

#--- the state: the day the views were last rotated ------------------------------------------

sub _state_path ($self) { return "$self->{log_dir}/" . STATE_FILE }

sub last_rotated ($self) {
    open(my $fh, '<', $self->_state_path) or return undef;
    my $d = <$fh>;
    close $fh;
    return defined $d && $d =~ /\A([0-9]{4}-[0-9]{2}-[0-9]{2})\s*\z/ ? $1 : undef;
}

sub _write_state ($self, $date) {
    my $p = $self->_state_path;
    open(my $fh, '>', "$p.tmp") or return 0;
    print {$fh} "$date\n";
    close $fh or return 0;
    return rename("$p.tmp", $p) ? 1 : 0;
}

# rotation_due(): true when the views have not been rotated on today's date
# (no state counts as never rotated: the first run rotates).
sub rotation_due ($self) {
    my $l = $self->last_rotated;
    return !defined $l || $l lt $self->today ? 1 : 0;
}

#--- rotate -----------------------------------------------------------------------------------

sub _target ($self, $name, $date) {
    my $d = $self->{log_dir};
    my $n = 0;
    while (1) {
        my $base = $n ? "$name-$date.$n.log" : "$name-$date.log";
        return "$d/$base" unless -e "$d/$base" || -e "$d/$base.gz";
        $n++;
    }
}

# rotate_views(): renames each view that holds lines; returns ([renames "from -> to"], [errors]).
# rsyslogd gets HUP after the renames; the state is written only when it did.
sub rotate_views ($self) {
    my (@done, @err);
    my $yesterday = date_of($self->now, 1);
    for my $name (@VIEWS) {
        my $f = "$self->{log_dir}/$name.log";
        next unless -s $f;
        my $to = $self->_target($name, $yesterday);
        if ($self->{dry_run}) { push @done, "$name.log -> " . ($to =~ s{.*/}{}r); next }
        if (rename($f, $to)) { push @done, "$name.log -> " . ($to =~ s{.*/}{}r) }
        else { push @err, "cannot rename $f: $!" }
    }
    return (\@done, \@err) if $self->{dry_run};
    if (@done) {
        if (!$self->{hup}->()) { push @err, 'rsyslogd did not take the HUP; the rotated files may still be open' }
    }
    if (!@err && !$self->_write_state($self->today)) { push @err, "cannot write $self->{log_dir}/" . STATE_FILE . ": $!" }
    return (\@done, \@err);
}

#--- the files --------------------------------------------------------------------------------

# files(): [{path, dir, name (the file's own name), view (events|metrics|audit
# or undef), date}] of every rotated view file and day file in the tree.
sub files ($self) {
    my $root = $self->{log_dir};
    my @out;
    opendir(my $dh, $root) or return @out;
    my @top = sort readdir $dh;
    closedir $dh;
    for my $n (@top) {
        next if $n =~ /\A\.\.?\z/;
        my $p = "$root/$n";
        if (-f $p && !-l $p) {
            if (my ($v, $d) = $n =~ /\A(events|metrics|audit)-([0-9]{4}-[0-9]{2}-[0-9]{2})(?:\.[0-9]{1,3})?\.log(?:\.gz)?\z/) {
                push @out, { path => $p, name => $n, view => $v, date => $d };
            }
        } elsif (-d $p && !-l $p) {
            push @out, $self->_day_files($p);
        }
    }
    return @out;
}

sub _day_files ($self, $dir, $depth = 1) {
    my @out;
    opendir(my $dh, $dir) or return @out;
    my @n = sort readdir $dh;
    closedir $dh;
    for my $n (@n) {
        next if $n =~ /\A\.\.?\z/;
        my $p = "$dir/$n";
        if (-l $p) { next }
        if (-f $p && $n =~ /\A([0-9]{4}-[0-9]{2}-[0-9]{2})\.log(?:\.gz)?\z/) {
            push @out, { path => $p, name => $n, dir => $dir, view => undef, date => $1 };
        } elsif (-d $p && $depth < 2) {
            push @out, $self->_day_files($p, $depth + 1);
        }
    }
    return @out;
}

#--- compress ---------------------------------------------------------------------------------

# compress(): gzips what is old enough; returns ([paths], [errors]).
sub compress ($self) {
    my (@done, @err);
    my $now = $self->now;
    my $today = $self->today;
    for my $f ($self->files) {
        my $p = $f->{path};
        next if $p =~ /\.gz\z/;
        next unless $f->{view} || $f->{date} lt $today;    # today's day file is open
        my @st = stat $p or next;
        next if $now - $st[9] < $self->{quiet};
        if ($self->{dry_run}) { push @done, $p; next }
        if (-s "$p.gz") {    # compressed earlier; only the removal of the plain file failed
            unlink $p;
            next;
        }
        my $z = "$p.gz.tmp";
        if (!gzip($p => $z)) { push @err, "cannot compress $p: $GzipError"; unlink $z; next }
        utime($st[9], $st[9], $z);
        if (!rename($z, "$p.gz")) { push @err, "cannot write $p.gz: $!"; unlink $z; next }
        if (!unlink $p) { push @err, "cannot remove $p: $!"; next }
        push @done, $p;
    }
    return (\@done, \@err);
}

#--- prune ------------------------------------------------------------------------------------

# prune(): deletes the files older than their retention; returns ([paths], [errors]).
sub prune ($self) {
    my (@done, @err, %dirs);
    my $now = $self->now;
    for my $f ($self->files) {
        my $days = $self->{keep}{ $f->{view} // 'other' };
        my $cut = date_of($now, $days);
        next unless $f->{date} lt $cut;
        if ($self->{dry_run}) { push @done, $f->{path}; next }
        if (unlink $f->{path}) { push @done, $f->{path}; $dirs{ $f->{dir} } = 1 if $f->{dir} }
        else { push @err, "cannot delete $f->{path}: $!" }
    }
    # a directory that held only expired files goes with them (rsyslog makes it again)
    for my $d (sort { length $b <=> length $a } keys %dirs) {
        my $p = $d;
        while ($p ne $self->{log_dir} && length $p > length $self->{log_dir}) {
            last unless rmdir $p;
            $p =~ s{/[^/]+\z}{};
        }
    }
    return (\@done, \@err);
}

# run_once(force => 1): rotates when due (or when forced), then compresses and
# prunes. Returns {rotated, compressed, pruned, errors, rotation_ran}.
sub run_once ($self, %o) {
    my %r = (rotated => [], compressed => [], pruned => [], errors => [], rotation_ran => 0);
    if ($o{force} || $self->rotation_due) {
        my ($d, $e) = $self->rotate_views;
        $r{rotated} = $d;
        push @{ $r{errors} }, @$e;
        $r{rotation_ran} = 1;
    }
    my ($c, $ce) = $self->compress;
    my ($p, $pe) = $self->prune;
    $r{compressed} = $c;
    $r{pruned} = $p;
    push @{ $r{errors} }, @$ce, @$pe;
    return \%r;
}

1;
