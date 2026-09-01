#!/usr/bin/env bash
# Bind the current alternate Relay poll shim and its exec target.
# Usage: fm-x-watch-register.sh <absolute-exec-target>
#
# Homes without a registration keep the stock generated shim and byte-static
# dispatch. This command is the only writer of the binding; bootstrap never
# creates it. The watcher and bootstrap both honor a still-matching binding and
# treat a stale one as unauthenticated (bootstrap then regenerates stock).
#
# Binding record: state/x-watch.poll-trust, mode 0600, never auto-created.
# Four lines and no extra:
#   fm-x-watch-poll-v1
#   <sha256 of current state/x-watch.check.sh>
#   <absolute path of the exec target>
#   <sha256 of that target's current bytes>
#
# The shim must already be the alternate (not stock). The target must be an
# absolute regular non-symlink file outside state/. Re-running overwrites the
# binding with the current bytes. bin/fm-x-lib.sh is the validator for this
# record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"

usage() {
  echo "usage: fm-x-watch-register.sh <absolute-exec-target>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
case "$1" in
  -h|--help) usage ;;
esac

TARGET=$1
CHECK="$STATE/x-watch.check.sh"
TRUST="$STATE/x-watch.poll-trust"

[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: poll shim is unavailable" >&2; exit 1; }
fmx_poll_exec_target_path_valid "$TARGET" \
  || { echo "error: exec target must be an absolute path" >&2; exit 1; }
case "$TARGET" in
  "$STATE"|"$STATE"/*)
    echo "error: exec target must not live under state/" >&2
    exit 1
    ;;
esac
[ "$TARGET" != "$CHECK" ] || { echo "error: exec target must not be the poll shim" >&2; exit 1; }
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] \
  || { echo "error: exec target is unavailable" >&2; exit 1; }

STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: poll shim is unavailable" >&2; exit 1; }
if fmx_poll_shim_stock_valid "$CHECK" "$FM_HOME" "$FM_ROOT"; then
  echo "error: shim matches the stock Relay poll identity; an alternate shim is required" >&2
  exit 1
fi
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: poll trust path is unavailable" >&2; exit 1; }

SHIM_HASH=$(fmx_sha256 "$CHECK") || { echo "error: poll shim hash is unavailable" >&2; exit 1; }
TARGET_HASH=$(fmx_sha256 "$TARGET") || { echo "error: exec target hash is unavailable" >&2; exit 1; }

umask 077
TMP=$(mktemp "$STATE/.fm-x-watch-poll-trust.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
printf '%s\n%s\n%s\n%s\n' fm-x-watch-poll-v1 "$SHIM_HASH" "$TARGET" "$TARGET_HASH" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
fmx_poll_shim_registered_valid "$CHECK" "$FM_HOME" "$FM_ROOT" \
  || { rm -f -- "$TRUST"; echo "error: poll shim registration is invalid" >&2; exit 1; }
printf 'registered: state/x-watch.check.sh -> %s\n' "$TARGET"
