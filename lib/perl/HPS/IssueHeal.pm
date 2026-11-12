package HPS::IssueHeal;
# The self-healing of mirror-leg issues (docs/ISSUES.md), run by hps-issue-watch
# after every poll (tick). For each open or healing mirror-leg issue whose time
# has come, through the runner (scripts/hps-run.sh, as HPS::Workload):
#   1. mirror-status <mirror> on the issue's host (every non-clean mirror of
#      that host when the issue names no mirror, as the kernel fallback rule):
#        clean     -> resolved "by mirror-status clean"
#        resyncing -> healing; checked again in CHECK_DELAY
#        absent    -> not assembled (the VM is stopped): a failed attempt
#        exit 3    -> the host does not know the mirror: needs-human
#   2. degraded: the workload record (cluster key workload_<name>) whose VM on
#      that host has the disk /dev/md/<mirror> gives the leg specs; the legs to
#      bring back are the one the marker named (leg=<iqn>@<portal>), else the
#      ones mirror-status does not show as members, else every leg (a leg that
#      is a member is a no-op for mirror-rejoin);
#      mirror-rejoin <mirror> --leg <spec> for each:
#        all exit 0 -> healing (resync from the bitmap); checked in CHECK_DELAY
#        any exit 3 -> needs-human, severity urgent, no more attempts
#                      (DIVERGED, or another refusal: a human decision)
#        otherwise  -> a failed attempt
# A failed attempt waits by the backoff (DELAYS, then the cap); at the cap the
# issue is escalated to urgent once. The first attempt is FIRST_DELAY after the
# healer first sees the issue. Every attempt and check is in the trail with the
# node's result line. Issues that are resolved or need a human are never touched.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HPS::Issues ();
use HPS::Log ();
use HPS::Registry ();

use constant FIRST_DELAY => 30;
use constant CHECK_DELAY => 30;
our @DELAYS = (60, 120, 300, 900);    # after failed attempt 1, 2, 3, 4 and later

# new(issues => HPS::Issues, runner => obj with call(mac, script, args), now => sub)
sub new ($class, %o) {
    my $issues = $o{issues} // HPS::Issues->new;
    my $runner = $o{runner};
    if (!$runner) {
        require HPS::Storage;
        $runner = HPS::Storage::Runner::HpsRun->new;
    }
    return bless { issues => $issues, runner => $runner, now => $o{now} // sub { time },
        kinds => { 'mirror-leg' => 1 } }, $class;
}

sub _now ($self) { return $self->{now}->() }
sub _reg ($self) { return $self->{issues}->registry }

