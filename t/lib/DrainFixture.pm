package DrainFixture;
# Shared setup for the class and drain tests: StorageFixture's workload
# fixture (host sch-001, a recording runner) plus small one-VM workloads of a
# given class.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload::Drain;
use HPS::Event ();

our $HOST = 'sch-001';

# wdef($name, $class, mem => MiB): one VM <name>-vm on sch-001 with a single
# local disk (no mirror). $class undef: the definition has no class key.
sub wdef {
    my ($name, $class, %o) = @_;
    return { name => $name, project => 'lab', (defined $class ? (class => $class) : ()),
        vms => [ { name => "$name-vm", memory_mib => $o{mem} // 1024, vcpus => 1, image => 'debian-13-generic-amd64',
            nets => ['mgmt'], disks => [ { name => 'root', size => '10G', legs => [ { host => $HOST, pool => 'lab' } ] } ] } ] };
}

# setup(ce => {...}): the fixture and a driver; the base definition t0 is not written.
sub setup {
    my %o = @_;
    my $f = StorageFixture::setup_workload(no_def => 1, ce => { out => { 'vm-save' => "VM-SAVE x y 1073741824\n" }, %{ $o{ce} // {} } });
    return ($f, $f->{wl}->());
}

# make($f, $wl, $name, $class, $state): define and create the workload and
# bring it to $state: running (default), stopped, suspended or created.
sub make {
    my ($f, $wl, $name, $class, $state, %o) = @_;
    $state //= 'running';
    StorageFixture::write_def($f, wdef($name, $class, %o));
    $wl->run('create', $name);
    return if $state eq 'created';
    $wl->run('start', $name);
    $wl->run('stop', $name) if $state eq 'stopped';
    $wl->run('suspend', $name) if $state eq 'suspended';
    return;
}

sub rec { my ($f, $name) = @_; return $f->{reg}->cluster_get_json('lab', "workload_$name") }
sub state { my ($f, $name) = @_; return rec($f, $name)->{vms}{"$name-vm"}{state} }
sub set_rec { my ($f, $name, $cb) = @_; my $r = rec($f, $name); $cb->($r); $f->{reg}->cluster_set('lab', "workload_$name", $r); return }
sub mark { my ($f) = @_; return $f->{reg}->host_exists($StorageFixture::MAC, 'drain') ? $f->{reg}->host_get_json($StorageFixture::MAC, 'drain') : undef }
sub reset_calls { my ($f) = @_; $f->{ce}{calls} = []; @{ $f->{log} } = (); return }

# The guest actions among the node calls: [script, vm] of vm-stop, vm-save, vm-start, vm-restore.
sub actions {
    my ($f) = @_;
    return [ map { [ $_->{script}, $_->{args}[0] ] } grep { $_->{script} =~ /^vm-(?:stop|save|start|restore)\z/ } $f->{ce}->calls ];
}

# The drain and undrain event lines of the log: the marker lines
# (HPS::Event, docs/LOGGING.md) whose text starts "drain " or "undrain ".
sub events { my ($f) = @_; return grep { /^\w+ HPS-(?:EVENT|ALERT) pri=\S+ kind=\S+ subject=\S+ state=\S+ (?:un)?drain \S+[: ]/ } @{ $f->{log} } }

# ev($pri, $kind, $subject, $state, $text): the logged form of one event line,
# "<syslog level> <marker line>", as the fixture's logger records it.
sub ev {
    my ($pri, $kind, $subject, $state, $text) = @_;
    return HPS::Event::syslog_level($pri) . ' ' . HPS::Event::line(pri => $pri, kind => $kind, subject => $subject, state => $state, text => $text);
}

1;
