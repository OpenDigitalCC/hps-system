package StorageFixture;
# Shared setup for the HPS::Storage tests: a temp registry with cluster 'lab'
# and host sch-001 (TYPE SCH), a keysafe, a fixed clock, and a fake ctrl-exec
# runner that records every call and its input.
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Keysafe;
use HPS::Storage;
use HPS::Workload;

our $MAC = '525400000001';
our $NOW = 1_800_000_000;

package FakeCE {
    sub new { my ($c, %o) = @_; return bless { calls => [], rc => $o{rc} || {}, out => $o{out} || {} }, $c }
    sub call {
        my ($self, %c) = @_;
        push @{ $self->{calls} }, { %c };
        my $rc = $self->{rc}{ $c{script} } // 0;
        $rc = shift @$rc if ref $rc eq 'ARRAY';
        return { rc => $rc, stdout => $self->{out}{ $c{script} } // "out of $c{script}\n", stderr => $rc ? "boom from $c{script}\n" : '' };
    }
    sub calls { return @{ $_[0]{calls} } }
    sub scripts { return map { $_->{script} } @{ $_[0]{calls} } }
}

sub setup {
    my %o = @_;
    my $base = tempdir(CLEANUP => 1);
    my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
    make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->host_set($MAC, 'STATE', 'NETWORK_BOOT');
    $reg->host_set($MAC, 'TYPE', 'SCH');
    $reg->host_set($MAC, 'HOSTNAME', 'sch-001');
    my $ks = HPS::Keysafe->new(registry => $reg);
    my $ce = FakeCE->new(%{ $o{ce} || {} });
    my @log;
    my $mk = sub {
        my %x = @_;
        return HPS::Storage->new(host => $MAC, registry => $reg, keysafe => $ks,
            runner => $ce, logger => sub { push @log, "$_[0] $_[1]" }, now => sub { $NOW },
            sleep => sub { $NOW += $_[0] }, %x);
    };
    return { base => $base, reg => $reg, ks => $ks, ce => $ce, log => \@log, mk => $mk };
}

# --- workloads (CS-3.6) -----------------------------------------------------------
# setup_workload(): setup() plus a network layout, the IPS address, an image on
# the IPS, and a runner-backed workload driver factory:
#   $f->{wl}->(%opt)  an HPS::Workload on the fake runner (storage objects from $f->{mk})
#   $f->{def}         the base definition (two VMs on host sch-001, one remote leg each)
#   write_def($f, $def)  writes workloads/<name>.json
our $MAC2 = '525400000002';

# write_hps_run_shim($path): a stand-in for scripts/hps-run.sh that answers like
# `hps-run.sh --json [--input] <mac> <script> [args]` does: one JSON run result
# {results:[{exit, stdout, stderr}]}. It appends its arguments to $SHIM_DIR/args
# and keeps stdin of --input calls in $SHIM_DIR/stdin.<pid>. Environment:
# FAKE_NODE_EXIT (the script's exit, default 0), FAKE_NODE_STDERR (its stderr,
# default "node complains"), FAKE_RUN_RC (hps-run itself fails with that status
# and no JSON, as when no agent is registered).
sub write_hps_run_shim {
    my ($path) = @_;
    open(my $sh, '>', $path) or die "$path: $!";
    print {$sh} <<'SHIM';
#!/usr/bin/env bash
echo "$*" >> "$SHIM_DIR/args"
input=0
while [[ "${1:-}" == --* ]]; do
  [[ "$1" == --input ]] && input=1
  shift
done
if [[ $input -eq 1 ]]; then cat > "$SHIM_DIR/stdin.$$"; fi
if [[ "${FAKE_RUN_RC:-0}" -ne 0 ]]; then
  echo "hps-run: no registered agent for $1" >&2
  exit "$FAKE_RUN_RC"
fi
case "$2" in
  vm-status) out="VM ${3} running" ;;
  mirror-status) out="MIRROR ${3} clean" ;;
  *) out="node says hi" ;;
esac
jq -n --argjson e "${FAKE_NODE_EXIT:-0}" --arg o "$out
" --arg s "${FAKE_NODE_STDERR-node complains}
" '{ok:1,results:[{host:"h",exit:$e,stdout:$o,stderr:$s}]}'
echo "hps-run: $1 -> agent h, script $2" >&2
exit 0
SHIM
    close $sh;
    chmod 0755, $path;
    return $path;
}


sub layout {
    return {
        mgmt => { cidr => '192.0.2.0/24',    vlan => undef, bridge => 'br-mgmt', purpose => 'workload' },
        db   => { cidr => '198.51.100.0/24', vlan => 41,    bridge => 'br-db',   purpose => 'workload' },
    };
}

sub base_def {
    my $t = JSON::PP::true;
    return {
        name => 't0', project => 'lab',
        access => { ssh_keys => ['ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest tester'], console => $t },
        vms => [
            { name => 't0-app', memory_mib => 2048, vcpus => 2, image => 'debian-13-generic-amd64', nets => ['mgmt'],
              priority => 3,
              disks => [ { name => 'root', size => '20G', legs => [
                  { host => 'sch-001', pool => 'lab' },
                  { host => 'nas', iqn => 'iqn.2026-01.lab.nas:hpslab-t0-root', portal => '192.0.2.50' } ] } ] },
            { name => 't0-db', memory_mib => 4096, vcpus => 4, image => 'debian-13-generic-amd64', nets => ['mgmt', 'db'],
              priority => 1,
              disks => [ { name => 'root', size => '40G', legs => [
                  { host => 'sch-001', pool => 'lab' },
                  { host => 'nas', iqn => 'iqn.2026-01.lab.nas:hpslab-t0-db', portal => '192.0.2.50' } ] } ] },
        ],
    };
}

sub write_def {
    my ($f, $def) = @_;
    my $dir = $f->{reg}->workload_dir('lab');
    make_path($dir);
    open(my $fh, '>', "$dir/$def->{name}.json") or die "$dir: $!";
    print {$fh} JSON::PP->new->canonical->pretty->encode($def);
    close $fh;
    return "$dir/$def->{name}.json";
}

sub setup_workload {
    my %o = @_;
    my $f = setup(%o);
    $f->{reg}->cluster_set('lab', 'network_layout', layout());
    $f->{reg}->cluster_set('lab', 'network_dhcp_ip', '192.0.2.1');
    my $images = "$f->{base}/images";
    make_path($images);
    for my $img ('debian-13-generic-amd64') {
        open(my $fh, '>', "$images/$img.qcow2") or die;
        print {$fh} "qcow2 stand-in\n";
        close $fh;
        open($fh, '>', "$images/$img.sha256") or die;
        print {$fh} 'ab' x 32, "  $img.qcow2\n";
        close $fh;
    }
    $f->{images} = $images;
    $f->{def} = base_def();
    write_def($f, $f->{def}) unless $o{no_def};
    $f->{wl} = sub {
        my %x = @_;
        return HPS::Workload->new(registry => $f->{reg}, keysafe => $f->{ks},
            storage => sub { $f->{mk}->(host => $_[0]) }, runner => $f->{ce}, logger => sub { push @{ $f->{log} }, "$_[0] $_[1]" },
            now => sub { $NOW }, images_dir => $images, by => 'tester', %x);
    };
    return $f;
}

1;
