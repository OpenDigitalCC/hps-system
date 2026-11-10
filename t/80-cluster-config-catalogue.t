#!/usr/bin/env perl
# Drift test: every question the cluster configure menu asks, and every key it
# stores, has a catalogue entry (scripts/cluster-config.d/*.sh are parsed).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::ClusterConfig;

my $dir = "$Bin/../scripts/cluster-config.d";
my @scripts = sort glob("$dir/*.sh");
ok(scalar @scripts >= 6, 'the menu scripts are found');

my %by_prompt = map { $_->{prompt} => $_ } HPS::ClusterConfig::questions();
my %by_key    = map { $_->{key} => $_ } HPS::ClusterConfig::questions();

# Prompts that are not configuration values.
my %NOT_A_KEY = map { $_ => 1 } (
    'Keep current DHCP configuration?',
    'Keep current storage network configuration?',
    'Configure storage networks?',
    'Keep current system service configuration?',
    'Keep current OpenSVC configuration?',
    'Customize OpenSVC parameters?',
);

my ($n_prompts, $n_keys) = (0, 0);
for my $s (@scripts) {
    open(my $fh, '<', $s) or die "$s: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    (my $name = $s) =~ s{.*/}{};

    while ($text =~ /\b(?:cli_prompt_yesno|cli_prompt|select_network_interface)\s+"([^"]+)"/g) {
        my $p = $1;
        $n_prompts++;
        next if $NOT_A_KEY{$p};
        ok($by_prompt{$p}, "$name: prompt '$p' has a catalogue entry");
    }

    while ($text =~ /CLUSTER_CONFIG_PENDING\+=\("([A-Za-z0-9_\$\{\}-]+):/g) {
        my $k = $1;
        $n_keys++;
        if ($k =~ /\$\{?vlan\}?/) {
            # network_storage_vlan${vlan}_<field>: derived per-VLAN key
            (my $probe = $k) =~ s/\$\{vlan\}/31/;
            ok(HPS::ClusterConfig::is_derived_key($probe), "$name: stored key $k is a derived key");
        }
        elsif ($k eq '${key}') {
            pass("$name: loop over the osvc defaults table (checked below)");
        }
        elsif ($k =~ /\$/) {
            fail("$name: unexpected variable key $k");
        }
        else {
            ok($by_key{$k} || HPS::ClusterConfig::is_derived_key($k), "$name: stored key $k is catalogued or derived");
        }
    }
}
cmp_ok($n_prompts, '>=', 20, 'the prompt scan found the questions');
cmp_ok($n_keys, '>=', 25, 'the stored-key scan found the keys');

# osvc keys of 090 are stored through a loop over the defaults table.
open(my $fh, '<', "$dir/090-set-opensvc-params.sh") or die $!;
my $osvc = do { local $/; <$fh> };
close $fh;
my @osvc = $osvc =~ /\["(osvc_[a-z_]+)"\]=/g;
is(scalar @osvc, 9, '090 defines nine osvc parameters');
ok($by_key{$_}, "090 default table key $_ is catalogued") for @osvc;

# The stored-value check: defaults in the catalogue equal the script defaults.
my %osvc_default;
@osvc_default{@osvc} = $osvc =~ /\["osvc_[a-z_]+"\]="([^"]*)"/g;
is($by_key{$_}{default}, $osvc_default{$_}, "$_ default matches 090") for @osvc;

# Catalogue shape.
my %groups = map { $_ => 1 } qw(description dns dhcp storage-networks services opensvc);
for my $q (HPS::ClusterConfig::questions()) {
    ok($groups{ $q->{group} }, "$q->{key}: group $q->{group} is a known group");
    ok(length $q->{prompt} && length $q->{rule}, "$q->{key}: prompt and rule present");
    unlike($q->{key}, HPS::ClusterConfig::secret_name_re(), "$q->{key}: not a secret name");
}
is(scalar(keys %by_key), scalar(HPS::ClusterConfig::questions()), 'no key appears twice');

done_testing;
