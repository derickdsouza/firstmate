#!/usr/bin/env bash
# Agent-agnostic login health probe for the fleet's supported harness CLIs:
# pi, grok, cursor-agent, and claude (Claude Code).
#
# Prints one OK or FAIL line per target. Exit 0 when every probe passes;
# exit 1 when at least one needs (re)login. Safe to run from cron, when-watches,
# or an interactive shell on macOS and Linux.
#
# Local host label is "mac" on Darwin and "vps" on Linux. Darwin uses
# /bin/zsh -l for pi so login-shell keychain loaders run; Linux uses the
# hardened PATH (nvm / ~/.local/bin) because zsh is not required there.
# Remote VPS probes over ssh run only from Darwin, so a Linux host (this
# machine is the VPS) does not ssh to itself.
#
# Environment:
#   FM_LOGIN_PROBE_VPS_SSH  SSH host alias for optional VPS probes (default:
#                           ghwave when BatchMode ssh succeeds; empty disables).
#   FM_LOGIN_PROBE_SKIP_VPS   1 = skip remote VPS probes even when ssh is configured.
#
# Cron hardening: cron's PATH lacks ~/.local/bin, nvm, and Homebrew roots, and
# a minimal environment may not export USER, which login-shell keychain
# loaders need. Before probing, USER/LOGNAME are defaulted when unset and the
# standard CLI install roots (~/.local/bin, nvm per-version bin, ~/.grok/bin,
# Homebrew) are prepended to PATH, so "not installed" is reported only when
# the CLI is truly absent from a login shell. Every variable expansion is
# guarded for set -u under an env -i style minimal environment.
set -u

# --- cron/minimal-environment hardening --------------------------------------

