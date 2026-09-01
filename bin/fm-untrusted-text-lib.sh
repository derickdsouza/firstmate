#!/usr/bin/env bash
# fm-untrusted-text-lib.sh - deterministic sanitizer for untrusted agent-facing text.
#
# This file is the single owner of the transform that length-bounds untrusted
# prose and makes injection payloads inert before they are stored or relayed
# into instructions. It is both a source-safe library and a CLI.
#
# Public contract:
#   Output is at most FM_UNTRUSTED_TEXT_CAP characters (8192), counting
#   Unicode scalars by walking UTF-8 bytes so a missing UTF-8 locale cannot
#   switch the cap to byte indexing or split a multibyte character.
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

# Every scalar POSIX [[:space:]] covers in ASCII, plus every code point
# Unicode gives White_Space=Yes outside ASCII, as UTF-8 byte sequences built
# from octal escapes so each entry stays reviewable in source (the same list
# and reason as bin/fm-composer-lib.sh, issue #1988): the daemon runs this
# transform under LC_ALL=C, where [[:space:]] misses U+3000 and friends, so
# whitespace classification here must not depend on the ambient locale.
# U+200B ZERO WIDTH SPACE is deliberately absent (White_Space=No) and is
# handled by the invisible-format strip instead.
FM_UNTRUSTED_WS_SCALARS=(' ' $'\t' $'\v' $'\f' $'\r')
for _fm_untrusted_ws_octal in \
  '\0302\0205' '\0302\0240' '\0341\0232\0200' \
  '\0342\0200\0200' '\0342\0200\0201' '\0342\0200\0202' '\0342\0200\0203' \
  '\0342\0200\0204' '\0342\0200\0205' '\0342\0200\0206' '\0342\0200\0207' \
  '\0342\0200\0210' '\0342\0200\0211' '\0342\0200\0212' \
  '\0342\0200\0250' '\0342\0200\0251' '\0342\0200\0257' \
  '\0342\0201\0237' '\0343\0200\0200'; do
  printf -v _fm_untrusted_ws_utf8 '%b' "$_fm_untrusted_ws_octal"
  FM_UNTRUSTED_WS_SCALARS+=("$_fm_untrusted_ws_utf8")
done
unset -v _fm_untrusted_ws_octal _fm_untrusted_ws_utf8

_FM_UNTRUSTED_TEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_OPERATIONAL_PREFIX+x}" ]; then
  # shellcheck source=bin/fm-operational-input.sh
  . "$_FM_UNTRUSTED_TEXT_LIB_DIR/fm-operational-input.sh"
fi