# backoff($attempts): seconds to wait after that many failed attempts.
sub backoff ($n) { return $DELAYS[ $n < 1 ? 0 : $n > @DELAYS ? $#DELAYS : $n - 1 ] }

# tick(): one pass over the due issues. Returns the number handled.
sub tick ($self) {
    my $n = 0;
    my $issues = $self->{issues};
    for my $rec ($issues->list) {
        next unless $self->{kinds}{ $rec->{kind} } && ($rec->{state} eq 'open' || $rec->{state} eq 'healing');
        my $h = $rec->{heal};
        if (ref $h ne 'HASH' || !defined $h->{next_at}) {
            $issues->update($rec->{id}, sub ($r) {
                $r->{heal} = { attempts => ($h->{attempts} // 0), next_at => $self->_now + FIRST_DELAY } if ref $h ne 'HASH' || !defined $h->{next_at};
            });
            next;
        }
        next if $h->{next_at} > $self->_now;
        $self->heal($rec);
        $n++;
    }
    return $n;
}

# _call($mac, $script, @args): {rc, stdout, stderr}; a runner that dies is rc 1.
sub _call ($self, $mac, $script, @args) {
    my $r = eval { $self->{runner}->call(mac => $mac, script => $script, args => [@args]) };
    return { rc => 1, stdout => '', stderr => 'runner: ' . ($@ =~ s/\s+\z//r) } unless ref $r eq 'HASH';
    return $r;
}

# result_line($r): the line that says what the node did: a DIVERGED or MIRROR
# line, else the last line of stderr, else of stdout.
sub result_line ($r) {
    my @out = grep { /\S/ } split /\n/, $r->{stdout} // '';
    my ($d) = grep { /\A(?:DIVERGED|MIRROR) / } reverse @out;
    return $d if defined $d;
    my @err = grep { /\S/ && !/\A\+ / } split /\n/, $r->{stderr} // '';
    return $err[-1] // $out[-1] // '';
}

# find_host($name): the host key of a MAC or host name, undef when unknown.
sub find_host ($self, $name) {
    return eval { HPS::Log->new(registry => $self->_reg)->find_host($name) };
}

# workload_disk($mac, $mirror): {workload, vm, specs} of the VM on host $mac with
# the disk /dev/md/$mirror, from the workload records; undef when none.
sub workload_disk ($self, $mac, $mirror) {
    my $reg = $self->_reg;
    my $c = eval { $reg->active_cluster } // return undef;
    for my $key ($reg->cluster_list($c)) {
        my ($wl) = $key =~ /\Aworkload_(.+)\z/ or next;
        next if $wl =~ /_destroyed\z/;
        my $rec = eval { $reg->cluster_get_json($c, $key) };
        next unless ref $rec eq 'HASH' && ref $rec->{vms} eq 'HASH';
        for my $vm (sort keys %{ $rec->{vms} }) {
            my $v = $rec->{vms}{$vm};
            next unless ref $v eq 'HASH' && ref $v->{disks} eq 'HASH';
            my $vmac = $self->find_host($v->{host} // '');
            next unless defined $vmac && $vmac eq $mac;
            for my $d (sort keys %{ $v->{disks} }) {
                my $disk = $v->{disks}{$d};
                next unless ref $disk eq 'HASH' && ($disk->{md} // '') eq "/dev/md/$mirror";
                return { workload => $wl, vm => $vm, specs => [ @{ $disk->{legs} // [] } ] };
            }
        }
    }
    return undef;
}

# missing_legs(\@specs, $status_stdout, $hint): the specs to rejoin.
sub missing_legs ($specs, $stdout, $hint = undef) {
    if (defined $hint && $hint =~ /\A(.+)@(.+)\z/) {
        my ($iqn, $portal) = ($1, $2);
        (my $ip = $portal) =~ s/:3260\z//;    # the marker writes <ip>:3260, a spec may hold the bare ip
        my @m = grep { $_ eq "iscsi:$portal:$iqn" || $_ eq "iscsi:$ip:$iqn" } @$specs;
        @m = grep { /:\Q$iqn\E\z/ } @$specs unless @m;
        return @m if @m;
    }
    my %dev;
    my @other;
    for my $l (split /\n/, $stdout // '') {
        if ($l =~ /\ALEG (\S+) .*\bdev=(\S*)/) { $dev{$1} = $2 }
        else { push @other, $l }
    }
    my @miss = grep {
        my $d = $dev{$_} // '';
        !length($d) || !grep { index($_, $d) >= 0 && !/faulty|removed/i } @other;
    } @$specs;
    return @miss ? @miss : @$specs;
}

# _mirror($mac, $host, $mirror, $hint): {outcome => clean|healing|failed|human, detail, attempted}
sub _mirror ($self, $mac, $host, $mirror, $hint) {
    my $st = $self->_call($mac, 'mirror-status', $mirror);
    my $line = result_line($st);
    return { outcome => 'human', detail => "mirror-status: $mirror is not a mirror on $host ($line)" } if $st->{rc} == 3;
    return { outcome => 'failed', detail => "mirror-status $mirror exit $st->{rc}: $line" } if $st->{rc} != 0;
    my ($state) = ($st->{stdout} // '') =~ /^MIRROR \Q$mirror\E (\S+)\s*$/m;
    $state //= 'unknown';
    return { outcome => 'clean', detail => "mirror-status clean ($mirror)" } if $state eq 'clean';
    return { outcome => 'healing', detail => "mirror-status: $mirror resyncing" } if $state eq 'resyncing';
    return { outcome => 'failed', detail => "mirror-status: $mirror absent (not assembled on $host)" } if $state eq 'absent';
    my $wd = $self->workload_disk($mac, $mirror)
        or return { outcome => 'human', detail => "no workload record has a VM on $host with the mirror $mirror: nothing to rejoin from" };
    my @legs = missing_legs($wd->{specs}, $st->{stdout}, $hint);
    return { outcome => 'human', detail => "workload $wd->{workload} VM $wd->{vm}: no leg specs for $mirror" } unless @legs;
    my (@d, %o);
    for my $spec (@legs) {
        my $r = $self->_call($mac, 'mirror-rejoin', $mirror, '--leg', $spec);
        my $l = result_line($r);
        push @d, "mirror-rejoin $mirror --leg $spec exit $r->{rc}" . (length $l ? ": $l" : '');
        $o{ $r->{rc} == 0 ? 'ok' : $r->{rc} == 3 ? 'human' : 'failed' }++;
    }
    my $outcome = $o{human} ? 'human' : $o{failed} ? 'failed' : 'healing';
    return { outcome => $outcome, detail => "$state; " . join('; ', @d), attempted => 1 };
}

# attempt($rec): the combined outcome over the issue's mirror(s).
sub attempt ($self, $rec) {
    my $f = $rec->{fields} // {};
    my $host = $f->{host} // '';
    my $mac = $self->find_host($host);
    return { outcome => 'human', detail => "host '$host' is not in the registry" } unless defined $mac;
    my @mirrors;
    if (defined $f->{mirror}) {
        @mirrors = ($f->{mirror});
    } else {
        my $st = $self->_call($mac, 'mirror-status');
        return { outcome => 'failed', detail => "mirror-status exit $st->{rc}: " . result_line($st) } if $st->{rc} != 0;
        my %s = ($st->{stdout} // '') =~ /^MIRROR (\S+) (\S+)\s*$/mg;
        # absent: not assembled (a stopped VM), nothing of a running array to heal
        @mirrors = sort grep { $s{$_} ne 'clean' && $s{$_} ne 'absent' } keys %s;
        return { outcome => 'clean', detail => "mirror-status clean (every mirror on $host)" } unless @mirrors;
    }
    my @r = map { $self->_mirror($mac, $host, $_, $f->{leg}) } @mirrors;
    my %o = map { $_->{outcome} => 1 } @r;
    my $outcome = $o{human} ? 'human' : $o{failed} ? 'failed' : $o{healing} ? 'healing' : 'clean';
    return { outcome => $outcome, detail => join(' | ', map { $_->{detail} } @r),
        attempted => (grep { $_->{attempted} } @r) ? 1 : 0 };
}

# heal($rec): one attempt or check, its result in the trail.
sub heal ($self, $rec) {
    my $res = $self->attempt($rec);
    my $issues = $self->{issues};
    my $resolved;
    $issues->update($rec->{id}, sub ($r) {
        return unless $r->{state} eq 'open' || $r->{state} eq 'healing';    # changed meanwhile
        my $h = $r->{heal} //= { attempts => 0 };
        my $now = $self->_now;
        $h->{last_at} = HPS::Issues::iso($now);
        $h->{last_result} = HPS::Issues::clean_text("$res->{outcome}: $res->{detail}");
        my $o = $res->{outcome};
        if ($res->{attempted} || $o eq 'failed') {
            $h->{attempts}++;
            $issues->trail($r, 'heal', "attempt $h->{attempts}: $res->{detail}");
        } else {
            $issues->trail($r, 'check', $res->{detail});
        }
        if ($o eq 'clean') {
            $resolved = 1;
            delete $h->{next_at};
        } elsif ($o eq 'healing') {
            $issues->set_state($r, 'healing', 'resync running');
            $h->{next_at} = $now + CHECK_DELAY;
        } elsif ($o eq 'human') {
            $issues->set_state($r, 'needs-human', $res->{detail});
            if ($r->{severity} ne 'urgent') {
                $r->{severity} = 'urgent';
                $issues->trail($r, 'escalated', 'needs a human');
            }
            delete $h->{next_at};
        } else {
            $issues->set_state($r, 'open', 'back to open: not healed');
            my $wait = backoff($h->{attempts});
            $h->{next_at} = $now + $wait;
            if ($wait == $DELAYS[-1] && $r->{severity} ne 'urgent') {
                $r->{severity} = 'urgent';
                $issues->trail($r, 'escalated', "still not healed after $h->{attempts} attempts; retrying every ${wait}s");
            }
        }
    });
    $issues->resolve($rec->{id}, 'mirror-status clean') if $resolved;
    my $after = $issues->get($rec->{id});
    $issues->_log($after->{state} eq 'needs-human' ? 'err' : 'info',
        "hps-issue: heal $rec->{id} $res->{outcome}: " . HPS::Issues::clean_text($res->{detail}))
        unless $res->{outcome} eq 'healing' && !$res->{attempted};
    return $res;
}

1;
