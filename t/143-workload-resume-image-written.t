#!/usr/bin/env perl
# #20: create --resume --image-written: the operator asserts the image is on the
# root disk; the resume skips vm-image-write and records it as done.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use WorkloadLegs;

# vm-image-write ran (the data is on the disk) but its step was never recorded:
# a create cut off there, then a resume that vm-image-write refuses (3).
my $f = WorkloadLegs::setup();
my $wl = $f->{wl}->();
$f->{ce}{rc}{'vm-image-write'} = 3;
my $e = eval { $wl->run('create', 't0'); 1 } ? undef : $@;
ok($e, 'create fails at vm-image-write');
is(WorkloadLegs::rec($f)->{state}, 'creating', 'record is creating');
ok(!(grep { $_ eq 'write:t0-vm' } @{ WorkloadLegs::rec($f)->{done} }), 'the write is not recorded');

$e = eval { $wl->run('create', 't0', resume => 1); 1 } ? undef : $@;
ok($e, 'a plain resume tries vm-image-write again and is refused');

$e = eval { $wl->run('create', 't0', image_written => 1); 1 } ? undef : $@;
like(ref $e ? $e->message : '', qr/--image-written is only for create --resume|already exists/, '--image-written without --resume is refused');

my $p = $wl->run('create', 't0', resume => 1, image_written => 1, dry_run => 1);
like(join("\n", @{ $p->{notes} }), qr/vm-image-write of t0-vm skipped: --image-written asserts/, 'dry run says what it skips');

$f->{ce}{calls} = [];
my $r = $wl->run('create', 't0', resume => 1, image_written => 1);
ok($r->{ok}, 'resume with --image-written completes');
ok(!(grep { $_->{script} eq 'vm-image-write' } $f->{ce}->calls), 'vm-image-write is not called');
like(join("\n", @{ $r->{notes} }), qr/vm-image-write of t0-vm skipped.*image_written_by: operator/, 'the message says what was skipped');
ok((grep { $_->{script} eq 'vm-define' } $f->{ce}->calls), 'the later steps ran (vm-define)');
is(WorkloadLegs::rec($f)->{vms}{'t0-vm'}{image_written_by}, 'operator', 'recorded: image_written_by operator');

# nothing pending: refused
{
    my $g = WorkloadLegs::setup();
    my $w = $g->{wl}->();
    $g->{ce}{rc}{'vm-define'} = 1;
    eval { $w->run('create', 't0'); 1 };
    $g->{ce}{rc} = {};
    my $x = eval { $w->run('create', 't0', resume => 1, image_written => 1); 1 } ? undef : $@;
    like(ref $x ? $x->message : '', qr/no image write is pending/, 'refused when the image write is already recorded');
}

# a create never recorded the image step before a later one: done order
{
    my $g = WorkloadLegs::setup();
    my $w = $g->{wl}->();
    $g->{ce}{rc}{'vm-define'} = 1;
    eval { $w->run('create', 't0'); 1 };
    ok((grep { $_ eq 'write:t0-vm' } @{ WorkloadLegs::rec($g)->{done} }), 'the image step is on record when a later step fails');
}

done_testing;
