package StorageFixture;
# Shared setup for the HPS::Storage tests: a temp registry with cluster 'lab'
# and host sch-001 (TYPE SCH), a keysafe, approvals at a fixed clock, and a
# fake ctrl-exec runner that records every call and its input.
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Keysafe;
use HPS::Approval;
use HPS::Storage;

our $MAC = '525400000001';
our $NOW = 1_800_000_000;

package FakeCE {
    sub new { my ($c, %o) = @_; return bless { calls => [], rc => $o{rc} || {} }, $c }
    sub call {
        my ($self, %c) = @_;
        push @{ $self->{calls} }, { %c };
        my $rc = $self->{rc}{ $c{script} } // 0;
        $rc = shift @$rc if ref $rc eq 'ARRAY';
        return { rc => $rc, stdout => "out of $c{script}\n", stderr => $rc ? "boom from $c{script}\n" : '' };
    }
    sub calls { return @{ $_[0]{calls} } }
    sub scripts { return map { $_->{script} } @{ $_[0]{calls} } }
}

sub setup {
    my %o = @_;
    my $base = tempdir(CLEANUP => 1);
    my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
    make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->host_set($MAC, 'STATE', 'NETWORK_BOOT');
    $reg->host_set($MAC, 'TYPE', 'SCH');
    $reg->host_set($MAC, 'HOSTNAME', 'sch-001');
    my $ks = HPS::Keysafe->new(registry => $reg);
    my $ap = HPS::Approval->new(registry => $reg, keysafe => $ks, now => sub { $NOW });
    my $ce = FakeCE->new(%{ $o{ce} || {} });
    my @log;
    my $mk = sub {
        my %x = @_;
        return HPS::Storage->new(host => $MAC, registry => $reg, keysafe => $ks, approval => $ap,
            runner => $ce, logger => sub { push @log, "$_[0] $_[1]" }, now => sub { $NOW },
            sleep => sub { $NOW += $_[0] }, %x);
    };
    return { base => $base, reg => $reg, ks => $ks, ap => $ap, ce => $ce, log => \@log, mk => $mk };
}

sub approve {
    my ($f, $action, %x) = @_;
    return $f->{ap}->issue({ action => $action, mac => $MAC, pool => 'lab',
        disks => $action eq 'pool-create' ? [ 'ata-SSD1', 'ata-SSD2' ] : [], issued_by => 'tester', %x });
}

1;
