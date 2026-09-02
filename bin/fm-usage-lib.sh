#!/usr/bin/env bash
# Per-task token usage ledger (schema: fm-usage.v1).
#
# CONTRACT (this header is the one owner of the binding and the line shape;
# docs/configuration.md "Usage ledger" owns the operator-facing summary).
#   - Binding (bin/fm-spawn.sh calls fm_usage_bind_meta at task-record
#     creation): state/<id>.meta gains usage_source= and, for a harness with a
#     known on-disk per-turn usage source, usage_log=<path or glob> resolved
#     from fm-spawn's own environment, because that is what the forwarded
#     launch environment writes to:
#       claude     ~/.claude/projects/<slug>/*.jsonl where <slug> is the
#                  worktree path with every non-alphanumeric byte replaced by
#                  "-" (Claude Code's project-directory encoding), under
#                  $CLAUDE_CONFIG_DIR when set (fm-spawn forwards it onto the
#                  launch, so the binding matches the store the crewmate
#                  actually uses). Assistant lines carry message.usage.
#       codex      ~/.codex/sessions/<YYYY/MM/DD local spawn date>/*.jsonl
#                  under $CODEX_HOME when set. The date directory is shared
#                  by every Codex session on the machine, so summation keeps
#                  only files whose first session_meta line records this
#                  task's worktree as cwd. token_count events carry a
#                  CUMULATIVE total_token_usage; the last one per file is
#                  that file's session total.
#       pi,pi-signed ~/.pi/agent/sessions/--<path>--/*.jsonl where <path> is
#                  the worktree path without its leading slash and with every
#                  remaining "/" replaced by "-" (pi's session directory
#                  encoding, dots preserved), under $PI_CODING_AGENT_DIR when
#                  set. Assistant lines carry message.usage including a cost
#                  object.
#     Every other harness (and every remote secondmate, whose harness runs on
#     another host) records usage_source=none and no usage_log line.
#     v1 limitation: a glob covers every session ever written under the bound
#     location, so a reused worktree path adds older sessions to the sum.
#   - Ledger append (bin/fm-teardown.sh calls fm_usage_ledger_append after
#     every refusal gate has passed and before the task record is removed):
#     one JSON object per appended line in data/usage.jsonl, fields in this
#     order - ts (UTC ISO-8601 append time), task, repo (basename of the
#     meta project=), kind, harness, model, effort, tokens{input,output,
#     cache_read,cache_write,reasoning}, cost (summed when the source reports
#     per-turn cost, i.e. pi; else null), first_seen and last_seen (min/max
#     entry timestamp across the summed files, null when none), usage_source
#     (the bound source, or "missing" when a bound log matched nothing
#     readable, jq is unavailable, or every matched file failed to parse -
#     zero tokens in all those cases). A task with no usage_source recorded
#     (spawned before this contract) appends nothing. The append NEVER fails
#     a teardown: every internal error degrades to a zero-token line or a
#     skipped append, with at most a stderr warning.
#   - Token-class mapping per source:
#       claude: input_tokens, output_tokens, cache_read_input_tokens,
#               cache_creation_input_tokens -> cache_write, reasoning 0.
#       codex:  input_tokens, output_tokens, cached_input_tokens ->
#               cache_read, reasoning_output_tokens, cache_write 0.
#       pi:     input, output, cacheRead, cacheWrite, reasoning,
#               cost.total summed into cost.
# Requires fm_meta_get (bin/fm-backend.sh) and jq at append time.

# fm_usage_bind_meta <harness> <worktree>: emit the usage_source=/usage_log=
# meta lines for a task record. Caller writes them into state/<id>.meta.
fm_usage_bind_meta() {  # <harness> <worktree>
  local harness=$1 worktree=$2 store
  case $harness in
    claude)
      store=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
      printf 'usage_source=claude\n'
      printf 'usage_log=%s/projects/%s/*.jsonl\n' \
        "$store" "$(printf '%s' "$worktree" | sed 's/[^A-Za-z0-9]/-/g')"
      ;;
    codex)
      store=${CODEX_HOME:-$HOME/.codex}
      printf 'usage_source=codex\n'
      printf 'usage_log=%s/sessions/%s/*.jsonl\n' "$store" "$(date +%Y/%m/%d)"
      ;;
    pi|pi-signed)
      store=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
      printf 'usage_source=pi\n'
      printf 'usage_log=%s/sessions/--%s--/*.jsonl\n' \
        "$store" "$(printf '%s' "${worktree#/}" | tr '/' '-')"
      ;;
    *)
      printf 'usage_source=none\n'
      ;;
  esac
}

