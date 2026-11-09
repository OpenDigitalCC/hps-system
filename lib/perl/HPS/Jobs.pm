package HPS::Jobs;
# The IPS privileged-action queue (ADR 0006). The web user never holds
# dispatcher or keysafe access; it submits a job - one JSON file in
# <cluster>/jobs/new/ - and the root runner (bin/hps-jobs) executes it from a
# fixed command table and writes <id>.result.json into done/ or failed/.
#
#   jobs/new/<epoch>-<pid>-<id>.json   {id, kind, args, requested_by, requested_at}
#   jobs/run/                          the one job being executed
#   jobs/{done,failed}/<id>.result.json  {id, kind, exit, stdout, stderr, finished_at, ...}
#
# This module has both sides: submit/wait/result for any caller, and the
# validation, command table, claim and finish steps the runner uses. The Bash
# helpers (lib/functions.d/jobs-functions.sh) keep the same file shapes and the
# same per-kind argument patterns.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP;
use POSIX qw(strftime);
use File::Path qw(make_path);
use Time::HiRes qw(sleep);
use Time::HiRes ();
use HPS::Registry;

our $OUTPUT_CAP = 64 * 1024;
my $ID_RE   = qr/^[0-9a-f]{8}\z/;
my $FILE_RE = qr/^(\d+)-(\d+)-([0-9a-f]{8})\.json\z/;
my $MAC_RE  = qr/^[0-9a-f]{12}\z/;

# kind => [ argument checker (returns an error string or undef), timeout seconds ]
my %KINDS = (
    'pairing-window-open'  => [ \&_args_seconds, 60 ],
    'pairing-window-close' => [ \&_args_none,    60 ],
    'pairing-list'         => [ \&_args_none,    60 ],
    'pairing-approve'      => [ \&_args_approve, 60 ],
    'storage-up'           => [ \&_args_mac,     900 ],
    'storage-down'         => [ \&_args_mac,     900 ],
    'storage-trim-check'   => [ \&_args_mac,     900 ],
    'storage-status'       => [ \&_args_mac,     900 ],
);

sub kinds { return sort keys %KINDS }

sub _args_none (@args) { return @args ? 'takes no arguments' : undef }

sub _args_seconds (@args) {
    return undef unless @args;
    return 'takes at most one argument (seconds)' if @args > 1;
    return 'seconds must be 1-600' unless $args[0] =~ /^[0-9]{1,3}\z/ && $args[0] >= 1 && $args[0] <= 600;
    return undef;
}

sub _args_approve (@args) {
    return 'needs <reqid> [--replace]' if @args < 1 || @args > 2;
    return 'reqid must be lowercase hex (1-64 characters)' unless $args[0] =~ /^[a-f0-9]{1,64}\z/;
    return 'second argument can only be --replace' if @args == 2 && $args[1] ne '--replace';
    return undef;
}

sub _args_mac (@args) {
    return 'needs exactly <mac> (12 lowercase hex digits)' unless @args == 1 && $args[0] =~ $MAC_RE;
    return undef;
}

# validate($kind, @args): undef when allowed, else the reason.
sub validate ($kind, @args) {
    return 'no kind' unless defined $kind && length $kind;
    my $k = $KINDS{$kind} or return "unknown kind '$kind'";
    for my $a (@args) { return 'arguments must be plain strings' if !defined $a || ref $a }
    my $why = $k->[0]->(@args);
    return defined $why ? "$kind: $why" : undef;
}

sub timeout_for ($kind) { return $KINDS{$kind} ? $KINDS{$kind}[1] : 60 }

