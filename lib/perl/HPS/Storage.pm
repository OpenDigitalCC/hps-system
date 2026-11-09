package HPS::Storage;
# IPS-side driver of a node's storage role. Every node action is a ctrl-exec
# script (node-manager/nixos-26/scripts/); this module decides which scripts to
# call, in which order, with which arguments and which stdin document, and
# records what happened in the host registry.
#
# plan($op) returns the calls as a list of hashes with the input document
# REDACTED (no key, no secret, no approval signature). run($op) sends the real
# documents through a runner object (see HPS::Storage::Runner::HpsRun).
#
# Key material is read from HPS::Keysafe only inside the closure that builds
# the document for the one call that needs it, and appears in no plan, log
# line, registry value or error message.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP;
use POSIX qw(strftime);
use HPS::Registry;
use HPS::Keysafe;
use HPS::Approval;

my $POOL_RE = qr/^[a-z][a-z0-9_.-]*$/;
my $ZVOL_RE = qr{^[A-Za-z0-9][A-Za-z0-9_.:/-]*$};
my $IQN_RE  = qr/^iqn\.[A-Za-z0-9._:-]+$/;
my $ADDR_RE = qr/^[0-9A-Fa-f:.]+$/;
my $DS_RE   = qr{^([a-z][a-z0-9_.-]*)/enc/([A-Za-z0-9_-]+)$};    # <pool>/enc/<name>
my $SIZE_RE = qr/^[1-9][0-9]*[KMGT]$/;
my $KEY     = 'enc';    # the keysafe name of <pool>/enc's key

my %OPS = (
    'up' => '_steps_up', 'down' => '_steps_down', 'create' => '_steps_create',
    'destroy' => '_steps_destroy', 'trim-check' => '_steps_trim', 'status' => '_steps_status',
    'zvol-create' => '_steps_zvol_create', 'zvol-destroy' => '_steps_zvol_destroy',
    'zvol-list' => '_steps_zvol_list', 'export' => '_steps_export', 'unexport' => '_steps_unexport',
);

sub _fail ($kind, $msg) { die HPS::Keysafe::Error->new($kind, $msg) }

sub ops { return sort keys %OPS }

# new(host => MAC|HOSTNAME, pool => NAME, allow_any_pool_name => 0|1,
#     registry => $reg, keysafe => $ks, approval => $ap, runner => $obj,
#     logger => sub ($level, $msg), now => sub, sleep => sub ($s), wait => SECONDS)
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    my $ks  = $opt{keysafe}  // HPS::Keysafe->new(registry => $reg);
    my $self = bless {
        registry => $reg, keysafe => $ks,
        approval => $opt{approval} // HPS::Approval->new(registry => $reg, keysafe => $ks),
        runner   => $opt{runner} // HPS::Storage::Runner::HpsRun->new,
        logger   => $opt{logger} // \&_default_logger,
        now      => $opt{now} // sub { time },
        sleep    => $opt{sleep} // sub ($s) { sleep $s },
        wait     => $opt{wait} // 0,
        pool_arg => $opt{pool},
        any_pool => $opt{allow_any_pool_name} ? 1 : 0,
    }, $class;
    $self->{mac} = $self->_resolve_host($opt{host});
    return $self;
}

sub mac ($self)  { return $self->{mac} }
sub approval_info ($self) { return $self->{approval_info} }

# A MAC in any format, else a registry HOSTNAME (whole value or first label).
sub _resolve_host ($self, $host) {
    _fail('usage', 'a host (MAC or HOSTNAME) is required') unless defined $host && length $host;
    my $reg = $self->{registry};
    my $mac = eval { HPS::Registry::normalise_mac($host) };
    if (defined $mac) {
        _fail('notfound', "No such host: $host") unless $reg->host_exists($mac);
        return $mac;
    }
    for my $m ($reg->host_list_all) {
        my $name = $reg->host_exists($m, 'HOSTNAME') ? $reg->host_get($m, 'HOSTNAME') : undef;
        next unless defined $name;
        (my $first = $name) =~ s/\..*//;
        return $m if $name eq $host || $first eq $host;
    }
    _fail('notfound', "No host in the registry matches: $host");
}

#--- logging -----------------------------------------------------------------------

sub _default_logger ($level, $msg) {
    print STDERR "hps-storage: $msg\n";
    return if $ENV{HPS_STORAGE_NO_SYSLOG};
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-storage: $msg");
    };
    return;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

#--- registry helpers --------------------------------------------------------------

