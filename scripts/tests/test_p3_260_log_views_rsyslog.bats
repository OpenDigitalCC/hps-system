#!/usr/bin/env bats
#
# The generated rsyslog configuration of the log views (docs/LOGGING.md):
# audit.log, metrics.log and events.log beside the day tree. rsyslogd itself is
# not run here (this host has none): the text is inspected for the routing, the
# templates every rule names, and balanced braces.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-260.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/services" "$TEST_DIR/log"
  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      log) echo "$TEST_DIR/log" ;;
      active_cluster) return 1 ;;
      *) return 1 ;;
    esac
  }
  get_path_cluster_services_dir() { echo "$TEST_DIR/services"; }
  export -f hps_log hps_get_config get_path_cluster_services_dir
  source "$ROOT/lib/functions.d/create-config-rsyslog.sh"
  create_config_rsyslog
  CONF="$TEST_DIR/services/rsyslog.conf"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "audit programs go to audit.log and stop, from any sender" {
  rule="$(grep -E '^if \(\$programname == \["ctrl-exec-api"' "$CONF")"
  for p in ctrl-exec-api ctrl-exec-agent ctrl-exec-dispatcher hps-auth-hook ips-admin; do
    [[ "$rule" == *"\"$p\""* ]]
  done
  [[ "$rule" != *fromhost-ip* ]]
  grep -qF "action(type=\"omfile\" file=\"$TEST_DIR/log/audit.log\" template=\"HPSAuditFormat\")" "$CONF"
  # the stop follows the audit action inside the same block
  awk '/HPSAuditFormat"\)$/{getline n; print n}' "$CONF" | grep -qx '  stop'
}

@test "the audit template is the one parse_audit reads: rfc3339 time, sender ip, host, tag, text" {
  grep -qF 'template(name="HPSAuditFormat" type="string" string="%timegenerated:::date-rfc3339% %fromhost-ip% [%HOSTNAME%] %syslogtag% %msg%\n")' "$CONF"
}

@test "the audit rule comes before the service and catch-all routing, so audit lines never reach the day tree" {
  audit=$(grep -n 'template="HPSAuditFormat")' "$CONF" | head -1 | cut -d: -f1)
  svc=$(grep -n 'dynaFile="IPSServiceLogFile"' "$CONF" | head -1 | cut -d: -f1)
  all=$(grep -n 'dynaFile="IPSLogFile"' "$CONF" | head -1 | cut -d: -f1)
  rem=$(grep -n 'dynaFile="RemoteLogFile"' "$CONF" | head -1 | cut -d: -f1)
  [ "$audit" -lt "$svc" ]
  [ "$audit" -lt "$all" ]
  [ "$audit" -lt "$rem" ]
}

@test "the service rule no longer lists the audit programs; dnsmasq-dhcp keeps its own directory" {
  rule="$(grep -E 'programname == \[.*"dnsmasq-dhcp"' "$CONF")"
  [[ "$rule" == *'"dnsmasq-dhcp"'* ]]
  [[ "$rule" != *'"ctrl-exec-api"'* ]]
  [[ "$rule" != *'"ctrl-exec-agent"'* ]]
  [[ "$rule" != *'"ips-admin"'* ]]
  [[ "$rule" == *'"hps"'* ]]
}

@test "metrics.log: hps-monitor host and tick lines, in the form hps-metrics reads, and no stop" {
  grep -qF 'template(name="HPSMetricFormat" type="string" string="%timegenerated:::date-rfc3339% metric %hostname% %syslogtag%%msg:::sp-if-no-1st-sp%%msg%\n")' "$CONF"
  grep -qF 'if ($msg contains "hps-monitor: host=" or $msg contains "hps-monitor: tick ") then {' "$CONF"
  grep -qF "action(type=\"omfile\" file=\"$TEST_DIR/log/metrics.log\" template=\"HPSMetricFormat\")" "$CONF"
  run awk '/metrics.log" template/{getline n; print n}' "$CONF"
  [ "$output" = "}" ]
}

@test "events.log: a marker line of a local program, first of the chain" {
  grep -qF 'if ($fromhost-ip == "127.0.0.1" and ($msg contains "HPS-EVENT pri=" or $msg contains "HPS-ALERT pri=")) then {' "$CONF"
  grep -qF 'template(name="HPSEventFormat" type="string" string="%timegenerated:::date-rfc3339% %hostname%%msg:::sp-if-no-1st-sp%%msg%\n")' "$CONF"
  # marker first, then only else-ifs: a marker line is never derived as well
  first=$(grep -n 'HPS-EVENT pri=" or' "$CONF" | head -1 | cut -d: -f1)
  d1=$(grep -n '^} else if (.*iPXE Initialisation' "$CONF" | head -1 | cut -d: -f1)
  [ "$first" -lt "$d1" ]
}

