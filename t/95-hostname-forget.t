#!/usr/bin/env perl
# IPS-06: the one hostname rule (HPS::Registry fqdn helpers, the 63-character
# cap), the host-forget approval, hps-onboard forget and prune-agents.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Onboard;
use HPS::ClusterConfig;

$StorageFixture::NOW = time;
sub err_of { my ($c) = @_; eval { $c->(); 1 } and return undef; return $@ }

#--- helpers --------------------------------------------------------------------
is(HPS::Registry::fqdn_of('SCH-001', 'Lab.HPS'), 'sch-001.lab.hps', 'fqdn_of lowers the case and joins');
is(HPS::Registry::fqdn_of('sch-001.old.domain', 'lab.hps'), 'sch-001.lab.hps', 'fqdn_of keeps only the first label of its input');
is(HPS::Registry::fqdn_of('sch-001', ''), 'sch-001', 'no domain: the label alone');
is(HPS::Registry::short_name('Sch-001.Lab.HPS'), 'sch-001', 'short_name');
my $dom = 'd' x 53;    # 7 + 1 + 53 = 61
is(length(HPS::Registry::fqdn_of('sch-001', $dom)), 61, 'an FQDN within 63 is accepted');
like(err_of(sub { HPS::Registry::fqdn_of('sch-001', 'd' x 60) }), qr/limit is 63/, 'an FQDN over 63 characters is refused');
like(err_of(sub { HPS::Registry::fqdn_of('-x', 'lab.hps') }), qr/no usable host label/, 'bad label refused');
like(err_of(sub { HPS::Registry::fqdn_of('x', 'bad domain') }), qr/not a usable DNS domain/, 'bad domain refused');

my $f   = StorageFixture::setup();
my $reg = $f->{reg};
my $mac = $StorageFixture::MAC;
$reg->cluster_set('lab', 'network_dns_domain', 'lab.hps');
is($reg->cluster_dns_domain, 'lab.hps', 'cluster_dns_domain');
is($reg->fqdn($mac), 'sch-001.lab.hps', 'Registry fqdn of a host');
is($reg->initiator_iqn($mac), 'iqn.2026-11.hps.lab:sch-001.lab.hps', 'initiator IQN carries the FQDN');
$reg->host_set('525400000009', 'STATE', 'HELD');
is($reg->fqdn('525400000009'), undef, 'no HOSTNAME: no FQDN');

# the cluster-config rule for the domain
my $q = HPS::ClusterConfig::question('network_dns_domain');
is(HPS::ClusterConfig::validate_value($q, 'lab.hps'), undef, 'domain lab.hps valid');
like(HPS::ClusterConfig::validate_value($q, join('.', 'a' x 30, 'b' x 30)), qr/52/, 'a domain over 52 characters is refused');

#--- host-forget approval ---------------------------------------------------------
ok((grep { $_ eq 'host-forget' } HPS::Approval::actions()), 'host-forget is an action');
my $doc = StorageFixture::approve($f, 'host-forget', pool => 'host');
my $v = $f->{ap}->verify($doc, $f->{ks}->cluster_secret('approval'));
is($v->{pool}, 'host', 'pool member is the fixed word');
for my $case ([ { disks => ['ata-X'] }, 'disks' ], [ { wipe => 1 }, 'wipe' ], [ { pool => 'other' }, 'pool word' ]) {
    my $e = err_of(sub { StorageFixture::approve($f, 'host-forget', pool => 'host', %{ $case->[0] }) });
    is(ref $e && $e->kind, 'usage', "refused: $case->[1]");
}
$f->{ap}->revoke($mac, 'host-forget', 'host');

#--- forget ---------------------------------------------------------------------------
my $tmp  = tempdir(CLEANUP => 1);
my $log  = "$tmp/hook.log";
my $hook = "$tmp/hook.sh";
open(my $hfh, '>', $hook) or die;
print {$hfh} <<'SH';
#!/usr/bin/env bash
echo "$*" >> "$HOOK_LOG"
case "$1" in
  agents) cat "$HOOK_AGENTS" ;;
  agent) exit "${HOOK_AGENT_RC:-0}" ;;
  dns-dhcp) exit "${HOOK_DNS_RC:-0}" ;;
esac
SH
close $hfh;
chmod 0755, $hook;
$ENV{HOOK_LOG}    = $log;
$ENV{HOOK_AGENTS} = "$tmp/agents";
sub hook_calls { open(my $l, '<', $log) or return (); my @l = <$l>; chomp @l; return @l }
sub reset_log  { unlink $log }

