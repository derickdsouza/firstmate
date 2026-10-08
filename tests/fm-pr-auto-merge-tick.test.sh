#!/usr/bin/env bash
# Offline tests for bin/fm-pr-auto-merge-tick.sh (watch wiring for #14).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="$ROOT/bin/fm-pr-auto-merge-tick.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-auto-merge-tick.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "pass: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

install_fake_auto() {
  local case_dir=$1 mode=$2
  mkdir -p "$case_dir/bin" "$case_dir/state"
  # Point SCRIPT_DIR resolution at our case by copying tick with ROOT override:
  # instead wrap AUTO by putting a fake next to a stub tick runner.
  cat > "$case_dir/bin/fm-pr-auto-merge.sh" <<SH
#!/usr/bin/env bash
printf 'called:%s:%s\\n' "\$1" "\$2" >> "$case_dir/auto.log"
case "$mode" in
  ok) echo "fm-pr-auto-merge: landed \$2"; exit 0 ;;
  refuse) echo "error: fm-pr-auto-merge: missing Evidence" >&2; exit 1 ;;
  *) echo "error: unknown mode"; exit 2 ;;
esac
SH
  chmod +x "$case_dir/bin/fm-pr-auto-merge.sh"
  cp "$TICK" "$case_dir/bin/fm-pr-auto-merge-tick.sh"
  chmod +x "$case_dir/bin/fm-pr-auto-merge-tick.sh"
}

write_poll() {
  local state=$1 id=$2 url=$3
  local path number
  # url https://github.com/owner/repo/pull/N
  path=$(printf '%s' "$url" | sed -E 's|https://github.com/([^/]+)/([^/]+)/pull/.*|\1/\2|')
  number=$(printf '%s' "$url" | sed -E 's|.*/pull/([0-9]+)|\1|')
  printf '%s\n' github "$url" github.com "$path" "$number" > "$state/$id.pr-poll"
}

test_kill_switch_off() {
  local c out
  c="$TMP_ROOT/off"; install_fake_auto "$c" ok
  write_poll "$c/state" t1 'https://github.com/nivasritech/harbor/pull/9'
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_PR_AUTO_MERGE=off \
    "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in *'skipped (FM_PR_AUTO_MERGE='*) pass "kill switch off skips" ;; *) fail "out=$out" ;; esac
  [ ! -f "$c/auto.log" ] || fail "auto-merge should not be called when off"
}

test_freeze_refuses_harbor_without_calling() {
  local c out
  c="$TMP_ROOT/freeze"; install_fake_auto "$c" ok
  write_poll "$c/state" t1 'https://github.com/nivasritech/harbor/pull/9'
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE= \
    FM_PR_AUTO_MERGE=on "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in *'refused freeze'*) pass "tick freeze refuses harbor" ;; *) fail "out=$out" ;; esac
  [ ! -f "$c/auto.log" ] || fail "freeze must not call auto-merge for harbor"
}

test_idle_no_polls() {
  local c out
  c="$TMP_ROOT/idle"; install_fake_auto "$c" ok
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" FM_PR_AUTO_MERGE=on \
    "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in *'idle'*) pass "idle with no polls" ;; *) fail "out=$out" ;; esac
}

test_calls_auto_merge_when_unfrozen() {
  local c out
  c="$TMP_ROOT/call"; install_fake_auto "$c" ok
  write_poll "$c/state" t2 'https://github.com/nivasritech/harbor/pull/42'
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE=1 \
    FM_PR_AUTO_MERGE=on "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in *'auto-merge: ok t2'*) pass "calls auto-merge when unfrozen" ;; *) fail "out=$out" ;; esac
  grep -q 'called:t2:https://github.com/nivasritech/harbor/pull/42' "$c/auto.log" \
    || fail "auto.log missing call"
}

test_non_harbor_not_blocked_by_freeze() {
  local c out
  c="$TMP_ROOT/other"; install_fake_auto "$c" ok
  write_poll "$c/state" t3 'https://github.com/nivasritech/firstmate/pull/3'
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE= \
    FM_PR_AUTO_MERGE=on "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in *'auto-merge: ok t3'*) pass "non-harbor allowed while frozen" ;; *) fail "out=$out" ;; esac
}

test_kill_switch_off
test_freeze_refuses_harbor_without_calling
test_idle_no_polls
test_calls_auto_merge_when_unfrozen
test_non_harbor_not_blocked_by_freeze
echo "fm-pr-auto-merge-tick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
