#!/usr/bin/env perl
# hps-issues open --summary takes the summary from standard input (IPS-34 item 17):
# `--summary -`; the token form and the default summary (the key) still work.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib/perl";
use IssuesCli;

IssuesCli::setup();
sub summary_of { my ($id) = @_; my (undef, $o) = IssuesCli::cli(undef, 'show', $id, '--json'); return decode_json($o)->{summary} }
my @k = ('open', '--kind', 'disk');

my ($rc, $out) = IssuesCli::cli("sdc: bad sectors (SMART 197/198), replace at 14:00\n", @k, '--key-field', 'host=n1', '--key-field', 'dev=sdc', '--summary', '-');
is($rc, 0, 'open --summary - reads the summary from stdin') or diag $out;
my ($id) = $out =~ /^opened (\S+)/m;
is(summary_of($id), 'sdc: bad sectors (SMART 197/198), replace at 14:00', 'the sentence is the summary');

($rc, $out) = IssuesCli::cli("ignored\n", @k, '--key-field', 'host=n2', '--key-field', 'dev=sdc', '--summary', 'leg', 'lost');
($id) = $out =~ /^opened (\S+)/m;
is(summary_of($id), 'leg lost', 'the token form works');

($rc, $out) = IssuesCli::cli("ignored\n", @k, '--key-field', 'host=n3', '--key-field', 'dev=sdc');
($id) = $out =~ /^opened (\S+)/m;
is(summary_of($id), 'disk:n3:sdc', 'no summary: the key, the input is not read');

($rc, $out) = IssuesCli::cli("\n", @k, '--key-field', 'host=n4', '--key-field', 'dev=sdc', '--summary', '-');
is($rc, 2, 'an empty input: usage');
($rc, $out) = IssuesCli::cli("api_key=ABCDEF0123456789abcdef\n", @k, '--key-field', 'host=n5', '--key-field', 'dev=sdc', '--summary', '-');
is($rc, 2, 'a secret-looking summary is refused');

done_testing;
