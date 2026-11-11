#!/usr/bin/env perl
# bin/hps-op, the operator client, against a fake ctrl-exec-cli that records
# its arguments, the token it was given and its stdin, and answers like the API.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use FindBin qw($Bin);

my $dir = tempdir(CLEANUP => 1);
my $TOKEN = 'hpsop_' . ('c' x 64);
my $PEM = "-----BEGIN CERTIFICATE-----\nMIIBtest\n-----END CERTIFICATE-----\n";

sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }
sub spew  { my ($f, $t, $m) = @_; open(my $fh, '>', $f) or die $!; print {$fh} $t; close $fh; chmod($m // 0600, $f) }

# The fake client: argv (one per line), CTRL_EXEC_TOKEN, the --ca file's text
# and stdin go to files; the reply is $FAKE_REPLY or a result with exit 3.
my $cli = "$dir/ctrl-exec-cli";
spew($cli, <<"EOT", 0755);
#!$^X
use strict; use warnings;
open(my \$a, '>', "$dir/argv"); print {\$a} map { "\$_\\n" } \@ARGV; close \$a;
open(my \$t, '>', "$dir/token"); print {\$t} \$ENV{CTRL_EXEC_TOKEN} // ''; close \$t;
my %o; for my \$i (0 .. \$#ARGV - 1) { \$o{\$ARGV[\$i]} //= \$ARGV[\$i + 1] }
if (open(my \$c, '<', \$o{'--ca'})) { local \$/; my \$x = <\$c>; open(my \$w, '>', "$dir/ca"); print {\$w} \$x; close \$w }
local \$/; my \$in = <STDIN> // '';
open(my \$s, '>', "$dir/stdin"); print {\$s} \$in; close \$s;
print \$ENV{FAKE_REPLY} // '{"ok":true,"reqid":"ab","results":[{"host":"ips.lab.hps","exit":3,"stdout":"out-line\\n","stderr":"err-line\\n"}]}';
exit(\$ENV{FAKE_CLI_RC} // 0);
EOT

my $cred = "$dir/lab-operator";
spew($cred, "# credential\nname = alice\nagent = ips.lab.hps\nurl = https://10.99.1.1:7445\ntoken = $TOKEN\n$PEM");

local $ENV{CTRL_EXEC_CLI} = $cli;

sub run_op {
    my ($stdin, @args) = @_;
    spew("$dir/in", $stdin // '');
    unlink "$dir/stdin", "$dir/argv";
    my $cmd = join ' ', map { quotemeta } $^X, "$Bin/../bin/hps-op", @args;
    my $out = qx($cmd < $dir/in 2>$dir/err);
    return ($? >> 8, $out, slurp("$dir/err"));
}

my ($rc, $out, $err) = run_op('ignored', '--cred', $cred, 'hps-onboard', 'list', '--json');
is($rc, 3, 'the exit status is the tool\'s');
is($out, "out-line\n", 'the tool\'s stdout on stdout');
is($err, "err-line\n", 'the tool\'s stderr on stderr');
my @argv = split /\n/, slurp("$dir/argv");
is_deeply(\@argv, [ '--url', 'https://10.99.1.1:7445', '--ca', $argv[3], '--timeout', 900, '--username', 'alice',
    'run', 'ips.lab.hps', '--script', 'hps-onboard', '--json', '--', 'list', '--json' ], 'the client call');
is(slurp("$dir/token"), $TOKEN, 'the token reaches the client in its environment');
ok(!(grep { index($_, $TOKEN) >= 0 } @argv), 'and never on its command line');
is(slurp("$dir/ca"), $PEM, 'the credential\'s certificate is the --ca');
ok(!-e $argv[3], 'the temporary CA file is removed');
is(slurp("$dir/stdin"), '', 'without --input the client gets no stdin');

($rc) = run_op("admin\nS3cret\n", '--cred', $cred, '--input', 'hps-bmc-credential', 'aa:bb:cc:dd:ee:01');
@argv = split /\n/, slurp("$dir/argv");
is(slurp("$dir/stdin"), "admin\nS3cret\n", '--input: stdin goes to the client');
ok((grep { $_ eq '--input' } @argv) && $argv[ (grep { $argv[$_] eq '--input' } 0 .. $#argv)[0] + 1 ] eq '-', '--input - is passed');
ok(!(grep { /S3cret/ } @argv), 'the input is in no argument');

($rc) = run_op('', '--cred', $cred, '--ips', 'https://192.0.2.5:7445', 'hps-ips-check');
@argv = split /\n/, slurp("$dir/argv");
is($argv[1], 'https://192.0.2.5:7445', '--ips overrides the credential url');
ok(!(grep { $_ eq '--' } @argv), 'no -- without arguments');

{
    local $ENV{FAKE_REPLY} = '{"ok":true,"results":[{"host":"ips.lab.hps","exit":0,"stdout":"fine\n","stderr":""}]}';
    ($rc, $out) = run_op('', '--cred', $cred, 'hps-pins', 'list');
    is($rc, 0, 'exit 0 passes');
    ($rc, $out) = run_op('', '--cred', $cred, '--json', 'hps-pins', 'list');
    is($out, $ENV{FAKE_REPLY}, '--json prints the reply as it is');
}
{
    local $ENV{FAKE_CLI_RC} = 1;
    local $ENV{FAKE_REPLY} = '';
    ($rc, $out, $err) = run_op('', '--cred', $cred, 'hps-pins', 'list');
    is($rc, 1, 'a failed API call exits 1');
    like($err, qr/the API call failed/, 'and says so');
}

chmod 0644, $cred;
($rc, $out, $err) = run_op('', '--cred', $cred, 'hps-pins', 'list');
is($rc, 2, 'a credential readable by others is refused');
like($err, qr/must be 0600 or tighter/, 'with the reason');
chmod 0600, $cred;

my $plain = "$dir/plain";
spew($plain, "name = a\nagent = ips.lab.hps\nurl = http://10.99.1.1:7445\ntoken = $TOKEN\n$PEM");
($rc, $out, $err) = run_op('', '--cred', $plain, 'hps-pins', 'list');
is($rc, 2, 'a plain http URL is refused');
my $nocert = "$dir/nocert";
spew($nocert, "name = a\nagent = ips.lab.hps\nurl = https://10.99.1.1:7445\ntoken = $TOKEN\n");
($rc, $out, $err) = run_op('', '--cred', $nocert, 'hps-pins', 'list');
is($rc, 2, 'a credential without a certificate needs --ca');
like($err, qr/hps-operator ca/, 'and points at hps-operator ca');
($rc) = run_op('', '--cred', $cred, 'Bad;Tool');
is($rc, 2, 'a tool name that is not a name is refused');
($rc) = run_op('', 'hps-pins');
is($rc, 2, '--cred is required');

done_testing;
