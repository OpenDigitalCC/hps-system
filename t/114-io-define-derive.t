#!/usr/bin/env perl
# hps-workload define: a disk whose definition leaves mbps_max unset gets one
# derived from tenant_write_fraction (default 0.25) x the lowest measured pool
# write speed of its leg hosts; --dry-run and show-definition print the figure
# and its source; an explicit mbps_max wins; no number of MiB/s is held in code.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my ($m1, $m2) = ($StorageFixture::MAC, $StorageFixture::MAC2);
my $js = JSON::PP->new->canonical->pretty;
my $tmp = tempdir(CLEANUP => 1);

sub fixture {
    my $f = StorageFixture::setup_workload(no_def => 1);
    $f->{reg}->host_set($m2, 'STATE', 'NETWORK_BOOT');
    $f->{reg}->host_set($m2, 'HOSTNAME', 'sch-002');
    $f->{reg}->host_set($m2, 'TYPE', 'SCH');
    for my $vm (@{ $f->{def}{vms} }) {
        $vm->{disks}[0]{legs}[1] = { host => 'sch-002', iqn => "iqn.2026-01.lab.sch2:hpslab-$vm->{name}", portal => '192.0.2.52' };
    }
    return $f;
}
sub measured { my ($f, $mac, $mbps, $at) = @_; $f->{reg}->host_set($mac, 'storage_pool_write_mbps', $mbps); $f->{reg}->host_set($mac, 'storage_measured_at', $at // '2026-11-13T09:00:00Z') }
sub stored { my ($f) = @_; return decode_json($f->{wl}->()->show_definition('t0')) }
sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

# --- both legs measured: the lowest x 0.25
{
    my $f = fixture();
    measured($f, $m1, 480);
    measured($f, $m2, 200, '2026-11-12T10:00:00Z');
    my $r = $f->{wl}->()->define('t0', $js->encode($f->{def}), dry_run => 1);
    is(scalar @{ $r->{derived} }, 2, 'dry run: one row per disk');
    my ($row) = grep { $_->{vm} eq 't0-app' } @{ $r->{derived} };
    is($row->{mbps_max}, 50, '200 x 0.25 = 50');
    ok($row->{derived}, 'marked derived');
    is($row->{source}, 'tenant_write_fraction 0.25 (default) x storage_pool_write_mbps 200 of sch-002 (lowest of 2 measured of 2 hosts), measured 2026-11-12T10:00:00Z', 'the source names fraction, figure, host and date');
    ok(!$r->{written}, 'dry run writes nothing');
    ok(!-e $r->{path}, 'no file');

    $r = $f->{wl}->()->define('t0', $js->encode($f->{def}));
    my $d = stored($f);
    is($d->{vms}[0]{disks}[0]{mbps_max}, 50, 'stored definition holds the derived mbps_max');
    is($d->{vms}[0]{disks}[0]{mbps_max_derived}, $row->{source}, 'and its source (what show-definition prints)');
    like($f->{wl}->()->show_definition('t0'), qr/"mbps_max_derived" : "tenant_write_fraction 0\.25 \(default\) x storage_pool_write_mbps 200 of sch-002/, 'show-definition shows the figure and the source');
    my $loaded = $f->{wl}->()->load('t0');
    is($loaded->{vms}[0]{disks}[0]{mbps_max}, 50, 'create sees the figure (it loads as any definition)');
    ok(!exists $loaded->{vms}[0]{disks}[0]{mbps_max_derived}, 'the marker is not a limit and is not carried');
    my $plan = $f->{wl}->()->plan('create', 't0');
    my ($def_step) = grep { $_->{script} eq 'vm-define' && $_->{args}[0] eq 't0-app' } @$plan;
    my @args = @{ $def_step->{args} };
    my ($i) = grep { $args[$_] eq '--disk-mbps' } 0 .. $#args;
    is($args[$i + 1], 50, 'vm-define gets --disk-mbps 50');
}

# --- an explicit mbps_max wins, and is reported as set in the definition
{
    my $f = fixture();
    measured($f, $m1, 480);
    $f->{def}{vms}[0]{disks}[0]{mbps_max} = 120;
    my $text = $js->encode($f->{def});
    my $r = $f->{wl}->()->define('t0', $text);
    my ($a) = grep { $_->{vm} eq 't0-app' } @{ $r->{derived} };
    is_deeply([ $a->{mbps_max}, $a->{derived}, $a->{source} ], [ 120, 0, 'set in the definition' ], 'explicit: reported, not derived');
    my $d = stored($f);
    is($d->{vms}[0]{disks}[0]{mbps_max}, 120, 'explicit value kept');
    ok(!exists $d->{vms}[0]{disks}[0]{mbps_max_derived}, 'no marker on an explicit value');
    is($d->{vms}[1]{disks}[0]{mbps_max}, 120, 'the other VM (unset) is derived from the same budget: 480 x 0.25') or diag explain $d->{vms}[1]{disks}[0];
}

# --- no measurement: nothing filled, the file is the text as given
{
    my $f = fixture();
    my $text = $js->encode($f->{def});
    my $r = $f->{wl}->()->define('t0', $text);
    ok(!(grep { defined $_->{mbps_max} } @{ $r->{derived} }), 'no figure');
    like($r->{derived}[0]{source}, qr/^none: no storage host of the disk has a measured storage_pool_write_mbps \(hps-storage <host> measure\)/, 'the row says why and how to fix it');
    is($f->{wl}->()->show_definition('t0'), $text, 'the stored text is exactly the input');
}

# --- the cluster key is a fraction; an invalid one is refused, nothing written
{
    my $f = fixture();
    measured($f, $m1, 400);
    $f->{reg}->cluster_set('lab', 'tenant_write_fraction', '0.1');
    my $r = $f->{wl}->()->define('t0', $js->encode($f->{def}), dry_run => 1);
    is($r->{derived}[0]{mbps_max}, 40, '0.1 x 400');
    like($r->{derived}[0]{source}, qr/tenant_write_fraction 0\.1 \(cluster key\)/, 'source says cluster key');
    $f->{reg}->cluster_set('lab', 'tenant_write_fraction', '2');
    my $e = err_of(sub { $f->{wl}->()->define('t0', $js->encode($f->{def})) });
    is(ref $e && $e->kind, 'refused', 'a fraction of 2 is refused');
    like($e->message, qr/tenant_write_fraction is '2'.*hps-cluster-config set tenant_write_fraction/, 'with the fix');
    ok(!-e $f->{wl}->()->definition_path('t0'), 'nothing written');
}

# --- replace: a derived figure is derived again; a stale one is kept when no budget is known
{
    my $f = fixture();
    measured($f, $m1, 400);
    $f->{wl}->()->define('t0', $js->encode($f->{def}));
    is(stored($f)->{vms}[0]{disks}[0]{mbps_max}, 100, 'first define: 400 x 0.25');
    measured($f, $m1, 800);
    $f->{wl}->()->define('t0', $f->{wl}->()->show_definition('t0'), replace => 1);
    is(stored($f)->{vms}[0]{disks}[0]{mbps_max}, 200, 're-define of the stored text: derived again from the new figure');
    $f->{reg}->host_unset($m1, 'storage_pool_write_mbps');
    my $r = $f->{wl}->()->define('t0', $f->{wl}->()->show_definition('t0'), replace => 1);
    is(stored($f)->{vms}[0]{disks}[0]{mbps_max}, 200, 'no figure any more: the earlier cap is kept, not dropped');
    like($r->{derived}[0]{source}, qr/^kept \(not re-derived: no storage host/, 'and the row says so');
}

# --- the marker is only valid next to an mbps_max, and only as text
{
    my $f = fixture();
    $f->{def}{vms}[0]{disks}[0]{mbps_max_derived} = 'x';
    my $e = err_of(sub { $f->{wl}->()->define('t0', $js->encode($f->{def})) });
    like($e->message, qr/mbps_max_derived without mbps_max/, 'marker alone refused');
    $f->{def}{vms}[0]{disks}[0]{mbps_max} = 10;
    $f->{def}{vms}[0]{disks}[0]{mbps_max_derived} = [1];
    $e = err_of(sub { $f->{wl}->()->define('t0', $js->encode($f->{def})) });
    like($e->message, qr/mbps_max_derived must be a string/, 'non-text marker refused');
}

# --- the CLI prints the rows, dry-run included
{
    my $f = fixture();
    measured($f, $m1, 400);
    local $ENV{HPS_CONFIG_BASE}        = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}    = "$f->{base}/system.db";
    local $ENV{HPS_RESOURCES}          = $f->{base};
    local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
    local $ENV{HPS_STORAGE_NO_SYSLOG}  = 1;
    local $ENV{SUDO_USER}              = 'tester';
    open(my $i, '>', "$tmp/stdin") or die;
    print {$i} $js->encode($f->{def});
    close $i;
    my $run = sub { my $q = join ' ', map { "'$_'" } ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @_); return scalar qx($q < $tmp/stdin 2>/dev/null) };
    my $out = $run->('define', 't0', '--dry-run');
    like($out, qr/Dry run: define t0;/, 'dry run says so');
    like($out, qr{  disk t0-app/root: mbps_max 100 \(tenant_write_fraction 0\.25 \(default\) x storage_pool_write_mbps 400 of sch-001}, 'and prints the derived figure and its source');
    $out = $run->('define', 't0');
    like($out, qr/define ok: workload t0 defined/, 'define ok');
    like($out, qr{  disk t0-db/root: mbps_max 100 \(}, 'the rows follow');
    $out = $run->('show-definition', 't0');
    like($out, qr/"mbps_max" : 100/, 'show-definition prints the figure');
    like($out, qr/"mbps_max_derived" : "tenant_write_fraction 0\.25/, 'and its source');
}

# --- no number of MiB/s is held in code
{
    open(my $fh, '<', "$Bin/../lib/perl/HPS/Workload.pm") or die;
    my $src = do { local $/; <$fh> };
    my ($block) = $src =~ /(#=== I\/O budget.*?#=== definitions on disk)/s;
    my @nums = grep { !/^\s*#/ && !/FRACTION_DEFAULT/ } grep { /\b[0-9]{2,}\b/ } split /\n/, $block;
    is_deeply(\@nums, [], 'no multi-digit constant in the I/O budget code');
}

done_testing;