sub _stamp ($self) { return strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($self->{now}->())) }

sub _get ($self, $key) {
    my $reg = $self->{registry};
    return $reg->host_exists($self->{mac}, $key) ? $reg->host_get($self->{mac}, $key) : undef;
}

sub _set ($self, $key, $value) { $self->{registry}->host_set($self->{mac}, $key, $value); return }

sub _unset ($self, $key) {
    my $reg = $self->{registry};
    $reg->host_unset($self->{mac}, $key) if $reg->host_exists($self->{mac}, $key);
    return;
}

sub _record ($self, $op, $ok, $script, $rc) {
    $self->_set('storage_last', { op => $op, ok => $ok ? 1 : 0, at => $self->_stamp,
        (defined $script ? (script => $script) : ()), (defined $rc ? (rc => $rc + 0) : ()) });
    return;
}

#--- pool and exports --------------------------------------------------------------

# The pool a host's storage role uses: --pool, else the pool HPS created there,
# else the active cluster (the pool is named after the cluster).
sub pool ($self, %a) {
    my $pool = $a{pool} // $self->{pool_arg} // $self->_dataset_pool($a{dataset}) // $self->_get('storage_pool')
        // eval { $self->{registry}->active_cluster };
    _fail('failed', 'No pool name and no active cluster') unless defined $pool;
    _fail('usage', "pool name '$pool' must match $POOL_RE") unless $pool =~ $POOL_RE;
    return $pool;
}

# The pool part of a <pool>/enc/<name> dataset, else undef.
sub _dataset_pool ($self, $dataset) {
    return undef unless defined $dataset && $dataset =~ $DS_RE;
    return $1;
}

# The dataset argument of the zvol ops: <pool>/enc/<name>.
sub _dataset ($self, %a) {
    my $ds = $a{dataset};
    _fail('usage', 'a dataset <pool>/enc/<name> is required') unless defined $ds && length $ds;
    _fail('usage', "dataset '$ds' must be <pool>/enc/<name>") unless $ds =~ $DS_RE;
    return $ds;
}

# The ruling: a pool is named after the active cluster.
sub _check_cluster_name ($self, $pool) {
    return if $self->{any_pool};
    my $cluster = $self->{registry}->active_cluster;
    _fail('refused', "pool '$pool' is not the active cluster name '$cluster' (use --allow-any-pool-name to override)")
        unless $pool eq $cluster;
    return;
}

# storage_exports: a JSON list of {zvol, iqn, initiator, portal}.
sub exports ($self) {
    my $reg = $self->{registry};
    return () unless $reg->host_exists($self->{mac}, 'storage_exports');
    my $list = $reg->host_get_json($self->{mac}, 'storage_exports');
    _fail('malformed', 'storage_exports is not a list') unless ref $list eq 'ARRAY';
    my @out;
    for my $e (@$list) {
        _fail('malformed', 'storage_exports entries must be objects') unless ref $e eq 'HASH';
        for my $f (qw(zvol iqn initiator portal)) {
            _fail('malformed', "storage_exports entry has no $f") unless defined $e->{$f} && !ref $e->{$f};
        }
        _fail('malformed', 'storage_exports: bad zvol')      unless $e->{zvol} =~ $ZVOL_RE;
        _fail('malformed', 'storage_exports: bad iqn')       unless $e->{iqn} =~ $IQN_RE;
        _fail('malformed', 'storage_exports: bad initiator') unless $e->{initiator} =~ $IQN_RE;
        _fail('malformed', 'storage_exports: bad portal')    unless $e->{portal} =~ $ADDR_RE;
        push @out, { map { $_ => "$e->{$_}" } qw(zvol iqn initiator portal) };
    }
    return @out;
}

#--- approvals ---------------------------------------------------------------------

# Verified approval fields and the cluster secret (hex) for an action.
sub _approval ($self, $action, $pool) {
    my $mac = $self->{mac};
    my $json = $self->{approval}->get($mac, $action, $pool)
        // _fail('refused', $action eq 'zvol-destroy'
            ? "no $action approval for dataset '$pool' on host $mac (a human runs: hps-approve $action $mac --dataset $pool)"
            : "no $action approval for pool '$pool' on host $mac (a human runs: hps-approve $action $mac --pool $pool ...)");
    my $secret = $self->{keysafe}->cluster_secret('approval');
    my $f = $self->{approval}->verify($json, $secret);   # dies: expired, tampered, malformed
    _fail('refused', "the approval is for another host") unless $f->{mac} eq $mac;
    _fail('refused', "the approval is for pool '$f->{pool}', not '$pool'") unless $f->{pool} eq $pool;
    _fail('refused', "the approval is for $f->{action}, not $action") unless $f->{action} eq $action;
    $self->{approval_info} = { map { $_ => $f->{$_} } qw(action pool disks wipe expires issued_by mac) };
    return ($f, unpack('H*', $secret));
}

