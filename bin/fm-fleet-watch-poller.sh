#!/usr/bin/env bash
# Harness-independent fleet when-watch poller.
#
# Keeps the home's when-watch runners alive and arms any missing watch.
# Safe under cursor-agent, pi, grok, Claude Code, or any other primary harness:
# it only supervises bin/fm-procevent-when.sh children, not an agent session.
#
# Watches maintained:
#   run-drift, book-sync, model-drift, login-watch
#
# Concurrency: poll runs under a single-flight lock
# ($STATE/fleet-watch-poller.lock); a concurrent poll exits 0 silently, so
# overlapping cron lines can never both arm a watch. install-cron treats any
# crontab line invoking fleet-watch-poller.sh - the tracked bin path or the
# legacy data/fleet-watch wrapper - as already present, keeping cron one copy.
#
# Usage:
#   fm-fleet-watch-poller.sh              run reconcile + ensure (cron default)
#   fm-fleet-watch-poller.sh status       read-only runner/spec summary
#   fm-fleet-watch-poller.sh install-cron install a 5-minute crontab entry
#
# Environment:
#   FM_HOME              firstmate home (default: parent of bin/)
#   FM_STATE_OVERRIDE    state dir override (default: $FM_HOME/state)
#   FM_FLEET_WATCH_LOG   poller log path (default: $FM_HOME/data/fleet-watch/poller.log)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="${FM_FLEET_WATCH_LOG:-$FM_HOME/data/fleet-watch/poller.log}"
POLL_LOCK="$STATE/fleet-watch-poller.lock"
export FM_HOME

WATCHES=(run-drift book-sync model-drift login-watch)

stamp() { date '+%F %H:%M:%S %Z'; }

runner_alive() {  # <when-source-id> e.g. when-run-drift
  local sid=$1
  local runner_file="$STATE/procevent/${sid}.runner"
  local pid cmd pattern="$FM_HOME/bin/fm-procevent-when.sh run $sid"
  if [ -f "$runner_file" ]; then
    pid=$(cat "$runner_file" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) pid= ;;
    esac
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
      case "$cmd" in *"fm-procevent-when.sh run $sid"*) return 0 ;; esac
    fi
  fi
  pgrep -f "$pattern" >/dev/null 2>&1
}

arm_watch() {  # <short-name>
  local short=$1
  case "$short" in
    login-watch)
      "$SCRIPT_DIR/fm-procevent-when.sh" arm login-watch \
        --interval 3600 --stable 1 --deadline 172800 \
        --condition /bin/bash "$FM_HOME/data/login-watch/condition-9am.sh" \
        --action /bin/bash "$FM_HOME/data/login-watch/action-report.sh"
      ;;
    run-drift)
      "$SCRIPT_DIR/fm-procevent-when.sh" arm run-drift \
        --interval 900 --stable 1 --deadline 345600 \
        --condition /bin/bash "$FM_HOME/data/run-watch/condition-run-drift.sh" \
        --action /bin/bash "$FM_HOME/data/run-watch/action-report.sh"
      ;;
    book-sync)
      "$SCRIPT_DIR/fm-procevent-when.sh" arm book-sync \
        --interval 3600 --stable 2 --deadline 604800 \
        --condition /bin/bash "$FM_HOME/data/run-watch/condition-book-drift.sh" \
        --action /bin/bash "$FM_HOME/data/run-watch/action-book-drift.sh"
      ;;
    model-drift)
      "$SCRIPT_DIR/fm-procevent-when.sh" arm model-drift \
        --interval 86400 --stable 1 --deadline 604800 \
        --condition /bin/bash "$FM_HOME/data/model-watch/condition-catalog-drift.sh" \
        --action /bin/bash "$FM_HOME/data/model-watch/action-catalog-update.sh"
      ;;
    *)
      printf 'error: unknown watch: %s\n' "$short" >&2
      return 1
      ;;
  esac
}

retire_watch() {  # <short-name>
  local short=$1
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "$short" 2>/dev/null || true
}

