package HPS::Node;
# IPS-side node power control. power_off() shuts a node down so that its data
# is safe: storage down (HPS::Storage 'down'), then the node script
# node-poweroff over ctrl-exec (systemctl poweroff; the node's own shutdown unit
# stops guests and mirrors and exports the pools), then it waits for the BMC to
# report Off (hps-bmc, IPS-08) and forces power off only after force_after
# seconds, logged as a fault. With no BMC driver it stops after the node script
# and says the power state is not confirmed.
#
# Every collaborator is injectable (storage, runner, bmc, logger, now, sleep) so
# the sequence is testable without a node, a BMC or a clock.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use POSIX qw(strftime);
use JSON::PP;
use HPS::Registry;
use HPS::Storage;

our $DEFAULT_FORCE_AFTER = 120;

# Result codes of power_off(): the CLI's exit status.
our %CODE = (off => 0, 'no-bmc' => 0, failed => 1, forced => 6);

# new(host => MAC|HOSTNAME, registry => $reg, storage => $obj (has run('down')),
#     runner => $obj (call(mac, script, args)), bmc => $obj (run($action, $host)),
#     logger => sub ($level, $msg), now => sub, sleep => sub ($s), poll => SECONDS)
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    my $log = $opt{logger} // \&_default_logger;
    my $self = bless {
        host     => $opt{host},
        registry => $reg,
        logger   => $log,
        now      => $opt{now} // sub { time },
        sleep    => $opt{sleep} // sub ($s) { sleep $s },
        poll     => $opt{poll} // $ENV{HPS_NODE_POLL} // 5,
        bmc      => $opt{bmc} // HPS::Node::Bmc->new,
    }, $class;
    $self->{storage} = $opt{storage} // HPS::Storage->new(host => $opt{host}, registry => $reg, logger => $log);
    $self->{runner}  = $opt{runner}  // HPS::Storage::Runner::HpsRun->new;
    $self->{mac}     = $self->{storage}->mac;
    return $self;
}

sub mac ($self) { return $self->{mac} }

sub _default_logger ($level, $msg) {
    print STDERR "hps-node: $msg\n";
    return if $ENV{HPS_NODE_NO_SYSLOG};
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-node: $msg");
    };
    return;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

sub _record ($self, $result, $detail) {
    my $at = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($self->{now}->()));
    eval { $self->{registry}->host_set($self->{mac}, 'poweroff_last', { result => $result, at => $at, detail => $detail }) };
    return;
}

# The BMC power state: 'on', 'off' or 'unknown'; undef when there is no driver
# (command missing, or exit 5 "not supported by this device").
sub _power ($self) {
    my $r = $self->{bmc}->run('status', $self->{host}, '--json');
    return undef if $r->{missing} || $r->{rc} == 5;
    return 'unknown' if $r->{rc} != 0;
    my $doc = eval { JSON::PP->new->decode($r->{stdout}) };
    my $p = ref $doc eq 'HASH' ? $doc->{power} : undef;
    return defined $p && $p =~ /^(?:on|off)$/ ? $p : 'unknown';
}

# Poll until the BMC says off or the deadline passes. Returns 'off', 'timeout'
# or 'no-bmc'.
sub _wait_off ($self, $force_after) {
    my $deadline = $self->{now}->() + $force_after;
    while (1) {
        my $p = $self->_power;
        return 'no-bmc' unless defined $p;
        $self->_log('info', "BMC power state: $p");
        return 'off' if $p eq 'off';
        return 'timeout' if $self->{now}->() >= $deadline;
        $self->{sleep}->($self->{poll});
    }
}

sub _force_off ($self) {
    my $r = $self->{bmc}->run('force-off', $self->{host});
    return 0 if $r->{missing};
    $self->_log('error', "hps-bmc force-off exited $r->{rc}") if $r->{rc} != 0;
    return $r->{rc} == 0;
}

