#!/usr/bin/env bash
# fm-spawn-gate-lib.sh — optional external spawn gate hook (FM_SPAWN_GATE_CMD).
#
# Why: firstmate's own crew spawns had no fleet cap in code. A host can now set
# one command that every fresh spawn must pass (harbor: the shared crew + CI slot
# budget on harbor-vps, fleet/bin/harbor-slot-gate.sh fm-hook).
#
# Contract:
#   FM_SPAWN_GATE_CMD unset or empty -> no-op (today's behaviour).
#   Set -> split on whitespace (no shell eval) and run as
#     <cmd...> acquire <task-id>   in fm-spawn.sh, fresh ship/scout spawns only,
#                                  under the task-set lock, before any endpoint,
#                                  worktree, or record exists. Non-zero refuses
#                                  the spawn; the hook's output is in the error.
#     <cmd...> release <task-id>   in fm-teardown.sh after the task record is
#                                  removed (ship/scout only). A failed release
#                                  warns and never fails the teardown.
#   A spawn that fails after acquire does not call release; the hook owner reaps
#   (harbor-slot-gate.sh drops a crew slot whose task record is absent after 10 min).
#   Relaunch and secondmate spawns are exempt (same rule as the away spend cap).

FM_SPAWN_GATE_OUT=

# fm_spawn_gate_run <acquire|release> <task-id>: rc of the hook (0 when unset).
fm_spawn_gate_run() {
  local rc=0
  local -a cmd=()
  FM_SPAWN_GATE_OUT=
  [ -n "${FM_SPAWN_GATE_CMD:-}" ] || return 0
  read -r -a cmd <<<"$FM_SPAWN_GATE_CMD"
  [ "${#cmd[@]}" -gt 0 ] || return 0
  FM_SPAWN_GATE_OUT=$("${cmd[@]}" "$1" "$2" 2>&1) || rc=$?
  return "$rc"
}

# fm_spawn_gate_acquire <task-id>: 0 allow; 1 refuse (message on stderr).
fm_spawn_gate_acquire() {
  local rc=0
  fm_spawn_gate_run acquire "$1" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "error: spawn refused by FM_SPAWN_GATE_CMD (rc=$rc): ${FM_SPAWN_GATE_OUT:-no output}" >&2
  return 1
}

# fm_spawn_gate_release <task-id>: always 0.
fm_spawn_gate_release() {
  fm_spawn_gate_run release "$1" \
    || echo "warn: FM_SPAWN_GATE_CMD release failed for $1: ${FM_SPAWN_GATE_OUT:-no output}" >&2
  return 0
}