my $ob = HPS::Onboard->new(registry => $reg, approval => $f->{ap}, keysafe => $f->{ks}, forget_cmd => $hook);

my $e = err_of(sub { $ob->forget('zz') });
is($e && $e->kind, 'usage', 'bad MAC');
$e = err_of(sub { $ob->forget('52:54:00:99:99:99') });
is($e && $e->kind, 'notfound', 'unknown host');

# refusals: exports, pool, workloads
$reg->host_set($mac, 'storage_exports', [ { zvol => 'lab/enc/vm/x', iqn => 'iqn.2026-11.hps:a', initiator => 'iqn.2026-11.hps:b', portal => '10.0.0.1' } ]);
$e = err_of(sub { $ob->forget($mac, dry_run => 1) });
is($e && $e->kind, 'refused', 'a host with storage exports is refused');
like($e->message, qr/storage exports/, 'the refusal says why');
$reg->host_unset($mac, 'storage_exports');
$reg->host_set($mac, 'storage_pool', 'lab');
$e = err_of(sub { $ob->forget($mac) });
like($e && $e->message, qr/a pool is recorded \(lab\)/, 'a host with a pool is refused');
$reg->host_unset($mac, 'storage_pool');
$reg->cluster_set('lab', 'workload_web', { state => 'running', vms => { v1 => { host => 'sch-001.lab.hps' } } });
$e = err_of(sub { $ob->forget($mac) });
like($e && $e->message, qr/workloads are recorded \(web\)/, 'a host named by a workload record is refused (by FQDN)');
$reg->cluster_set('lab', 'workload_web', { state => 'running', vms => { v1 => { host => $mac } } });
$e = err_of(sub { $ob->forget($mac) });
like($e && $e->message, qr/web/, '... and by MAC');
$reg->cluster_unset('lab', 'workload_web');
$reg->cluster_set('lab', 'workload_old_destroyed', { at => 'x' });
$reg->cluster_set('lab', 'workload_old', { vms => { v1 => { host => $mac } } });
$reg->cluster_unset('lab', 'workload_old');
ok(!err_of(sub { $ob->forget($mac, dry_run => 1) }), 'a destroyed workload does not hold the host');
ok($reg->host_exists($mac), 'refusals and dry-run leave the host');
is_deeply([ hook_calls() ], [], 'refused and dry-run runs call nothing');

# dry run
my $r = $ob->forget($mac, dry_run => 1);
is($r->{fqdn}, 'sch-001.lab.hps', 'agent name is the FQDN');
like(join("\n", @{ $r->{steps} }), qr/approval: missing/, 'dry run reports the missing approval');
like(join("\n", @{ $r->{steps} }), qr/would remove ctrl-exec agent sch-001\.lab\.hps/, 'dry run lists the agent');

# approval needed
$e = err_of(sub { $ob->forget($mac) });
is($e && $e->kind, 'refused', 'no approval: refused');
like($e->message, qr/hps-approve host-forget/, 'refusal says how to approve');
ok($reg->host_exists($mac), 'host still there');
StorageFixture::approve($f, 'host-forget', pool => 'host');
like(join("\n", @{ $ob->forget($mac, dry_run => 1)->{steps} }), qr/approval: present and valid/, 'dry run sees the approval');

# agent removal fails: the host stays
{
    local $ENV{HOOK_AGENT_RC} = 1;
    $e = err_of(sub { $ob->forget($mac) });
    is($e && $e->kind, 'failed', 'agent removal failure fails the forget');
    ok($reg->host_exists($mac), '... and leaves the host in the registry');
    is_deeply([ hook_calls() ], ['agent sch-001.lab.hps'], '... before DNS is touched');
    reset_log();
}

# the real run
$r = $ob->forget($mac);
is_deeply([ hook_calls() ], [ 'agent sch-001.lab.hps', 'dns-dhcp' ], 'agent removed, then the DHCP/DNS files regenerated');
ok(!$reg->host_exists($mac), 'registry host removed');
is(scalar(grep { /removed ctrl-exec agent sch-001.lab.hps/ } @{ $r->{steps} }), 1, 'each removal is reported (agent)');
is(scalar(grep { /removed registry host $mac \(sch-001\)/ } @{ $r->{steps} }), 1, 'each removal is reported (registry)');
ok(!(grep { $_ eq $mac } $reg->host_list_all), 'not in host_list_all');
reset_log();

