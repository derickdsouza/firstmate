#!/usr/bin/env bash
# fm-secondmate-health-lib.sh - alive-but-stuck classification for secondmates.
#
# Process-alive is not health. An idle secondmate pane is healthy by design,
# but an unacknowledged steering inbox past the existing re-ring ladder, or a
# repeating runtime-fault capture (a Node missing-module loop after a harness
# upgrade under a long-lived process), is stuck and authorizes replace-relaunch.
#
# This library owns only the classifiers. bin/fm-remote-secondmate-control.sh
# health/inbox-tick/relaunch and bin/fm-bootstrap.sh's liveness sweep consume
# them. Sourced; no side effects on source.
#
# Tunables:
#   FM_SECONDMATE_INBOX_STUCK_SECS
#     default: fm_task_inbox_grace_secs * fm_task_inbox_ring_max
#     (the full ladder budget). An unhandled record older than this is stuck
#     even if the ladder was never rung, so a session-start sweep can replace a
#     helper whose mail has sat for days without waiting for three new rings.

_FM_SECONDMATE_HEALTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_FM_SECONDMATE_HEALTH_LIB_DIR/fm-task-inbox-lib.sh"

# fm_secondmate_inbox_stuck_secs: the age at which unacked mail is stuck.
fm_secondmate_inbox_stuck_secs() {
  local override=${FM_SECONDMATE_INBOX_STUCK_SECS:-} grace max
  case "$override" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$override"; return 0 ;;
  esac
  grace=$(fm_task_inbox_grace_secs)
  max=$(fm_task_inbox_ring_max)
  printf '%s\n' $((grace * max))
}

# fm_secondmate_inbox_stuck <state-dir> <task-id>
# True when the oldest escalation-tracked unhandled record is at least
# fm_secondmate_inbox_stuck_secs old. An empty inbox is not stuck.
fm_secondmate_inbox_stuck() {
  local state=$1 task=$2 oldest age budget
  oldest=$(fm_task_inbox_oldest_unhandled "$state" "$task") || return 1
  age=$(fm_path_age "$oldest")
  budget=$(fm_secondmate_inbox_stuck_secs)
  [ "$age" -ge "$budget" ]
}

# fm_secondmate_capture_has_runtime_fault
# True when capture text shows a repeating Node missing-module fault, the
# failure mode of a harness upgraded on disk under a still-running process.
# Reads stdin. Portable: the string is the Node ESM loader, not a TUI glyph.
fm_secondmate_capture_has_runtime_fault() {
  local text
  text=$(cat)
  case "$text" in
    *'Cannot find module'*dist/bundle/chunks/*.js*) return 0 ;;
  esac
  return 1
}

# fm_secondmate_health_from_parts <agent-state> <inbox-stuck 0|1> <runtime-fault 0|1>
# Prints one token: the agent-state, or stuck:unacked-inbox / stuck:runtime-fault
# when the process is present but not healthy. dead/missing/unreadable pass
# through unchanged so callers keep using the recovery-grade vocabulary.
fm_secondmate_health_from_parts() {
  local agent_state=$1 inbox_stuck=$2 runtime_fault=$3
  case "$agent_state" in
    dead|missing)
      printf '%s\n' "$agent_state"
      return 0
      ;;
  esac
  if [ "$inbox_stuck" = 1 ]; then
    printf 'stuck:unacked-inbox\n'
    return 0
  fi
  if [ "$agent_state" = alive ] && [ "$runtime_fault" = 1 ]; then
    printf 'stuck:runtime-fault\n'
    return 0
  fi
  printf '%s\n' "$agent_state"
}
