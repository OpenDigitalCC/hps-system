#!/usr/bin/env perl
# IPS-08: HPS::BMC - driver selection from the audit (lib/bmc/drivers.map), the
# operator override, power devices, the credential hand-over (stdin only, never
# logged), the retry policy and the host/device records.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use JSON::PP;
use HPS::Registry;
use HPS::Keysafe;
use HPS::BMC;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');

my $PASS = 's3cr3t"Pw\\x9';
my $USER = 'admin-test';

# The lab DL360 audit as the audit image reports it: dmi vendor HP, product
# ProLiant DL360 Gen9, BMC facts from ipmitool and DMI.
my $dl360 = {
    schema => 'hps-audit/1',
    dmi    => { sys_vendor => 'HP', product_name => 'ProLiant DL360 Gen9', product_serial => 'SER1' },
    bmc    => {
        ipmi_device => JSON::PP::true,
        lan   => { mac => 'aa:bb:cc:00:11:22', ip_source => 'DHCP Address', ip => '192.0.2.50' },
        mc    => { manufacturer_id => '11', product_id => '8199', firmware => '2.55' },
        dmi38 => 1,
        dmi42 => 0,
    },
};

my @logs;
my @sleeps;
my $bmc = HPS::BMC->new(registry => $reg, logger => sub { push @logs, "$_[0] $_[1]" },
    sleep => sub { push @sleeps, $_[0] });

sub err_of { my $c = shift; eval { $c->(); 1 } and return ''; return ref $@ ? $@->message : $@ }

#--- the rule table ---------------------------------------------------------------

my $m = $bmc->map_audit($dl360);
is($m->{driver}, 'hpe-ilo', 'the lab DL360 audit maps to hpe-ilo');
is($m->{evidence}{vendor}, 'HP', 'the evidence keeps the vendor');

my $nobmc = { dmi => { sys_vendor => 'HP', product_name => 'ProLiant DL360 Gen9' } };
is($bmc->map_audit($nobmc)->{driver}, 'hpe-ilo', 'an audit without BMC facts still maps by vendor and product');

is($bmc->map_audit({ dmi => { sys_vendor => 'HPE', product_name => 'ProLiant DL380 Gen10' } })->{driver}, 'hpe-ilo', 'HPE vendor spelling');
is($bmc->map_audit({ dmi => { sys_vendor => 'Dell Inc.', product_name => 'PowerEdge R640' } })->{driver}, 'dell-idrac', 'Dell vendor maps to dell-idrac');
is($bmc->map_audit({ dmi => { sys_vendor => 'Acme', product_name => 'X' }, bmc => { mc => { manufacturer_id => '674' } } })->{driver},
    'dell-idrac', 'manufacturer id 674 maps to dell-idrac');
is($bmc->map_audit({ dmi => { sys_vendor => 'Acme' }, bmc => { mc => { manufacturer_id => '11' } } })->{driver},
    'hpe-ilo', 'manufacturer id 11 maps to hpe-ilo');
is($bmc->map_audit({ dmi => { sys_vendor => 'Acme' }, bmc => { dmi42 => 1, dmi38 => 1 } })->{driver},
    'redfish-generic', 'a Redfish host interface maps to redfish-generic');
is($bmc->map_audit({ dmi => { sys_vendor => 'Acme' }, bmc => { dmi38 => 1 } })->{driver},
    'ipmi', 'IPMI evidence only maps to ipmi');
is($bmc->map_audit({ dmi => { sys_vendor => 'Acme' } })->{driver}, 'manual', 'nothing found maps to manual');
is($bmc->map_audit({ dmi => { sys_vendor => 'Hewlett Packard Enterprise', product_name => 'Synergy 480' } })->{driver},
    'hpe-ilo', 'long HPE vendor name');
is($bmc->map_audit({ dmi => { sys_vendor => 'HP', product_name => 'Desktop Pro' } })->{driver},
    'manual', 'an HP that is not a server is not an iLO');
ok(scalar(grep { $_ eq 'hpe-ilo' } $bmc->drivers), 'the installed drivers are listed');
is_deeply([ sort $bmc->drivers ], [ sort qw(dell-idrac external hpe-ilo ipmi manual redfish-generic) ], 'the first driver set');

