#!/usr/bin/env bats
#
# The bash side of the event lines (docs/LOGGING.md): hps_event, and the pairing
# outcomes that use it. Every hps_event call in the tree is checked against the
# fixed vocabulary of lib/perl/HPS/Event.pm, which is also what parses it.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-262.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$ROOT/lib/functions-core-lib.sh"
  # hps_log stub: one "<level> <message>" line per call
  hps_log() { printf '%s %s\n' "$1" "${*:2}" >> "$TEST_DIR/log"; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

parses() {
  # the message of the last logged line parses as an event with the given fields
  perl -I"$ROOT/lib/perl" -MHPS::Event -e '
    my $m = (split /\n/, do { local $/; <STDIN> })[-1] =~ s/\A\S+ //r;
    my $e = HPS::Event::parse($m) or exit 1;
    my %want = map { split /=/, $_, 2 } @ARGV;
    for my $k (keys %want) { exit 1 unless ($e->{$k} // "") eq $want{$k} }' "$@" < "$TEST_DIR/log"
}

@test "hps_event: a warning is an alert at hps_log level warn, with the four fields and the text" {
  run hps_event warning pairing 525400000001 refused "ce_approve: refused: no IP"
  [ "$status" -eq 0 ]
  read -r level msg < "$TEST_DIR/log"
  [ "$level" = warn ]
  [ "$msg" = "HPS-ALERT pri=warning kind=pairing subject=525400000001 state=refused ce_approve: refused: no IP" ]
  parses pri=warning kind=pairing subject=525400000001 state=refused attention=1
}

@test "hps_event: urgent is an alert at level error; notice and info are events at info" {
  hps_event urgent issue k escalated "t"
  [ "$(awk '{print $1}' "$TEST_DIR/log")" = error ]
  grep -q ' HPS-ALERT pri=urgent kind=issue subject=k state=escalated t$' "$TEST_DIR/log" || grep -q '^error HPS-ALERT pri=urgent' "$TEST_DIR/log"
  : > "$TEST_DIR/log"
  hps_event notice pairing m paired "t"
  [ "$(awk '{print $1, $2}' "$TEST_DIR/log")" = "info HPS-EVENT" ]
  parses pri=notice attention=0
  : > "$TEST_DIR/log"
  hps_event info boot m started "t"
  [ "$(awk '{print $1, $2}' "$TEST_DIR/log")" = "info HPS-EVENT" ]
}

@test "hps_event: a subject has no space or =; an empty one is -" {
  hps_event info node "a b=c" up "t"
  parses subject=a_b_c
  : > "$TEST_DIR/log"
  hps_event info node "" up "t"
  parses subject=-
}

@test "hps_event: a priority outside the list, or too few arguments, logs nothing and returns 1" {
  run hps_event debug node s up t
  [ "$status" -eq 1 ]
  run hps_event info node s
  [ "$status" -eq 1 ]
  [ ! -s "$TEST_DIR/log" ]
}

@test "every hps_event call in the tree uses a priority, kind and state of HPS::Event" {
  run grep -rhoE '\bhps_event [a-z]+ [a-z]+ [^ ]+ [a-z-]+' "$ROOT/lib" "$ROOT/http" "$ROOT/bin" "$ROOT/scripts" --include='*.sh' --include='*' --exclude-dir=tests --exclude-dir=.git
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  while read -r _ pri kind _ state; do
    perl -I"$ROOT/lib/perl" -MHPS::Event -e 'exit(HPS::Event::is_priority($ARGV[0]) && (grep { $_ eq $ARGV[1] } HPS::Event::kinds()) && HPS::Event::state_class($ARGV[2]) ? 0 : 1)' "$pri" "$kind" "$state"
  done <<< "$output"
}

@test "pairing: an approval is a notice event, a refusal a warning, a request to retry nothing" {
  source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
  hps_event() { printf '%s|' "$@" >> "$TEST_DIR/ev"; printf '\n' >> "$TEST_DIR/ev"; }
  mac=525400000001
  _ce_pair_answer paired approved
  _ce_pair_answer refused "no allocated IP to bind the request to"
  _ce_pair_answer reboots_exhausted "gave up"
  _ce_pair_answer pending "the job did not finish"
  _ce_pair_answer outside_window "reboot 1 of 3"
  _ce_pair_answer no_request "none"
  [ "$(wc -l < "$TEST_DIR/ev")" -eq 3 ]
  sed -n 1p "$TEST_DIR/ev" | grep -qx 'notice|pairing|525400000001|paired|ce_approve: 525400000001 approved: approved|'
  sed -n 2p "$TEST_DIR/ev" | grep -qx 'warning|pairing|525400000001|refused|ce_approve: 525400000001 refused: no allocated IP to bind the request to|'
  sed -n 3p "$TEST_DIR/ev" | grep -q '^warning|pairing|525400000001|refused|'
  [ "$CE_PAIR_REASON" = no_request ]
}

@test "pairing: the answer is unchanged when hps_event does not exist or fails" {
  source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
  unset -f hps_event
  mac=525400000001
  _ce_pair_answer paired approved
  [ "$CE_PAIR_REASON" = paired ]
  hps_event() { return 1; }
  _ce_pair_answer refused "x"
  [ "$CE_PAIR_REASON" = refused ]
}