# command($kind, \@args, %env): the argv for the kind (never a shell string).
# env: dispatcher (CLI name/path), storage (hps-storage path).
sub command ($kind, $args, %env) {
    my $ced = $env{dispatcher} // 'ctrl-exec-dispatcher';
    my @a   = @$args;
    return ($ced, 'pairing-mode', 'start', '--timeout', ($a[0] // 300)) if $kind eq 'pairing-window-open';
    return ($ced, 'pairing-mode', 'stop')                              if $kind eq 'pairing-window-close';
    return ($ced, 'list-requests')                                     if $kind eq 'pairing-list';
    return ($ced, 'approve', @a)                                       if $kind eq 'pairing-approve';
    my $st = $env{storage} // 'hps-storage';
    return ($st, $a[0], 'up', '--wait', 120)                           if $kind eq 'storage-up';
    return ($st, $a[0], 'down')                                        if $kind eq 'storage-down';
    return ($st, $a[0], 'trim-check')                                  if $kind eq 'storage-trim-check';
    return ($st, $a[0], 'status')                                      if $kind eq 'storage-status';
    die "no command for kind '$kind'\n";
}

sub _now_iso ($t = time) { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($t)) }

# new(dir => JOBS_DIR | registry => $reg | registry_opts => {...}, now => sub)
sub new ($class, %opt) {
    my $dir = $opt{dir} // $ENV{HPS_JOBS_DIR};
    unless (defined $dir && length $dir) {
        my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
        $dir = $reg->cluster_dir($reg->active_cluster) . '/jobs';
    }
    return bless { dir => $dir, now => $opt{now} // sub { time }, cap => $opt{cap} // $OUTPUT_CAP }, $class;
}

sub dir ($self) { return $self->{dir} }
sub sub_dir ($self, $name) { return "$self->{dir}/$name" }

# ensure_dirs: new/ run/ done/ failed/, setgid, group-writable, group hps when
# we can chgrp (the same ownership rule as lib/hps-state.sh).
sub ensure_dirs ($self) {
    my $gid = (getgrnam('hps'))[2];
    make_path($self->{dir}) unless -d $self->{dir};
    for my $d ($self->{dir}, map { $self->sub_dir($_) } qw(new run done failed)) {
        unless (-d $d) {
            mkdir $d or die "Cannot create $d: $!\n" unless -d $d;
        }
        chmod 02775, $d;
        chown -1, $gid, $d if defined $gid && $> == 0;
    }
    return 1;
}

sub _new_id () { return sprintf('%08x', int(rand(0xFFFFFFFF))) }

sub _write_atomic ($path, $text) {
    my ($d, $f) = $path =~ m{^(.*)/([^/]+)$};
    my $tmp = "$d/.tmp-$f.$$";
    open(my $fh, '>:raw', $tmp) or die "Cannot write $tmp: $!\n";
    print {$fh} $text;
    close($fh) or die "Cannot write $tmp: $!\n";
    chmod 0664, $tmp;
    rename $tmp, $path or die "Cannot rename $tmp: $!\n";
    return 1;
}

sub _slurp ($file) {
    open(my $fh, '<:raw', $file) or return;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# submit($kind, @args): validate, write the job file, return the id.
sub submit ($self, $kind, @args) {
    umask 002;
    my $why = validate($kind, @args);
    die "$why\n" if defined $why;
    my $new = $self->sub_dir('new');
    -d $new or die "Job queue not available: $new\n";
    my $id   = _new_id();
    my $now  = $self->{now}->();
    my $prog = $0;
    $prog =~ s{.*/}{};
    my $job = {
        id => $id, kind => $kind, args => [@args],
        requested_by => "$>/$prog", requested_at => _now_iso($now),
    };
    _write_atomic(sprintf('%s/%d-%d-%s.json', $new, $now, $$, $id), JSON::PP->new->canonical->encode($job) . "\n");
    return $id;
}

# result($id): the result hash, or undef while the job has not finished.
sub result ($self, $id) {
    die "Invalid job id\n" unless defined $id && $id =~ $ID_RE;
    for my $d (qw(done failed)) {
        my $f = $self->sub_dir($d) . "/$id.result.json";
        next unless -f $f;
        my $text = _slurp($f);
        next unless defined $text;
        my $r = eval { decode_json($text) } or next;
        return $r;
    }
    return undef;
}

# wait($id, $timeout): the result hash, or undef on timeout.
sub wait ($self, $id, $timeout = 30) {
    my $end = time + $timeout;
    while (1) {
        my $r = $self->result($id);
        return $r if $r;
        last if time >= $end;
        sleep 0.2;
    }
    return undef;
}

#--- runner side --------------------------------------------------------------

# pending: the file names in new/ that look like jobs, oldest first (epoch in
# the name, then the file's own modification time, then the name).
sub pending ($self) {
    my $new = $self->sub_dir('new');
    opendir(my $dh, $new) or return;
    my @f = grep { $_ =~ $FILE_RE && -f "$new/$_" && !-l "$new/$_" } readdir $dh;
    closedir $dh;
    my %key = map { my ($epoch) = $_ =~ $FILE_RE; ($_ => [ $epoch, (Time::HiRes::stat("$new/$_"))[9] // 0 ]) } @f;
    return sort { $key{$a}[0] <=> $key{$b}[0] || $key{$a}[1] <=> $key{$b}[1] || $a cmp $b } @f;
}

# claim($name): move new/<name> to run/ and parse it. Returns
# ($job, $problem): $job a hash with id/kind/args when well-formed; $problem
# the reason when not (id then still comes from the file name).
sub claim ($self, $name) {
    my ($epoch, $pid, $fid) = $name =~ $FILE_RE or return (undef, 'bad file name');
    my $from = $self->sub_dir('new') . "/$name";
    my $to   = $self->sub_dir('run') . "/$name";
    rename $from, $to or return (undef, "cannot claim $name: $!");
    my $text = _slurp($to);
    my $job  = defined $text ? eval { decode_json($text) } : undef;
    my $bad;
    if (ref $job ne 'HASH') { $bad = 'job file is not a JSON object' }
    elsif (!defined $job->{id} || $job->{id} ne $fid) { $bad = 'job id does not match the file name' }
    elsif (ref($job->{args} // []) ne 'ARRAY') { $bad = 'args is not a list' }
    else {
        $job->{args} //= [];
        $bad = validate($job->{kind}, @{ $job->{args} });
    }
    return ({ id => $fid, kind => (ref $job eq 'HASH' ? $job->{kind} : undef), file => $name }, $bad) if defined $bad;
    $job->{file} = $name;
    return ($job, undef);
}

sub _cap ($self, $text) {
    $text = '' unless defined $text;
    return ($text, JSON::PP::false) if length($text) <= $self->{cap};
    return (substr($text, 0, $self->{cap}), JSON::PP::true);
}

# finish($job, %r): write the result (exit, stdout, stderr, started, ...) to
# done/ (exit 0) or failed/, then remove the job file from run/.
sub finish ($self, $job, %r) {
    umask 002;
    my ($out, $otr) = $self->_cap($r{stdout});
    my ($err, $etr) = $self->_cap($r{stderr});
    my $now = $self->{now}->();
    my $res = {
        id => $job->{id}, kind => $job->{kind}, exit => $r{exit} + 0,
        stdout => $out, stderr => $err, finished_at => _now_iso($now),
    };
    $res->{stdout_truncated} = JSON::PP::true if $otr;
    $res->{stderr_truncated} = JSON::PP::true if $etr;
    $res->{duration} = $r{duration} + 0 if defined $r{duration};
    my $dest = $r{exit} == 0 ? 'done' : 'failed';
    _write_atomic($self->sub_dir($dest) . "/$job->{id}.result.json", JSON::PP->new->canonical->encode($res) . "\n");
    unlink $self->sub_dir('run') . "/$job->{file}" if defined $job->{file};
    return $dest;
}

# stale_run: the run/ entries left by a runner that died mid-job.
sub stale_run ($self) {
    my $run = $self->sub_dir('run');
    opendir(my $dh, $run) or return;
    my @f = sort grep { $_ =~ $FILE_RE } readdir $dh;
    closedir $dh;
    return @f;
}

# prune($days): drop results older than $days from done/ and failed/.
sub prune ($self, $days = 7) {
    my $n = 0;
    for my $d (qw(done failed)) {
        my $dir = $self->sub_dir($d);
        opendir(my $dh, $dir) or next;
        for my $f (grep { /\.result\.json\z/ } readdir $dh) {
            my $age = (time - (stat "$dir/$f")[9]) / 86400;
            $n += unlink "$dir/$f" if $age > $days;
        }
        closedir $dh;
    }
    return $n;
}

1;
