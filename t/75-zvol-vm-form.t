#!/usr/bin/env perl
# CS-3.6: zvols under <pool>/enc/vm/<name> through HPS::Storage and HPS::Approval.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $f   = StorageFixture::setup();
my $mac = $StorageFixture::MAC;
my $VDS = 'lab/enc/vm/t0-app-root';
sub err_of { my ($c) = @_; eval { $c->(); 1 } and return undef; return $@ }

my $st = $f->{mk}->();
$st->run('zvol-create', dataset => $VDS, size => '20G');
is_deeply(($f->{ce}->calls)[0]{args}, [ $VDS, '20G' ], 'zvol-create accepts <pool>/enc/vm/<name>');
$st->run('zvol-create', dataset => 'lab/enc/t0', size => '1G');
is_deeply(($f->{ce}->calls)[1]{args}, [ 'lab/enc/t0', '1G' ], 'the plain form still works');
for my $bad ('lab/enc/vm/', 'lab/enc/vm/a/b', 'lab/vm/t0', 'lab/enc/vm//x', 'lab/enc/vm/t 0') {
    is(err_of(sub { $st->run('zvol-create', dataset => $bad, size => '1G') })->kind, 'usage', "refused: $bad");
}
is(err_of(sub { $st->run('zvol-create', dataset => 'other/enc/vm/t0', size => '1G') })->kind, 'refused', 'pool part of the vm form is checked');

# approvals for the vm form
my $doc = StorageFixture::approve($f, 'zvol-destroy', pool => $VDS);
is($f->{ap}->get($mac, 'zvol-destroy', $VDS), $doc, 'stored under a slash-free key');
ok($f->{reg}->host_exists($mac, 'approval_zvol-destroy_lab__enc__vm__t0-app-root'), 'key maps / to __');
$f->{ce}{calls} = [];
$st->run('zvol-destroy', dataset => $VDS);
my ($c) = $f->{ce}->calls;
is($c->{script}, 'storage-zvol-destroy', 'zvol-destroy runs for the vm form');
is_deeply($c->{args}, [ $VDS, '--approval-file', '-' ], 'arguments');
like($c->{input}, qr/"pool":"\Q$VDS\E"/, 'the approval carries the vm dataset');
is(err_of(sub { StorageFixture::approve($f, 'zvol-destroy', pool => 'lab/enc/vm/a__b') })->kind, 'usage', 'no __ in a dataset');
is(err_of(sub { StorageFixture::approve($f, 'zvol-destroy', pool => 'lab/enc/vm/a/b') })->kind, 'usage', 'no deeper nesting');

done_testing;
