#!/usr/bin/env bash
# Agent-agnostic login health probe for the fleet's supported harness CLIs:
# pi, grok, cursor-agent, and claude (Claude Code).
#
# Prints one OK or FAIL line per target. Exit 0 when every probe passes;
# exit 1 when at least one needs (re)login. Safe to run from cron, when-watches,
# or an interactive shell on macOS and Linux.
#
# Environment:
#   FM_LOGIN_PROBE_VPS_SSH  SSH host alias for optional VPS probes (default:
#                           ghwave when BatchMode ssh succeeds; empty disables).
#   FM_LOGIN_PROBE_SKIP_VPS   1 = skip VPS probes even when ssh is configured.
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

check_mac_pi() {
  if ! command -v pi >/dev/null 2>&1; then
    probe_fail mac pi 'pi not installed'
    return
  fi
  if /bin/zsh -l -c 'pi --list-models 2>/dev/null' | grep -q '^zai'; then
    probe_ok mac pi
  else
    probe_fail mac pi 'needs re-login'
  fi
}

check_mac_grok() {
  if ! command -v grok >/dev/null 2>&1; then
    probe_fail mac grok 'grok not installed'
    return
  fi
  if grok models 2>/dev/null | grep -q 'grok-'; then
    probe_ok mac grok
  else
    probe_fail mac grok 'needs re-login'
  fi
}

check_mac_cursor() {
  if ! command -v cursor-agent >/dev/null 2>&1; then
    probe_fail mac cursor 'cursor-agent not installed'
    return
  fi
  if cursor-agent --list-models 2>/dev/null | grep -q 'composer'; then
    probe_ok mac cursor
  else
    probe_fail mac cursor 'needs re-login'
  fi
}

check_mac_claude() {
  if [ -f "${HOME}/.claude/.credentials.json" ] || [ -d "${HOME}/.claude/plugins" ]; then
    probe_ok mac claude
    return
  fi
  if command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1; then
    probe_ok mac claude
  else
    probe_fail mac claude 'needs re-login'
  fi
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

check_mac_pi
check_mac_grok
check_mac_cursor
check_mac_claude

if vps_ssh=$(resolve_vps_ssh); then
  [ -n "$vps_ssh" ] && check_vps "$vps_ssh"
fi

exit "$FAIL"
