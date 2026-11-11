#!/usr/bin/env perl
# hps-workload define <name> (the JSON definition on stdin) and show-definition
# <name>: the definition checked as create checks it, written atomically, never
# over an existing one without --replace, never replaced while the workload
# exists. HPS::Workload::define and bin/hps-workload.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $f    = StorageFixture::setup_workload(no_def => 1);
my $dir  = $f->{reg}->workload_dir('lab');
my $path = "$dir/t0.json";
my $tmp  = tempdir(CLEANUP => 1);
my $js   = JSON::PP->new->canonical->pretty;
my $text = $js->encode($f->{def});

local $ENV{HPS_CONFIG_BASE}        = $f->{base};
local $ENV{HPS_SYSTEM_REGISTRY}    = "$f->{base}/system.db";
local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
local $ENV{HPS_STORAGE_NO_SYSLOG}  = 1;
local $ENV{SUDO_USER}              = 'tester';

sub slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    return scalar <$fh>;
}

# cli($stdin, @args): run bin/hps-workload with $stdin on its stdin.
sub cli {
    my ($in, @args) = @_;
    open(my $i, '>:raw', "$tmp/stdin") or die;
    print {$i} $in;
    close $i;
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @args);
    my $q = join ' ', map { "'$_'" } @cmd;
    my $out = qx($q < $tmp/stdin 2>$tmp/stderr);
    my $rc = $? >> 8;
    my $err = slurp("$tmp/stderr") // '';
    return ($rc, $out . $err, $out);
}

sub refused_like {
    my ($code, $re, $label) = @_;
    my $ok = eval { $code->(); 1 };
    my $e = $@;
    ok(!$ok, "$label: refused");
    is(ref $e && $e->kind, 'refused', "$label: kind refused");
    like(ref $e ? $e->message : "$e", $re, "$label: says why");
    return;
}

my $wl = $f->{wl}->();

# --- the library: define, dry-run, refusals --------------------------------------------
my $r = $wl->define('t0', $text, dry_run => 1);
ok($r->{dry_run} && !$r->{written}, 'dry run: valid, nothing written');
is_deeply($r->{vms}, [ 't0-app', 't0-db' ], 'dry run: names the VMs');
ok(!-e $path, 'dry run: no file');

$r = $wl->define('t0', $text);
ok($r->{written} && !$r->{replaced}, 'define: written, not a replacement');
is(slurp($path), $text, 'define: the file holds the definition as given');
is(sprintf('%04o', (stat $path)[2] & 07777), '0664', 'define: a new file is mode 0664');
is((stat $path)[5], (stat $dir)[5], "define: a new file has the directory's group");
opendir(my $dh, $dir) or die;
is_deeply([ sort grep { !/^\.\.?\z/ } readdir $dh ], ['t0.json'], 'define: no temporary file left');
closedir $dh;
is($wl->load('t0')->{name}, 't0', 'the written definition loads as create loads it');
is($wl->show_definition('t0'), $text, 'show_definition: the stored text');

refused_like(sub { $wl->define('t0', $text) }, qr/already defined.*--replace/, 'existing definition without --replace');

my %d2 = %{ $f->{def} };
$d2{project} = 'other';
my $text2 = $js->encode(\%d2);
$r = $wl->define('t0', $text2, replace => 1, dry_run => 1);
ok($r->{replaced} && !$r->{written}, 'replace dry run: would replace, writes nothing');
is(slurp($path), $text, 'replace dry run: the file is unchanged');
chmod 0640, $path;
$r = $wl->define('t0', $text2, replace => 1);
ok($r->{replaced} && $r->{written}, 'replace: written');
is(slurp($path), $text2, 'replace: the new definition');
is(sprintf('%04o', (stat $path)[2] & 07777), '0640', 'replace: the file keeps its mode');

$f->{reg}->cluster_set('lab', 'workload_t0', { state => 'created', vms => {} });
refused_like(sub { $wl->define('t0', $text, replace => 1) }, qr/exists \(state created\); destroy it/,
    '--replace while the workload exists');
refused_like(sub { $wl->define('t0', $text, replace => 1, dry_run => 1) }, qr/exists/,
    '--replace while the workload exists, dry run too');