#--- the steps -----------------------------------------------------------------------

# A step: {script, args, input_desc (redacted hash or undef), input (code
# building the real document text, or undef), after (code run on success)}.
sub _step ($script, $args, %x) { return { script => $script, args => $args, %x } }

sub _json ($data) { return JSON::PP->new->utf8->canonical->encode($data) }

sub _key_hex ($self) { return unpack('H*', $self->{keysafe}->get_or_create_key($self->{mac}, $KEY)) }

sub _up_steps ($self, $pool) {
    my @s = (
        _step('storage-pool-import', [$pool]),
        _step('dataset-unlock', ["$pool/enc"],
            input_desc => { key_hex => '<redacted: 64 hex, from the keysafe>' },
            input => sub { _json({ key_hex => $self->_key_hex }) }),
    );
    for my $e ($self->exports) {
        push @s, _step('iscsi-export', [ $e->{zvol}, '--iqn', $e->{iqn}, '--initiator', $e->{initiator}, '--portal', $e->{portal} ]);
    }
    return @s;
}

sub _steps_up ($self, %a) {
    my $pool = $self->pool(%a);
    _fail('notfound', "pool not created by HPS: no '$KEY' key held for host $self->{mac}")
        unless $self->{keysafe}->has_key($self->{mac}, $KEY);
    return $self->_up_steps($pool);
}

sub _steps_down ($self, %a) {
    $self->pool(%a);
    return map { _step('iscsi-unexport', [ $_->{iqn} ]) } $self->exports;
}

sub _steps_create ($self, %a) {
    my $pool = $self->pool(%a);
    $self->_check_cluster_name($pool);
    my ($f, $secret_hex) = $self->_approval('pool-create', $pool);
    my %desc_approval = (%$f, hmac => '<redacted>');
    my @disks = @{ $f->{disks} };
    return (
        _step('storage-pool-create', [ $pool, (map { ('--disk', $_) } @disks), '--approval-file', '-' ],
            input_desc => { approval => \%desc_approval, secret => '<redacted: 64 hex, cluster approval secret>',
                            key_hex => '<redacted: 64 hex, generated by the keysafe if absent>' },
            input => sub { _json({ approval => $f, secret => $secret_hex, key_hex => $self->_key_hex }) },
            after => sub {
                $self->_set('storage_pool', $pool);
                $self->_set('storage_created_at', $self->_stamp);
            }),
        $self->_up_steps($pool),
    );
}

sub _steps_destroy ($self, %a) {
    my $pool = $self->pool(%a);
    $self->_check_cluster_name($pool);
    my ($f, $secret_hex) = $self->_approval('pool-destroy', $pool);
    my %desc_approval = (%$f, hmac => '<redacted>');
    return (
        _step('storage-pool-destroy', [ $pool, '--approval-file', '-' ],
            input_desc => { approval => \%desc_approval, secret => '<redacted: 64 hex, cluster approval secret>' },
            input => sub { _json({ approval => $f, secret => $secret_hex }) }),
    );
}

sub _steps_trim ($self, %a) { return _step('storage-trim-check', [ $self->pool(%a) ]) }

# Read-only: pool status, keystatus, zvols, exports. Imports nothing.
sub _steps_status ($self, %a) { return _step('storage-status', [ $self->pool(%a) ]) }

#--- zvols and exports

sub _steps_zvol_create ($self, %a) {
    my $ds = $self->_dataset(%a);
    my $size = $a{size};
    _fail('usage', 'a size like 1G is required (K, M, G or T)') unless defined $size && $size =~ $SIZE_RE;
    my $pool = $self->pool(%a, dataset => undef);    # the host's pool, not the dataset's
    _fail('refused', "dataset '$ds' is not in pool '$pool'") unless $self->_dataset_pool($ds) eq $pool;
    return _step('storage-zvol-create', [ $ds, $size ]);
}