#--- selection and override -----------------------------------------------------------

my $mac = '52:54:00:97:00:01';
$reg->host_set($mac, 'STATE', 'HELD');
$reg->host_set($mac, 'HOSTNAME', 'sch-001.lab');
$reg->host_set($mac, 'audit', $dl360);

my $r = $bmc->select_from_audit($mac);
is($r->{driver}, 'hpe-ilo', 'select picks hpe-ilo');
is($reg->host_get($mac, 'bmc_driver'), 'hpe-ilo', 'bmc_driver recorded');
is($reg->host_get($mac, 'bmc_driver_source'), 'audit', 'source is audit');
is($reg->host_get($mac, 'bmc_addr'), '192.0.2.50', 'bmc_addr from lan print');
is($reg->host_get_json($mac, 'bmc_evidence')->{vendor}, 'HP', 'evidence recorded');
is($reg->host_get_json($mac, 'bmc_evidence')->{rule}, $m->{rule}, 'the matching rule line is recorded');

# DHCP-less BMC: address from the audit goes away when a re-audit finds none.
my %again = %$dl360;
$again{bmc} = { %{ $dl360->{bmc} }, lan => { mac => '', ip_source => '', ip => '0.0.0.0' } };
$reg->host_set($mac, 'audit', \%again);
$bmc->select_from_audit($mac);
ok(!$reg->host_exists($mac, 'bmc_addr'), 'an audit that finds no address clears the audit-sourced address');
$reg->host_set($mac, 'audit', $dl360);
$bmc->select_from_audit('sch-001');
is($reg->host_get($mac, 'bmc_addr'), '192.0.2.50', 'resolved by HOSTNAME as well');

# Operator override.
$bmc->device_set('pdu1', addr => '192.0.2.99', options => { cmd => 'pdu-ctl --outlet {outlet} {action}' });
like(err_of(sub { $bmc->set($mac, driver => 'nosuch') }), qr/No such driver/, 'an unknown driver is refused');
like(err_of(sub { $bmc->set($mac, driver => 'external') }), qr/outlet/, 'external needs an outlet');
like(err_of(sub { $bmc->set($mac, driver => 'external', options => { outlet => 'nopdu:3' }) }), qr/No power device/, 'external needs a defined device');
like(err_of(sub { $bmc->set($mac, driver => 'external', options => { 'Bad Key' => 1 }) }), qr/Invalid option name/, 'bad option name refused');
$bmc->set($mac, driver => 'external', options => { outlet => 'pdu1:7' });
is($reg->host_get($mac, 'bmc_driver'), 'external', 'operator driver set');
is($reg->host_get($mac, 'bmc_driver_source'), 'operator', 'source is operator');
is_deeply($reg->host_get_json($mac, 'bmc_options'), { outlet => 'pdu1:7' }, 'options recorded');

my $kept = $bmc->select_from_audit($mac);
is($kept->{changed}, 0, 'a re-audit changes nothing for an operator choice');
is($reg->host_get($mac, 'bmc_driver'), 'external', 'operator driver survives the re-audit');
is($reg->host_get($mac, 'bmc_driver_source'), 'operator', 'source stays operator');
$reg->host_set($mac, 'audit', { dmi => { sys_vendor => 'Dell Inc.', product_name => 'PowerEdge' } });
$bmc->select_from_audit($mac);
is($reg->host_get($mac, 'bmc_driver'), 'external', 'operator driver survives an audit that would pick another');

$bmc->set($mac, driver => 'auto');
is($reg->host_get($mac, 'bmc_driver'), 'dell-idrac', 'driver auto hands the choice back to the audit');
is($reg->host_get($mac, 'bmc_driver_source'), 'audit', 'source back to audit');
ok(!$reg->host_exists($mac, 'bmc_options'), 'operator options cleared by auto');
$reg->host_set($mac, 'audit', $dl360);
$bmc->select_from_audit($mac);
like(err_of(sub { $bmc->select_from_audit('52:54:00:97:00:09') }), qr/No such host/, 'unknown host');

