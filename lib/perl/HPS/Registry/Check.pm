package HPS::Registry::Check;
# Read-only scan of the JSON registry for values that were mangled into a
# number: a stored number where the catalogue declares the key as text, and any
# stored value in a float-exponent form (5.254000870E+13, 8.187E+910). A jq
# re-print of a number-looking value such as the MAC digits 5254000870e4 or a
# hex id 8187e907 produced them (see HPS::Registry::_encode_value).
# Nothing is written, locked or repaired.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP;
use HPS::Registry::Keys;

# Declared types whose values are text, never numbers.
my %TEXT = map { $_ => 1 } qw(string mac pin stamp iso8601 ip cidr);

my $NUMBER   = qr/\A-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\z/;
my $EXPONENT = qr/\A-?\d+(?:\.\d+)?(?:E[+-]?\d+|e[+-]\d+)\z/;

sub _slurp ($file) {
    open(my $fh, '<:raw', $file) or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# check_value($scope, $key, $raw_text): the reason this stored document is
# mangled, or undef when it is fine.
sub check_value ($scope, $key, $raw) {
    return undef unless defined $raw;
    (my $t = $raw) =~ s/\A\s+|\s+\z//g;
    if ($t =~ $NUMBER) {
        my $type = HPS::Registry::Keys::type_of($scope, $key);
        return 'a number where the key is text' if defined $type && $TEXT{$type};
        return 'a number in float-exponent form' if $t =~ /[eE]/;
        return undef;
    }
    my $data = eval { JSON::PP->new->utf8->allow_nonref->decode($t) };
    return undef if $@ || ref $data || !defined $data;
    return 'text in float-exponent form' if $data =~ $EXPONENT;
    return undef;
}

# scan_db($scope, $owner, $dir): one finding per mangled key in a registry
# directory, as { scope, owner, key, value, reason }.
sub scan_db ($scope, $owner, $dir) {
    my @found;
    opendir(my $dh, $dir) or return @found;
    for my $f (sort grep { /\.json\z/ && -f "$dir/$_" } readdir $dh) {
        (my $key = $f) =~ s/\.json\z//;
        my $raw = _slurp("$dir/$f");
        my $why = check_value($scope, $key, $raw);
        next unless defined $why;
        (my $v = $raw) =~ s/\A\s+|\s+\z//g;
        push @found, { scope => $scope, owner => $owner, key => $key, value => $v, reason => $why };
    }
    closedir $dh;
    return @found;
}

# scan($config_base, $system_registry): every system, cluster and host key under a
# config base laid out as <base>/clusters/<name>/{cluster.db,hosts/<mac>.db}.
sub scan ($base, $system_db = undef) {
    my @found;
    push @found, scan_db('system', '-', $system_db) if defined $system_db && -d $system_db;
    for my $c (sort glob("$base/clusters/*")) {
        next unless -d $c;
        (my $name = $c) =~ s{.*/}{};
        push @found, scan_db('cluster', $name, "$c/cluster.db") if -d "$c/cluster.db";
        for my $h (sort glob("$c/hosts/*.db")) {
            next unless -d $h;
            (my $mac = $h) =~ s{.*/}{};
            $mac =~ s/\.db\z//;
            push @found, scan_db('host', $mac, $h);
        }
    }
    return @found;
}

1;
