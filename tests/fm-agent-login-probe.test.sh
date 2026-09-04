#!/usr/bin/env bash
# Tests for fm-agent-login-probe.sh FAIL detail (firstmate #10).
# A FAIL under the when-watch runner must say WHY: 'not on PATH' (exit 127),
# 'command failed (exit N: stderr)' (auth/runtime fault), or 'catalog fetch
# failed' (exit 0 but no model match) — never a blanket 'needs re-login'.
# Stubs live in a fixture PATH + fake HOME so the probe's install-root
# hardening resolves nothing real on the host.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bin/fm-agent-login-probe.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-login-probe.XXXXXX")
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "pass: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Fake home: empty, so PATH hardening adds only standard roots that do not
# exist here, and the stubs below are the only pi/grok/cursor-agent.
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"

probe_run() { # extra stubs already installed; runs the probe, VPS off
  PATH="$TMP/bin:/usr/bin:/bin" \
  FM_LOGIN_PROBE_SKIP_VPS=1 \
  bash "$SCRIPT" 2>"$TMP/err"
}

stub() { # <name> <printf-format> <exit>
  cat >"$TMP/bin/$1" <<STUB
#!/usr/bin/env bash
printf '$2'
exit $3
STUB
  chmod +x "$TMP/bin/$1"
}

stub_err() { # <name> <stdout-fmt> <stderr-fmt> <exit>
  cat >"$TMP/bin/$1" <<STUB
#!/usr/bin/env bash
printf '$2'
printf '$3' >&2
exit $4
STUB
  chmod +x "$TMP/bin/$1"
}

test_healthy_all_ok() {
  stub pi 'zai-glmo-1\n' 0
  stub grok 'grok-4\n' 0
  stub cursor-agent 'composer-5\n' 0
  stub claude 'unused' 0
  probe_run >"$TMP/out"
  grep -q '^OK   pi@mac' "$TMP/out" && grep -q '^OK   cursor@mac' "$TMP/out" && grep -q '^OK   grok@mac' "$TMP/out" \
    && pass "healthy catalogs: all mac probes OK" \
    || fail "healthy: $(cat "$TMP/out")"
}

test_exit127_reports_not_on_path() {
  stub_err pi '' 'env: pi: No such file or directory\n' 127
  probe_run >"$TMP/out" || true
  grep -q '^FAIL pi@mac (pi not on PATH' "$TMP/out" \
    && pass "exit 127 reports not-on-PATH" \
    || fail "127: $(cat "$TMP/out")"
}

test_nonzero_reports_exit_and_stderr() {
  stub_err pi '' 'AUTH_REQUIRED: run pi login\n' 4
  probe_run >"$TMP/out" || true
  grep -Eq '^FAIL pi@mac \(command failed \(exit 4[:)]' "$TMP/out" \
    && pass "non-zero exit carries exit code" \
    || fail "exit4: $(cat "$TMP/out")"
  grep -q 'AUTH_REQUIRED' "$TMP/out" \
    && pass "non-zero exit carries stderr detail" \
    || fail "stderr missing: $(cat "$TMP/out")"
}

test_zero_no_match_reports_catalog_fetch() {
  stub pi 'some-other-model\n' 0
  probe_run >"$TMP/out" || true
  grep -Eq '^FAIL pi@mac \(catalog fetch failed' "$TMP/out" \
    && pass "exit 0 without match reports catalog fetch failed" \
    || fail "catalog: $(cat "$TMP/out")"
}

test_cursor_and_grok_detail() {
  stub pi 'zai-1\n' 0
  stub grok 'other\n' 0
  stub_err cursor-agent '' 'boom\n' 3
  probe_run >"$TMP/out" || true
  grep -Eq '^FAIL cursor@mac \(command failed \(exit 3' "$TMP/out" \
    && pass "cursor detail carries exit code" \
    || fail "cursor: $(cat "$TMP/out")"
  grep -Eq '^FAIL grok@mac \(catalog fetch failed' "$TMP/out" \
    && pass "grok detail distinguishes catalog failure" \
    || fail "grok: $(cat "$TMP/out")"
}

test_missing_cli_still_not_installed() {
  # pi absent, others healthy: the pre-check must still fire first.
  rm -f "$TMP/bin/pi"
  stub grok 'grok-4\n' 0
  stub cursor-agent 'composer-5\n' 0
  probe_run >"$TMP/out" || true
  grep -q '^FAIL pi@mac (pi not installed)' "$TMP/out" \
    && pass "absent CLI still reports not installed" \
    || fail "absent: $(cat "$TMP/out")"
}

command -v bash >/dev/null 2>&1 || { echo "skip: bash not found"; exit 0; }

test_healthy_all_ok
test_exit127_reports_not_on_path
test_nonzero_reports_exit_and_stderr
test_zero_no_match_reports_catalog_fetch
test_cursor_and_grok_detail
test_missing_cli_still_not_installed

echo "fm-agent-login-probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
