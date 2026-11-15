package BootFixture;
# Shared fixtures of the boot-reliability tests (t/270-t/277): a registry with a
# provisioning address, a fake /proc with or without dnsmasq, a /proc/net/udp
# text, a TFTP root, and a tiny HTTP server that answers the boot_manager probe.
use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IO::Socket::INET;
use HPS::Registry;

our $IPS = '10.100.1.2';

sub hexip { my ($d) = @_; return uc sprintf('%02X%02X%02X%02X', reverse split /\./, $d) }

# udp_text(@ports): a /proc/net/udp with a socket bound to each port on $IPS.
sub udp_text {
    my (@ports) = @_;
    my $t = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n";
    my $n = 0;
    $t .= sprintf("%5d: %s:%04X 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 %d 2 0000000000000000 0\n",
        $n++, hexip($IPS), $_, 1000 + $n) for @ports;
    return $t;
}

sub write_file { my ($f, $text) = @_; open(my $h, '>', $f) or die "$f: $!"; print {$h} $text; close $h; return $f }

# make(%o): {dir, reg, proc, udp, tftp}. dnsmasq => 0|1, ports => [67,69], tftp_files => 0|1.
sub make {
    my (%o) = @_;
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/clusters/lab/cluster.db", "$dir/clusters/lab/hosts", "$dir/proc/1", "$dir/tftp", "$dir/replies");
    my $reg = HPS::Registry->new(config_base => $dir, system_registry => "$dir/system.db");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->cluster_set('lab', 'network_dhcp_ip', $IPS) unless $o{no_ip};
    write_file("$dir/proc/1/comm", "init\n");
    if ($o{dnsmasq} // 1) { make_path("$dir/proc/42"); write_file("$dir/proc/42/comm", "dnsmasq\n") }
    write_file("$dir/udp", udp_text(@{ $o{ports} // [ 67, 69 ] }));
    if ($o{tftp_files} // 1) { write_file("$dir/tftp/$_", "binary") for qw(snponly.efi undionly.kpxe) }
    return { dir => $dir, reg => $reg, proc => "$dir/proc", udp => "$dir/udp", tftp => "$dir/tftp" };
}

# http_server($code, $body): forks a server on 127.0.0.1 that answers every request with that;
# returns (host:port, pid). The caller kills the pid.
sub http_server {
    my ($code, $body) = @_;
    my $l = IO::Socket::INET->new(Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1) or die "listen: $!";
    my $port = $l->sockport;
    my $pid = fork() // die;
    if (!$pid) {
        while (my $c = $l->accept) {
            local $/ = "\r\n\r\n";
            my $req = <$c>;
            print {$c} "HTTP/1.1 $code X\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
            close $c;
        }
        exit 0;
    }
    close $l;
    return ("127.0.0.1:$port", $pid);
}

1;
