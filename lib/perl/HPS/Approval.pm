package HPS::Approval;
# Human approvals for destructive storage actions, signed with HMAC-SHA256
# under the per-cluster 'approval' secret from HPS::Keysafe.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP;
use HPS::Registry;
use HPS::Keysafe;

my %ACTIONS = map { $_ => 1 } qw(pool-create pool-destroy dataset-wipe zvol-destroy peer-gone mirror-create workload-destroy);
my $POOL_RE = qr/^[A-Za-z][A-Za-z0-9_-]*$/;
# zvol-destroy carries the dataset <pool>/enc/<name> in the 'pool' member; no '__'
# so the registry key (which maps '/' to '__') stays unambiguous.
my $DATASET_RE = qr{^(?!.*__)[A-Za-z][A-Za-z0-9_-]*/enc/[A-Za-z0-9_-]+$};
my $DISK_RE = qr{^(?:/dev/disk/by-id/)?[A-Za-z0-9][A-Za-z0-9_.:+-]*$};
# peer-gone and mirror-create list mirror legs, not disks: the two leg specs
# (local:<pool>/enc/vm/<name> or iscsi:<ip>:<iqn>) of the mirror named in pool.
my $LEG_RE  = qr{^(?:local|iscsi):[A-Za-z0-9][A-Za-z0-9_.:/+-]*$};
my %LEG_ACTIONS = map { $_ => 1 } qw(peer-gone mirror-create);
my $USER_RE = qr/^[A-Za-z0-9_][A-Za-z0-9_.@-]*$/;

sub _fail ($kind, $msg) { die HPS::Keysafe::Error->new($kind, $msg) }

sub actions { return sort keys %ACTIONS }

# new(registry => $reg, keysafe => $ks, now => sub { time })
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    my $ks  = $opt{keysafe}  // HPS::Keysafe->new(registry => $reg);
    return bless { registry => $reg, keysafe => $ks, now => $opt{now} // sub { time } }, $class;
}

sub now ($self) { return $self->{now}->() }

sub _pool_ok ($action, $pool) {
    return 0 unless defined $pool && !ref $pool;
    return $pool =~ ($action eq 'zvol-destroy' ? $DATASET_RE : $POOL_RE) ? 1 : 0;
}

sub registry_key ($action, $pool) { (my $p = $pool) =~ s{/}{__}g; return "approval_${action}_$p" }

#--- canonical form --------------------------------------------------------------

# Validate and normalise the fields; returns a fresh hash with disks sorted,
# wipe 0|1 and expires an integer. Does not touch the signature.
sub _normalise ($f) {
    _fail('usage', 'approval fields must be a hash') unless ref $f eq 'HASH';
    my $action = $f->{action};
    _fail('usage', 'action must be one of ' . join(', ', actions()))
        unless defined $action && $ACTIONS{$action};
    my $mac = eval { HPS::Registry::normalise_mac($f->{mac}) };
    _fail('usage', 'mac is not a valid MAC address') unless defined $mac;
    my $pool = $f->{pool};
    _fail('usage', $action eq 'zvol-destroy' ? "pool must be a dataset <pool>/enc/<name> (matching $DATASET_RE)" : "pool must match $POOL_RE")
        unless _pool_ok($action, $pool);
    my $disks = $f->{disks} // [];
    _fail('usage', 'disks must be a list') unless ref $disks eq 'ARRAY';
    my %seen;
    my $legs = $LEG_ACTIONS{$action};
    _fail('usage', "$action needs exactly two legs") if $legs && @$disks != 2;
    for my $d (@$disks) {
        if ($legs) {
            _fail('usage', 'legs must be local:... or iscsi:... specs') unless defined $d && !ref $d && $d =~ $LEG_RE;
        } else {
            _fail('usage', 'disk ids must be by-id names') unless defined $d && !ref $d && $d =~ $DISK_RE;
        }
        _fail('usage', "disk listed twice: $d") if $seen{$d}++;
    }
    _fail('usage', "$action needs at least one disk") if $action eq 'pool-create' && !@$disks;
    _fail('usage', 'zvol-destroy takes no disks') if $action eq 'zvol-destroy' && @$disks;
    _fail('usage', 'workload-destroy takes no disks') if $action eq 'workload-destroy' && @$disks;
    my $wipe = $f->{wipe} // 0;
    _fail('usage', 'wipe must be 0 or 1') unless !ref $wipe && $wipe =~ /^[01]$/;
    _fail('usage', 'zvol-destroy takes wipe 0') if $action eq 'zvol-destroy' && $wipe != 0;
    _fail('usage', 'workload-destroy takes wipe 0') if $action eq 'workload-destroy' && $wipe != 0;
    my $exp = $f->{expires};
    _fail('usage', 'expires must be an epoch') unless defined $exp && !ref $exp && $exp =~ /^[0-9]{1,12}$/;
    my $by = $f->{issued_by};
    _fail('usage', 'issued_by is missing or has odd characters') unless defined $by && !ref $by && $by =~ $USER_RE;
    return {
        action => "$action", mac => "$mac", pool => "$pool",
        disks => [ sort map {"$_"} @$disks ],
        wipe => $wipe + 0, expires => $exp + 0, issued_by => "$by",
    };
}

