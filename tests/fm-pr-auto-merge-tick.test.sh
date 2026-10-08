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
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE='' \
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

test_freeze_refuses_non_harbor_without_calling() {
  local c out
  c="$TMP_ROOT/other"; install_fake_auto "$c" ok
  write_poll "$c/state" t3 'https://github.com/nivasritech/firstmate/pull/3'
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE='' \
    FM_PR_AUTO_MERGE=on "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in
    *'refused freeze for t3'*'queued, not merged'*) pass "tick freeze refuses non-harbor (queued)" ;;
    *) fail "out=$out" ;;
  esac
  [ ! -f "$c/auto.log" ] || fail "freeze must not call auto-merge for non-harbor"
}

test_freeze_refuses_mixed_repos() {
  local c out
  c="$TMP_ROOT/mixed"; install_fake_auto "$c" ok
  write_poll "$c/state" h1 'https://github.com/nivasritech/harbor/pull/11'
  write_poll "$c/state" o1 'https://github.com/derickdsouza/some-app/pull/12'
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE=0 \
    FM_PR_AUTO_MERGE=on "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in *'refused freeze for h1'*) ;; *) fail "harbor not refused: $out"; return ;; esac
  case "$out" in *'refused freeze for o1'*) ;; *) fail "other repo not refused: $out"; return ;; esac
  case "$out" in *'auto-merge: ok'*) fail "nothing may merge while frozen: $out"; return ;; esac
  [ ! -f "$c/auto.log" ] || { fail "freeze must not call auto-merge (mixed)"; return; }
  pass "tick freeze refuses every repo (HARBOR_DO_UNFREEZE=0)"
}

test_unfrozen_non_harbor_calls_auto_merge() {
  local c out
  c="$TMP_ROOT/other-open"; install_fake_auto "$c" ok
  write_poll "$c/state" t4 'https://github.com/nivasritech/firstmate/pull/4'
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE=1 \
    FM_PR_AUTO_MERGE=on "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in *'auto-merge: ok t4'*) pass "non-harbor uses normal rules when unfrozen" ;; *) fail "out=$out" ;; esac
  grep -q 'called:t4:https://github.com/nivasritech/firstmate/pull/4' "$c/auto.log" \
    || fail "auto.log missing non-harbor call"
}

test_unfrozen_refuse_passes_through() {
  local c out
  c="$TMP_ROOT/refuse-open"; install_fake_auto "$c" refuse
  write_poll "$c/state" t5 'https://github.com/nivasritech/firstmate/pull/5'
  out=$(FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE=1 \
    FM_PR_AUTO_MERGE=on "$c/bin/fm-pr-auto-merge-tick.sh" 2>&1) || true
  case "$out" in *'auto-merge: refused t5'*'missing Evidence'*) pass "unfrozen: merge-script refusal reported" ;; *) fail "out=$out" ;; esac
}

test_kill_switch_off
test_freeze_refuses_harbor_without_calling
test_idle_no_polls
test_calls_auto_merge_when_unfrozen
test_freeze_refuses_non_harbor_without_calling
test_freeze_refuses_mixed_repos
test_unfrozen_non_harbor_calls_auto_merge
test_unfrozen_refuse_passes_through
echo "fm-pr-auto-merge-tick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
