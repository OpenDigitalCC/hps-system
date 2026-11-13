#!/usr/bin/env perl
# hps-issues resolve takes --by from standard input (IPS-34 item 17): `--by -`, or
# no text at all; a sentence the ips-admin token gate cannot carry ("/", quotes,
# spaces). The token form still works; a secret-looking text is refused.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib/perl";
use IssuesCli;
use HPS::Issues;

IssuesCli::setup();
sub open_one { my ($h) = @_; my ($rc, $o) = IssuesCli::cli(undef, 'open', '--kind', 'om3-hb', '--key-field', "host=$h", '--key-field', 'peer=p1'); my ($id) = $o =~ /^opened (\S+)/m; return $id }
sub show { my ($id) = @_; my (undef, $o) = IssuesCli::cli(undef, 'show', $id, '--json'); return decode_json($o) }

my $sentence = "operator: om3 5/5 beating (osvc_hb OK), after the 12:20 cycle - 'checked' by hand";

my $id = open_one('a1');
my ($rc, $out) = IssuesCli::cli("$sentence\n", 'resolve', $id, '--by', '-');
is($rc, 0, 'resolve --by - reads the text from stdin') or diag $out;
my $r = show($id);
is($r->{state}, 'resolved', 'resolved');
is($r->{resolution}{result}, $sentence, 'the whole sentence is the result');
is($r->{resolution}{action}, $sentence, 'and the action');
is($r->{resolution}{by}, 'operator tester', 'by operator <who>');
is($r->{trail}[-1]{detail}, "by tester: $sentence", 'the trail has it');

$id = open_one('a2');
($rc, $out) = IssuesCli::cli("om3 beating\nchecked twice\n\n", 'resolve', $id);
is($rc, 0, 'resolve with no text reads stdin') or diag $out;
is(show($id)->{resolution}{result}, 'om3 beating checked twice', 'newlines become spaces, the ends are trimmed');

$id = open_one('a3');
($rc, $out) = IssuesCli::cli("fixed via keyed resolve\n", 'resolve', '--kind', 'om3-hb', '--key-field', 'host=a3', '--key-field', 'peer=p1', '--by', '-');
is($rc, 0, 'resolve by key with --by - too') or diag $out;
is(show($id)->{resolution}{result}, 'fixed via keyed resolve', 'the text');

$id = open_one('a4');
($rc, $out) = IssuesCli::cli("ignored\n", 'resolve', $id, '--by', 'replaced', 'the', 'cable');
is($rc, 0, 'the token form works as before');
is(show($id)->{resolution}{result}, 'replaced the cable', 'words are joined');

$id = open_one('a5');
($rc, $out) = IssuesCli::cli("\n", 'resolve', $id, '--by', '-');
is($rc, 2, 'an empty input: usage error');
like($out, qr/no text on standard input/, 'saying so');
($rc, $out) = IssuesCli::cli(undef, 'resolve', $id, '--by');
is($rc, 2, '--by with nothing and no input: usage');
($rc, $out) = IssuesCli::cli('x' x 5000, 'resolve', $id, '--by', '-');
is($rc, 2, 'more than 4096 bytes: usage');
like($out, qr/more than 4096 bytes/, 'saying so');
($rc, $out) = IssuesCli::cli("the password is hunter2 token=abcdef0123456789abcdef\n", 'resolve', $id, '--by', '-');
is($rc, 2, 'a secret-looking text from the input is refused too');
like($out, qr/secret/, 'naming the rule');
is(show($id)->{state}, 'open', 'and the issue stays open');
($rc, $out) = IssuesCli::cli("a sentence\n", 'resolve', $id, '--by', '-', 'extra');
is($rc, 0, '"-" followed by words is the token form (a literal "- extra")');

done_testing;