is(slurp($path), $text2, 'refused replace: the file is unchanged');
$f->{reg}->cluster_set('lab', 'workload_t0', { state => 'creating', vms => {} });
refused_like(sub { $wl->define('t0', $text, replace => 1) }, qr/state creating/, '--replace while creating');
$f->{reg}->cluster_unset('lab', 'workload_t0');
$f->{reg}->cluster_set('lab', 'workload_t0_destroyed', { at => 'x', by => 'y' });
ok($wl->define('t0', $text, replace => 1)->{written}, '--replace after destroy: allowed');

# The same checks as create, from the same code.
refused_like(sub { $wl->define('t1', '{not json') }, qr/not valid JSON/, 'invalid JSON');
refused_like(sub { $wl->define('t1', $text) }, qr/name 't0' differs from the file name 't1'/, 'name differs from the argument');
my %bad = %{ $f->{def} };
$bad{vms} = [ { %{ $f->{def}{vms}[0] }, nets => ['nowhere'] } ];
refused_like(sub { $wl->define('t0', $js->encode(\%bad), replace => 1) }, qr/nowhere/, 'a net missing from the layout (create checks it)');
my %unk = (%{ $f->{def} }, colour => 'blue');
refused_like(sub { $wl->define('t0', $js->encode(\%unk), replace => 1) }, qr/unknown field 'colour'/, 'unknown field');
refused_like(sub { $wl->define('t1', '') }, qr/no definition/, 'empty input');
refused_like(sub { $wl->define('t1', ' ' x ($HPS::Workload::MAX_DEFINITION_BYTES + 1)) }, qr/larger than/, 'oversized input');
ok(!-e "$dir/t1.json", 'refusals write nothing');
for my $n ('../x', 'Bad', 'a/b', '') {
    my $ok = eval { $wl->define($n, $text); 1 };
    ok(!$ok && $@->kind eq 'usage', "bad name '$n': usage");
}
symlink('/etc/hostname', "$dir/t9.json") or die;
my %d9 = (%{ $f->{def} }, name => 't9');
refused_like(sub { $wl->define('t9', $js->encode(\%d9), replace => 1) }, qr/not a regular file/, 'a symlink is never replaced');
unlink "$dir/t9.json";

# --- the CLI ----------------------------------------------------------------------------------
unlink $path;
my ($rc, $out, $stdout) = cli($text, 'define', 't0', '--dry-run');
is($rc, 0, 'cli define --dry-run: 0');
like($out, qr/Dry run: define t0; the definition is valid \(VMs: t0-app, t0-db\)/, 'cli dry run says so');
ok(!-e $path, 'cli dry run writes nothing');
($rc, $out) = cli($text, 'define', 't0');
is($rc, 0, 'cli define: 0');
like($out, qr/define ok: workload t0 defined in \Q$path\E/, 'cli define says so');
is(slurp($path), $text, 'cli define: written');
($rc, $out) = cli($text, 'define', 't0');
is($rc, 3, 'cli define over an existing definition: refused (3)');
like($out, qr/--replace/, 'names --replace');
($rc, $out, $stdout) = cli($text2, 'define', 't0', '--replace', '--json');
is($rc, 0, 'cli define --replace --json: 0');
my $j = decode_json($stdout);
ok($j->{replaced} && $j->{written}, 'json: replaced and written');
($rc, $out, $stdout) = cli('', 'show-definition', 't0');
is($rc, 0, 'cli show-definition: 0');
is($stdout, $text2, 'cli show-definition prints the stored JSON');
($rc, $out) = cli('', 'show-definition', 'ghost');
is($rc, 4, 'cli show-definition of no definition: not found (4)');
($rc, $out) = cli('', 'define', 't2');
is($rc, 3, 'cli define with no input: refused (3)');
($rc, $out) = cli('{"name":', 'define', 't2');
is($rc, 3, 'cli define with bad JSON: refused (3)');
($rc, $out) = cli($text, 'define', 'Bad');
is($rc, 2, 'cli define with a bad name: usage (2)');
($rc, $out) = cli($text, 'define', 't0', 'extra');
is($rc, 2, 'cli define with an extra argument: usage');
($rc, $out) = cli($text, 'define', 't0', '--forget');
is($rc, 2, 'cli define --forget: usage');
($rc, $out) = cli('', 'show-definition', 't0', '--dry-run');
is($rc, 2, 'cli show-definition takes no options');
($rc, $out) = cli('', 'create', 't0', '--replace');
is($rc, 2, 'cli --replace is only for define');
like($out, qr/--replace is only for define/, 'says so');
ok(!-e "$dir/t2.json", 'cli refusals write nothing');

done_testing;
