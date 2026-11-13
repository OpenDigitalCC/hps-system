#!/usr/bin/env perl
# hps-issues note takes its text from standard input (IPS-34 item 17): `note <id> -`
# or no text; the token form still works.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib/perl";
use IssuesCli;

IssuesCli::setup();
my ($rc, $out) = IssuesCli::cli(undef, 'open', '--kind', 'disk', '--key-field', 'host=n1', '--key-field', 'dev=sdc');
my ($id) = $out =~ /^opened (\S+)/m;
sub notes { my (undef, $o) = IssuesCli::cli(undef, 'show', $id, '--json'); return map { $_->{detail} } grep { $_->{event} eq 'note' } @{ decode_json($o)->{trail} } }

($rc, $out) = IssuesCli::cli("peer rebooted at 12:03 (DL360 cycle); 5/5 beating\n", 'note', $id, '-');
is($rc, 0, 'note <id> - reads the text from stdin') or diag $out;
($rc, $out) = IssuesCli::cli("second note\nover two lines\n", 'note', $id);
is($rc, 0, 'note <id> with no text reads stdin') or diag $out;
($rc, $out) = IssuesCli::cli("ignored\n", 'note', $id, 'swapped', 'the', 'cable');
is($rc, 0, 'the token form works');
is_deeply([ notes() ], [ 'tester: peer rebooted at 12:03 (DL360 cycle); 5/5 beating', 'tester: second note over two lines', 'tester: swapped the cable' ],
    'the three notes, one line each');
($rc, $out) = IssuesCli::cli("\n", 'note', $id, '-');
is($rc, 2, 'an empty input is refused');
($rc, $out) = IssuesCli::cli(undef, 'note', $id);
is($rc, 2, 'no text and no input: usage');
($rc, $out) = IssuesCli::cli("password=Sup3rS3cret!x\n", 'note', $id, '-');
is($rc, 2, 'a secret-looking note is refused');
($rc, $out) = IssuesCli::cli(undef, 'note');
is($rc, 2, 'no id: usage');

done_testing;