# power_off(force_after => SECONDS): returns {result => off|forced|no-bmc|failed,
# message}. 'failed' means the node was not (confirmed) powered off by a clean
# path and was not forced: the message says which step.
sub power_off ($self, %a) {
    my $force_after = $a{force_after} // $DEFAULT_FORCE_AFTER;
    my $host = $self->{host};
    $self->_log('info', "power-off $host: storage down");
    my $ok = eval { $self->{storage}->run('down'); 1 };
    unless ($ok) {
        my $e = $@;
        my $m = ref $e && $e->can('message') ? $e->message : $e;
        $m =~ s/\s+\z//;
        $self->_log('error', "power-off $host: storage down failed: $m; the node is not powered off");
        $self->_record('failed', "storage down: $m");
        return { result => 'failed', message => "storage down failed: $m" };
    }
    $self->_log('info', "power-off $host: node-poweroff");
    my $r = $self->{runner}->call(mac => $self->{mac}, script => 'node-poweroff', args => [], input => undef);
    if ($r->{rc} != 0) {
        my $last = (grep { length } split /\n/, ($r->{stderr} // ''))[-1] // '';
        $self->_log('error', "power-off $host: node-poweroff exited $r->{rc}" . (length $last ? ": $last" : ''));
        $self->_record('failed', "node-poweroff exit $r->{rc}");
        return { result => 'failed', message => "node-poweroff exited $r->{rc}" };
    }
    my $w = $self->_wait_off($force_after);
    if ($w eq 'no-bmc') {
        $self->_log('warning', "power-off $host: no BMC driver; poweroff was requested, power state not confirmed");
        $self->_record('no-bmc', 'poweroff requested; no BMC driver');
        return { result => 'no-bmc', message => 'poweroff requested on the node; no BMC driver, so power state is not confirmed' };
    }
    if ($w eq 'off') {
        $self->_log('info', "power-off $host: BMC reports off");
        $self->_record('off', 'clean');
        return { result => 'off', message => 'node is off (clean shutdown)' };
    }
    $self->_log('error', "FAULT power-off $host: not off after $force_after s; forcing power off through the BMC");
    unless ($self->_force_off) {
        $self->_record('failed', "not off after $force_after s; force-off failed");
        return { result => 'failed', message => "not off after $force_after s and the BMC force-off failed" };
    }
    my $after = $self->_power // 'unknown';
    $self->_log('error', "FAULT power-off $host: forced; BMC power state after force-off: $after");
    $self->_record('forced', "not off after $force_after s; BMC force-off sent");
    return { result => 'forced', message => "not off after $force_after s: forced off through the BMC (fault)" };
}

#=== the BMC command ===========================================================

package HPS::Node::Bmc;
# Runs `hps-bmc <action> <host> [args]`; the command is HPS_BMC_CMD or hps-bmc
# on PATH. run() returns {rc, stdout, stderr, missing}; missing is true when the
# command cannot be executed at all (no BMC driver installed).
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);

sub new ($class, %opt) { return bless { cmd => $opt{cmd} // $ENV{HPS_BMC_CMD} // 'hps-bmc' }, $class }

sub run ($self, $action, $host, @extra) {
    my ($in, $out);
    my $err = gensym;
    my $pid = eval { open3($in, $out, $err, $self->{cmd}, $action, $host, @extra) };
    return { rc => 127, stdout => '', stderr => "cannot run $self->{cmd}\n", missing => 1 } unless $pid;
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
    return { rc => $rc, stdout => $buf{out}, stderr => $buf{err}, missing => $rc == 127 ? 1 : 0 };
}

1;

__END__

=head1 NAME

HPS::Node - IPS-side node power control (power-off)

=head1 SEQUENCE

C<power_off>: C<HPS::Storage> C<down> (a failure stops here; the node is left
alone); ctrl-exec script C<node-poweroff>; then poll C<hps-bmc status HOST
--json> every C<HPS_NODE_POLL> (5) seconds until it reports C<off>. After
C<force_after> seconds (default 120) C<hps-bmc force-off HOST> is sent and
logged as a fault. A missing command or exit 5 from C<hps-bmc> is the no-BMC
path: stop after the node script and report.

The node's own C<hps-shutdown-storage.service> stops guests and mirrors and
exports the pools on every poweroff, so the pools are exported whether or not
the IPS asked.

=head1 REGISTRY KEYS (per host)

C<poweroff_last> (C<{result,at,detail}>; result off, forced, no-bmc, failed).

=cut
