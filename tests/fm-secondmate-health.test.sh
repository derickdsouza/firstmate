#!/usr/bin/env bash
# tests/fm-secondmate-health.test.sh - alive-but-stuck classifiers in
# bin/fm-secondmate-health-lib.sh.
#
# Process-alive is not health. These tests pin the public classifiers with
# real files and capture text, not by reading the library source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-secondmate-health)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

health_lib() {
  bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-secondmate-health-lib.sh" "$@"
}

write_msg() {  # <dir> <name> <age-secs>
  local dir=$1 name=$2 age=$3
  mkdir -p "$dir/handled"
  cat > "$dir/$name" <<'EOF'
schema=fm-task-inbox.v1
at=2026-08-31T10:41:47Z
--
do the work
EOF
  touch -d "@$(($(date +%s) - age))" "$dir/$name" 2>/dev/null \
    || touch -t "$(date -u -v-"${age}"S +%Y%m%d%H%M.%S 2>/dev/null)" "$dir/$name"
}

test_empty_inbox_is_not_stuck() {
  local state=$TMP_ROOT/empty
  mkdir -p "$state/mate.inbox/handled"
  health_lib fm_secondmate_inbox_stuck "$state" mate && fail "an empty inbox must not be stuck"
  pass "empty inbox is not stuck"
}

test_fresh_unhandled_is_not_stuck() {
  local state=$TMP_ROOT/fresh
  write_msg "$state/mate.inbox" 001.msg 10
  FM_SECONDMATE_INBOX_STUCK_SECS=60 health_lib fm_secondmate_inbox_stuck "$state" mate \
    && fail "mail younger than the stuck budget must not be stuck"
  pass "fresh unhandled mail is not stuck"
}

test_old_unhandled_is_stuck() {
  local state=$TMP_ROOT/old
  write_msg "$state/mate.inbox" 001.msg 400
  FM_SECONDMATE_INBOX_STUCK_SECS=60 health_lib fm_secondmate_inbox_stuck "$state" mate \
    || fail "mail older than the stuck budget must be stuck"
  pass "old unhandled mail is stuck"
}

test_capture_runtime_fault() {
  printf '%s\n' 'Error: Cannot find module' \
    "'/Users/x/.nvm/versions/node/v24.7.0/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/chunks/openai-completions-JD4WAC3R.js'" \
    | health_lib fm_secondmate_capture_has_runtime_fault \
    || fail "a missing hashed chunk must classify as a runtime fault"
  printf '%s\n' 'idle secondmate waiting for routed work' \
    | health_lib fm_secondmate_capture_has_runtime_fault \
    && fail "ordinary idle capture must not classify as a runtime fault"
  pass "capture runtime-fault classifier"
}

test_health_from_parts() {
  local out
  out=$(health_lib fm_secondmate_health_from_parts alive 0 0)
  [ "$out" = alive ] || fail "healthy alive should stay alive, got '$out'"
  out=$(health_lib fm_secondmate_health_from_parts alive 1 0)
  [ "$out" = stuck:unacked-inbox ] || fail "inbox stuck should win, got '$out'"
  out=$(health_lib fm_secondmate_health_from_parts alive 0 1)
  [ "$out" = stuck:runtime-fault ] || fail "runtime fault should win, got '$out'"
  out=$(health_lib fm_secondmate_health_from_parts dead 1 1)
  [ "$out" = dead ] || fail "dead should pass through, got '$out'"
  out=$(health_lib fm_secondmate_health_from_parts unreadable 1 0)
  [ "$out" = stuck:unacked-inbox ] || fail "unreadable with old mail should be stuck, got '$out'"
  out=$(health_lib fm_secondmate_health_from_parts unreadable 0 0)
  [ "$out" = unreadable ] || fail "unreadable without mail should stay unreadable, got '$out'"
  pass "health_from_parts vocabulary"
}

test_control_health_old_inbox_without_herdr() {
  local home=$TMP_ROOT/remote-home out
  mkdir -p "$home/bin" "$home/state/parent-route/mate.inbox/handled"
  printf 'mate\n' > "$home/.fm-secondmate-home"
  printf '# firstmate\n' > "$home/AGENTS.md"
  write_msg "$home/state/parent-route/mate.inbox" 001.msg 400
  cat > "$home/state/parent-route/mate.meta" <<'EOF'
window=fm-remote:w1:p2
endpoint_task_id=mate
worktree=/tmp/mate
project=/tmp/mate
harness=pi
kind=secondmate
backend=herdr
herdr_session=fm-remote
herdr_workspace_id=w1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
EOF
  out=$(FM_SECONDMATE_INBOX_STUCK_SECS=60 FM_HOME="$home" "$ROOT/bin/fm-remote-secondmate-control.sh" health mate 2>/dev/null | tail -1)
  [ "$out" = stuck:unacked-inbox ] || fail "control health with old mail and no live herdr should be stuck:unacked-inbox, got '$out'"
  pass "control health reports stuck:unacked-inbox for old remote mail"
}

test_empty_inbox_is_not_stuck
test_fresh_unhandled_is_not_stuck
test_old_unhandled_is_stuck
test_capture_runtime_fault
test_health_from_parts
test_control_health_old_inbox_without_herdr
