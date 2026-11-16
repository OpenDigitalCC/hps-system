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

@test "audit programs go to audit.log and stop (of this cluster: see the own-cluster tests below)" {
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

# --- whose lines (docs/LOGGING.md "Whose lines"): the views take this cluster's lines only ---

# gen_with_domain <domain>: regenerate the file as a cluster whose network_dns_domain is <domain>.
gen_with_domain() {
  local dom="$1"
  hps_get_config() {
    case "$1" in
      log) echo "$TEST_DIR/log" ;;
      active_cluster) echo lab ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() {
    [[ "$2" == get && "$3" == network_dns_domain && -n "$dom" ]] && { echo "\"$dom\""; return 0; }
    return 1
  }
  create_config_rsyslog
}

# own_regex: the regular expression of the re_match in the generated file, as a Perl pattern
own_regex() {
  grep -o 're_match($hostname, "[^"]*")' "$CONF" | head -1 | sed -e 's/^re_match(\$hostname, "//' -e 's/")$//' -e 's/\\\$$/$/' -e 's/\\\\/\\/g'
}

# is_own <regex> <hostname>: 0 when the host name is this cluster's
is_own() {
  perl -e 'exit($ARGV[1] =~ qr/$ARGV[0]/ ? 0 : 1)' "$1" "$2"
}

@test "the three views are gated on this IPS or a host named as the cluster names its hosts, and the gate is the same text each time" {
  gate="$(grep -o '^if (($fromhost-ip == "127.0.0.1" or re_match(.*)) then {$' "$CONF" | sort -u)"
  [ "$(printf '%s\n' "$gate" | wc -l)" -eq 1 ]
  [ "$(grep -c '^if (($fromhost-ip == "127.0.0.1" or re_match' "$CONF")" -eq 3 ]
  # the line after each gate is the view's own rule
  grep -A1 '^if (($fromhost-ip == "127.0.0.1" or re_match' "$CONF" | grep -qF 'if ($programname == ["ctrl-exec-api"'
  grep -A1 '^if (($fromhost-ip == "127.0.0.1" or re_match' "$CONF" | grep -qF 'if ($msg contains "hps-monitor: host="'
  grep -A1 '^if (($fromhost-ip == "127.0.0.1" or re_match' "$CONF" | grep -qF 'if ($fromhost-ip == "127.0.0.1" and ($msg contains "HPS-EVENT pri="'
}

@test "a line that is not this cluster's matches no view and is stopped by none: only the audit rule stops, inside its gate, so a foreign line reaches the day files" {
  views=$(grep -n '^## # Whose lines' "$CONF" | cut -d: -f1)
  routing=$(grep -n '^## # Log message routing' "$CONF" | cut -d: -f1)
  [ "$views" -lt "$routing" ]
  stops=$(sed -n "${views},${routing}p" "$CONF" | grep -c '^  stop$')
  [ "$stops" -eq 1 ]
  # that stop is inside the gate: the audit rule's closing is "}" "}" (rule, gate)
  grep -A1 '^  stop$' "$CONF" | grep -q '^}$'
  [ "$(sed -n "${views},${routing}p" "$CONF" | grep -c '^}$')" -ge 3 ]
  # the remote catch-all, which files every foreign line, is unchanged
  grep -qF 'dynaFile="RemoteLogFile"' "$CONF"
}

@test "no domain: only a single label is this cluster's; the lab's forwarded hosts are not" {
  re="$(own_regex)"
  [ "$re" = '^[a-z0-9_-]+$' ]
  is_own "$re" ips
  is_own "$re" sch-001
  is_own "$re" tch-004
  ! is_own "$re" s1.ips
  ! is_own "$re" s3.tch-001
  ! is_own "$re" s1.sch-002
  ! is_own "$re" sch-001.lab.example
}

@test "with a cluster DNS domain: a label, or label.domain; a forwarded host (prefix.label, prefix.label.domain) is not" {
  gen_with_domain lab.example
  re="$(own_regex)"
  [ "$re" = '^[a-z0-9_-]+(\.lab\.example)?$' ]
  grep -qF 're_match($hostname, "^[a-z0-9_-]+(\\.lab\\.example)?\$")' "$CONF"
  is_own "$re" ips
  is_own "$re" sch-001
  is_own "$re" sch-001.lab.example
  ! is_own "$re" s1.ips
  ! is_own "$re" s1.sch-001.lab.example
  ! is_own "$re" s3.tch-001
  ! is_own "$re" sch-001.other.example
  ! is_own "$re" lab.example
}

@test "a domain that is not a plain DNS name is ignored (never put into the rule)" {
  gen_with_domain 'x") or ($msg contains "y'
  re="$(own_regex)"
  [ "$re" = '^[a-z0-9_-]+$' ]
  [ "$(grep -c 'contains "y"' "$CONF")" -eq 0 ]
}

@test "the err-level derived line: HPS programs are a warning (attention), anything else is info (events only)" {
  hps_row="" ; other_row=""
  for row in "${RSYSLOG_DERIVED_EVENTS[@]}"; do
    IFS='|' read -r name cond pri kind state <<< "$row"
    [ "$name" = error ] && hps_row="$row"
    [ "$name" = error-other ] && other_row="$row"
  done
  [ -n "$hps_row" ] && [ -n "$other_row" ]
  IFS='|' read -r name cond pri kind state <<< "$hps_row"
  [ "$pri" = warning ]
  [[ "$cond" == *'$programname startswith "hps"'* ]]
  [[ "$cond" == *'$programname startswith "ctrl-exec"'* ]]
  [[ "$cond" == *'"dnsmasq"'* && "$cond" == *'"om"'* ]]
  IFS='|' read -r name cond pri kind state <<< "$other_row"
  [ "$pri" = info ]
  [[ "$cond" != *programname* ]]
  # the HPS row comes first, so a line of an HPS program is never the info one
  a=$(grep -n 'HPSDerived_error"' "$CONF" | head -1 | cut -d: -f1)
  e=$(grep -n 'HPSDerived_error_other"' "$CONF" | tail -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$e" ]
  grep -n '^} else if (\$syslogseverity' "$CONF" | head -2 | grep -q 'startswith "hps"'
}
