#!/usr/bin/env perl
# IPS-11 item 3: storage-up waits (bounded) for the node's agent to answer a
# ping before its first call.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $mac = $StorageFixture::MAC;

package PingCE {
    our @ISA = ('FakeCE');
    sub new { my ($c, %o) = @_; my $s = FakeCE::new($c); $s->{pings} = $o{pings}; $s->{order} = []; return $s }
    sub ping { my $s = shift; push @{ $s->{order} }, 'ping'; my $p = shift @{ $s->{pings} }; return $p // 0 }
    sub call { my ($s, %c) = @_; push @{ $s->{order} }, "call:$c{script}"; return FakeCE::call($s, %c) }
}

sub run_up {
    my (%o) = @_;
    my $f = StorageFixture::setup();
    $f->{ks}->get_or_create_key($mac, 'enc');
    my $ce = PingCE->new(pings => $o{pings});
    my $st = HPS::Storage->new(host => $mac, registry => $f->{reg}, keysafe => $f->{ks}, approval => $f->{ap},
        runner => $ce, logger => sub { push @{ $f->{log} }, "$_[0] $_[1]" }, now => sub { $StorageFixture::NOW },
        sleep => sub { $StorageFixture::NOW += $_[0] }, wait => $o{wait});
    $st->run('up');
    return ($f, $ce);
}

{
    my ($f, $ce) = run_up(wait => 120, pings => [ 0, 0, 1 ]);
    is_deeply([ @{ $ce->{order} }[ 0 .. 3 ] ], [ qw(ping ping ping call:storage-pool-import) ],
        'pings until the agent answers, then the first call');
    ok(!grep({ /did not answer a ping/ } @{ $f->{log} }), 'no timeout line when the agent answered');
}
{
    my ($f, $ce) = run_up(wait => 120, pings => []);
    my $pings = grep { $_ eq 'ping' } @{ $ce->{order} };
    ok($pings >= 2 && $pings <= 20, "a silent agent is pinged a bounded number of times ($pings)");
    is((grep { /^call:/ } @{ $ce->{order} })[0], 'call:storage-pool-import', 'the calls go ahead after the timeout');
    ok(scalar(grep({ /^info agent of \Q$mac\E did not answer a ping within 30s/ } @{ $f->{log} })), 'one info line on timeout');
}
{
    my ($f, $ce) = run_up(wait => 0, pings => [ 1 ]);
    ok(!grep({ $_ eq 'ping' } @{ $ce->{order} }), 'no ping without --wait');
}

done_testing;
