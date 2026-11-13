package IssuesCli;
# A temporary register and a runner for bin/hps-issues with standard input
# (t/122-124: the text through --input).
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use HPS::Registry;

my $base;
sub setup {
    $base = tempdir(CLEANUP => 1);
    my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
    make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $ENV{HPS_CONFIG_BASE}      = $base;
    $ENV{HPS_SYSTEM_REGISTRY}  = "$base/system.db";
    $ENV{HPS_ISSUES_NO_SYSLOG} = 1;
    $ENV{HPS_ISSUE_RULES}      = "$Bin/../lib/hps-issue-rules.conf";
    $ENV{USER}                 = 'tester';
    delete $ENV{SUDO_USER};
    return $base;
}

# cli($stdin, @args): (exit, output); $stdin undef: /dev/null.
sub cli {
    my ($stdin, @args) = @_;
    my $in = "$base/stdin.$$";
    open(my $fh, '>:raw', $in) or die $!;
    print {$fh} $stdin // '';
    close $fh;
    my @q = map { my $a = $_; $a =~ s/'/'\\''/g; "'$a'" } @args;
    my $out = qx($^X $Bin/../bin/hps-issues @q < '$in' 2>&1);
    return ($? >> 8, $out);
}
1;
