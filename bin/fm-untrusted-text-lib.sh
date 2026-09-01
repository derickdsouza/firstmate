#!/usr/bin/env bash
# fm-untrusted-text-lib.sh - deterministic sanitizer for untrusted agent-facing text.
#
# This file is the single owner of the transform that length-bounds untrusted
# prose and makes injection payloads inert before they are stored or relayed
# into instructions. It is both a source-safe library and a CLI.
#
# Public contract:
#   Output is at most FM_UNTRUSTED_TEXT_CAP characters (8192), counting
#   Unicode scalars under a UTF-8 locale, never splitting a multibyte character.
#   Over-cap input is cut and then FM_UNTRUSTED_TEXT_SUFFIX is appended inside
#   that same cap. HTML comments are removed; an unclosed comment drops the
#   remainder. Invisible format characters used to hide prefixes are stripped,
#   while U+200D ZWJ is kept so emoji sequences stay intact. Exact operational
#   prefixes owned by bin/fm-operational-input.sh, plus the ASCII FIRSTMATE_OP:
#   look-alike, are replaced with [op] . Line-leading system/assistant/user
#   role markers, including an optional markdown heading or bullet, are
#   replaced with [role] . ChatML-style special tokens are removed. The
#   transform is pure text: stable input yields stable output, and sanitizing
#   already-sanitized text is a fixed point.
#
# Wired intake: bin/fm-x-poll.sh applies this transform to mention .text,
# .in_reply_to.text, and each .in_reply_to_chain[].text before the inbox stash.
# Other home intakes found and not wired: captain inbox notes and voice
# handover (bin/fm-inbox.sh) are trusted-channel captain text; process-event
# captured results are adapter-owned evidence, not rewritten into operational
# input; this repo has no script that ingests GitHub reviewer comment bodies
# into agent-facing instructions.
#
# Usage:
#   . bin/fm-untrusted-text-lib.sh
#   fm_sanitize_untrusted_text_var "<text>"   # result in FM_UNTRUSTED_TEXT
#   fm_sanitize_untrusted_text "<text>"       # result on stdout, no added newline
#   bin/fm-untrusted-text-lib.sh              # sanitize stdin
#   bin/fm-untrusted-text-lib.sh --file PATH  # sanitize file contents
#   bin/fm-untrusted-text-lib.sh -- ARG...    # sanitize joined arguments
#   bin/fm-untrusted-text-lib.sh ARG...       # sanitize joined arguments
#
# Bash 3.2 compatible. No model calls. No persistent state.

# shellcheck shell=bash

FM_UNTRUSTED_TEXT_CAP=8192
FM_UNTRUSTED_TEXT_SUFFIX=' [truncated]'
FM_UNTRUSTED_ROLE_STANDIN='[role] '
FM_UNTRUSTED_OP_STANDIN='[op] '

_FM_UNTRUSTED_TEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_OPERATIONAL_PREFIX+x}" ]; then
  # shellcheck source=bin/fm-operational-input.sh
  . "$_FM_UNTRUSTED_TEXT_LIB_DIR/fm-operational-input.sh"
fi

fm_untrusted_text_utf8_locale() {
  local saved=${LC_ALL:-${LANG:-}}
  case "$saved" in
    C|POSIX|'') printf '%s\n' C.UTF-8 ;;
    *) printf '%s\n' "$saved" ;;
  esac
}

fm_untrusted_strip_html_comments_var() {
  local text=$1 prefix rest guard=0
  while :; do
    case "$text" in
      *'<!--'*) ;;
      *) break ;;
    esac
    prefix=${text%%'<!--'*}
    rest=${text#*'<!--'}
    case "$rest" in
      *'-->'*) text="${prefix}${rest#*'-->'}" ;;
      *) text=$prefix; break ;;
    esac
    guard=$((guard + 1))
    [ "$guard" -lt 10000 ] || break
  done
  FM_UNTRUSTED_TEXT=$text
}

