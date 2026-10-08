#!/usr/bin/env bash
# Tests for bin/fm-spawn-gate-lib.sh (FM_SPAWN_GATE_CMD hook) and its two call
# sites in bin/fm-spawn.sh and bin/fm-teardown.sh.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-gate.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "pass: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }
# shellcheck source=bin/fm-spawn-gate-lib.sh
. "$ROOT/bin/fm-spawn-gate-lib.sh"

cat >"$TMP/gate" <<G
#!/usr/bin/env bash
echo "\$*" >>"$TMP/calls"
[ "\$1 \$2" = "x acquire" ] || { echo "bad-args:\$*"; exit 9; }
[ -f "$TMP/refuse" ] && { echo "CAP_FLEET:5:of:5"; exit 11; }
echo "SLOT_OK:crew:\$3"
G
chmod +x "$TMP/gate"

unset FM_SPAWN_GATE_CMD
fm_spawn_gate_acquire t1 && pass "unset hook is a no-op" || fail "unset hook refused"
FM_SPAWN_GATE_CMD="$TMP/gate x"
fm_spawn_gate_acquire t2 && grep -qx "x acquire t2" "$TMP/calls" && pass "hook gets extra args + acquire <id>" || fail "acquire call shape: $(cat "$TMP/calls" 2>/dev/null)"
: >"$TMP/refuse"
err=$(fm_spawn_gate_acquire t3 2>&1) && fail "refusal should return 1" || {
  case "$err" in *"rc=11"*CAP_FLEET:5:of:5*) pass "refusal returns 1 with hook output" ;; *) fail "refusal message: $err" ;; esac
}
rm -f "$TMP/refuse"
FM_SPAWN_GATE_CMD="$TMP/missing-gate"
fm_spawn_gate_acquire t4 2>/dev/null && fail "missing hook binary must refuse (fail closed)" || pass "missing hook binary refuses"
fm_spawn_gate_release t4 2>/dev/null && pass "release never fails teardown" || fail "release returned non-zero"
FM_SPAWN_GATE_CMD='$(touch '"$TMP"'/pwned) x'
fm_spawn_gate_acquire t5 >/dev/null 2>&1
[ ! -e "$TMP/pwned" ] && pass "hook string is not shell-evaluated" || fail "hook string was evaluated"

grep -q 'fm_spawn_gate_acquire "\$ID"' "$ROOT/bin/fm-spawn.sh" && pass "fm-spawn.sh calls acquire" || fail "fm-spawn.sh call site missing"
grep -q 'fm_spawn_gate_release "\$ID"' "$ROOT/bin/fm-teardown.sh" && pass "fm-teardown.sh calls release" || fail "fm-teardown.sh call site missing"

echo "fm-spawn-gate-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