USER="${USER:-$(id -un)}"
LOGNAME="${LOGNAME:-$USER}"
export USER LOGNAME
for _dir in "$HOME"/.local/bin "$HOME"/.nvm/versions/node/*/bin "$HOME"/.grok/bin /opt/homebrew/bin /usr/local/bin; do
  [ -d "$_dir" ] && PATH="$_dir:$PATH"
done
export PATH

FAIL=0

local_host_label() {
  case "$(uname -s)" in
    Darwin) printf 'mac\n' ;;
    *) printf 'vps\n' ;;
  esac
}

probe_ok() {  # <host-label> <agent-label>
  printf 'OK   %s@%s\n' "$2" "$1"
}

probe_fail() {  # <host-label> <agent-label> [reason]
  printf 'FAIL %s@%s%s\n' "$2" "$1" "${3:+ ($3)}"
  FAIL=1
}

has_stdout() {  # <command...>
  local out
  out=$("$@" 2>/dev/null) || return 1
  [ -n "$out" ]
}

# Catalog probe with actionable FAIL detail (firstmate #10): a FAIL must
# say WHY. Exit 127 = the CLI resolved in the probe's shell but not in the
# invocation context (login shell / PATH reset under the when-watch runner);
# any other non-zero exit carries the code plus first stderr bytes (auth or
# runtime fault — the only real 'needs re-login' family); exit 0 with no
# pattern match is a catalog fetch that returned nothing usable.
check_catalog_match() {  # <host-label> <agent> <grep-pattern> <command...>
  local host=$1 agent=$2 pattern=$3
  shift 3
  local out rc errfile err
  errfile=$(mktemp)
  out=$("$@" 2>"$errfile"); rc=$?
  err=$(head -c 120 "$errfile" | tr '\n' ' ')
  rm -f "$errfile"
  if [ "$rc" -eq 127 ]; then
    probe_fail "$host" "$agent" "$agent not on PATH in this invocation (exit 127)"
  elif [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "$pattern"; then
    probe_ok "$host" "$agent"
  elif [ "$rc" -ne 0 ]; then
    probe_fail "$host" "$agent" "command failed (exit $rc${err:+: $err})"
  else
    probe_fail "$host" "$agent" "catalog fetch failed (no match for '$pattern', exit 0${err:+: $err})"
  fi
}

# pi on Darwin needs a login zsh so keychain-backed env is present. Linux
# uses the hardened PATH (nvm / ~/.local/bin); zsh is not required.
# (Catalog invocation lives in check_local_pi so its exit code and stderr
# reach check_catalog_match — see firstmate #10.)

check_local_pi() {  # <host-label>
  local host=$1
  if ! command -v pi >/dev/null 2>&1; then
    probe_fail "$host" pi 'pi not installed'
    return
  fi
  # pi on Darwin needs a login zsh so keychain-backed env is present. Linux
  # uses the hardened PATH (nvm / ~/.local/bin); zsh is not required.
  if [ "$(uname -s)" = Darwin ] && [ -x /bin/zsh ]; then
    check_catalog_match "$host" pi '^zai' /bin/zsh -l -c 'pi --list-models'
  else
    check_catalog_match "$host" pi '^zai' pi --list-models
  fi
}

check_local_grok() {  # <host-label>
  local host=$1
  if ! command -v grok >/dev/null 2>&1; then
    probe_fail "$host" grok 'grok not installed'
    return
  fi
  check_catalog_match "$host" grok 'grok-' grok models
}

check_local_cursor() {  # <host-label>
  local host=$1
  if ! command -v cursor-agent >/dev/null 2>&1; then
    probe_fail "$host" cursor 'cursor-agent not installed'
    return
  fi
  check_catalog_match "$host" cursor 'composer' cursor-agent --list-models
}

check_local_claude() {  # <host-label>
  local host=$1
  if [ -f "${HOME}/.claude/.credentials.json" ] || [ -d "${HOME}/.claude/plugins" ]; then
    probe_ok "$host" claude
    return
  fi
  if command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; then
    probe_ok "$host" claude
  else
    probe_fail "$host" claude 'needs re-login'
  fi
}

check_local() {  # <host-label>
  local host=$1
  check_local_pi "$host"
  check_local_grok "$host"
  check_local_cursor "$host"
  check_local_claude "$host"
}

check_vps() {  # <ssh-alias>
  local alias=$1
  [ -n "$alias" ] || return 1
  local -a ssh=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$alias")
  if ! has_stdout "${ssh[@]}" true; then
    probe_fail vps pi 'ssh unreachable'
    probe_fail vps grok 'ssh unreachable'
    probe_fail vps cursor 'ssh unreachable'
    probe_fail vps claude 'ssh unreachable'
    return
  fi
  if has_stdout "${ssh[@]}" 'source /root/.bashrc 2>/dev/null; /root/.nvm/current/bin/pi --list-models 2>/dev/null | grep -c "^zai"'; then
    probe_ok vps pi
  else
    probe_fail vps pi 'needs re-login'
  fi
  if has_stdout "${ssh[@]}" 'source /root/.bashrc 2>/dev/null; grok models 2>/dev/null | grep -c grok-'; then
    probe_ok vps grok
  else
    probe_fail vps grok 'needs re-login'
  fi
  # shellcheck disable=SC2016  # $HOME/$PATH expand on the remote host
  if has_stdout "${ssh[@]}" 'export PATH=$HOME/.local/bin:$PATH; cursor-agent --list-models 2>/dev/null | grep -c composer'; then
    probe_ok vps cursor
  else
    probe_fail vps cursor 'needs re-login'
  fi
  if has_stdout "${ssh[@]}" '[ -f /root/.claude/.credentials.json ] && echo 1'; then
    probe_ok vps claude
  else
    probe_fail vps claude 'needs re-login'
  fi
}

resolve_vps_ssh() {
  if [ "${FM_LOGIN_PROBE_SKIP_VPS:-}" = 1 ]; then
    return 1
  fi
  if [ -n "${FM_LOGIN_PROBE_VPS_SSH:-}" ]; then
    printf '%s\n' "$FM_LOGIN_PROBE_VPS_SSH"
    return 0
  fi
  if ssh -o BatchMode=yes -o ConnectTimeout=3 ghwave true >/dev/null 2>&1; then
    printf 'ghwave\n'
    return 0
  fi
  return 1
}

LOCAL_LABEL=$(local_host_label)
check_local "$LOCAL_LABEL"

# Remote VPS probes belong on Darwin. Linux already is the VPS.
if [ "$LOCAL_LABEL" = mac ]; then
  if vps_ssh=$(resolve_vps_ssh); then
    [ -n "$vps_ssh" ] && check_vps "$vps_ssh"
  fi
fi

exit "$FAIL"