fm_untrusted_strip_format_chars_var() {
  local text=$1 c
  # Strip Cf / bidi / BOM / soft-hyphen hides. Do not strip U+200D ZWJ.
  for c in \
    $'\xE2\x80\x8B' $'\xE2\x80\x8C' $'\xE2\x81\xA0' $'\xE2\x81\xA3' \
    $'\xEF\xBB\xBF' $'\xE2\x80\x8E' $'\xE2\x80\x8F' \
    $'\xE2\x80\xAA' $'\xE2\x80\xAB' $'\xE2\x80\xAC' $'\xE2\x80\xAD' $'\xE2\x80\xAE' \
    $'\xE2\x81\xA6' $'\xE2\x81\xA7' $'\xE2\x81\xA8' $'\xE2\x81\xA9' \
    $'\xC2\xAD'
  do
    text=${text//"$c"/}
  done
  FM_UNTRUSTED_TEXT=$text
}

fm_untrusted_strip_special_tokens_var() {
  local text=$1 c
  for c in \
    '<|im_start|>' '<|im_end|>' '<|system|>' '<|user|>' '<|assistant|>' \
    '<|endoftext|>' '[INST]' '[/INST]' '<<SYS>>' '<</SYS>>'
  do
    text=${text//"$c"/}
  done
  FM_UNTRUSTED_TEXT=$text
}

fm_untrusted_strip_operational_prefixes_var() {
  local text=$1
  text=${text//"$FM_OPERATIONAL_PREFIX"/$FM_UNTRUSTED_OP_STANDIN}
  text=${text//"$FM_FROMFIRST_MARK"/$FM_UNTRUSTED_OP_STANDIN}
  text=${text//"$FM_FROMFIRST_LABEL"/$FM_UNTRUSTED_OP_STANDIN}
  text=${text//FIRSTMATE_OP: /$FM_UNTRUSTED_OP_STANDIN}
  text=${text//FIRSTMATE_OP:/$FM_UNTRUSTED_OP_STANDIN}
  text=${text//"$FM_LEGACY_WATCHER_PREFIX"/$FM_UNTRUSTED_OP_STANDIN}
  FM_UNTRUSTED_TEXT=$text
}

# Neutralize consecutive line-leading system/assistant/user role markers.
# Optional markdown heading hashes and a single bullet stay in the lead.
fm_untrusted_neutralize_one_line() {
  local line=$1 lead body sp rest name n prefix lowered after aftersp
  line=${line%$'\r'}
  lead=${line%%[![:space:]]*}
  body=${line#"$lead"}
  while [ "${body#"#"}" != "$body" ]; do
    lead="${lead}#"
    body=${body#"#"}
  done
  sp=${body%%[![:space:]]*}
  lead="${lead}${sp}"
  body=${body#"$sp"}
  case "$body" in
    '- '*|'* '*|'+ '*)
      lead="${lead}${body:0:2}"
      body=${body:2}
      ;;
  esac
  rest=$body
  body=
  while :; do
    for name in system assistant user; do
      n=${#name}
      prefix=${rest:0:$n}
      lowered=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')
      if [ "$lowered" = "$name" ]; then
        after=${rest:$n}
        aftersp=${after%%[![:space:]]*}
        after=${after#"$aftersp"}
        case "$after" in
          :*)
            after=${after#:}
            after=${after#"${after%%[![:space:]]*}"}
            body="${body}${FM_UNTRUSTED_ROLE_STANDIN}"
            rest=$after
            continue 2
            ;;
        esac
      fi
    done
    break
  done
  FM_UNTRUSTED_LINE="${lead}${body}${rest}"
}

fm_untrusted_neutralize_role_lines_var() {
  local text=$1 out="" first=1 line
  FM_UNTRUSTED_TEXT=$text
  [ -n "$text" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    fm_untrusted_neutralize_one_line "$line"
    if [ "$first" -eq 1 ]; then
      out=$FM_UNTRUSTED_LINE
      first=0
    else
      out="${out}"$'\n'"${FM_UNTRUSTED_LINE}"
    fi
  done < <(printf '%s' "$text")
  FM_UNTRUSTED_TEXT=$out
}

fm_untrusted_truncate_var() {
  local text=$1 max=${2:-$FM_UNTRUSTED_TEXT_CAP} keep loc
  loc=$(fm_untrusted_text_utf8_locale)
  local LC_ALL=$loc
  if [ "${#text}" -le "$max" ]; then
    FM_UNTRUSTED_TEXT=$text
    return 0
  fi
  keep=$((max - ${#FM_UNTRUSTED_TEXT_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  FM_UNTRUSTED_TEXT="${text:0:$keep}$FM_UNTRUSTED_TEXT_SUFFIX"
}

fm_sanitize_untrusted_text_var() {
  local text=${1-}
  fm_untrusted_strip_html_comments_var "$text"
  fm_untrusted_strip_format_chars_var "$FM_UNTRUSTED_TEXT"
  fm_untrusted_strip_special_tokens_var "$FM_UNTRUSTED_TEXT"
  fm_untrusted_strip_operational_prefixes_var "$FM_UNTRUSTED_TEXT"
  fm_untrusted_neutralize_role_lines_var "$FM_UNTRUSTED_TEXT"
  fm_untrusted_truncate_var "$FM_UNTRUSTED_TEXT"
}

fm_sanitize_untrusted_text() {
  fm_sanitize_untrusted_text_var "${1-}"
  printf '%s' "$FM_UNTRUSTED_TEXT"
}

fm_untrusted_text_usage() {
  cat <<'EOF'
Usage:
  bin/fm-untrusted-text-lib.sh                 sanitize stdin
  bin/fm-untrusted-text-lib.sh --file PATH     sanitize file contents
  bin/fm-untrusted-text-lib.sh -- ARG...       sanitize joined arguments
  bin/fm-untrusted-text-lib.sh ARG...          sanitize joined arguments

Deterministic length-bound sanitizer for untrusted agent-facing text.
The transform, cap, and wired intakes are owned by this file's header.
EOF
}

fm_untrusted_text_main() {
  local input
  case "${1-}" in
    -h|--help|help)
      fm_untrusted_text_usage
      return 0
      ;;
    --file)
      [ "$#" -eq 2 ] && [ -n "${2-}" ] && [ -f "$2" ] && [ ! -L "$2" ] || {
        fm_untrusted_text_usage >&2
        return 2
      }
      input=$(cat -- "$2"; printf x)
      input=${input%x}
      ;;
    --)
      shift
      input="$*"
      ;;
    '')
      input=$(cat; printf x)
      input=${input%x}
      ;;
    *)
      input="$*"
      ;;
  esac
  fm_sanitize_untrusted_text_var "$input"
  printf '%s' "$FM_UNTRUSTED_TEXT"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_untrusted_text_main "$@"
  exit $?
fi
