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

# Every code point Unicode gives White_Space=Yes outside ASCII, as UTF-8 byte
# sequences (the same list and reason as bin/fm-composer-lib.sh, issue #1988):
# classification must not depend on the ambient locale because the daemon runs
# this transform under LC_ALL=C, where [[:space:]] misses these. U+200B ZERO
# WIDTH SPACE is deliberately absent (White_Space=No); the invisible-format
# strip owns it.
FM_UNTRUSTED_WS_SEQS=(
  $'\xC2\x85' $'\xC2\xA0' $'\xE1\x9A\x80'
  $'\xE2\x80\x80' $'\xE2\x80\x81' $'\xE2\x80\x82' $'\xE2\x80\x83'
  $'\xE2\x80\x84' $'\xE2\x80\x85' $'\xE2\x80\x86' $'\xE2\x80\x87'
  $'\xE2\x80\x88' $'\xE2\x80\x89' $'\xE2\x80\x8A'
  $'\xE2\x80\xA8' $'\xE2\x80\xA9' $'\xE2\x80\xAF' $'\xE2\x81\x9F'
  $'\xE3\x80\x80'
)

_FM_UNTRUSTED_TEXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_OPERATIONAL_PREFIX+x}" ]; then
  # shellcheck source=bin/fm-operational-input.sh
  . "$_FM_UNTRUSTED_TEXT_LIB_DIR/fm-operational-input.sh"
fi

# Byte length of the first `max` Unicode scalars in `text`.
# Runs under LC_ALL=C so ${#} and ${var:n:m} stay byte-indexed. A prefix's
# scalar count is its bytes minus UTF-8 continuation bytes, which one pattern
# pass computes at C speed, so the cut is found by binary search instead of a
# per-scalar interpreted walk; the cut then lands on a complete scalar and an
# incomplete trailing sequence is dropped rather than emitted as invalid UTF-8.
# Sets FM_UNTRUSTED_UTF8_BYTES.
fm_untrusted_utf8_prefix_bytes() {
  local text=$1 max=$2
  local LC_ALL=C
  local byte_len=${#text} lo hi mid scalars b j back ord seq
  local cont_lo=$'\x80' cont_hi=$'\xBF'
  if [ "$byte_len" -le "$max" ]; then
    FM_UNTRUSTED_UTF8_BYTES=$byte_len
    return 0
  fi
  lo=0
  hi=$byte_len
  while [ "$lo" -lt "$hi" ]; do
    mid=$(((lo + hi) / 2))
    scalars=${text:0:mid}
    scalars=${scalars//[$cont_lo-$cont_hi]/}
    if [ "${#scalars}" -ge "$max" ]; then
      hi=$mid
    else
      lo=$((mid + 1))
    fi
  done
  b=$lo
  while [ "$b" -lt "$byte_len" ]; do
    case "${text:b:1}" in
      [$cont_lo-$cont_hi]) b=$((b + 1)) ;;
      *) break ;;
    esac
  done
  j=$b
  back=0
  while [ "$back" -lt 4 ] && [ "$j" -gt 0 ]; do
    case "${text:$((j - 1)):1}" in
      [$cont_lo-$cont_hi]) j=$((j - 1)); back=$((back + 1)) ;;
      *) break ;;
    esac
  done
  if [ "$j" -gt 0 ]; then
    printf -v ord '%d' "'${text:$((j - 1)):1}"
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
    if [ $((j - 1 + seq)) -gt "$b" ]; then
      b=$((j - 1))
    fi
  fi
  FM_UNTRUSTED_UTF8_BYTES=$b
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

# Longest prefix of $1 made of whitespace, matched byte-exactly against the
# POSIX [[:space:]] ASCII set plus every code point Unicode gives
# White_Space=Yes outside ASCII (FM_UNTRUSTED_WS_SEQS), so classification
# never depends on the ambient locale. Maps the non-ASCII sequences to spaces
# for the match, then maps the run's scalar count back to original bytes
# through fm_untrusted_utf8_prefix_bytes, so no per-scalar interpreted walk
# runs on cap-length whitespace runs. Sets FM_UNTRUSTED_WS_LEAD to the prefix
# and FM_UNTRUSTED_WS_LEAD_LEN to its byte length.
fm_untrusted_ws_lead() {
  local text=$1 norm seq n
  local LC_ALL=C
  case "${text:0:1}" in
    ' '|$'\t'|$'\v'|$'\f'|$'\r'|$'\xC2'|$'\xE1'|$'\xE2'|$'\xE3') ;;
    *)
      FM_UNTRUSTED_WS_LEAD=
      FM_UNTRUSTED_WS_LEAD_LEN=0
      return 0
      ;;
  esac
  norm=$text
  for seq in "${FM_UNTRUSTED_WS_SEQS[@]}"; do
    norm=${norm//"$seq"/ }
  done
  norm=${norm%%[![:space:]]*}
  n=${#norm}
  if [ "$n" -eq 0 ]; then
    FM_UNTRUSTED_WS_LEAD=
    FM_UNTRUSTED_WS_LEAD_LEN=0
    return 0
  fi
  fm_untrusted_utf8_prefix_bytes "$text" "$n"
  FM_UNTRUSTED_WS_LEAD_LEN=$FM_UNTRUSTED_UTF8_BYTES
  FM_UNTRUSTED_WS_LEAD=${text:0:$FM_UNTRUSTED_WS_LEAD_LEN}
}

# Neutralize consecutive line-leading system/assistant/user role markers.
# Optional markdown heading hashes and a single bullet stay in the lead.
fm_untrusted_neutralize_one_line() {
  local line=$1 lead body sp rest after
  local LC_ALL=C
  while [ "${line%$'\r'}" != "$line" ]; do
    line=${line%$'\r'}
  done
  fm_untrusted_ws_lead "$line"
  lead=$FM_UNTRUSTED_WS_LEAD
  body=${line:$FM_UNTRUSTED_WS_LEAD_LEN}
  while [ "${body#"#"}" != "$body" ]; do
    lead="${lead}#"
    body=${body#"#"}
  done
  fm_untrusted_ws_lead "$body"
  sp=$FM_UNTRUSTED_WS_LEAD
  lead="${lead}${sp}"
  body=${body:$FM_UNTRUSTED_WS_LEAD_LEN}
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
    after=${after:$FM_UNTRUSTED_WS_LEAD_LEN}
    case "$after" in
      :*)
        after=${after#:}
        fm_untrusted_ws_lead "$after"
        after=${after:$FM_UNTRUSTED_WS_LEAD_LEN}
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
