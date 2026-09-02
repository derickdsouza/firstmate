#!/usr/bin/env bash
# Behavior tests for bin/fm-fleet-watch-poller.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-watch-tests)
trap fm_test_cleanup EXIT

# --- fm-fleet-watch-poller status -------------------------------------------

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state/when" "$HOME_DIR/data/fleet-watch"

out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-watch-poller.sh" status)
printf '%s\n' "$out" | grep -q "fm-home: $HOME_DIR" || fail 'status names FM_HOME'
for w in run-drift book-sync model-drift login-watch; do
  printf '%s\n' "$out" | grep -q "$w spec=absent runner=dead" || fail "$w not absent in empty home"
done
pass 'fleet-watch-poller status on empty home'

# --- fm-fleet-watch-poller help ---------------------------------------------

"$ROOT/bin/fm-fleet-watch-poller.sh" help | grep -q 'run-drift' || fail 'poller help mentions run-drift'
pass 'fleet-watch-poller help'

# --- install-cron dedupe against the legacy wrapper -------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CRON_FILE="$TMP_ROOT/crontab.txt"
cat > "$FAKEBIN/crontab" <<SH
#!/usr/bin/env bash
# stub crontab: -l prints the seeded file, - replaces it from stdin.
CRON_FILE="$CRON_FILE"
if [ "\$1" = -l ]; then
  [ -f "\$CRON_FILE" ] && cat "\$CRON_FILE"
  exit 0
fi
if [ "\$1" = - ]; then
  cat > "\$CRON_FILE"
fi
SH
chmod +x "$FAKEBIN/crontab"

# A legacy data/fleet-watch wrapper line must count as the entry itself: the
# dedupe branch reports it and never appends a second line firing in lockstep.
printf '*/5 * * * * /opt/legacy-home/data/fleet-watch/fleet-watch-poller.sh >> /tmp/fleet-watch.log 2>&1\n' > "$CRON_FILE"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-watch-poller.sh" install-cron)
assert_contains "$out" 'cron entry already present' 'install-cron must dedupe the legacy wrapper line'
[ "$(grep -c . "$CRON_FILE")" = 1 ] || fail 'install-cron appended a second cron line despite the legacy entry'
pass 'install-cron dedupes legacy wrapper line'

# A fresh crontab still gets exactly one entry.
rm -f "$CRON_FILE"
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-watch-poller.sh" install-cron)
assert_contains "$out" 'installed cron:' 'install-cron must install on a fresh crontab'
[ "$(grep -c . "$CRON_FILE")" = 1 ] || fail 'install-cron wrote more than one cron line'
pass 'install-cron installs on fresh crontab'

# --- single-flight lock ------------------------------------------------------

# A held lock dir (no readable pid) makes poll exit 0 silently without arming:
# no log is written, so no reconcile or arm can have run.
mkdir -p "$HOME_DIR/state/fleet-watch-poller.lock"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-watch-poller.sh" poll
expect_code 0 $? 'poll under a held lock must exit 0'
assert_absent "$HOME_DIR/data/fleet-watch/poller.log" 'poll under a held lock must not arm or log'
pass 'held lock makes poll exit 0 without arming'

# --- login probe under a cron-like minimal environment -----------------------

# env -i reproduces cron: no ~/.local/bin, no nvm, no USER. The probe must
# still complete every Mac check, exit 0 or 1, and never hit an unbound
# variable (the 2026-08-31 report died with "v: unbound variable").
PROBE_OUT=$(env -i HOME="$HOME" PATH=/usr/bin:/bin FM_LOGIN_PROBE_SKIP_VPS=1 \
  /bin/bash "$ROOT/bin/fm-agent-login-probe.sh" 2>&1)
PROBE_RC=$?
case "$PROBE_RC" in
  0|1) ;;
  *) fail "probe minimal-env exit code $PROBE_RC outside 0..1" ;;
esac
case "$PROBE_OUT" in
  *'unbound variable'*) fail 'probe hit an unbound variable under the minimal env' ;;
esac
for agent in pi grok cursor claude; do
  printf '%s\n' "$PROBE_OUT" | grep -q "$agent@mac" || fail "probe minimal-env output missing a $agent@mac verdict"
done
pass 'login probe completes under minimal cron env'

printf 'done\n'
