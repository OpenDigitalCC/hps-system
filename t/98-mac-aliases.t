#!/usr/bin/env perl
# IPS-15: every MAC of a machine identifies the same host. HPS::Registry
# (host_macs, mac_index, mac_conflicts, resolve_mac), hps-onboard show and forget,
# and the registry key catalogue rows for `macs` and `boot_mac_last`.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Onboard;
use HPS::Registry::Keys;

sub err_of { my ($c) = @_; eval { $c->(); 1 } and return undef; return $@ }

my $f   = StorageFixture::setup();
my $reg = $f->{reg};
my $A   = $StorageFixture::MAC;     # 525400000001, host sch-001
my $B   = $StorageFixture::MAC2;
$reg->host_set($B, 'STATE', 'HELD');
$reg->cluster_set('lab', 'network_dns_domain', 'lab.hps');

# --- catalogue -------------------------------------------------------------------
is(HPS::Registry::Keys::type_of('host', 'macs'), 'json', 'macs is catalogued as json');
is(HPS::Registry::Keys::type_of('host', 'boot_mac_last'), 'mac', 'boot_mac_last is catalogued as mac');

# --- before any audit: a host is its own MAC -----------------------------------------
is($reg->resolve_mac('52:54:00:00:00:01'), $A, 'a host key resolves to itself, any format');
is($reg->resolve_mac('AA-BB-CC-DD-EE-FF'), 'aabbccddeeff', 'an unknown MAC resolves to itself, normalised (it becomes a new host)');
like(err_of(sub { $reg->resolve_mac('nonsense') }), qr/Invalid MAC/, 'text that is not a MAC is refused');
is_deeply([ $reg->host_macs($A) ], [$A], 'no macs key: the host key is the only MAC');
is_deeply([ $reg->host_macs('525400999999') ], [], 'no such host: no MACs');

# --- record macs ------------------------------------------------------------------------
$reg->host_set($A, 'macs', [
    { mac => '52:54:00:aa:00:02', ifname => 'eno2', driver => 'tg3', speed => 1000 },
    { mac => '52:54:00:00:00:01', ifname => 'eno1', driver => 'tg3', speed => 1000 },
    { mac => '52:54:00:aa:00:03', ifname => 'eno3', driver => undef, speed => undef },
]);
is_deeply([ $reg->host_macs($A) ], [ $A, '525400aa0002', '525400aa0003' ], 'host_macs: key first, then the recorded MACs, no repeats');
is($reg->resolve_mac('52:54:00:aa:00:02'), $A, 'a second port resolves to the first host');
is($reg->resolve_mac('525400AA0003'), $A, 'a third port, any case, resolves to the first host');
is($reg->resolve_mac($B), $B, 'another host keeps its own key');
my $idx = $reg->mac_index;
is($idx->{'525400aa0002'}, $A, 'the index maps a recorded MAC to its host');
is($idx->{$B}, $B, 'the index maps a host key to itself');

# --- conflicts ---------------------------------------------------------------------------
is_deeply([ $reg->mac_conflicts($A, '525400aa0002', $A) ], [], 'a host does not conflict with its own MACs');
is_deeply([ $reg->mac_conflicts($B, '525400aa0002') ], [ [ '525400aa0002', $A ] ], 'a MAC another host lists is a conflict');
is_deeply([ $reg->mac_conflicts($B, $A) ], [ [ $A, $A ] ], 'another host key is a conflict');
is_deeply([ $reg->mac_conflicts($B, '525400bb0001') ], [], 'a free MAC is no conflict');

# --- show lists the MACs and takes any of them ---------------------------------------------
my $ob = HPS::Onboard->new(registry => $reg, approval => $f->{ap}, keysafe => $f->{ks});
$reg->host_set($A, 'boot_mac_last', '525400aa0002');
my $s = $ob->show('52:54:00:aa:00:03');
is($s->{mac}, $A, 'show by a second MAC finds the host');
is(scalar @{ $s->{macs} }, 3, 'show carries every recorded MAC');
is($s->{boot_mac_last}, '525400aa0002', 'show carries boot_mac_last');
ok(!exists $s->{identity}{macs}, 'the macs array is not dumped into the identity text');
my $cli = sub {
    local $ENV{HPS_CONFIG_BASE}     = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-onboard", @_);
    my $out = qx(@cmd 2>&1);
    return ($? >> 8, $out);
};
my ($rc, $out) = $cli->('show', '52:54:00:aa:00:02');
is($rc, 0, 'hps-onboard show by a second MAC exits 0') or diag $out;
like($out, qr/^Host $A$/m, 'show names the host by its key');
like($out, qr/MAC addresses/, 'show has a MAC section');
like($out, qr/52:54:00:aa:00:02\s+eno2\s+tg3\s+1000 Mb\/s/, 'show lists a MAC with interface, driver and speed');
like($out, qr/52:54:00:aa:00:03\s+eno3\s+-\s+-/, 'show lists a MAC without driver or speed');
like($out, qr/last booted from: 525400aa0002/, 'show says which port booted last');

# --- forget frees the MACs --------------------------------------------------------------------
my $tmp  = tempdir(CLEANUP => 1);
my $hook = "$tmp/hook.sh";
open(my $h, '>', $hook) or die;
print {$h} "#!/usr/bin/env bash\nexit 0\n";
close $h;
chmod 0755, $hook;
my $ob2 = HPS::Onboard->new(registry => $reg, approval => $f->{ap}, keysafe => $f->{ks}, forget_cmd => $hook);
StorageFixture::approve($f, 'host-forget', pool => 'host');
my $r = $ob2->forget('52:54:00:aa:00:03', dry_run => 1);
is($r->{mac}, $A, 'forget by a second MAC acts on the host');
like(join("\n", @{ $r->{steps} }), qr/would free MACs 525400000001, 525400aa0002, 525400aa0003/, 'the dry run names the MACs it would free');
$r = $ob2->forget('52:54:00:aa:00:03');
like(join("\n", @{ $r->{steps} }), qr/freed MACs 525400000001, 525400aa0002, 525400aa0003/, 'forget reports the MACs it freed');
ok(!$reg->host_exists($A), 'the host is gone');
is($reg->resolve_mac('52:54:00:aa:00:02'), '525400aa0002', 'a freed MAC is unknown again (it would become a new host)');
is_deeply([ $reg->mac_conflicts($B, '525400aa0002') ], [], 'a freed MAC is no longer a conflict');

done_testing;
