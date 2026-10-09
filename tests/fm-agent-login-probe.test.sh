#!/usr/bin/env bash
# Behavior tests for bin/fm-agent-login-probe.sh.
#
# Pins the single catalog retry on pi: a transient first-pass blip from
# `pi --list-models` must not declare FAIL, while two failed passes still do.
# Exercises the probe through its public OK/FAIL output contract only.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agent-login-probe-tests)
trap fm_test_cleanup EXIT

# Darwin labels the host mac; Linux (this VPS) labels it vps.
if [ "$(uname -s)" = Darwin ]; then
  PROBE_HOST=mac
else
  PROBE_HOST=vps
fi

# Shared companion fakes: always-authenticated, so only pi's catalog drives FAIL.
install_companion_fakes() {
  local dir=$1
  cat > "$dir/grok" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'grok-4.6'
SH
  cat > "$dir/cursor-agent" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'composer-2.5'
SH
  cat > "$dir/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'claude 1.0'
SH
  chmod +x "$dir/grok" "$dir/cursor-agent" "$dir/claude"
}

# Fake pi that fails the catalog on the first N calls, then succeeds with zai.
# Call count is recorded so the suite can assert at most one retry.
install_flaky_pi() {
  local dir=$1 fails_before_ok=$2
  cat > "$dir/pi" <<SH
#!/usr/bin/env bash
count_file="$dir/pi-calls"
n=\$(( \$(cat "\$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > "\$count_file"
if [ "\$n" -le $fails_before_ok ]; then
  # Transient empty catalog (the blip that used to false-FAIL).
  exit 0
fi
printf '%s\n' 'zai/glm-5.3'
SH
  chmod +x "$dir/pi"
}

run_probe() {
  local fakebin=$1
  env -i HOME="$TMP_ROOT/empty-home" PATH="$fakebin:/usr/bin:/bin" \
    FM_LOGIN_PROBE_SKIP_VPS=1 /bin/bash "$ROOT/bin/fm-agent-login-probe.sh" 2>&1
}

# --- single blip recovers on the one retry ----------------------------------

BLIP="$TMP_ROOT/blip"
mkdir -p "$BLIP"
install_companion_fakes "$BLIP"
install_flaky_pi "$BLIP" 1
BLIP_OUT=$(run_probe "$BLIP")
BLIP_RC=$?
printf '%s\n' "$BLIP_OUT" | grep -q "OK   pi@$PROBE_HOST" \
  || fail "single catalog blip must recover to OK pi@$PROBE_HOST; got: $BLIP_OUT"
[ "$BLIP_RC" = 0 ] || fail "single catalog blip must exit 0; got $BLIP_RC"
[ "$(cat "$BLIP/pi-calls")" = 2 ] || fail "single blip must call pi exactly twice; got $(cat "$BLIP/pi-calls")"
pass 'single pi catalog blip recovers on one retry'

# --- two failed passes still FAIL -------------------------------------------

HARD="$TMP_ROOT/hard-fail"
mkdir -p "$HARD"
install_companion_fakes "$HARD"
install_flaky_pi "$HARD" 99
HARD_OUT=$(run_probe "$HARD")
HARD_RC=$?
printf '%s\n' "$HARD_OUT" | grep -q "FAIL pi@$PROBE_HOST (needs re-login)" \
  || fail "two failed catalog passes must FAIL needs re-login; got: $HARD_OUT"
[ "$HARD_RC" = 1 ] || fail "two failed catalog passes must exit 1; got $HARD_RC"
[ "$(cat "$HARD/pi-calls")" = 2 ] || fail "hard fail must call pi exactly twice; got $(cat "$HARD/pi-calls")"
pass 'two failed pi catalog passes still FAIL'

# --- first-pass OK never retries --------------------------------------------

OK="$TMP_ROOT/first-ok"
mkdir -p "$OK"
install_companion_fakes "$OK"
install_flaky_pi "$OK" 0
OK_OUT=$(run_probe "$OK")
OK_RC=$?
printf '%s\n' "$OK_OUT" | grep -q "OK   pi@$PROBE_HOST" \
  || fail "first-pass catalog OK must print OK pi@$PROBE_HOST; got: $OK_OUT"
[ "$OK_RC" = 0 ] || fail "first-pass catalog OK must exit 0; got $OK_RC"
[ "$(cat "$OK/pi-calls")" = 1 ] || fail "first-pass OK must call pi once; got $(cat "$OK/pi-calls")"
pass 'first-pass pi catalog OK does not retry'

# --- missing pi still fails without catalog retry ---------------------------

MISSING="$TMP_ROOT/missing-pi"
mkdir -p "$MISSING"
install_companion_fakes "$MISSING"
# No pi binary on PATH.
MISS_OUT=$(run_probe "$MISSING")
MISS_RC=$?
printf '%s\n' "$MISS_OUT" | grep -q "FAIL pi@$PROBE_HOST (pi not installed)" \
  || fail "absent pi must FAIL not installed; got: $MISS_OUT"
[ "$MISS_RC" = 1 ] || fail "absent pi must exit 1; got $MISS_RC"
pass 'absent pi fails as not installed without catalog retry'

printf 'done\n'
