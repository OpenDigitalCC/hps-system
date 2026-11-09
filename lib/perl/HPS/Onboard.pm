package HPS::Onboard;
# Onboarding of held hosts: list, show the stored audit, assign a role.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HPS::Registry;

package HPS::Onboard::Error {
    # kind: usage (2), refused (3), notfound (4), failed (1)
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

my %TYPES = map { $_ => 1 } qw(SCH TCH DRH);

sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    return bless { registry => $reg }, $class;
}

sub registry ($self) { return $self->{registry} }

sub _fail ($kind, $msg) { die HPS::Onboard::Error->new($kind, $msg) }

# Hosts whose STATE is HELD, as [{mac, audit_at, ...}], sorted by MAC.
sub list_held ($self) {
    my $reg = $self->{registry};
    my @held;
    for my $mac ($reg->host_list_all) {
        my $state = $reg->host_get($mac, 'STATE');
        next unless defined $state && $state eq 'HELD';
        my $at = $reg->host_get($mac, 'audit_at');
        push @held, { mac => $mac, state => $state, audit_at => $at, has_audit => $reg->host_exists($mac, 'audit') ? 1 : 0 };
    }
    return @held;
}

# {mac, identity => {key => raw value, audit excluded}, audit => decoded|undef, audit_at}
sub show ($self, $mac) {
    my $reg = $self->{registry};
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', "Invalid MAC address: $mac") unless defined $m;
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($m);
    my %identity;
    for my $key ($reg->host_list($m)) {
        next if $key eq 'audit';
        $identity{$key} = $reg->host_get($m, $key);
    }
    return {
        mac      => $m,
        state    => $identity{STATE},
        identity => \%identity,
        audit    => $reg->host_get_json($m, 'audit'),
        audit_at => $identity{audit_at},
    };
}

sub _validate_args ($self, $a) {
    my $type = $a->{type};
    _fail('usage', 'type is required') unless defined $type && length $type;
    my @t = split /,/, $type, -1;
    my %seen;
    for my $t (@t) {
        _fail('usage', "type '$type' must be a comma list of SCH, TCH, DRH")
            unless $TYPES{$t} && !$seen{$t}++;
    }
    my $profile = $a->{profile};
    _fail('usage', "profile '" . ($profile // '') . "' must match ^[A-Z][A-Z0-9_]*\$")
        unless defined $profile && $profile =~ /^[A-Z][A-Z0-9_]*$/;
    my $os = $a->{os};
    _fail('usage', 'os is required (arch:name:version)')
        unless defined $os && $os =~ /^[^:\s\/]+:[^:\s\/]+:[^:\s\/]+$/;
    my $pin = $a->{pin};
    _fail('usage', "pin '" . ($pin // '') . "' must match ^[a-z0-9][a-z0-9.-]+\$")
        unless defined $pin && $pin =~ /^[a-z0-9][a-z0-9.-]+$/;
    return 1;
}

sub assign ($self, $mac, $a) {
    my $reg = $self->{registry};
    $self->_validate_args($a);
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', "Invalid MAC address: $mac") unless defined $m;
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($m);
    my $state = $reg->host_get($m, 'STATE');
    $state = '(none)' unless defined $state;
    _fail('refused', "Host $m is in state $state; only HELD hosts can be assigned")
        unless $state eq 'HELD';
    _fail('notfound', "OS $a->{os} is not in the OS registry") unless $reg->os_exists($a->{os});

    $reg->host_set($m, 'TYPE',         $a->{type});
    $reg->host_set($m, 'HOST_PROFILE', $a->{profile});
    $reg->host_set($m, 'PROFILE',      $a->{profile});
    $reg->host_set($m, 'os_id',        $a->{os});
    $reg->host_set($m, 'system_pin',   $a->{pin});
    $reg->host_set($m, 'storage_note', $a->{storage_note})
        if defined $a->{storage_note} && length $a->{storage_note};
    $reg->host_set($m, 'assigned_at',  $reg->timestamp);

    # IP/hostname allocation stays in Bash (host_network_configure). The hook
    # is a program path run as: $HPS_ONBOARD_NETCONF_CMD <mac>. It runs before
    # STATE is written because host_network_configure sets STATE=CONFIGURED.
    my $cmd = $ENV{HPS_ONBOARD_NETCONF_CMD};
    if (defined $cmd && length $cmd) {
        system($cmd, $m) == 0
            or _fail('failed', "Network configuration hook failed for $m (exit " . ($? >> 8) . ')');
    }
    $reg->host_set($m, 'STATE', 'NETWORK_BOOT');
    return { mac => $m, state => 'NETWORK_BOOT' };
}

1;