# Byte length of the first `max` Unicode scalars in `text`.
# Walks UTF-8 under LC_ALL=C so ${#} and ${var:n:m} stay byte-indexed.
# Incomplete trailing sequences are omitted rather than emitted as invalid UTF-8.
# Sets FM_UNTRUSTED_UTF8_BYTES.
fm_untrusted_utf8_prefix_bytes() {
  local text=$1 max=$2
  local LC_ALL=C
  local i=0 byte_len=${#text} count=0 rem seq ord b
  while [ "$count" -lt "$max" ] && [ "$i" -lt "$byte_len" ]; do
    rem=$((byte_len - i))
    b=${text:i:1}
    # printf -v is a builtin; a command substitution here forks once per scalar
    # and can blow the 30s fm-x-poll timeout on over-cap C-locale input.
    printf -v ord '%d' "'$b"
    if [ "$ord" -lt 128 ]; then
      seq=1
    elif [ "$ord" -ge 194 ] && [ "$ord" -le 223 ]; then
      seq=2
    elif [ "$ord" -ge 224 ] && [ "$ord" -le 239 ]; then
      seq=3
    elif [ "$ord" -ge 240 ] && [ "$ord" -le 244 ]; then
      seq=4
    else
      seq=1
    fi
    if [ "$seq" -gt "$rem" ]; then
      break
    fi
    i=$((i + seq))
    count=$((count + 1))
  done
  FM_UNTRUSTED_UTF8_BYTES=$i
}

fm_untrusted_strip_html_comments_var() {
  local text=$1 prefix rest
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
  done
  FM_UNTRUSTED_TEXT=$text
}

fm_untrusted_strip_format_chars_var() {
  local text=$1 c
  # Strip Cf / bidi / BOM / soft-hyphen hides. Do not strip U+200D ZWJ.
  for c in \
    $'\xE2\x80\x8B' $'\xE2\x80\x8C' $'\xE2\x81\xA0' $'\xE2\x81\xA3' \
    $'\xE2\x81\xA1' $'\xE2\x81\xA2' $'\xE2\x81\xA4' $'\xE2\x81\xA5' \
    $'\xEF\xBB\xBF' $'\xE2\x80\x8E' $'\xE2\x80\x8F' \
    $'\xE2\x80\xAA' $'\xE2\x80\xAB' $'\xE2\x80\xAC' $'\xE2\x80\xAD' $'\xE2\x80\xAE' \
    $'\xE2\x81\xA6' $'\xE2\x81\xA7' $'\xE2\x81\xA8' $'\xE2\x81\xA9' \
    $'\xC2\xAD' $'\xD8\x9C' $'\xE1\xA0\x8E'
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

# Longest prefix of $1 made of FM_UNTRUSTED_WS_SCALARS, byte-exactly, so the
# match never depends on the ambient locale. Sets FM_UNTRUSTED_WS_LEAD.
fm_untrusted_ws_lead() {
  local text=$1 out="" ws
  while [ -n "$text" ]; do
    for ws in "${FM_UNTRUSTED_WS_SCALARS[@]}"; do
      case "$text" in
        "$ws"*)
          out="${out}${ws}"
          text=${text#"$ws"}
          continue 2
          ;;
      esac
    done
    break
  done
  FM_UNTRUSTED_WS_LEAD=$out
}

# Neutralize consecutive line-leading system/assistant/user role markers.
# Optional markdown heading hashes and a single bullet stay in the lead.
fm_untrusted_neutralize_one_line() {
  local line=$1 lead body sp rest after
  while [ "${line%$'\r'}" != "$line" ]; do
    line=${line%$'\r'}
  done
  fm_untrusted_ws_lead "$line"
  lead=$FM_UNTRUSTED_WS_LEAD
  body=${line#"$lead"}
  while [ "${body#"#"}" != "$body" ]; do
    lead="${lead}#"
    body=${body#"#"}
  done
  fm_untrusted_ws_lead "$body"
  sp=$FM_UNTRUSTED_WS_LEAD
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
    case "$rest" in
      [sS][yY][sS][tT][eE][mM]*)
        after=${rest:6}
        ;;
      [aA][sS][sS][iI][sS][tT][aA][nN][tT]*)
        after=${rest:9}
        ;;
      [uU][sS][eE][rR]*)
        after=${rest:4}
        ;;
      *)
        break
        ;;
    esac
    fm_untrusted_ws_lead "$after"
    after=${after#"$FM_UNTRUSTED_WS_LEAD"}
    case "$after" in
      :*)
        after=${after#:}
        fm_untrusted_ws_lead "$after"
        after=${after#"$FM_UNTRUSTED_WS_LEAD"}
        body="${body}${FM_UNTRUSTED_ROLE_STANDIN}"
        rest=$after
        ;;
      *)
        break
        ;;
    esac
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
  case "$text" in
    *$'\n') out="${out}"$'\n' ;;
  esac
  FM_UNTRUSTED_TEXT=$out
}

fm_untrusted_truncate_var() {
  local text=$1 max=${2:-$FM_UNTRUSTED_TEXT_CAP} keep byte_len
  local probe=$'\xE4\xB8\x80'
  # UTF-8 locales: bash ${#} and ${var:n:m} already count scalars.
  if [ "${#probe}" -eq 1 ]; then
    if [ "${#text}" -le "$max" ]; then
      FM_UNTRUSTED_TEXT=$text
      return 0
    fi
    keep=$((max - ${#FM_UNTRUSTED_TEXT_SUFFIX}))
    [ "$keep" -ge 0 ] || keep=0
    FM_UNTRUSTED_TEXT="${text:0:$keep}$FM_UNTRUSTED_TEXT_SUFFIX"
    return 0
  fi
  # C / POSIX: ${#} is bytes. Walk UTF-8 so the cap stays in scalars.
  local LC_ALL=C
  byte_len=${#text}
  if [ "$byte_len" -le "$max" ]; then
    FM_UNTRUSTED_TEXT=$text
    return 0
  fi
  fm_untrusted_utf8_prefix_bytes "$text" "$max"
  if [ "$FM_UNTRUSTED_UTF8_BYTES" -eq "$byte_len" ]; then
    FM_UNTRUSTED_TEXT=$text
    return 0
  fi
  keep=$((max - ${#FM_UNTRUSTED_TEXT_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  fm_untrusted_utf8_prefix_bytes "$text" "$keep"
  FM_UNTRUSTED_TEXT="${text:0:$FM_UNTRUSTED_UTF8_BYTES}$FM_UNTRUSTED_TEXT_SUFFIX"
}

fm_sanitize_untrusted_text_var() {
  local text=${1-} prev
  fm_untrusted_truncate_var "$text"
  prev=$FM_UNTRUSTED_TEXT
  while :; do
    fm_untrusted_strip_format_chars_var "$FM_UNTRUSTED_TEXT"
    fm_untrusted_strip_special_tokens_var "$FM_UNTRUSTED_TEXT"
    fm_untrusted_strip_html_comments_var "$FM_UNTRUSTED_TEXT"
    if [ "$FM_UNTRUSTED_TEXT" = "$prev" ]; then
      break
    fi
    prev=$FM_UNTRUSTED_TEXT
  done
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
