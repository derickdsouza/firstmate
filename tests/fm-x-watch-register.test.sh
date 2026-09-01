#!/usr/bin/env bash
# Behavior tests for alternate Relay poll-shim registration: stock remains
# byte-static, a valid binding is honored by the watcher and preserved across
# bootstrap regeneration, and unregistered or stale variants are refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$ROOT/bin/fm-x-lib.sh"

REGISTER="$ROOT/bin/fm-x-watch-register.sh"
WATCH="$ROOT/bin/fm-watch.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-x-watch-register)

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

write_stock_shim() {
  local home=$1
  mkdir -p "$home/state"
  fmx_poll_shim_content "$home" "$ROOT" > "$home/state/x-watch.check.sh"
  chmod 700 "$home/state/x-watch.check.sh"
}

write_alt_shim() {
  local home=$1 target=$2
  mkdir -p "$home/state"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# test alternate Relay poll shim'
    printf 'export FM_HOME=%s\n' "$(printf '%q' "$home")"
    printf 'exec %s\n' "$(printf '%q' "$target")"
  } > "$home/state/x-watch.check.sh"
  chmod 700 "$home/state/x-watch.check.sh"
}

write_wrapper() {
  local path=$1 line=${2:-alt-poll-ok}
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$line'
SH
  chmod 755 "$path"
}

make_fake_curl() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -m|-w|-H) shift 2 ;;
    -s) shift ;;
    http://*|https://*) shift ;;
    *) shift ;;
  esac
done
[ -n "$ofile" ] && : > "$ofile"
printf '%s' "${FAKE_POLL_CODE:-401}"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

run_watch() {
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env "$@" "$WATCH"
}

test_stock_shim_validates_through_watcher() {
  local home fakebin rc
  home=$(make_home stock)
  write_stock_shim "$home"
  printf 'FMX_PAIRING_TOKEN=tok-stock\n' > "$home/.env"
  fakebin=$(make_fake_curl "$home")
  set +e
  PATH="$fakebin:$PATH" FAKE_POLL_CODE=401 \
    run_watch FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
      FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      > "$home/watch.out" 2> "$home/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "stock watcher cycle failed (rc=$rc): $(cat "$home/watch.err")"
  assert_contains "$(cat "$home/watch.out")" "x-mode-error relay returned HTTP 401" \
    "stock shim must dispatch the trusted poll script"
  assert_absent "$home/state/x-watch.poll-trust" \
    "stock path must not auto-create a poll-trust binding"
  fmx_poll_shim_stock_valid "$home/state/x-watch.check.sh" "$home" "$ROOT" \
    || fail "stock shim must validate as stock"
  pass "stock Relay poll shim validates through the watcher path"
}

test_registered_variant_validates_through_watcher() {
  local home wrapper rc
  home=$(make_home registered-watch)
  wrapper="$home/fm-x-poll-harbor.sh"
  write_wrapper "$wrapper" alt-poll-ok
  write_alt_shim "$home" "$wrapper"
  FM_HOME="$home" "$REGISTER" "$wrapper" > "$home/register.out" \
    || fail "register failed: $(cat "$home/register.out" 2>/dev/null || true)"
  assert_contains "$(cat "$home/register.out")" "registered: state/x-watch.check.sh -> $wrapper" \
    "register must report the bound target"
  [ "$(path_mode "$home/state/x-watch.poll-trust")" = 600 ] \
    || fail "binding must be mode 0600"
  set +e
  run_watch FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    > "$home/watch.out" 2> "$home/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "registered watcher cycle failed (rc=$rc): $(cat "$home/watch.err")"
  assert_contains "$(cat "$home/watch.out")" "alt-poll-ok" \
    "watcher must dispatch the registered exec target"
  assert_not_contains "$(cat "$home/watch.out")" "rejected unauthenticated" \
    "a valid registration must not be rejected"
  pass "registered alternate shim validates through the watcher path"
}

test_unregistered_rewrite_is_rejected() {
  local home wrapper rc
  home=$(make_home unregistered)
  wrapper="$home/fm-x-poll-harbor.sh"
  write_wrapper "$wrapper" should-not-run
  write_alt_shim "$home" "$wrapper"
  set +e
  run_watch FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    > "$home/watch.out" 2> "$home/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "unregistered watcher cycle failed (rc=$rc): $(cat "$home/watch.err")"
  assert_contains "$(cat "$home/watch.out")" "rejected unauthenticated state checks:" \
    "unregistered rewrite must be rejected without execution"
  assert_contains "$(cat "$home/watch.out")" "x-watch.check.sh" \
    "rejection must name the unauthenticated shim"
  assert_not_contains "$(cat "$home/watch.out")" "should-not-run" \
    "unregistered rewrite must not execute the wrapper"
  assert_not_contains "$(cat "$home/watch.out")" "re-register with bin/fm-x-watch-register.sh" \
    "unregistered rewrite must keep today's rejection wording"
  pass "unregistered rewrite is rejected without execution"
}

