#!/usr/bin/env bats
#
# IPS-42 row 2: lab/egress-allow turns the egress hosts that workload
# definitions declare into per-address allowances for the lab egress proxy, and
# accepts only the hosts the owner lists per flavour in lab/egress-approved.
# lab/egress-proxy.pl reads such a file at every connection. These files live
# outside this repository (the lab directory of the hps project), so the tests
# skip where it is absent. No network: the proxy is tried on 127.0.0.1 and an
# allowed host is told apart from a refused one by 502 (upstream) against 403.

bats_require_minimum_version 1.5.0

setup() {
  LAB="${HPS_LAB_DIR:-/srv/projects/hps/lab}"
  [ -x "$LAB/egress-allow" ] || skip "no $LAB/egress-allow"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ips42-02.XXXXXX")"
  cat > "$T/approved" <<'A'
# comment
podman-host production.cloudfront.docker.com
podman-host registry.example.org
odoo-test production.cloudfront.docker.com
A
  cat > "$T/in.json" <<'J'
{"egress":[
 {"name":"p-a","project":"p","flavour":"podman-host","state":"running","egress":["production.cloudfront.docker.com"],"addresses":["10.100.1.101"]},
 {"name":"p-b","project":"q","flavour":"podman-host","state":"running","egress":["production.cloudfront.docker.com","registry.example.org"],"addresses":["10.100.1.102","10.100.1.103"]},
 {"name":"p-f","project":"p","flavour":"odoo-test","state":"running","egress":["production.cloudfront.docker.com"],"addresses":["10.100.1.106"]},
 {"name":"p-c","project":"p","flavour":"video-edit","state":"running","egress":["production.cloudfront.docker.com"],"addresses":["10.100.1.104"]},
 {"name":"p-d","project":"p","state":"running","egress":["evil.example.org"],"addresses":["10.100.1.105"]},
 {"name":"p-e","project":"p","flavour":"podman-host","state":"created","egress":["production.cloudfront.docker.com"],"addresses":[]}
]}
J
}

teardown() { rm -rf "$T"; }

@test "approved hosts become IP=hosts lines, refused ones are named with the file and exit 3" {
  run --separate-stderr "$LAB/egress-allow" --approved "$T/approved" --input "$T/in.json"
  [ "$status" -eq 3 ]
  [ "$output" = "$(printf '10.100.1.101=production.cloudfront.docker.com\n10.100.1.102=production.cloudfront.docker.com,registry.example.org\n10.100.1.103=production.cloudfront.docker.com,registry.example.org\n10.100.1.106=production.cloudfront.docker.com')" ]
  [[ "$stderr" == *"workload p-c (flavour video-edit) declares production.cloudfront.docker.com"*"$T/approved"* ]]
  [[ "$stderr" == *"workload p-d (flavour none) declares evil.example.org"*"$T/approved"* ]]
  [[ "$stderr" == *"workload p-e has no address yet"* ]]
}

@test "a definition cannot grant itself a host: nothing for video-edit or a flavourless workload" {
  run --separate-stderr "$LAB/egress-allow" --approved "$T/approved" --input "$T/in.json"
  [[ "$output" != *10.100.1.104* ]]
  [[ "$output" != *10.100.1.105* ]]
  [[ "$output" != *evil.example.org* ]]
}

@test "--project keeps one project's workloads" {
  run --separate-stderr "$LAB/egress-allow" --approved "$T/approved" --input "$T/in.json" --project q
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '10.100.1.102=production.cloudfront.docker.com,registry.example.org\n10.100.1.103=production.cloudfront.docker.com,registry.example.org')" ]
}

@test "--out writes the file through a rename and prints nothing" {
  run --separate-stderr "$LAB/egress-allow" --approved "$T/approved" --input "$T/in.json" --project q --out "$T/allow"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(wc -l < "$T/allow")" -eq 2 ]
  run ls "$T"
  [[ "$output" != *.tmp.* ]]
}

@test "the input comes from lab-op hps-workload egress --json when --input is not given" {
  cat > "$T/fake-lab-op" <<EOS
#!/bin/bash
[ "\$1 \$2 \$3" = "hps-workload egress --json" ] || exit 9
cat "$T/in.json"
EOS
  chmod +x "$T/fake-lab-op"
  EGRESS_LAB_OP="$T/fake-lab-op" run --separate-stderr "$LAB/egress-allow" --approved "$T/approved" --project q
  [ "$status" -eq 0 ]
  [[ "$output" == 10.100.1.102=* ]]
}

@test "a malformed approved list is exit 2 naming the file and line" {
  printf 'podman-host\n' > "$T/bad"
  run --separate-stderr "$LAB/egress-allow" --approved "$T/bad" --input "$T/in.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"$T/bad line 1"* ]]
}

@test "input that is not the egress JSON is exit 2" {
  echo '{"workloads":[]}' > "$T/x.json"
  run --separate-stderr "$LAB/egress-allow" --approved "$T/approved" --input "$T/x.json"
  [ "$status" -eq 2 ]
}

@test "the shipped approved list names the one host, for the docker and podman flavours only" {
  run grep -v '^#' "$LAB/egress-approved"
  [ "$output" = "$(printf 'podman-host production.cloudfront.docker.com\nodoo-test production.cloudfront.docker.com')" ]
}

@test "the proxy no longer carries the CDN host in its default list" {
  run grep -c "^my \$allow .*production.cloudfront.docker.com" "$LAB/egress-proxy.pl"
  [ "$output" = "0" ]
}

@test "the proxy reads --allow-for-file at every connection: refused, then allowed after the file changes" {
  command -v perl >/dev/null
  port=$((20000 + RANDOM % 20000))
  : > "$T/af"
  perl "$LAB/egress-proxy.pl" --listen "127.0.0.1:$port" --allow-for-file "$T/af" > "$T/proxy.log" 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q listening "$T/proxy.log" && break; sleep 0.3; done
  cat > "$T/connect.pl" <<'P'
use IO::Socket::INET;
my ($port, $host) = @ARGV;
my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 5) or die "connect: $!";
print $s "CONNECT $host:443 HTTP/1.1\r\nHost: $host:443\r\n\r\n";
my $l = <$s>; $l =~ s/\s+\z//; print "$l\n";
P
  run perl "$T/connect.pl" "$port" localhost
  [[ "$output" == "HTTP/1.1 403 Forbidden" ]]
  echo '127.0.0.1=localhost' > "$T/af"
  run perl "$T/connect.pl" "$port" localhost
  [[ "$output" == "HTTP/1.1 502 Bad Gateway" ]]
  echo '127.0.0.2=localhost' > "$T/af"
  run perl "$T/connect.pl" "$port" localhost
  kill "$pid"
  [[ "$output" == "HTTP/1.1 403 Forbidden" ]]
}
