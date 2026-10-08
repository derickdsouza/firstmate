#!/usr/bin/env bash
# Offline tests for bin/fm-pr-auto-merge.sh (firstmate #14).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTO="$ROOT/bin/fm-pr-auto-merge.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-auto-merge.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "pass: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

install_gh() {
  local case_dir=$1
  mkdir -p "$case_dir/fakebin" "$case_dir/state"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh:%s\n' "$*" >> "${GH_LOG:?}"
case "$*" in
  *"pr view"*"body"*)
    cat "${FIXTURE_BODY:?}"; exit 0 ;;
  *"pr view"*)
    cat "${FIXTURE_VIEW:?}"; exit 0 ;;
  api*)
    cat "${FIXTURE_FILES:?}"; exit 0 ;;
  *"pr rebase"*)
    exit "${FIXTURE_REBASE_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

good_body_json='{"body":"## Summary\n\nx\n\n## Evidence\n\nbun test\n\n## Merge Danger\n\nN/A\n"}'
view_clean='{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","baseRefName":"main","statusCheckRollup":[{"name":"relay-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"tui-tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"contract-validators","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"claim-guard","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"quint-gate","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"pr-template","status":"COMPLETED","conclusion":"SUCCESS"}]}'

test_freeze_refuses_harbor() {
  local c out rc=0
  c="$TMP_ROOT/freeze"; mkdir -p "$c"; install_gh "$c"
  export GH_LOG="$c/gh.log" FIXTURE_BODY="$c/body.json" FIXTURE_VIEW="$c/view.json" FIXTURE_FILES="$c/files.json"
  printf '%s\n' "$good_body_json" > "$FIXTURE_BODY"
  printf '%s\n' "$view_clean" > "$FIXTURE_VIEW"
  printf '%s\n' '[]' > "$FIXTURE_FILES"
  out=$(PATH="$c/fakebin:$PATH" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE= \
    "$AUTO" task-x1 'https://github.com/nivasritech/harbor/pull/9' --dry-run 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { fail "freeze should refuse: $out"; return; }
  case "$out" in *freeze*) pass "freeze refuses harbor merge" ;; *) fail "expected freeze: $out" ;; esac
}

test_missing_evidence_refuses() {
  local c out rc=0
  c="$TMP_ROOT/noev"; mkdir -p "$c"; install_gh "$c"
  export GH_LOG="$c/gh.log" FIXTURE_BODY="$c/body.json" FIXTURE_VIEW="$c/view.json" FIXTURE_FILES="$c/files.json"
  printf '%s\n' '{"body":"## Summary\n\nonly summary\n"}' > "$FIXTURE_BODY"
  printf '%s\n' "$view_clean" > "$FIXTURE_VIEW"
  printf '%s\n' '[]' > "$FIXTURE_FILES"
  out=$(PATH="$c/fakebin:$PATH" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE=1 \
    "$AUTO" task-x1 'https://github.com/nivasritech/harbor/pull/9' --dry-run 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { fail "missing evidence should refuse: $out"; return; }
  case "$out" in *Evidence*) pass "missing Evidence refuses" ;; *) fail "out=$out" ;; esac
}

test_protected_path_refuses() {
  local c out rc=0
  c="$TMP_ROOT/prot"; mkdir -p "$c"; install_gh "$c"
  export GH_LOG="$c/gh.log" FIXTURE_BODY="$c/body.json" FIXTURE_VIEW="$c/view.json" FIXTURE_FILES="$c/files.json"
  printf '%s\n' "$good_body_json" > "$FIXTURE_BODY"
  printf '%s\n' "$view_clean" > "$FIXTURE_VIEW"
  printf '%s\n' '[{"filename":"GLOSSARY.md"}]' > "$FIXTURE_FILES"
  out=$(PATH="$c/fakebin:$PATH" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE=1 \
    "$AUTO" task-x1 'https://github.com/nivasritech/harbor/pull/9' --dry-run 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || { fail "protected should refuse: $out"; return; }
  case "$out" in *protected*) pass "protected path refuses" ;; *) fail "out=$out" ;; esac
}

test_dry_run_green_ok() {
  local c out rc=0
  c="$TMP_ROOT/green"; mkdir -p "$c"; install_gh "$c"
  export GH_LOG="$c/gh.log" FIXTURE_BODY="$c/body.json" FIXTURE_VIEW="$c/view.json" FIXTURE_FILES="$c/files.json"
  printf '%s\n' "$good_body_json" > "$FIXTURE_BODY"
  printf '%s\n' "$view_clean" > "$FIXTURE_VIEW"
  printf '%s\n' '[{"filename":"src/cli/do.ts"}]' > "$FIXTURE_FILES"
  out=$(PATH="$c/fakebin:$PATH" FM_STATE_OVERRIDE="$c/state" HARBOR_DO_UNFREEZE=1 \
    "$AUTO" task-x1 'https://github.com/nivasritech/harbor/pull/9' --dry-run 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || { fail "green dry-run rc=$rc out=$out"; return; }
  case "$out" in *dry-run:*merge*) pass "dry-run merge when green+Evidence" ;; *) fail "out=$out" ;; esac
}

test_freeze_refuses_harbor
test_missing_evidence_refuses
test_protected_path_refuses
test_dry_run_green_ok
echo "fm-pr-auto-merge: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