test_tampered_target_is_rejected_and_named() {
  local home wrapper rc
  home=$(make_home tampered)
  wrapper="$home/fm-x-poll-harbor.sh"
  write_wrapper "$wrapper" should-not-run
  write_alt_shim "$home" "$wrapper"
  FM_HOME="$home" "$REGISTER" "$wrapper" >/dev/null \
    || fail "could not register before tamper"
  printf '# tampered\n' >> "$wrapper"
  set +e
  run_watch FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    > "$home/watch.out" 2> "$home/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "tampered watcher cycle failed (rc=$rc): $(cat "$home/watch.err")"
  assert_contains "$(cat "$home/watch.out")" "rejected unauthenticated state checks:" \
    "tampered target must be rejected"
  assert_not_contains "$(cat "$home/watch.out")" "should-not-run" \
    "tampered target must not execute"
  assert_contains "$(cat "$home/watch.out")" "re-register with bin/fm-x-watch-register.sh $wrapper" \
    "stale-target rejection must name the re-register command and bound path"
  pass "tampered registered target is rejected and names the re-register command"
}

test_bootstrap_preserves_valid_registration() {
  local home wrapper before after rc
  home=$(make_home boot-preserve)
  printf 'FMX_PAIRING_TOKEN=tok-preserve\n' > "$home/.env"
  wrapper="$home/fm-x-poll-harbor.sh"
  write_wrapper "$wrapper" alt-poll-ok
  write_alt_shim "$home" "$wrapper"
  FM_HOME="$home" "$REGISTER" "$wrapper" >/dev/null \
    || fail "could not register before bootstrap preserve"
  before=$(cat "$home/state/x-watch.check.sh")
  FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" >/dev/null 2>"$home/bootstrap.err" \
    || fail "bootstrap failed while preserving registration: $(cat "$home/bootstrap.err")"
  after=$(cat "$home/state/x-watch.check.sh")
  [ "$before" = "$after" ] || fail "bootstrap clobbered a still-valid registered shim"
  fmx_poll_shim_registered_valid "$home/state/x-watch.check.sh" "$home" "$ROOT" \
    || fail "preserved shim must still be a valid registration"
  ! fmx_poll_shim_stock_valid "$home/state/x-watch.check.sh" "$home" "$ROOT" \
    || fail "preserved registered shim must not match stock"
  set +e
  run_watch FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=2 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    > "$home/watch.out" 2> "$home/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "preserved watcher cycle failed (rc=$rc): $(cat "$home/watch.err")"
  assert_contains "$(cat "$home/watch.out")" "alt-poll-ok" \
    "bootstrap-preserved registration must still dispatch the bound target"
  pass "bootstrap regeneration preserves a valid registered variant"
}

test_bootstrap_replaces_stale_registration_with_stock() {
  local home wrapper
  home=$(make_home boot-stale)
  printf 'FMX_PAIRING_TOKEN=tok-stale\n' > "$home/.env"
  wrapper="$home/fm-x-poll-harbor.sh"
  write_wrapper "$wrapper" alt-poll-ok
  write_alt_shim "$home" "$wrapper"
  FM_HOME="$home" "$REGISTER" "$wrapper" >/dev/null \
    || fail "could not register before stale bootstrap"
  printf '# harbor redeploy\n' >> "$wrapper"
  FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" >/dev/null 2>"$home/bootstrap.err" \
    || fail "bootstrap failed while replacing stale registration: $(cat "$home/bootstrap.err")"
  fmx_poll_shim_stock_valid "$home/state/x-watch.check.sh" "$home" "$ROOT" \
    || fail "stale registration must be replaced with the stock shim"
  ! fmx_poll_shim_registered_valid "$home/state/x-watch.check.sh" "$home" "$ROOT" \
    || fail "stale binding must not remain valid after bootstrap"
  assert_present "$home/state/x-watch.poll-trust" \
    "bootstrap must not auto-delete an operator-written binding"
  pass "bootstrap replaces a stale registered variant with stock"
}

test_register_refuses_stock_shim() {
  local home err rc
  home=$(make_home refuse-stock)
  write_stock_shim "$home"
  write_wrapper "$home/wrapper.sh" unused
  set +e
  FM_HOME="$home" "$REGISTER" "$home/wrapper.sh" >"$home/out" 2>"$home/err"
  rc=$?
  set -e
  err=$(cat "$home/err")
  [ "$rc" -ne 0 ] || fail "register accepted a stock shim"
  assert_contains "$err" "alternate shim is required" \
    "register must refuse the stock identity"
  assert_absent "$home/state/x-watch.poll-trust" \
    "refused register must not create a binding"
  pass "register refuses to bind the stock Relay poll shim"
}

test_stock_shim_validates_through_watcher
test_registered_variant_validates_through_watcher
test_unregistered_rewrite_is_rejected
test_tampered_target_is_rejected_and_named
test_bootstrap_preserves_valid_registration
test_bootstrap_replaces_stale_registration_with_stock
test_register_refuses_stock_shim