ensure_watch() {  # <short-name> [reason]
  local short=$1 reason=${2:-runner missing}
  local fname="when-$short"
  local spec="$STATE/when/${fname}.spec"

  if runner_alive "$fname"; then
    return 0
  fi

  mkdir -p "$(dirname "$LOG")"
  printf '%s ensuring %s (%s)\n' "$(stamp)" "$short" "$reason" >>"$LOG"

  if [ -f "$spec" ]; then
    retire_watch "$short"
  fi

  if ! arm_watch "$short" >>"$LOG" 2>&1; then
    printf '%s arm failed: %s\n' "$(stamp)" "$short" >>"$LOG"
    return 1
  fi
  printf '%s armed: %s\n' "$(stamp)" "$short" >>"$LOG"
  return 0
}

cmd_status() {
  local short fname spec
  printf 'fm-home: %s\n' "$FM_HOME"
  for short in "${WATCHES[@]}"; do
    fname="when-$short"
    spec="$STATE/when/${fname}.spec"
    if runner_alive "$fname"; then
      runstate=alive
    else
      runstate=dead
    fi
    if [ -f "$spec" ]; then
      specstate=present
    else
      specstate=absent
    fi
    printf '%s spec=%s runner=%s\n' "$short" "$specstate" "$runstate"
  done
}

trim_log() {
  [ -f "$LOG" ] || return 0
  tail -200 "$LOG" >"${LOG}.tmp" && mv "${LOG}.tmp" "$LOG" 2>/dev/null || true
}

cmd_poll() {
  # Single-flight lock: mkdir is atomic, so exactly one poll owns the cycle and
  # every concurrent poll exits 0 silently. A lock stranded by a SIGKILLed
  # owner is reclaimed only when its recorded pid is provably dead, and via an
  # atomic rename so two reclaimers can never both win the fresh mkdir.
  mkdir -p "$STATE"
  if ! mkdir "$POLL_LOCK" 2>/dev/null; then
    local owner
    owner=$(cat "$POLL_LOCK/pid" 2>/dev/null || true)
    case "$owner" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    if kill -0 "$owner" 2>/dev/null; then
      exit 0
    fi
    if ! mv "$POLL_LOCK" "${POLL_LOCK}.stale.$$" 2>/dev/null; then
      exit 0
    fi
    rm -rf "${POLL_LOCK}.stale.$$"
    mkdir "$POLL_LOCK" 2>/dev/null || exit 0
  fi
  trap 'rm -rf "$POLL_LOCK"' EXIT INT TERM
  printf '%s\n' "$$" >"$POLL_LOCK/pid"

  mkdir -p "$(dirname "$LOG")"
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >>"$LOG" 2>&1 || true

  local short fname spec
  for short in "${WATCHES[@]}"; do
    fname="when-$short"
    spec="$STATE/when/${fname}.spec"
    if runner_alive "$fname"; then
      continue
    fi
    if [ -f "$spec" ]; then
      ensure_watch "$short" 'runner exited'
    else
      ensure_watch "$short" 'first arm'
    fi
  done

  "$SCRIPT_DIR/fm-procevent.sh" reconcile >>"$LOG" 2>&1 || true
  trim_log
}

cmd_install_cron() {
  local line="*/5 * * * * $SCRIPT_DIR/fm-fleet-watch-poller.sh >> $LOG 2>&1"
  local existing
  existing=$(crontab -l 2>/dev/null || true)
  # Dedupe on the script name: any line invoking fleet-watch-poller.sh counts,
  # which covers both the tracked bin path and the legacy data/fleet-watch
  # wrapper that execs it, so a stale legacy entry is never joined by a second
  # copy firing at the same second.
  if printf '%s\n' "$existing" | grep -Fq 'fleet-watch-poller.sh'; then
    printf 'cron entry already present\n'
    return 0
  fi
  {
    printf '%s\n' "$existing"
    printf '%s\n' "$line"
  } | crontab -
  printf 'installed cron: %s\n' "$line"
}

case "${1:-poll}" in
  status) cmd_status ;;
  install-cron) cmd_install_cron ;;
  poll|'') cmd_poll ;;
  -h|--help|help)
    awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
    ;;
  *)
    printf 'error: unknown command: %s\n' "$1" >&2
    exit 2
    ;;
esac