# Codex date directories are machine-wide, so a bound glob must keep only the
# files whose own session header ran in this task's worktree.
fm_usage_codex_file_matches_cwd() {  # <file> <worktree>
  head -n 1 -- "$1" 2>/dev/null | grep -Fq "\"cwd\":\"$2\""
}

fm_usage_sum_claude_file() {  # <file> -> one aggregate JSON row
  jq -s '
    def nums(f): [ .[] | select(.message.usage != null)
                   | (.message.usage | f) // 0 ] | add // 0;
    {
      first: ([.[].timestamp] | map(select(. != null)) | min),
      last: ([.[].timestamp] | map(select(. != null)) | max),
      in: nums(.input_tokens), out: nums(.output_tokens),
      cr: nums(.cache_read_input_tokens),
      cw: nums(.cache_creation_input_tokens),
      rs: 0, cost: null
    }' "$1"
}

fm_usage_sum_codex_file() {  # <file> -> one aggregate JSON row
  jq -s '
    def last_totals(f): [ .[]
      | select(.type == "event_msg" and .payload.type == "token_count"
               and .payload.info.total_token_usage != null)
      | (.payload.info.total_token_usage | f) ] | last // 0;
    {
      first: ([.[].timestamp] | map(select(. != null)) | min),
      last: ([.[].timestamp] | map(select(. != null)) | max),
      in: last_totals(.input_tokens), out: last_totals(.output_tokens),
      cr: last_totals(.cached_input_tokens),
      rs: last_totals(.reasoning_output_tokens),
      cw: 0, cost: null
    }' "$1"
}

fm_usage_sum_pi_file() {  # <file> -> one aggregate JSON row
  jq -s '
    def nums(f): [ .[] | select(.message.usage != null)
                   | (.message.usage | f) // 0 ] | add // 0;
    {
      first: ([.[].timestamp] | map(select(. != null)) | min),
      last: ([.[].timestamp] | map(select(. != null)) | max),
      in: nums(.input), out: nums(.output),
      cr: nums(.cacheRead), cw: nums(.cacheWrite), rs: nums(.reasoning),
      cost: ([ .[] | select(.message.usage.cost.total != null)
               | .message.usage.cost.total ] | add // null)
    }' "$1"
}

# Aggregate the per-file rows on stdin (one JSON object per line) into one.
fm_usage_sum_rows() {
  jq -s '
    {
      in: (map(.in // 0) | add // 0),
      out: (map(.out // 0) | add // 0),
      cr: (map(.cr // 0) | add // 0),
      cw: (map(.cw // 0) | add // 0),
      rs: (map(.rs // 0) | add // 0),
      cost: (if any(.[]; (.cost // null) != null)
             then (map(.cost // 0) | add) else null end),
      first: (map(.first) | map(select(. != null)) | min),
      last: (map(.last) | map(select(. != null)) | max)
    }'
}

# fm_usage_collect_rows <source> <glob> <worktree>: sum the bound log into one
# aggregate JSON row, or print nothing when nothing readable matched.
fm_usage_collect_rows() {  # <source> <glob> <worktree>
  local source=$1 glob=$2 worktree=$3 f row rows=
  local -a files=()
  while IFS= read -r f; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    if [ "$source" = codex ] \
       && ! fm_usage_codex_file_matches_cwd "$f" "$worktree"; then
      continue
    fi
    files+=("$f")
  done < <(compgen -G "$glob")
  [ "${#files[@]}" -gt 0 ] || return 0
  for f in "${files[@]}"; do
    row=
    case $source in
      claude) row=$(fm_usage_sum_claude_file "$f" 2>/dev/null) || row= ;;
      codex) row=$(fm_usage_sum_codex_file "$f" 2>/dev/null) || row= ;;
      pi) row=$(fm_usage_sum_pi_file "$f" 2>/dev/null) || row= ;;
    esac
    [ -n "$row" ] || continue
    rows="${rows}${row}"$'\n'
  done
  [ -n "$rows" ] || return 0
  printf '%s' "$rows" | fm_usage_sum_rows 2>/dev/null || return 0
}

# fm_usage_ledger_append <data-dir> <meta-file> <task-id>: append this task's
# fm-usage.v1 line to <data-dir>/usage.jsonl. Best effort by contract: never
# returns non-zero and never writes to stderr on the happy paths.
fm_usage_ledger_append() {  # <data-dir> <meta-file> <task-id>
  local data=$1 meta=$2 id=$3
  local source glob worktree harness model effort kind project repo ts
  local agg line_source first last cost_json
  [ -f "$meta" ] || return 0
  source=$(fm_meta_get "$meta" usage_source) || return 0
  [ -n "$source" ] || return 0
  glob=$(fm_meta_get "$meta" usage_log) || glob=
  worktree=$(fm_meta_get "$meta" worktree) || worktree=
  harness=$(fm_meta_get "$meta" harness) || harness=
  model=$(fm_meta_get "$meta" model) || model=
  effort=$(fm_meta_get "$meta" effort) || effort=
  kind=$(fm_meta_get "$meta" kind) || kind=
  project=$(fm_meta_get "$meta" project) || project=
  repo=${project##*/}
  [ -n "$model" ] || model=default
  [ -n "$effort" ] || effort=default
  [ -n "$kind" ] || kind=ship
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 0
  agg=
  line_source=$source
  case $source in
    claude|codex|pi)
      if [ -n "$glob" ] && command -v jq >/dev/null 2>&1; then
        agg=$(fm_usage_collect_rows "$source" "$glob" "$worktree")
      fi
      if [ -z "$agg" ]; then
        line_source=missing
        echo "warning: usage log for $id ($source) matched nothing readable; recording a zero-token ledger line" >&2
      fi
      ;;
    none) ;;
    *)
      # An unknown usage_source value is not this contract's to interpret.
      return 0
      ;;
  esac
  if [ -z "$agg" ]; then
    agg='{"in":0,"out":0,"cr":0,"cw":0,"rs":0,"cost":null,"first":null,"last":null}'
  fi
  cost_json=$(printf '%s' "$agg" | jq -c '.cost' 2>/dev/null) || cost_json=null
  first=$(printf '%s' "$agg" | jq -r '.first // ""' 2>/dev/null) || first=
  last=$(printf '%s' "$agg" | jq -r '.last // ""' 2>/dev/null) || last=
  line=$(jq -cn \
    --arg ts "$ts" --arg task "$id" --arg repo "$repo" --arg kind "$kind" \
    --arg harness "$harness" --arg model "$model" --arg effort "$effort" \
    --argjson in "$(printf '%s' "$agg" | jq '.in // 0' 2>/dev/null || echo 0)" \
    --argjson out "$(printf '%s' "$agg" | jq '.out // 0' 2>/dev/null || echo 0)" \
    --argjson cr "$(printf '%s' "$agg" | jq '.cr // 0' 2>/dev/null || echo 0)" \
    --argjson cw "$(printf '%s' "$agg" | jq '.cw // 0' 2>/dev/null || echo 0)" \
    --argjson rs "$(printf '%s' "$agg" | jq '.rs // 0' 2>/dev/null || echo 0)" \
    --argjson cost "$cost_json" \
    --arg first "$first" --arg last "$last" --arg usage_source "$line_source" \
    '{ts:$ts,task:$task,repo:$repo,kind:$kind,harness:$harness,model:$model,
      effort:$effort,
      tokens:{input:$in,output:$out,cache_read:$cr,cache_write:$cw,
              reasoning:$rs},
      cost:$cost,
      first_seen:(if $first == "" then null else $first end),
      last_seen:(if $last == "" then null else $last end),
      usage_source:$usage_source}' 2>/dev/null) || line=
  [ -n "$line" ] || {
    echo "warning: usage ledger line for $id could not be composed; skipping the append" >&2
    return 0
  }
  mkdir -p -- "$data" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$data/usage.jsonl" 2>/dev/null \
    || echo "warning: usage ledger append failed for $id at $data/usage.jsonl" >&2
  return 0
}