#--- credentials -------------------------------------------------------------------

$bmc->set($mac, driver => 'external', options => { outlet => 'pdu1:7' });
like(err_of(sub { $bmc->credential_set($mac, $USER, '') }), qr/required/, 'an empty password is refused');
like(err_of(sub { $bmc->credential_set($mac, $USER, "a\nb") }), qr/one line/, 'a multi-line password is refused');
like(err_of(sub { $bmc->credential_set('device:nopdu', $USER, $PASS) }), qr/No power device/, 'unknown device');
$bmc->credential_set('device:pdu1', $USER, $PASS);
$bmc->credential_set($mac, 'bmcuser', 'hostpass');
my $ks = HPS::Keysafe->new(registry => $reg);
is($ks->get_secret('device-pdu1'), "$USER\n$PASS\n", 'the device credential is in the keysafe');
is($ks->get_secret('525400970001'), "bmcuser\nhostpass\n", 'the host credential is in the keysafe');
is(sprintf('%04o', (stat "$base/clusters/lab/keysafe/credentials/device-pdu1.cred")[2] & 07777), '0600', 'credential file mode 0600');
is(sprintf('%04o', (stat "$base/clusters/lab/keysafe/credentials")[2] & 07777), '0700', 'credential dir mode 0700');
ok(!defined $ks->get_secret('nothing-here'), 'a missing secret is undef');

# Nothing but the keysafe holds the password: grep every other file under the base.
{
    my @hits;
    require File::Find;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        return if $_ =~ m{/keysafe/};
        open(my $fh, '<', $_) or return;
        local $/;
        my $c = <$fh>;
        push @hits, $_ if index($c, $PASS) >= 0 || index($c, 'hostpass') >= 0;
    } }, $base);
    is_deeply(\@hits, [], 'the password is in no registry file');
}

#--- run: the driver call -------------------------------------------------------------

my $drv = tempdir(CLEANUP => 1);
my $rec = tempdir(CLEANUP => 1);
for my $name (qw(hpe-ilo external dell-idrac)) {
    open(my $fh, '>', "$drv/$name") or die;
    print $fh <<"SH";
#!/usr/bin/env bash
echo "\$*" >> "$rec/argv"
env | grep '^BMC_' | sort > "$rec/env"
cat > "$rec/stdin"
echo "stderr line" >&2
if [[ "\$1" == status ]]; then
  echo '{"power":"on","model":"M","serial":"S","bmc_firmware":"F","extra":"x"}'
else
  echo "echo of \$(sed -n 2p "$rec/stdin")"
fi
rc=0
if [[ -s "$rec/rcs" ]]; then
  rc="\$(head -n1 "$rec/rcs")"
  tail -n +2 "$rec/rcs" > "$rec/rcs.new"
  mv "$rec/rcs.new" "$rec/rcs"
fi
exit "\$rc"
SH
    close $fh;
    chmod 0755, "$drv/$name";
}
sub rcs { open(my $fh, '>', "$rec/rcs") or die; print $fh map {"$_\n"} @_; close $fh }
sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; return scalar <$fh> }

my $run = HPS::BMC->new(registry => $reg, drivers_dir => $drv, logger => sub { push @logs, "$_[0] $_[1]" },
    sleep => sub { push @sleeps, $_[0] });

# hpe-ilo host with a host credential
$bmc->set($mac, driver => 'auto');
$bmc->credential_set($mac, $USER, $PASS);
@logs = ();
my $s = $run->run('sch-001', 'status');
is($s->{rc}, 0, 'status exits 0');
is_deeply($s->{status}, { power => 'on', model => 'M', serial => 'S', bmc_firmware => 'F' }, 'status JSON is reduced to the four contract fields');
is(slurp("$rec/stdin"), "$USER\n$PASS\n", 'the credential arrived on the driver stdin');
is(slurp("$rec/argv"), "status\n", 'argv is the action only');
my $env = slurp("$rec/env");
like($env, qr/^BMC_ADDR=192\.0\.2\.50$/m, 'BMC_ADDR from bmc_addr');
like($env, qr/^BMC_HOST=525400970001$/m, 'BMC_HOST is the MAC');
unlike($env, qr/\Q$PASS\E/, 'the password is not in the driver environment');
is($reg->host_get_json($mac, 'bmc_last')->{rc}, 0, 'bmc_last recorded');
is($reg->host_get_json($mac, 'bmc_last')->{power}, 'on', 'bmc_last carries the power state');