sub _steps_zvol_destroy ($self, %a) {
    my $ds = $self->_dataset(%a);
    $self->_check_cluster_name($self->_dataset_pool($ds));
    for my $e (grep { $_->{zvol} eq $ds } $self->exports) {
        _fail('refused', "zvol '$ds' is exported (iqn $e->{iqn}); run unexport first");
    }
    my ($f, $secret_hex) = $self->_approval('zvol-destroy', $ds);
    my %desc_approval = (%$f, hmac => '<redacted>');
    return _step('storage-zvol-destroy', [ $ds, '--approval-file', '-' ],
        input_desc => { approval => \%desc_approval, secret => '<redacted: 64 hex, cluster approval secret>' },
        input => sub { _json({ approval => $f, secret => $secret_hex }) });
}

sub _steps_zvol_list ($self, %a) { return _step('storage-zvol-list', [ $self->pool(%a) ]) }

# The export is recorded (an entry of the same iqn replaced) once the node did it.
sub _steps_export ($self, %a) {
    my $ds = $self->_dataset(%a);
    my ($iqn, $init) = ($a{iqn}, $a{initiator});
    _fail('usage', '--iqn must be an iqn name') unless defined $iqn && $iqn =~ $IQN_RE;
    _fail('usage', '--initiator must be an iqn name') unless defined $init && $init =~ $IQN_RE;
    my $portal = $a{portal} // $self->_get('IP');
    _fail('usage', 'no --portal given and the host has no IP in the registry') unless defined $portal;
    _fail('usage', '--portal must be a specific address') unless $portal =~ $ADDR_RE && $portal ne '0.0.0.0';
    for my $e ($self->exports) {
        _fail('refused', "iqn $iqn already exports $e->{zvol}") if $e->{iqn} eq $iqn && $e->{zvol} ne $ds;
        _fail('refused', "zvol $ds is already exported as $e->{iqn}") if $e->{zvol} eq $ds && $e->{iqn} ne $iqn;
    }
    return _step('iscsi-export', [ $ds, '--iqn', $iqn, '--initiator', $init, '--portal', $portal ],
        after => sub {
            my @keep = grep { $_->{iqn} ne $iqn } $self->exports;
            $self->_set('storage_exports', [ @keep, { zvol => $ds, iqn => $iqn, initiator => $init, portal => $portal } ]);
        });
}

sub _steps_unexport ($self, %a) {
    my $iqn = $a{iqn};
    _fail('usage', 'an iqn is required') unless defined $iqn && $iqn =~ $IQN_RE;
    return _step('iscsi-unexport', [$iqn], after => sub {
        my @keep = grep { $_->{iqn} ne $iqn } $self->exports;
        if (@keep) { $self->_set('storage_exports', \@keep) } else { $self->_unset('storage_exports') }
    });
}

# What the registry says after a successful op.
sub _post ($self, $op, $pool, $results) {
    if ($op eq 'up' || $op eq 'create') {
        $self->_set('storage_state', 'up');
        $self->_set('storage_up_at', $self->_stamp);
    }
    elsif ($op eq 'down') {
        $self->_set('storage_state', 'down');
        $self->_set('storage_down_at', $self->_stamp);
    }
    elsif ($op eq 'destroy') {
        my $recorded = $self->_get('storage_pool');
        if (!defined $recorded || $recorded eq $pool) {
            $self->_unset($_) for qw(storage_state storage_up_at storage_down_at storage_pool
                storage_created_at storage_exports);
        }
    }
    elsif ($op eq 'trim-check') {
        $self->_record_trim($results);
    }
    return;
}

