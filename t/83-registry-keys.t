#!/usr/bin/env perl
# IPS-07: the registry key catalogue (HPS::Registry::Keys) lists every key the code
# writes, and docs/REGISTRY-KEYS.md is generated from it.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry::Keys;

my $root = "$Bin/..";

sub slurp {
    my ($f) = @_;
    open(my $h, '<', "$root/$f") or die "$f: $!";
    local $/;
    return scalar <$h>;
}

# Normal form of a key as written in code: ${x} and $x become <>.
sub norm {
    my ($k) = @_;
    $k =~ s/\$\{[^}]*\}|\$[A-Za-z_]\w*/<>/g;
    return $k;
}

sub files {
    my @out;
    for my $d (qw(lib http bin scripts cli node-manager)) {
        next unless -d "$root/$d";
        open(my $p, '-|', 'find', "$root/$d", '-type', 'f', '-not', '-path', '*/tests/*', '-not', '-name', '*.md') or die;
        while (my $f = <$p>) { chomp $f; $f =~ s{^\Q$root\E/}{}; push @out, $f }
        close $p;
    }
    return sort @out;
}

# Every [scope, key, where] the code writes under a literal (or interpolated) name.
sub written_keys {
    my @w;
    for my $f (files()) {
        next if $f =~ m{^lib/perl/HPS/Registry/Keys\.pm\z};
        my $text = slurp($f);
        if ($f =~ /\.pm\z|^bin\// || $text =~ /\A#!.*perl/) {
            while ($text =~ /->(host|cluster|os)_(?:set|unset)\(\s*[^,()]+,\s*(['"])([^'"]+)\2/g) { push @w, [ $1, norm($3), $f ] }
            while ($text =~ /->system_(?:set|unset)\(\s*(['"])([^'"]+)\1/g)                        { push @w, [ 'system', norm($2), $f ] }
            while ($text =~ /\$self->_(?:set|unset)\(\s*'([^']+)'/g)                              { push @w, [ 'host', norm($1), $f ] }
            while ($text =~ /\$self->_db_set\(\$db,\s*'([^']+)'/g)                                  { push @w, [ 'host', $1, $f ] }
            while ($text =~ /\bderives\s*=>\s*\[\s*([^\]]+)\]/g) {
                push @w, [ 'cluster', $_, $f ] for grep { !/\*/ } $1 =~ /'([^']+)'/g;
            }
            while ($text =~ /\b_q\(key\s*=>\s*'([^']+)'/g)                                          { push @w, [ 'cluster', $1, $f ] }
            while ($text =~ /sub (registry_key|_rec_key|_destroyed_key)\b[^\n]*return\s+"([^"]+)"/g) {
                push @w, [ $1 eq 'registry_key' ? 'host' : 'cluster', norm($2), $f ];
            }
        }
        next unless $f =~ /\.sh\z/;
        for my $line (split /\n/, $text) {
            next if $line =~ /^\s*#/;
            next unless $line =~ /\b(host|cluster|system|os)_registry\b/;
            my $scope = $1;
            next unless $line =~ /\b(host|cluster|system|os)_registry\b[^|\n]*?\s"?(?:set|delete|unset)"?\s+"?([^\s"]+)"?/;
            my $key = $2;
            next if $key =~ /^\$[A-Za-z_]\w*\z/ || $key =~ /^\$\{[^}]*\}\z/ || $key =~ /[<>\[]/;
            push @w, [ $1, norm($key), $f ];
        }
    }
    return @w;
}

my @written = written_keys();
cmp_ok(scalar(@written), '>', 60, 'the scan finds the keys the code writes') or diag scalar @written;

my %seen;
for my $w (@written) {
    my ($scope, $key, $where) = @$w;
    next if $seen{"$scope $key"}++;
    ok(defined HPS::Registry::Keys::lookup($scope, $key), "$scope key '$key' ($where) is in the catalogue");
}

# A key written in code but missing from the table is caught (the scan itself).
{
    no warnings 'redefine';
    my $row = HPS::Registry::Keys::lookup('host', 'ctrl_exec_paired_at');
    ok($row, 'control: the catalogue knows ctrl_exec_paired_at');
    ok(!defined HPS::Registry::Keys::lookup('host', 'made_up_key_xyz'), 'control: an unknown key is not in the catalogue');
    ok(!defined HPS::Registry::Keys::lookup('cluster', 'ctrl_exec_paired_at'), 'scope matters');
}

# The scan reads the ClusterConfig catalogue and the derived keys.
ok($seen{'cluster network_dhcp_ip'} && $seen{'cluster osvc_hb_type'} && $seen{'host UPDATED'}, 'ClusterConfig keys, derived keys and UPDATED are scanned');

# The table itself: every row complete, types known, names unique per scope.
my %types = map { $_->{name} => 1 } HPS::Registry::Keys::types();
my %uniq;
for my $r (HPS::Registry::Keys::keys_table()) {
    ok($types{ $r->{type} }, "$r->{scope} $r->{name}: type '$r->{type}' is a documented type");
    ok(length $r->{writer} && length $r->{meaning}, "$r->{scope} $r->{name}: writer and meaning given");
    ok(!$uniq{"$r->{scope} $r->{name}"}++, "$r->{scope} $r->{name}: listed once");
    like($r->{scope}, qr/\A(?:host|cluster|system)\z/, "$r->{name}: scope");
}
for my $t (qw(bool epoch iso8601 string json pin mac)) { ok($types{$t}, "the filing's type '$t' exists") }

# ctrl_exec_paired: the compatibility key and its replacement.
is(HPS::Registry::Keys::type_of('host', 'ctrl_exec_paired_at'), 'epoch', 'ctrl_exec_paired_at is an epoch');
is(HPS::Registry::Keys::type_of('host', 'ctrl_exec_paired'), 'epoch', 'ctrl_exec_paired holds an epoch (compatibility)');
is((grep { $_->{name} eq 'ctrl_exec_paired' } HPS::Registry::Keys::keys_table())[0]{replaced_by}, 'ctrl_exec_paired_at', 'and names its replacement');

# The document is the table, rendered.
is(slurp('docs/REGISTRY-KEYS.md'), HPS::Registry::Keys::render_markdown(), 'docs/REGISTRY-KEYS.md is up to date (bin/hps-registry-keys --markdown)');

# Free-form writers exist (a moved file would make the list stale).
ok(-f "$root/$_->{file}", "free-form writer $_->{file} exists") for HPS::Registry::Keys::free_form();

done_testing;