# an agent already gone is not an error
$reg->host_set($mac, 'HOSTNAME', 'sch-001');
$reg->host_set($mac, 'STATE', 'HELD');
StorageFixture::approve($f, 'host-forget', pool => 'host');
{
    local $ENV{HOOK_AGENT_RC} = 4;
    $r = $ob->forget($mac);
    like(join("\n", @{ $r->{steps} }), qr/no ctrl-exec agent registered as sch-001\.lab\.hps/, 'rc 4: nothing to remove, carries on');
    ok(!$reg->host_exists($mac), 'host removed');
}
reset_log();

# a host with no HOSTNAME: hps-<mac> agent
my $held = '525400000009';
StorageFixture::approve($f, 'host-forget', pool => 'host', mac => $held);
$r = $ob->forget($held);
is($r->{fqdn}, 'hps-525400000009.lab.hps', 'a held host registers as hps-<mac>.<domain>');

# no hook: reported as not done
$reg->host_set($mac, 'HOSTNAME', 'sch-001');
StorageFixture::approve($f, 'host-forget', pool => 'host');
{
    local $ENV{HPS_ONBOARD_FORGET_CMD};
    delete $ENV{HPS_ONBOARD_FORGET_CMD};
    my $ob2 = HPS::Onboard->new(registry => $reg, approval => $f->{ap}, keysafe => $f->{ks});
    $r = $ob2->forget($mac);
    like(join("\n", @{ $r->{steps} }), qr/NOT removed: no forget hook/, 'without a hook the agent step is reported as not done');
    like(join("\n", @{ $r->{steps} }), qr/NOT regenerated/, '... and so is the DNS step');
    $e = err_of(sub { $ob2->prune_agents });
    is($e && $e->kind, 'refused', 'prune-agents needs the hook');
}

#--- prune-agents -------------------------------------------------------------------------
$reg->host_set($StorageFixture::MAC,  'HOSTNAME', 'sch-001');
$reg->host_set($StorageFixture::MAC2, 'HOSTNAME', 'tch-002');
$reg->host_set($StorageFixture::MAC2, 'STATE', 'NETWORK_BOOT');
open(my $afh, '>', "$tmp/agents") or die;
print {$afh} join("\n", qw(sch-001.lab.hps tch-002.lab.hps tch-002 stale-abc hps-aabbccddeeff.lab.hps tch-001.lab.hps)), "\n";
close $afh;
reset_log();
$r = $ob->prune_agents(dry_run => 1);
is_deeply($r->{keep},  [qw(sch-001.lab.hps tch-002.lab.hps)], 'the FQDN agents of registry hosts are kept');
is_deeply($r->{stale}, [qw(hps-aabbccddeeff.lab.hps stale-abc tch-001.lab.hps tch-002)], 'short-name duplicates, stale-*, hps-<mac> and forgotten hosts are stale');
is_deeply([ hook_calls() ], ['agents'], 'dry run removes nothing');
reset_log();
$r = $ob->prune_agents;
is_deeply($r->{removed}, $r->{stale}, 'all stale agents removed');
is_deeply([ hook_calls() ], [ 'agents', map { "agent $_" } @{ $r->{stale} } ], 'one unpair per stale agent');
{
    local $ENV{HOOK_AGENT_RC} = 1;
    $r = $ob->prune_agents;
    is(scalar @{ $r->{failed} }, 4, 'failures are reported');
}

#--- the CLI -----------------------------------------------------------------------------------
local $ENV{HPS_CONFIG_BASE}     = $f->{base};
local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
local $ENV{HPS_ONBOARD_FORGET_CMD} = $hook;
sub cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-onboard", @_);
    my $out = qx(@cmd 2>&1);
    return ($? >> 8, $out);
}
reset_log();
my ($rc, $out) = cli('prune-agents', '--dry-run');
is($rc, 0, 'hps-onboard prune-agents --dry-run exits 0') or diag $out;
like($out, qr/Stale agents that would be removed: 4/, 'prints the stale count');
($rc) = cli('prune-agents', 'x');
is($rc, 2, 'prune-agents takes no arguments');
($rc, $out) = cli('forget', $StorageFixture::MAC2, '--dry-run');
is($rc, 0, 'hps-onboard forget --dry-run exits 0') or diag $out;
like($out, qr/Dry run host 525400000002 \(tch-002\), agent name tch-002\.lab\.hps/, 'forget --dry-run output');
($rc, $out) = cli('forget', $StorageFixture::MAC2);
is($rc, 3, 'forget without an approval exits 3');
($rc) = cli('forget');
is($rc, 2, 'forget needs a MAC');
($rc) = cli('forget', '525400000077');
is($rc, 4, 'forget of an unknown host exits 4');

done_testing;