@test "every derived row has a template, a rule, a valid priority, kind and state" {
  rows="${#RSYSLOG_DERIVED_EVENTS[@]}"
  [ "$rows" -ge 10 ]
  n=0
  for row in "${RSYSLOG_DERIVED_EVENTS[@]}"; do
    IFS='|' read -r name cond pri kind state <<< "$row"
    t="HPSDerived_${name//-/_}"
    grep -q "^template(name=\"$t\"" "$CONF"
    grep -q "template=\"$t\")" "$CONF"
    grep -qF "else if ($cond) then {" "$CONF"
    [[ " urgent warning notice info " == *" $pri "* ]]
    [[ " issue monitor workload storage node power job pairing boot auth service log " == *" $kind "* ]]
    perl -I"$ROOT/lib/perl" -MHPS::Event -e 'exit(HPS::Event::state_class($ARGV[0]) ? 0 : 1)' "$state"
    n=$((n + 1))
  done
  [ "$n" -eq "$rows" ]
}

@test "a derived line is an event line HPS::Event parses (marker follows the priority)" {
  for row in "${RSYSLOG_DERIVED_EVENTS[@]}"; do
    IFS='|' read -r name cond pri kind state <<< "$row"
    t="HPSDerived_${name//-/_}"
    line="$(grep "^template(name=\"$t\"" "$CONF")"
    [[ "$line" == *"pri=$pri kind=$kind subject=- state=$state "* ]]
    if [ "$pri" = warning ] || [ "$pri" = urgent ]; then
      [[ "$line" == *" HPS-ALERT pri="* ]]
    else
      [[ "$line" == *" HPS-EVENT pri="* ]]
    fi
    sample="HPS-EVENT pri=$pri kind=$kind subject=- state=$state hps: text"
    perl -I"$ROOT/lib/perl" -MHPS::Event -e 'exit(HPS::Event::parse($ARGV[0]) ? 0 : 1)' "$sample"
  done
}

@test "the derived table keeps what the owner listed: iPXE, boot, up, off, held, bmc action not status, node fault, storage exit, ips-check FAIL" {
  all="${RSYSLOG_DERIVED_EVENTS[*]}"
  for w in 'iPXE Initialisation requested' 'NixOS network boot:' 'Reached target Multi-User System' 'reboot: Power down' ' is HELD ' 'hps-bmc: action=' 'FAULT' 'hps-storage:' 'hps-ips-check'; do
    [[ "$all" == *"$w"* ]]
  done
  grep -qF 'not ($msg contains "action=status")' "$CONF"
}

@test "the generated file balances its braces and parentheses outside strings" {
  perl -e 'my $t = do { local $/; <> }; $t =~ s/"[^"\n]*"//g; $t =~ s/^\s*#.*$//mg;
    my ($b, $p) = (0, 0); for my $c (split //, $t) { $b++ if $c eq "{"; $b-- if $c eq "}"; $p++ if $c eq "("; $p-- if $c eq ")" }
    exit(($b == 0 && $p == 0) ? 0 : 1)' "$CONF"
}

@test "every template an action names is defined, and only constructs the tree already uses appear" {
  for t in $(grep -o 'template="[A-Za-z_]*"' "$CONF" | sort -u | cut -d'"' -f2); do
    grep -q "^template(name=\"$t\"" "$CONF"
  done
  # constructs: omfile (file= or dynaFile=), omfwd, if/else if/then, stop, contains, startswith, ==, !=, <=
  run grep -E 'omprog|ommail|omjournal|ruleset\(|^ *call |\$!|^ *set |reload' "$CONF"
  [ "$status" -eq 1 ]
}

@test "the whole file still has the routing section last and the forward block before it" {
  fwd=$(grep -n 'Forward everything' "$CONF" | head -1 | cut -d: -f1 || true)
  views=$(grep -n '^## # Audit' "$CONF" | cut -d: -f1)
  routing=$(grep -n '^## # Log message routing' "$CONF" | cut -d: -f1)
  [ "$views" -lt "$routing" ]
  [ -z "$fwd" ] || [ "$fwd" -lt "$views" ]
}
