package HPS::Workload::Report;
# hps-workload report: everything an operator needs about a workload VM that will not
# start, on one screen, and as JSON for the browser. READ-ONLY: it writes nothing (no
# registry key, reservation, job or state file) and calls only read-only node scripts
# (storage-zvol-list, iscsi-status, mirror-status).
#
# Sections per VM, in this order:
#   storage      per disk and leg what the IPS RECORDED (workload record
#                workload_<name> in cluster.db, definition workloads/<name>.json, the
#                host registry), complete with every node off; beside it, only when the
#                node answers, what the node says LIVE
#   why          the newest failed or refused operation on the VM: verb, step, time,
#                the failure line verbatim, and its source
#   open_issues  the unresolved HPS-ISSUE records naming the VM, its workload or mirror
#   last_errors  the newest error lines from the events view, the IPS log, the failed
#                job records, the issue trails and the compute host's syslog
#   reconstruct  the existing commands, with this VM's names, that assemble the mirror
#
# A value that is not on record is the string "not recorded"; a node that does not
# answer gives "not reachable" for every live fact; with probing off "not probed". A
# key is never left out for want of data. Nothing secret is stored in the records read
# here (HPS::Log withholds a line that looks like one), and nothing secret is printed.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use POSIX qw(strftime);
use Time::Local qw(timegm);
use HPS::Issues ();
use HPS::Log ();
use HPS::Keysafe ();

use constant NOT_RECORDED  => 'not recorded';
use constant NOT_REACHABLE => 'not reachable';
use constant NOT_PROBED    => 'not probed';
use constant SCHEMA        => 1;
use constant MAX_ERRORS    => 15;
use constant PER_SOURCE    => 10;

our @TOP_KEYS = qw(schema workload cluster generated_at state probed vms notes);
our @VM_KEYS  = qw(vm compute_host recorded_state last_owner storage why_it_will_not_start open_issues last_errors reconstruct);

sub _iso ($epoch) { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $epoch) }

sub _epoch ($iso) {
    return undef unless defined $iso && $iso =~ /\A(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)/;
    return eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
}

sub _slurp_json ($path) {
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return eval { JSON::PP->new->utf8->decode($t) };
}

# The registry host of a name (HOSTNAME, whole or first label): {name, mac, ip}; undef when none.
sub _find_host ($reg, $name) {
    return undef unless defined $name && length $name;
    for my $m (eval { $reg->host_list_all }) {
        my $hn = $reg->host_exists($m, 'HOSTNAME') ? $reg->host_get($m, 'HOSTNAME') : next;
        (my $first = $hn) =~ s/\..*//;
        next unless $hn eq $name || $first eq $name;
        return { name => $name, mac => $m, ip => ($reg->host_exists($m, 'IP') ? $reg->host_get($m, 'IP') : undef) };
    }
    return undef;
}

# new(registry, runner, log (an HPS::Log), now, probe, jobs_dir)
sub new ($class, %o) {
    return bless { %o, now => $o{now} // time, reach => {}, probe => ($o{probe} // 1) }, $class;
}

sub _reachable ($self, $h) {
    return 0 unless $h && defined $h->{mac};
    return $self->{reach}{ $h->{mac} } //= do {
        my $r = $self->{runner};
        $r && $r->can('ping') ? ($r->ping($h->{mac}) ? 1 : 0) : ($r ? 1 : 0);
    };
}

