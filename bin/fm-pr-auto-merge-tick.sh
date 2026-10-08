#!/usr/bin/env bash
# Attempt auto-merge for every armed GitHub PR poll (firstmate #14 watch wiring).
#
# Usage: fm-pr-auto-merge-tick.sh
#
# Kill switch: FM_PR_AUTO_MERGE defaults to on. Set to off|0|false|no to disable.
# Harbor merges are refused while HARBOR_DO_UNFREEZE is unset (freeze gate here
# and again inside bin/fm-pr-auto-merge.sh). Never wakes firstmate; prints one
# line per decision to stdout for the watcher triage log.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
AUTO="$SCRIPT_DIR/fm-pr-auto-merge.sh"

harbor_frozen() {
  case "${HARBOR_DO_UNFREEZE:-}" in
    1|true|yes|on|TRUE|YES|ON) return 1 ;;
    *) return 0 ;;
  esac
}

auto_merge_enabled() {
  case "${FM_PR_AUTO_MERGE:-on}" in
    0|false|no|off|FALSE|NO|OFF) return 1 ;;
    *) return 0 ;;
  esac
}

if ! auto_merge_enabled; then
  echo "auto-merge: skipped (FM_PR_AUTO_MERGE=${FM_PR_AUTO_MERGE:-off})"
  exit 0
fi

if [ ! -x "$AUTO" ]; then
  echo "auto-merge: skipped (fm-pr-auto-merge.sh missing or not executable)"
  exit 0
fi

[ -d "$STATE" ] || { echo "auto-merge: skipped (state dir missing)"; exit 0; }

found=0
for poll in "$STATE"/*.pr-poll; do
  [ -e "$poll" ] || continue
  [ ! -L "$poll" ] || continue
  id=$(basename "$poll" .pr-poll)
  # Sidecar layout: provider, url, host, path, number (one per line). Same as
  # bin/fm-pr-poll.sh. Refuse to read a doctored extra line.
  {
    IFS= read -r provider || continue
    IFS= read -r url || continue
    IFS= read -r host || continue
    IFS= read -r path || continue
    IFS= read -r number || continue
    if IFS= read -r _extra; then
      echo "auto-merge: skipped $id (sidecar has extra lines)"
      continue
    fi
  } < "$poll" || continue

  case "$provider" in
    github) ;;
    *)
      echo "auto-merge: skipped $id (provider=$provider)"
      continue
      ;;
  esac
  case "$url" in
    https://github.com/*/*/pull/[1-9]*) ;;
    *)
      echo "auto-merge: skipped $id (unparseable url)"
      continue
      ;;
  esac

  found=1
  repo=${path##*/}
  if [ "$repo" = harbor ] && harbor_frozen; then
    echo "auto-merge: refused freeze for $id $url (HARBOR_DO_UNFREEZE unset)"
    continue
  fi

  out=
  rc=0
  out=$("$AUTO" "$id" "$url" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "auto-merge: ok $id $url"
  else
    # Keep the refuse reason on one triage line (first error line preferred).
    reason=$(printf '%s\n' "$out" | grep -E '^(error:|fm-pr-auto-merge:)' | head -1)
    [ -n "$reason" ] || reason=$(printf '%s\n' "$out" | head -1)
    echo "auto-merge: refused $id $url — ${reason:-rc=$rc}"
  fi
done

if [ "$found" -eq 0 ]; then
  echo "auto-merge: idle (no armed GitHub PR polls)"
fi
exit 0