my $o = $run->run($mac, 'on');
is($o->{rc}, 0, 'on exits 0');
unlike($o->{stdout}, qr/\Q$PASS\E/, 'a driver that echoes the password is scrubbed');
like($o->{stdout}, qr/\*\*\*/, 'scrubbed with ***');
is(scalar(grep { /\Q$PASS\E/ || /$USER/ } @logs), 0, 'the log never carries the credential');
ok((grep { /action=status host=525400970001 driver=hpe-ilo exit=0/ } @logs), 'every call is logged: action, host, driver, exit');
{
    my $dump = join "\n", @logs;
    unlike($dump, qr/\Q$PASS\E/, 'password absent from all log lines');
}

# retry policy
@sleeps = ();
rcs(4, 4, 0);
my $t = $run->run($mac, 'reset');
is($t->{rc}, 0, 'exit 4 twice then success is success');
is($t->{tries}, 3, 'three tries');
is_deeply(\@sleeps, [ 20, 20 ], 'retry_delay between tries');
@sleeps = ();
rcs(4, 4, 4, 4, 4);
$t = $run->run($mac, 'reset');
is($t->{rc}, 4, 'persistent exit 4 stays 4');
is($t->{tries}, 4, 'four tries, then stop');
is_deeply(\@sleeps, [ 20, 20, 20 ], 'three waits: 60 seconds over four tries');
@sleeps = ();
for my $code (3, 5, 1) {
    rcs($code, 0);
    $t = $run->run($mac, 'reset');
    is($t->{rc}, $code, "exit $code is returned");
    is($t->{tries}, 1, "exit $code is never retried");
}
is_deeply(\@sleeps, [], 'no waiting for 1, 3 or 5');
rcs();

# no driver, unknown action, driver not installed
my $mac2 = '52:54:00:97:00:02';
$reg->host_set($mac2, 'STATE', 'INSTALLED');
my $nd = $run->run($mac2, 'status');
is($nd->{rc}, 5, 'a host without a driver exits 5 (escalate)');
like($nd->{stderr}, qr/No BMC driver/, 'and says why');
like(err_of(sub { $run->run($mac, 'explode') }), qr/Unknown action/, 'unknown action');
$reg->host_set($mac2, 'bmc_driver', 'vanished');
is($run->run($mac2, 'on')->{rc}, 1, 'a recorded driver that is not installed fails with 1');

# external: device settings, outlet and the device credential
$run->set($mac2, driver => 'external', options => { outlet => 'pdu1:7', cycle_delay => '0' });
$run->run($mac2, 'off');
$env = slurp("$rec/env");
like($env, qr/^BMC_ADDR=192\.0\.2\.99$/m, 'external: the address is the power device');
like($env, qr/^BMC_OPT_outlet=7$/m, 'external: the outlet number');
like($env, qr/^BMC_OPT_cmd=pdu-ctl --outlet \{outlet\} \{action\}$/m, 'external: the command template from the device');
like($env, qr/^BMC_OPT_cycle_delay=0$/m, 'external: host options pass through');
is(slurp("$rec/stdin"), "$USER\n$PASS\n", 'external: the credential is the power device credential');
like(err_of(sub { $run->device_delete('pdu1') }), qr/used by host/, 'a device in use is not deleted');
is_deeply([ sort keys %{ $run->devices } ], ['pdu1'], 'devices listed');

# list
my @rows = $run->list;
is(scalar(@rows), 2, 'list shows the hosts with a driver');
is($rows[0]{driver}, 'hpe-ilo', 'list: driver');
is($rows[0]{source}, 'audit', 'list: source');
is($rows[0]{last}{action}, 'reset', 'list: last call');

done_testing;