# The exact bytes that are signed. See the POD at the end of this file.
sub canonical ($fields) {
    my $n = _normalise($fields);
    return JSON::PP->new->utf8->canonical->encode($n);
}

sub _sign ($canonical, $secret) { return hmac_sha256_hex($canonical, $secret) }

# Canonical bytes of the signed document: the fields plus "hmac" (sorted in).
sub _document ($fields, $hmac) {
    my $n = _normalise($fields);
    $n->{hmac} = "$hmac";
    return JSON::PP->new->utf8->canonical->encode($n);
}

# Constant-time string comparison: no early exit on the first difference.
sub ct_equal ($x, $y) {
    return 0 unless defined $x && defined $y;
    return 0 unless length $x == length $y;
    my $diff = 0;
    $diff |= ord(substr($x, $_, 1)) ^ ord(substr($y, $_, 1)) for 0 .. length($x) - 1;
    return $diff == 0 ? 1 : 0;
}

# The bytes a verifier signs/checks: the stored document with the
# "hmac":"<64 hex>", member removed.
sub signed_payload ($json) {
    (my $p = $json) =~ s/"hmac":"[0-9a-f]{64}",//;
    return $p;
}

#--- issue / verify / revoke --------------------------------------------------------

# issue(\%fields): stores the signed document under the host as
# approval_<action>_<pool> (replacing any earlier one, expired or not) and
# returns its JSON text.
sub issue ($self, $fields) {
    my %f = %{ $fields // {} };
    $f{expires}   //= $self->now + 3600;
    $f{issued_by} //= $ENV{SUDO_USER} // $ENV{USER} // 'operator';
    $f{wipe}      //= 0;
    my $canon = canonical(\%f);   # validates
    _fail('usage', 'expires is not in the future') unless $f{expires} > $self->now;
    my $reg = $self->{registry};
    _fail('notfound', "No such host: $f{mac}") unless $reg->host_exists($f{mac});
    my $doc = _document(\%f, _sign($canon, $self->{keysafe}->cluster_secret('approval')));
    $reg->host_set($f{mac}, registry_key($f{action}, $f{pool}), $doc);
    return $doc;
}

# verify($json, $secret, now => epoch): the decoded fields (with hmac), or
# dies with kind malformed, tampered or expired. The text must be exactly the
# canonical form, so the Bash verifier and this one sign the same bytes.
sub verify ($class_or_self, $json, $secret, %opt) {
    my $now = $opt{now} // (ref $class_or_self ? $class_or_self->now : time);
    my $data = eval { JSON::PP->new->utf8->decode($json // '') };
    _fail('malformed', 'approval is not valid JSON') unless ref $data eq 'HASH';
    my $hmac = delete $data->{hmac};
    _fail('malformed', 'approval has no hmac') unless defined $hmac && !ref $hmac && $hmac =~ /^[0-9a-f]{64}$/;
    my $canon = eval { canonical($data) };
    _fail('malformed', 'approval fields are invalid') unless defined $canon;
    _fail('tampered', 'approval is not in canonical form') unless $json eq _document($data, $hmac);
    _fail('tampered', 'approval signature does not match')
        unless ct_equal(_sign($canon, $secret), $hmac);
    _fail('expired', 'approval has expired') if $data->{expires} <= $now;
    $data->{hmac} = $hmac;
    return $data;
}

# The stored approval JSON for a host/action/pool, or undef.
sub get ($self, $mac, $action, $pool) {
    my $reg = $self->{registry};
    my $key = registry_key($action, $pool);
    return undef unless $reg->host_exists($mac, $key);
    my $data = $reg->host_get_json($mac, $key);
    return undef unless ref $data eq 'HASH';
    my $hmac = $data->{hmac} // '';
    return _document($data, $hmac);
}

# [{key, action, pool, disks, wipe, expires, issued_by, mac, status}] for a
# host; status is 'valid', 'expired' or 'invalid' (signature check against the
# cluster secret).
sub list ($self, $mac) {
    my $reg = $self->{registry};
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($mac);
    my $secret = $self->{keysafe}->cluster_secret('approval');
    my @out;
    for my $key (grep { /^approval_/ } $reg->host_list($mac)) {
        my $data = $reg->host_get_json($mac, $key);
        next unless ref $data eq 'HASH';
        my $json = eval { _document($data, $data->{hmac} // '') };
        my $status = 'invalid';
        if (defined $json) {
            my $ok = eval { $self->verify($json, $secret); 1 };
            $status = $ok ? 'valid' : (ref $@ && $@->kind eq 'expired' ? 'expired' : 'invalid');
        }
        push @out, { key => $key, status => $status, %$data };
    }
    return @out;
}

# Returns 1 if an approval was removed, 0 if there was none.
sub revoke ($self, $mac, $action, $pool) {
    _fail('usage', 'unknown action') unless defined $action && $ACTIONS{$action};
    _fail('usage', 'invalid pool') unless _pool_ok($action, $pool);
    my $reg = $self->{registry};
    my $key = registry_key($action, $pool);
    return 0 unless $reg->host_exists($mac) && $reg->host_exists($mac, $key);
    $reg->host_unset($mac, $key);
    return 1;
}

1;

__END__

=head1 NAME

HPS::Approval - HMAC-signed human approvals for storage actions

=head1 CANONICAL FORM

An approval is a JSON object with exactly these members: C<action>
(C<pool-create>, C<pool-destroy>, C<dataset-wipe>, C<zvol-destroy>,
C<peer-gone>, C<mirror-create> or C<workload-destroy>), C<disks> (array of by-id names or
C</dev/disk/by-id/...> paths, sorted bytewise, unique; for C<peer-gone> and
C<mirror-create> exactly the two leg specs of the mirror, C<local:...> or
C<iscsi:...>, with the mirror name in C<pool>),
C<expires> (epoch seconds, JSON integer), C<issued_by> (string), C<mac> (12
lower-case hex digits, no separators), C<pool> (string), C<wipe> (JSON
integer 0 or 1).
For C<zvol-destroy> the C<pool> member carries the dataset name
C<E<lt>poolE<gt>/enc/E<lt>nameE<gt>> (no C<__>), C<disks> is empty and C<wipe> is 0; the form and
the HMAC are otherwise identical. The registry key maps C</> to C<__>
(C<approval_zvol-destroy_lab__enc__t0>).
For C<workload-destroy> the C<pool> member carries the workload name
(C<^[a-z][a-z0-9-]{0,31}$>), C<disks> is empty and C<wipe> is 0; the host is the
compute host of the workload's first VM.

The signed bytes are that object encoded as UTF-8 JSON with the members
sorted bytewise by name, no whitespace anywhere, strings escaped as
JSON::PP does (C</> is not escaped), numbers as bare integers:

 {"action":"pool-create","disks":["a","b"],"expires":1800003600,"issued_by":"operator","mac":"525400000001","pool":"lab","wipe":1}

The signature is C<hmac> = lower-case hex HMAC-SHA256 of those bytes keyed
with the 32 raw bytes of the cluster C<approval> secret
(C<keysafe/approval.hmac>). The stored and transmitted document is the same
object with the member C<hmac> added; it sorts between C<expires> and
C<issued_by>:

 {"action":...,"disks":[...],"expires":1800003600,"hmac":"<64 hex>","issued_by":...}

A verifier recovers the signed bytes by deleting the exact text
C<"hmac":"<64 hex>",> from the document (C<signed_payload>). C<verify>
refuses any document that is not byte-for-byte this canonical form.

Bash check (the secret as hex, e.g. delivered over ctrl-exec input):

 printf '%s' "$payload" | openssl dgst -sha256 -mac HMAC -macopt hexkey:"$secret_hex" -r

and compare the first field with C<hmac> in constant time or at least
exactly; then check C<expires> against the node clock and the C<mac>,
C<pool>, C<disks> and C<wipe> against the request. The fixtures
F<t/fixtures/approval-canonical.json> (payload), C<.hmac> (expected hex) and
C<.secret.hex> (a public test secret) pin the form.

=cut