# The verdict is a STDOUT line of storage-trim-check ("TRIM OK" or "TRIM NOT
# REACHING <disk>"), never a stderr trace line. A runner that hands back stdout
# with stderr appended (ced run text mode) would put "+ cmd" lines last, so the
# last line starting with "TRIM " wins; failing that, the last non-empty line.
sub _record_trim ($self, $results) {
    my @lines = grep { length } map { s/\s+\z//r } split /\n/, ($results->[-1]{stdout} // '');
    my ($verdict) = reverse grep { /^TRIM / } @lines;
    $verdict //= @lines ? $lines[-1] : '';
    $self->_set('storage_trim_at', $self->_stamp);
    $self->_set('storage_trim_verdict', $verdict);
    $self->_set('storage_trim_ok', $verdict eq 'TRIM OK' ? 1 : 0);
    return;
}

#--- plan and run ----------------------------------------------------------------------

sub _steps ($self, $op, %a) {
    my $m = $OPS{ $op // '' } // _fail('usage', 'unknown operation; one of: ' . join(', ', ops()));
    $self->{approval_info} = undef;
    return $self->$m(%a);
}

# The ordered calls, input documents redacted: [{n, script, args, input}].
sub plan ($self, $op, %a) {
    my @steps = $self->_steps($op, %a);
    my $n = 0;
    return [ map {
        $n++;
        { n => $n, script => $_->{script}, args => [ @{ $_->{args} } ],
          input => $_->{input_desc} ? _json($_->{input_desc}) : undef }
    } @steps ];
}

# One node call, retried (only when wait > 0) while the agent is not there yet.
sub _call ($self, $st, $retry) {
    my $input = $st->{input} ? $st->{input}->() : undef;
    my $deadline = $self->{now}->() + $self->{wait};
    my $r;
    while (1) {
        $self->_log('info', "call $st->{script} " . join(' ', @{ $st->{args} }));
        $r = $self->{runner}->call(mac => $self->{mac}, script => $st->{script},
            args => [ @{ $st->{args} } ], input => $input);
        $self->_log('info', "$st->{script} exit $r->{rc}");
        last if $r->{rc} == 0 || !$retry || ($r->{rc} != 1 && $r->{rc} != 4);
        last if $self->{now}->() >= $deadline;
        $self->{sleep}->(5);
    }
    return $r;
}

# run($op, %a): executes the plan; dies with HPS::Keysafe::Error on the first
# failing call. Returns {op, mac, pool, ok, steps => [{n, script, args, rc,
# stdout, stderr}]}. With dry_run => 1 it only returns {dry_run => 1, plan}.
sub run ($self, $op, %a) {
    my $pool = $self->pool(%a);
    if ($a{dry_run}) {
        return { dry_run => 1, op => $op, mac => $self->{mac}, pool => $pool, plan => $self->plan($op, %a) };
    }
    my @steps = eval { $self->_steps($op, %a) };
    if (my $e = $@) {
        $self->_log('warning', "$op refused: " . (ref $e ? $e->message : $e));
        die $e;
    }
    my (@results, $n);
    $n = 0;
    for my $st (@steps) {
        $n++;
        my $r = $self->_call($st, $n == 1);
        push @results, { n => $n, script => $st->{script}, args => $st->{args}, rc => $r->{rc},
            stdout => $r->{stdout} // '', stderr => $r->{stderr} // '' };
        if ($r->{rc} != 0) {
            $self->_record($op, 0, $st->{script}, $r->{rc});
            $self->_record_trim(\@results) if $op eq 'trim-check';
            my $last = (grep { length } split /\n/, ($r->{stderr} // ''))[-1] // '';
            my $kind = $r->{rc} == 3 ? 'refused' : 'failed';
            _fail($kind, "$op: step $n/" . scalar(@steps) . " $st->{script} exited $r->{rc}" . (length $last ? ": $last" : ''));
        }
        $st->{after}->() if $st->{after};
    }
    $self->_post($op, $pool, \@results);
    $self->_record($op, 1, undef, 0);
    return { op => $op, mac => $self->{mac}, pool => $pool, ok => 1, steps => \@results };
}

#--- forget-key --------------------------------------------------------------------------

# Explicit operator action: remove the host's 'enc' key from the keysafe. The
# pool's data cannot be unlocked afterwards. Refused while the registry still
# records a pool unless yes => 1.
sub forget_key ($self, %a) {
    my $has = $self->{keysafe}->has_key($self->{mac}, $KEY);
    my $state = $self->_get('storage_state');
    _fail('refused', "host $self->{mac} still records storage_state '$state'; destroy the pool first or pass --yes to delete the key anyway")
        if defined $state && !$a{yes};
    return { dry_run => 1, forgot => 0, had_key => $has } if $a{dry_run};
    my $gone = $has ? $self->{keysafe}->delete_key($self->{mac}, $KEY) : 0;
    $self->_log('warning', "forget-key host $self->{mac}: " . ($gone ? 'key removed' : 'no key held'));
    return { forgot => $gone, had_key => $has };
}

#=== the default runner =======================================================================

package HPS::Storage::Runner::HpsRun;
# Calls scripts/hps-run.sh <mac> <script> [args]. Without input that is
# `ced run <agent> <script> -- args` (output and exit status are the node
# script's). With input it is `hps-run.sh --input --json ...`, which runs
#   ctrl-exec-cli run <agent> --script <script> --input - --json -- args
# with the document on the child's stdin: ctrl-exec-cli sends it as the one
# field "input" of POST /run, which an `input = raw` script reads whole from its
# stdin. `ced run` has no input option on 0.14.4. The JSON reply carries the
# node script's exit status, stdout and stderr per host.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use JSON::PP;
use FindBin ();
use File::Spec;

sub new ($class, %opt) {
    my $default = File::Spec->catfile($FindBin::RealBin, '..', 'scripts', 'hps-run.sh');
    return bless { hps_run => $opt{hps_run} // $ENV{HPS_RUN_CMD} // $default }, $class;
}

sub _spawn ($self, $input, @cmd) {
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);
    if (defined $input) {
        local $SIG{PIPE} = 'IGNORE';
        print {$in} $input;
    }
    close $in;
    my %buf = (out => '', err => '');
    my $sel = IO::Select->new($out, $err);
    while ($sel->count) {
        for my $fh ($sel->can_read) {
            my $n = sysread($fh, my $chunk, 65536);
            if (!$n) { $sel->remove($fh); next }
            $buf{ $fh == $out ? 'out' : 'err' } .= $chunk;
        }
    }
    waitpid($pid, 0);
    my $rc = $? == -1 ? 1 : ($? & 127) ? 128 + ($? & 127) : $? >> 8;
    return ($rc, $buf{out}, $buf{err});
}

# call(mac, script, args, input) -> {rc, stdout, stderr}
sub call ($self, %c) {
    my $has_input = defined $c{input};
    my @cmd = ($self->{hps_run}, ($has_input ? ('--input', '--json') : ()), $c{mac}, $c{script}, @{ $c{args} });
    my ($rc, $out, $err) = eval { $self->_spawn($c{input}, @cmd) };
    return { rc => 1, stdout => '', stderr => "cannot run $self->{hps_run}: " . ($@ =~ s/ at .*//sr) } unless defined $rc;
    # The client exits non-zero when the node script fails, but its --json
    # body still carries the script's exit, stdout and stderr: parse it
    # whenever it parses, so a node failure is reported with its own words.
    return { rc => $rc, stdout => $out, stderr => $err } unless $has_input;
    my $doc = eval { JSON::PP->new->utf8->decode($out) };
    my $res = ref $doc eq 'HASH' && ref $doc->{results} eq 'ARRAY' ? $doc->{results}[0] : undef;
    return { rc => 1, stdout => '', stderr => $err . "the dispatcher reply was not a run result\n" } unless ref $res eq 'HASH';
    my $exit = $res->{exit};
    $exit = 1 unless defined $exit && $exit =~ /^\d+$/;
    return { rc => $exit + 0, stdout => $res->{stdout} // '',
             stderr => ($res->{stderr} // '') . (length($res->{error} // '') ? "$res->{error}\n" : '') . $err };
}

1;

__END__

=head1 NAME

HPS::Storage - drive a node's storage role over ctrl-exec

=head1 OPERATIONS

C<up>: C<storage-pool-import POOL>, C<dataset-unlock POOL/enc> (existing key
only; no key means "pool not created by HPS"), C<iscsi-export> for each entry
of the host's C<storage_exports>; sets C<storage_state=up>.
C<down>: C<iscsi-unexport> for each export; C<storage_state=down>; the pool is
never exported. C<create>: needs an unexpired, valid C<pool-create> approval;
one C<storage-pool-create> call carrying approval, secret and key, then C<up>.
C<destroy>: needs a C<pool-destroy> approval; one C<storage-pool-destroy>
call; clears the storage_* registry keys; the key stays in the keysafe.
C<trim-check>, C<status> as named (C<status> is the read-only
C<storage-status>; it imports nothing). C<zvol-create DATASET SIZE>,
C<zvol-destroy DATASET> (needs a C<zvol-destroy> approval whose C<pool> is the
dataset; refused while the zvol is in C<storage_exports>), C<zvol-list>,
C<export DATASET --iqn --initiator [--portal]> (portal defaults to the host's
registry C<IP>; recorded in C<storage_exports> after the node did it) and
C<unexport IQN> (removes the entry). A zvol is C<POOL/enc/NAME>.

=head1 REGISTRY KEYS (per host)

C<storage_state> (up|down), C<storage_up_at>, C<storage_down_at>,
C<storage_pool>, C<storage_created_at>, C<storage_exports> (list of
C<{zvol,iqn,initiator,portal}>), C<storage_trim_at>, C<storage_trim_verdict>, C<storage_trim_ok> (0|1),
C<storage_last> (C<{op,ok,at,script,rc}>).

=cut
