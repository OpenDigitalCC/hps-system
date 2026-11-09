#!/usr/bin/env perl
# CS-2.0d: HPS::Registry->new sets umask 002, so new state is group-writable
# (0664 files) and every directory it creates is setgid group-writable (2775).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;

my $old = umask 077;
my $base = tempdir(CLEANUP => 1);
chmod 0755, $base;
my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
is(sprintf('%04o', umask), '0002', 'new() leaves umask 0002');

$reg->system_set('last_boot_at', 'x');
sub mode { my ($path) = @_; return sprintf('%o', (stat $path)[2] & 07777) }

is(mode("$base/system.db"),                       '2775', 'registry directory is setgid group-writable');
is(mode("$base/system.db/.lock"),                 '2775', 'lock directory is setgid group-writable');
is(mode("$base/system.db/last_boot_at.json"),     '664',  'registry file is group-writable');

$reg->system_set('k2', 'v');
is(mode("$base/system.db"), '2775', 'unchanged by a second write');

umask $old;
done_testing;