# _node($h, $script, @args): ($state, $stdout): state 'ok', 'not probed', 'not reachable' or
# "unknown (...)".
sub _node ($self, $h, $script, @args) {
    return (NOT_PROBED) unless $self->{probe} && $self->{runner};
    return (NOT_REACHABLE) unless $self->_reachable($h);
    my $r = eval { $self->{runner}->call(mac => $h->{mac}, script => $script, args => [@args]) };
    return ('unknown (' . ($@ =~ s/\s+\z//r) . ')') unless $r;
    return ('ok', $r->{stdout} // '', $r->{rc}, $r->{stderr}) if $r->{rc} == 0 || ($script eq 'mirror-status' && $r->{rc} == 3);
    my ($last) = reverse grep { length } split /\n/, ($r->{stderr} // '');
    return ("unknown ($script exit $r->{rc}" . (defined $last ? ": $last" : '') . ')', '', $r->{rc});
}

#--- the records -----------------------------------------------------------------------

sub _definition ($self, $name) {
    my $reg = $self->{registry};
    my $path = $reg->workload_dir($self->{cluster}) . "/$name.json";
    return undef unless -f $path;
    return _slurp_json($path);
}

sub _record ($self, $name) {
    my $reg = $self->{registry};
    return undef unless $reg->cluster_exists($self->{cluster}, "workload_$name");
    return eval { $reg->cluster_get_json($self->{cluster}, "workload_$name") };
}

# The legs of one disk: [{index, kind, host, address, pool, zvol, target, portal, spec, size}] from the
# record (its leg specs, in mirror order), else from the definition. Every missing value says so.
sub _legs ($self, $wl, $vmname, $dname, $rdisk, $ddisk, $rvm) {
    my $reg = $self->{registry};
    my @specs = ref $rdisk->{legs} eq 'ARRAY' ? @{ $rdisk->{legs} } : ();
    my @remote = ref $rdisk->{remote} eq 'ARRAY' ? @{ $rdisk->{remote} } : ();
    my @dlegs = ref $ddisk->{legs} eq 'ARRAY' ? @{ $ddisk->{legs} } : ();
    my $compute = $rvm->{host};
    if (!@specs) {    # no record: what the definition says (the spec portal only when it names one)
        for my $l (@dlegs) {
            if (defined $l->{pool}) { push @specs, "local:$l->{pool}/enc/vm/$wl-$vmname-$dname" }
            else { push @specs, 'iscsi:' . ($l->{portal} // '?') . ":$l->{iqn}" }
        }
    }
    my @out;
    my $i = 0;
    for my $spec (@specs) {
        my ($r, $dl);
        my %leg = (index => $i++, spec => $spec, recorded_from => (@{ $rdisk->{legs} // [] } ? 'workload record' : 'workload definition'));
        if ($spec =~ /\Alocal:(.+)\z/) {
            my $ds = $1;
            my ($dl) = grep { defined $_->{pool} } @dlegs;
            @leg{qw(kind host pool zvol target portal)} = ('local', $compute // $dl->{host} // NOT_RECORDED, (split m{/}, $ds)[0], $ds, 'not applicable (local zvol)', 'not applicable');
        }
        elsif ($spec =~ /\Aiscsi:([^:]*):(.+)\z/) {
            my ($portal, $iqn) = ($1, $2);
            ($r) = grep { ($_->{iqn} // '') eq $iqn } @remote;
            ($dl) = grep { ($_->{iqn} // '') eq $iqn } @dlegs;
            my $host = $r->{host} // $dl->{host};
            my $sh = _find_host($reg, $host);
            my $exports = $sh ? (eval { $reg->host_exists($sh->{mac}, 'storage_exports') ? $reg->host_get_json($sh->{mac}, 'storage_exports') : [] } // []) : [];
            my ($exp) = grep { ($_->{iqn} // '') eq $iqn } @$exports;
            my $zvol = $r->{dataset} // $exp->{zvol};
            my $pool = $r->{pool} // (defined $zvol ? (split m{/}, $zvol)[0] : undef);
            $leg{recorded_from} .= ($r->{dataset} ? '' : (defined $exp->{zvol} ? ' and storage_exports of the storage host' : ''));
            @leg{qw(kind host pool zvol target portal)} = ('iscsi', $host // NOT_RECORDED, $pool // NOT_RECORDED, $zvol // NOT_RECORDED, $iqn,
                ($portal ne '?' && length $portal ? $portal : ($exp->{portal} // NOT_RECORDED)));
            $leg{address} = $sh && defined $sh->{ip} ? $sh->{ip} : (($portal ne '?' && length $portal) ? "$portal (portal; host IP not recorded)" : NOT_RECORDED);
            $leg{host_known} = $sh ? JSON::PP::true : JSON::PP::false;
            $leg{_mac} = $sh ? $sh->{mac} : undef;
        }
        else {
            @leg{qw(kind host pool zvol target portal)} = ('unknown', NOT_RECORDED, NOT_RECORDED, NOT_RECORDED, NOT_RECORDED, NOT_RECORDED);
            $leg{note} = "leg spec '$spec' is not local: or iscsi:";
        }
        $leg{address} //= do { my $h = _find_host($reg, $leg{host}); $h && defined $h->{ip} ? $h->{ip} : NOT_RECORDED };
        $leg{size} = $r->{size} // $ddisk->{size} // NOT_RECORDED;
        $leg{size_note} = 'the disk size (the leg zvol has no size of its own on record)';
        push @out, \%leg;
    }
    return \@out;
}

# live facts per leg and per mirror
sub _live_disk ($self, $disk, $compute) {
    my $mirror = $disk->{mirror};
    my @legs = @{ $disk->{legs} };
    my $na = sub { +{ host_reachable => $_[0], zvol_exists => $_[0], target_exported => $_[0], session => $_[0], device_state => $_[0] } };
    # per leg: the zvol and the target, from the leg's storage host (or the compute host for a local zvol)
    my %zl;
    for my $l (@legs) {
        my $live = $na->(NOT_PROBED);
        $live->{target_exported} = 'not applicable' if $l->{kind} eq 'local';
        $l->{live} = $live;
        next unless $self->{probe};
        my $h = $l->{kind} eq 'local' ? $compute : ($l->{_mac} ? { mac => $l->{_mac}, name => $l->{host} } : undef);
        if (!$h) { $l->{live} = $na->('unknown (storage host not in the registry)'); $l->{live}{target_exported} = 'not applicable' if $l->{kind} eq 'local'; next }
        my $reach = $self->{runner} ? ($self->_reachable($h) ? 1 : 0) : 0;
        $live->{host_reachable} = $reach ? 'yes' : NOT_REACHABLE;
        if (!$reach) { $live->{$_} = NOT_REACHABLE for qw(zvol_exists target_exported session device_state); $live->{target_exported} = 'not applicable' if $l->{kind} eq 'local'; $live->{session} = 'not applicable' if $l->{kind} eq 'local' && 0; next }
        if (defined $l->{pool} && $l->{pool} !~ /\Anot recorded/ && defined $l->{zvol} && $l->{zvol} ne NOT_RECORDED) {
            my $key = "$h->{mac}/$l->{pool}";
            $zl{$key} //= [ $self->_node($h, 'storage-zvol-list', $l->{pool}) ];
            my ($st, $out) = @{ $zl{$key} };
            $live->{zvol_exists} = $st ne 'ok' ? $st : $out =~ /^\Q$l->{zvol}\E\s/m ? 'yes' : 'no';
        }
        else { $live->{zvol_exists} = 'unknown (zvol or pool not recorded)' }
        if ($l->{kind} eq 'iscsi') {
            my $key = "$h->{mac}/iscsi";
            $zl{$key} //= [ $self->_node($h, 'iscsi-status') ];
            my ($st, $out) = @{ $zl{$key} };
            $live->{target_exported} = $st ne 'ok' ? $st : index($out, $l->{target}) >= 0 ? 'yes' : 'no';
        }
        $live->{session} = $l->{kind} eq 'local' ? 'not applicable' : NOT_PROBED if $live->{session} eq NOT_PROBED;
        $live->{device_state} = $l->{kind} eq 'local' ? 'not applicable' : NOT_PROBED if $live->{device_state} eq NOT_PROBED;
    }
    my %m = (host_reachable => NOT_PROBED, mirror_state => NOT_PROBED, array_state => NOT_PROBED);
    if ($self->{probe} && $disk->{mirrored} && $compute) {
        my ($st, $out) = $self->_node($compute, 'mirror-status', $mirror);
        if ($st eq 'ok') {
            $m{host_reachable} = 'yes';
            my ($ms) = reverse $out =~ /^MIRROR \S+ (\S+)/mg;
            my ($as) = $out =~ /^ARRAY \S+ array_state=(\S+)/m;
            $m{mirror_state} = $ms // 'unknown (no MIRROR line)';
            $m{array_state}  = $as // 'not reported by this node image';
            for my $l (@legs) {
                next unless $l->{kind} eq 'iscsi';
                my ($s, $d) = $out =~ /^LEGSTATE \Q$l->{spec}\E session=(\S+) device=(\S+)/m;
                $l->{live}{session} = $s // 'not reported by this node image';
                $l->{live}{device_state} = $d // 'not reported by this node image';
            }
        }
        else {
            %m = (host_reachable => ($st eq NOT_REACHABLE ? NOT_REACHABLE : 'yes'), mirror_state => $st, array_state => $st);
            for my $l (grep { $_->{kind} eq 'iscsi' } @legs) { $l->{live}{session} = $st; $l->{live}{device_state} = $st }
        }
        $m{mirror_state} = 'absent: not assembled on this node' if $m{mirror_state} eq 'absent';
    }
    elsif ($self->{probe} && !$disk->{mirrored}) { %m = (host_reachable => 'not applicable', mirror_state => 'not applicable (one leg, no mirror)', array_state => 'not applicable') }
    delete $_->{_mac} for @legs;
    return \%m;
}

#--- failures and errors ---------------------------------------------------------------

# The part of a text that says what happened: REFUSED/FAILED/DIVERGED/UNREADABLE ... to the
# end, else the text.
sub _line ($t) {
    return $1 if $t =~ /\b((?:REFUSED|FAILED|DIVERGED|UNREADABLE) .*?)(?:\)?\s*\z)/;
    return $t;
}

sub _verb_step ($t) {
    # an event of hps-workload: "<verb> <name>: step N/M <script> exited R: ..." or "<verb> <name> refused: ..."
    return ($1, "step $2 $3 exited $4") if $t =~ /\A([a-z-]+) \S+: step (\d+\/\d+) (\S+) exited (\d+)/;
    return ($1, undef) if $t =~ /\A([a-z-]+) \S+ refused/;
    my ($v, $rc) = $t =~ /\b((?:vm|mirror|storage|iscsi)-[a-z-]+) [^;]*?exit (\d+)/ ? ($1, $2) : ();
    return (defined $v ? ($v, "exit $rc") : (undef, undef));
}

sub _events ($self, $name, $vm) {
    my $log = $self->{log} or return ([], 'no log reader');
    my $r = eval { $log->events_log(grep => $name, lines => 500) };
    return ([], 'events view not readable: ' . (ref $@ ? $@->message : ($@ =~ s/\s+\z//r))) unless $r;
    my @e = grep { ($_->{kind} // '') eq 'workload' && defined $_->{subject} && ($_->{subject} eq $name || $_->{subject} eq "$name/$vm") } @{ $r->{lines} };
    return (\@e, undef);
}

sub _jobs ($self, $name) {
    my $dir = $self->{jobs_dir} or return [];
    my @files = sort { (stat $b)[9] <=> (stat $a)[9] } glob("$dir/failed/*.result.json");
    my @out;
    for my $f (@files[ 0 .. ($#files < 199 ? $#files : 199) ]) {
        my $j = _slurp_json($f) or next;
        next unless ($j->{kind} // '') =~ /\Aworkload-/;
        my $named = ref $j->{args} eq 'ARRAY' ? (($j->{args}[0] // '') eq $name) : (($j->{stderr} // '') . ($j->{stdout} // '')) =~ /(?<![A-Za-z0-9-])\Q$name\E(?![A-Za-z0-9-])/;
        push @out, $j if $named;
    }
    return \@out;
}

sub _issues ($self, $name, $vm, $mirrors, $iqns) {
    my $reg = $self->{registry};
    my $dir = $reg->issues_dir($self->{cluster});
    return [] unless -d $dir;
    my $is = HPS::Issues->new(registry => $reg, cluster => $self->{cluster}, dir => $dir);
    my %mir = map { $_ => 1 } @$mirrors;
    my @hit;
    for my $i ($is->all) {
        my $f = $i->{fields} // {};
        my $leg = $f->{leg} // '';
        my $about = (defined $f->{workload} && $f->{workload} eq $name) || (defined $f->{guest} && $f->{guest} eq $vm)
            || (defined $f->{mirror} && $mir{ $f->{mirror} }) || scalar(grep { length $_ && index($leg, $_) >= 0 } @$iqns);
        push @hit, $i if $about;
    }
    return \@hit;
}

sub _issue_view ($i) {
    my $h = $i->{heal} // {};
    return { id => $i->{id}, kind => $i->{kind}, state => $i->{state}, severity => $i->{severity} // NOT_RECORDED,
        summary => $i->{summary} // NOT_RECORDED, opened_at => $i->{opened_at} // NOT_RECORDED,
        last_seen_at => $i->{last_seen_at} // NOT_RECORDED, heal_attempts => $h->{attempts} // 0,
        heal_last_at => $h->{last_at} // NOT_RECORDED, heal_last_result => $h->{last_result} // NOT_RECORDED };
}

sub _vm_failures ($self, $name, $vm, $mirrors, $iqns) {
    my (@why, @err);
    my ($events, $eerr) = $self->_events($name, $vm);
    for my $e (@$events) {
        my $failed = ($e->{state} // '') =~ /\A(?:refused|failed|unreadable)\z/ || ($e->{pri} // '') =~ /\A(?:warning|urgent)\z/;
        next unless $failed;
        my ($verb, $step) = _verb_step($e->{text} // '');
        my $c = { epoch => $e->{epoch}, at => $e->{time}, source => 'events.log', verb => $verb // NOT_RECORDED, step => $step // NOT_RECORDED,
            line => _line($e->{text} // $e->{message}), text => $e->{text} // $e->{message} };
        push @err, $c;
        push @why, $c if ($e->{state} // '') =~ /\A(?:refused|failed)\z/;
    }
    for my $j (@{ $self->_jobs($name) }) {
        my ($last) = reverse grep { /\S/ } split /\n/, ($j->{stderr} // '');
        my $e = _epoch($j->{finished_at});
        my $c = { epoch => $e // 0, at => $j->{finished_at} // NOT_RECORDED, source => "jobs/failed/$j->{id}", verb => ($j->{kind} // '') =~ s/\Aworkload-//r,
            step => NOT_RECORDED, line => $last // "exit $j->{exit}", text => $last // "exit $j->{exit}" };
        push @err, $c;
        push @why, $c;
    }
    for my $i (@{ $self->_issues($name, $vm, $mirrors, $iqns) }) {
        for my $t (@{ $i->{trail} // [] }) {
            next unless ($t->{event} // '') =~ /\A(?:heal|failed|escalated|needs-human)\z/ || ($t->{detail} // '') =~ /\b(?:REFUSED|FAILED|failed)\b/;
            my $ep = _epoch($t->{at}) // 0;
            my ($verb, $step) = _verb_step($t->{detail} // '');
            my $c = { epoch => $ep, at => $t->{at} // NOT_RECORDED, source => "issue $i->{id} trail ($t->{event})", verb => $verb // NOT_RECORDED,
                step => $step // NOT_RECORDED, line => _line($t->{detail} // ''), text => $t->{detail} // '' };
            push @err, $c;
            push @why, $c if ($t->{event} // '') eq 'heal' && ($t->{detail} // '') =~ /\bexit [1-9]|REFUSED|FAILED|failed/;
        }
    }
    my $ips = eval { $self->{log} && $self->{log}->ips_log(grep => $name, min_level => 'warning', lines => PER_SOURCE) };
    push @err, map { +{ epoch => $_->{epoch}, at => $_->{time}, source => "IPS log ($_->{source})", verb => NOT_RECORDED, step => NOT_RECORDED, line => $_->{message}, text => $_->{message} } } @{ $ips->{lines} // [] };
    return (\@why, \@err, $eerr);
}

sub _node_syslog ($self, $compute, $vm, $mirrors) {
    return () unless $self->{log} && $compute && $compute->{name};
    my @out;
    for my $w ($vm, @$mirrors) {
        my $r = eval { $self->{log}->host_log($compute->{name}, grep => $w, min_level => 'warning', lines => PER_SOURCE) } or next;
        push @out, map { +{ epoch => $_->{epoch}, at => $_->{time}, source => "syslog of $compute->{name}", verb => NOT_RECORDED, step => NOT_RECORDED,
            line => $_->{message}, text => $_->{message} } } @{ $r->{lines} };
    }
    # a mirror name holds the VM name, so one line answers both greps: keep it once
    my %seen;
    return grep { !$seen{ "$_->{epoch}|$_->{line}" }++ } @out;
}

#--- the report ------------------------------------------------------------------------

sub _reconstruct ($vm, $compute) {
    my @c;
    my $ch = $compute->{name} // NOT_RECORDED;
    for my $d (@{ $vm->{storage} }) {
        my @iscsi = grep { $_->{kind} eq 'iscsi' } @{ $d->{legs} };
        if (!$d->{mirrored}) {
            my ($l) = @{ $d->{legs} };
            push @c, "# disk $d->{disk}: one leg, no mirror; the disk is the zvol " . ($l ? $l->{zvol} : NOT_RECORDED) . " on $ch (hps-storage $ch up imports the pool and unlocks it)";
            next;
        }
        my %seen;
        for my $l (@iscsi) {
            next if $seen{ $l->{host} }++ || $l->{host} eq NOT_RECORDED;
            push @c, "hps-storage $l->{host} up    # imports the pool, unlocks it and exports the targets of storage host $l->{host}";
        }
        push @c, "scripts/hps-run.sh $ch mirror-status $d->{mirror}    # what the compute host says now";
        if (grep { $_->{spec} =~ /\?/ || $_->{target} eq NOT_RECORDED } @{ $d->{legs} }) {
            push @c, "# disk $d->{disk}: a leg is not recorded; nothing is printed that would guess it";
            next;
        }
        push @c, "scripts/hps-run.sh $ch mirror-assemble $d->{mirror} " . join(' ', map { "--leg $_->{spec}" } @{ $d->{legs} });
    }
    push @c, "bin/hps-workload start $vm->{workload} --vm $vm->{vm}    # assembles the mirrors the same way, then starts the guest" if @c;
    return \@c;
}

# report($name, vm => $vm): the structure.
sub report ($self, $name, %o) {
    my $reg = $self->{registry};
    $self->{cluster} //= $reg->active_cluster;
    my $def = $self->_definition($name);
    my $rec = $self->_record($name);
    my @notes;
    die HPS::Keysafe::Error->new('notfound', "no workload '$name': no definition and no record") unless $def || $rec;
    push @notes, "no workload record: the workload is not created (or was destroyed); the storage shown is what its definition says" unless $rec;
    push @notes, "no readable definition workloads/$name.json: storage shown from the record alone" unless $def;
    my %dvm = map { $_->{name} => $_ } @{ $def->{vms} // [] };
    my @names = sort keys %{ { map { $_ => 1 } (keys %dvm, keys %{ $rec->{vms} // {} }) } };
    if (defined $o{vm}) {
        die HPS::Keysafe::Error->new('notfound', "workload '$name' has no VM '$o{vm}' (VMs: " . join(', ', @names) . ')') unless grep { $_ eq $o{vm} } @names;
        @names = ($o{vm});
    }
    my @vms;
    for my $vn (@names) {
        my ($rvm, $dv) = ($rec->{vms}{$vn} // {}, $dvm{$vn} // {});
        my $cname = $rvm->{host} // $dv->{compute_host} // ((grep { defined $_->{pool} } map { @{ $_->{legs} // [] } } @{ $dv->{disks} // [] })[0] // {})->{host};
        my $ch = _find_host($reg, $cname) // { name => $cname, mac => undef, ip => undef };
        my %dd = map { $_->{name} => $_ } @{ $dv->{disks} // [] };
        my @dn = sort keys %{ { map { $_ => 1 } (keys %dd, keys %{ $rvm->{disks} // {} }) } };
        my (@disks, @mirrors, @iqns);
        for my $dn (@dn) {
            my $legs = $self->_legs($name, $vn, $dn, $rvm->{disks}{$dn} // {}, $dd{$dn} // {}, { host => $cname });
            my $mirror = ($rvm->{disks}{$dn}{md} // '') =~ m{/dev/md/(.+)\z} ? $1 : "$vn-$dn";
            my $mirrored = @$legs == 2 ? 1 : 0;
            push @mirrors, $mirror if $mirrored;
            push @iqns, map { $_->{target} } grep { $_->{kind} eq 'iscsi' } @$legs;
            my $disk = { disk => $dn, mirror => ($mirrored ? $mirror : 'not applicable (one leg, no mirror)'), mirror_name => $mirror,
                size => $dd{$dn}{size} // $legs->[0]{size} // NOT_RECORDED, mirrored => $mirrored, device => $rvm->{disks}{$dn}{md} // NOT_RECORDED, legs => $legs };
            $disk->{mirror} = $mirror if $mirrored;
            $disk->{live_mirror} = $self->_live_disk({ %$disk, mirror => $mirror }, $ch);
            push @disks, $disk;
        }
        my ($why, $err, $eerr) = $self->_vm_failures($name, $vn, \@mirrors, \@iqns);
        my @last = (@$err, $self->_node_syslog($ch, $vn, \@mirrors));
        @last = sort { $b->{epoch} <=> $a->{epoch} } @last;
        @last = @last[ 0 .. (MAX_ERRORS - 1) ] if @last > MAX_ERRORS;
        my ($w) = sort { $b->{epoch} <=> $a->{epoch} } @$why;
        my $whyv = $w ? { status => 'failed or refused operation on record', at => $w->{at}, source => $w->{source}, verb => $w->{verb}, step => $w->{step}, line => $w->{line} }
            : { status => 'none on record', at => NOT_RECORDED, source => NOT_RECORDED, verb => NOT_RECORDED, step => NOT_RECORDED,
                line => 'no failed or refused operation of this workload is on record in the events view, the failed jobs or the issue trails' };
        $whyv->{note} = $eerr if $eerr;
        my $v = { vm => $vn, workload => $name,
            compute_host => { name => $cname // NOT_RECORDED, address => $ch->{ip} // NOT_RECORDED, recorded_from => defined $rvm->{host} ? 'workload record' : defined $cname ? 'workload definition' : NOT_RECORDED },
            recorded_state => $rvm->{state} // NOT_RECORDED, last_owner => $rvm->{last_owner} // NOT_RECORDED,
            storage => \@disks, why_it_will_not_start => $whyv,
            open_issues => [ map { _issue_view($_) } grep { $_->{state} ne 'resolved' } @{ $self->_issues($name, $vn, \@mirrors, \@iqns) } ],
            last_errors => [ map { +{ time => $_->{at}, source => $_->{source}, line => $_->{line} } } @last ] };
        $v->{reconstruct} = _reconstruct($v, $ch);
        delete $v->{workload};
        push @vms, $v;
    }
    my $out = { schema => SCHEMA, workload => $name, cluster => $self->{cluster}, generated_at => _iso($self->{now}),
        state => $rec->{state} // NOT_RECORDED, probed => ($self->{probe} ? JSON::PP::true : JSON::PP::false), vms => \@vms, notes => \@notes };
    return _redact($out);
}

# Nothing that looks like a secret is shown (the log reader's own test): such a string becomes
# "[redacted]".
sub _redact ($x) {
    if (ref $x eq 'HASH')  { $x->{$_} = _redact($x->{$_}) for keys %$x; return $x }
    if (ref $x eq 'ARRAY') { $_ = _redact($_) for @$x; return $x }
    return $x if ref $x || !defined $x;
    return HPS::Log::is_secret($x) ? '[redacted]' : $x;
}

#--- text ------------------------------------------------------------------------------

sub render ($r) {
    my $o = "Workload $r->{workload} (cluster $r->{cluster}): $r->{state}; report at $r->{generated_at}; live facts "
        . ($r->{probed} ? 'from the nodes that answer' : 'not probed (--no-probe)') . "\n";
    $o .= "  note: $_\n" for @{ $r->{notes} };
    for my $v (@{ $r->{vms} }) {
        $o .= "\n=== VM $v->{vm}: recorded $v->{recorded_state}, last owner $v->{last_owner}\n";
        $o .= "STORAGE (recorded on the IPS)\n";
        $o .= "  compute host $v->{compute_host}{name} ($v->{compute_host}{address}), from the $v->{compute_host}{recorded_from}\n";
        for my $d (@{ $v->{storage} }) {
            $o .= "  disk $d->{disk}: " . ($d->{mirrored} ? "mirror $d->{mirror}" : $d->{mirror}) . ", size $d->{size}, device $d->{device}\n";
            for my $l (@{ $d->{legs} }) {
                $o .= "    leg $l->{index} ($l->{kind}): storage host $l->{host} ($l->{address}), pool $l->{pool}, zvol $l->{zvol}, target $l->{target}\n";
                $o .= "      spec $l->{spec}; portal $l->{portal}; size $l->{size}; recorded from $l->{recorded_from}\n";
                my $x = $l->{live};
                $o .= "      live: host $x->{host_reachable}; zvol exists $x->{zvol_exists}; target exported $x->{target_exported}; session $x->{session}; device $x->{device_state}\n";
            }
            my $m = $d->{live_mirror};
            $o .= "    live mirror (on $v->{compute_host}{name}): $m->{mirror_state}; array_state $m->{array_state}\n";
        }
        my $w = $v->{why_it_will_not_start};
        $o .= "WHY IT WILL NOT START\n";
        $o .= $w->{status} eq 'none on record' ? "  $w->{line}\n"
            : "  $w->{verb}, $w->{step}, at $w->{at}, from $w->{source}\n  $w->{line}\n";
        $o .= "  open issue $_->{id} ($_->{kind}, $_->{state}, $_->{severity}): $_->{summary}\n    healer, $_->{heal_attempts} attempt(s), last $_->{heal_last_at}: $_->{heal_last_result}\n" for @{ $v->{open_issues} };
        $o .= "  no open HPS-ISSUE names this VM\n" unless @{ $v->{open_issues} };
        $o .= "LAST ERRORS (newest first)\n";
        $o .= "  $_->{time}  [$_->{source}]  $_->{line}\n" for @{ $v->{last_errors} };
        $o .= "  none found in the sources read\n" unless @{ $v->{last_errors} };
        $o .= "TO RECONSTRUCT BY HAND\n";
        $o .= "  $_\n" for @{ $v->{reconstruct} };
        $o .= "  nothing to reconstruct\n" unless @{ $v->{reconstruct} };
    }
    return $o;
}

1;
