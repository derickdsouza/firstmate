#!/usr/bin/env bash
# Behavior tests for the per-task token usage ledger (fm-usage.v1).
#
# Spawn-side tests drive bin/fm-spawn.sh through the fake-tmux spawn harness
# with a controlled HOME, pinning the usage_source=/usage_log= binding each
# harness records. Teardown-side tests drive bin/fm-teardown.sh --force over
# fixture session logs under tests/fixtures/usage/, pinning the summed
# fm-usage.v1 line appended to data/usage.jsonl. Direct bind-rule tests pin
# the path encoding for fixed inputs, independent of the sandbox layout.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-usage-lib.sh
. "$ROOT/bin/fm-usage-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
FIXTURES="$ROOT/tests/fixtures/usage"
TMP_ROOT=$(fm_test_tmproot fm-usage-ledger)

# --- direct bind-rule tests ---------------------------------------------------

test_bind_rules_for_fixed_paths() {
  local lines
  lines=$(CLAUDE_CONFIG_DIR= CODEX_HOME= PI_CODING_AGENT_DIR= HOME=/h \
    fm_usage_bind_meta claude /tmp/x.y/z-w)
  [ "$lines" = "$(printf '%s\n' 'usage_source=claude' 'usage_log=/h/.claude/projects/-tmp-x-y-z-w/*.jsonl')" ] \
    || fail "claude bind rule wrong: $lines"

  lines=$(CLAUDE_CONFIG_DIR=/store CODEX_HOME= PI_CODING_AGENT_DIR= HOME=/h \
    fm_usage_bind_meta claude /tmp/x)
  [ "$lines" = "$(printf '%s\n' 'usage_source=claude' 'usage_log=/store/projects/-tmp-x/*.jsonl')" ] \
    || fail "claude CLAUDE_CONFIG_DIR bind rule wrong: $lines"

  lines=$(CLAUDE_CONFIG_DIR= CODEX_HOME= PI_CODING_AGENT_DIR= HOME=/h \
    fm_usage_bind_meta pi /Users/u/.treehouse/pool/1/firstmate)
  [ "$lines" = "$(printf '%s\n' 'usage_source=pi' 'usage_log=/h/.pi/agent/sessions/--Users-u-.treehouse-pool-1-firstmate--/*.jsonl')" ] \
    || fail "pi bind rule wrong: $lines"

  lines=$(CLAUDE_CONFIG_DIR= CODEX_HOME= PI_CODING_AGENT_DIR= HOME=/h \
    fm_usage_bind_meta pi-signed /a/b)
  [ "$lines" = "$(printf '%s\n' 'usage_source=pi' 'usage_log=/h/.pi/agent/sessions/--a-b--/*.jsonl')" ] \
    || fail "pi-signed should bind the pi session store: $lines"

  lines=$(CLAUDE_CONFIG_DIR= CODEX_HOME=/cx PI_CODING_AGENT_DIR= HOME=/h \
    fm_usage_bind_meta codex /a)
  local expected_today expected_tomorrow
  expected_today="/cx/sessions/$(date +%Y/%m/%d)/*.jsonl"
  expected_tomorrow="/cx/sessions/$(date -v+1d +%Y/%m/%d 2>/dev/null || date -d tomorrow +%Y/%m/%d)/*.jsonl"
  case "$lines" in
    *"usage_log=$expected_today"*|*"usage_log=$expected_tomorrow"*) ;;
    *) fail "codex bind rule wrong: $lines" ;;
  esac

  lines=$(CLAUDE_CONFIG_DIR= CODEX_HOME= PI_CODING_AGENT_DIR= HOME=/h \
    fm_usage_bind_meta grok /a)
  [ "$lines" = "usage_source=none" ] || fail "unknown harness must bind none: $lines"
  pass "bind rules encode each harness session location for fixed paths"
}

# --- spawn binding tests ------------------------------------------------------

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_case() {  # <name>: echoes "home|proj|wt|fakebin|fakehome"
  local name=$1 case_dir home proj wt fakebin fakehome
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakehome="$case_dir/fakehome"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$fakehome"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$fakehome"
}

read_spawn_case() {
  IFS='|' read -r SPAWN_HOME PROJ_DIR WT_DIR FAKEBIN_DIR FAKE_HOME <<EOF
$1
EOF
}

# Run a ship spawn with the ledger-relevant environment fully controlled.
# Per-case store overrides ride FM_TEST_CLAUDE_CONFIG_DIR/FM_TEST_CODEX_HOME,
# mirroring how the dispatch-profile suite pins the same variables.
run_usage_spawn() {  # <id> <harness>
  local id=$1 harness=$2
  fm_test_spawn_brief "$SPAWN_HOME" "$id"
  HOME="$FAKE_HOME" CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    CODEX_HOME="${FM_TEST_CODEX_HOME:-}" PI_CODING_AGENT_DIR= \
    FM_FAKE_PI_VERSION=0.84.0 GROK_HOME="$SPAWN_HOME/grok-home" \
    fm_test_run_spawn "$SPAWN_HOME" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness "$harness" --mode no-mistakes --yolo off
}

test_spawn_binds_claude_session_dir() {
  local rec id out status meta slug
  id=usage-claude-z1
  rec=$(make_spawn_case claude-bind)
  read_spawn_case "$rec"
  out=$(run_usage_spawn "$id" claude)
  status=$?
  expect_code 0 "$status" "claude spawn should succeed"
  meta="$SPAWN_HOME/state/$id.meta"
  slug=$(printf '%s' "$WT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  assert_grep "usage_source=claude" "$meta" "claude meta missing usage_source"
  assert_grep "usage_log=$FAKE_HOME/.claude/projects/$slug/*.jsonl" "$meta" \
    "claude meta missing the session-dir glob for its worktree"
  pass "claude spawn binds the Claude Code project session dir"
}

test_spawn_binds_claude_config_dir_store() {
  local rec id out meta store
  id=usage-claude-store-z1
  rec=$(make_spawn_case claude-store)
  read_spawn_case "$rec"
  store="$FAKE_HOME/claude-store"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$store" run_usage_spawn "$id" claude)
  expect_code 0 "$?" "claude spawn with CLAUDE_CONFIG_DIR should succeed"
  meta="$SPAWN_HOME/state/$id.meta"
  assert_grep "usage_log=$store/projects/" "$meta" \
    "claude meta did not bind the forwarded CLAUDE_CONFIG_DIR store"
  pass "claude spawn binds the forwarded CLAUDE_CONFIG_DIR store"
}

test_spawn_binds_codex_date_glob() {
  local rec id out meta today tomorrow
  id=usage-codex-z1
  rec=$(make_spawn_case codex-bind)
  read_spawn_case "$rec"
  out=$(run_usage_spawn "$id" codex)
  expect_code 0 "$?" "codex spawn should succeed"
  meta="$SPAWN_HOME/state/$id.meta"
  today="$FAKE_HOME/.codex/sessions/$(date +%Y/%m/%d)/*.jsonl"
  tomorrow="$FAKE_HOME/.codex/sessions/$(date -v+1d +%Y/%m/%d 2>/dev/null || date -d tomorrow +%Y/%m/%d)/*.jsonl"
  assert_grep "usage_source=codex" "$meta" "codex meta missing usage_source"
  { grep -F "usage_log=$today" "$meta" || grep -F "usage_log=$tomorrow" "$meta"; } >/dev/null \
    || fail "codex meta missing the spawn-date session glob: $(grep '^usage_log=' "$meta")"
  pass "codex spawn binds the local-date sessions glob"
}

test_spawn_binds_pi_session_dir() {
  local rec id out meta dashed
  id=usage-pi-z1
  rec=$(make_spawn_case pi-bind)
  read_spawn_case "$rec"
  out=$(run_usage_spawn "$id" pi)
  expect_code 0 "$?" "pi spawn should succeed"
  meta="$SPAWN_HOME/state/$id.meta"
  dashed=$(printf '%s' "${WT_DIR#/}" | tr '/' '-')
  assert_grep "usage_source=pi" "$meta" "pi meta missing usage_source"
  assert_grep "usage_log=$FAKE_HOME/.pi/agent/sessions/--$dashed--/*.jsonl" "$meta" \
    "pi meta missing the dashed session-dir glob for its worktree"
  pass "pi spawn binds the pi agent session dir"
}

test_spawn_records_none_for_other_harness() {
  local rec id out meta
  id=usage-grok-z1
  rec=$(make_spawn_case grok-bind)
  read_spawn_case "$rec"
  out=$(run_usage_spawn "$id" grok)
  expect_code 0 "$?" "grok spawn should succeed"
  meta="$SPAWN_HOME/state/$id.meta"
  assert_grep "usage_source=none" "$meta" "grok meta missing usage_source=none"
  assert_no_grep "^usage_log=" "$meta" "none harness must not record a usage_log glob"
  pass "harnesses without a usage source record none and no glob"
}

# --- teardown ledger tests ----------------------------------------------------

# Sandbox for one teardown case: state/config/data dirs, fake runtime stubs,
# and an origin/project/worktree git chain, mirroring tests/fm-teardown.test.sh.
make_teardown_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin" \
    "$case_dir/worktree"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# Write a task-x1 meta carrying a usage binding. Args: case_dir harness source log
write_usage_meta() {
  local case_dir=$1 harness=$2 source=$3 log=$4
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=$harness" \
    "kind=ship" \
    "mode=no-mistakes" \
    "model=test-model" \
    "effort=medium" \
    "spawn_gen=usage-test-task-x1" \
    "usage_source=$source" \
    "usage_log=$log"
}

run_usage_teardown() {  # <case_dir> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

ledger_field() {  # <case_dir> <jq expr>
  jq -r "$2" "$1/data/usage.jsonl"
}

expect_force_teardown_ok() {  # <case_dir> <description>
  local case_dir=$1 rc
  run_usage_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  expect_code 0 "$rc" "$2: teardown should succeed"
}

test_teardown_sums_claude_log() {
  local case_dir
  case_dir=$(make_teardown_case claude-sum)
  write_usage_meta "$case_dir" claude claude "$FIXTURES/claude-session.jsonl"
  expect_force_teardown_ok "$case_dir" "claude-sum"
  [ "$(wc -l < "$case_dir/data/usage.jsonl" | tr -d '[:space:]')" = 1 ] \
    || fail "claude-sum: expected exactly one ledger line"
  jq -e '
    .task == "task-x1" and .repo == "project" and .kind == "ship"
    and .harness == "claude" and .model == "test-model" and .effort == "medium"
    and .tokens == {"input":150,"output":12,"cache_read":500,"cache_write":10,"reasoning":0}
    and .cost == null
    and .first_seen == "2026-09-01T10:00:00.000Z"
    and .last_seen == "2026-09-01T10:00:02.000Z"
    and .usage_source == "claude"
    and (.ts | test("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$"))
  ' "$case_dir/data/usage.jsonl" >/dev/null \
    || fail "claude-sum: ledger line wrong: $(cat "$case_dir/data/usage.jsonl")"
  pass "teardown sums per-turn claude usage into one fm-usage.v1 line"
}

test_teardown_sums_codex_glob_with_cwd_filter() {
  local case_dir
  case_dir=$(make_teardown_case codex-sum)
  # The glob spans both fixture files; only the file whose session header ran
  # in THIS task's worktree may count, and only its last cumulative totals.
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=/wt/fixture-a" \
    "project=$case_dir/project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "model=gpt-5" \
    "effort=low" \
    "spawn_gen=usage-test-task-x1" \
    "usage_source=codex" \
    "usage_log=$FIXTURES/codex-*.jsonl"
  expect_force_teardown_ok "$case_dir" "codex-sum"
  jq -e '
    .tokens == {"input":150,"output":8,"cache_read":30,"cache_write":0,"reasoning":4}
    and .cost == null
    and .first_seen == "2026-09-01T12:00:00.000Z"
    and .last_seen == "2026-09-01T12:00:04.000Z"
    and .usage_source == "codex"
  ' "$case_dir/data/usage.jsonl" >/dev/null \
    || fail "codex-sum: ledger line wrong: $(cat "$case_dir/data/usage.jsonl")"
  pass "teardown sums the last cumulative codex totals, scoped by session cwd"
}

test_teardown_sums_pi_log_with_cost() {
  local case_dir
  case_dir=$(make_teardown_case pi-sum)
  write_usage_meta "$case_dir" pi pi "$FIXTURES/pi-session.jsonl"
  expect_force_teardown_ok "$case_dir" "pi-sum"
  jq -e '
    .tokens == {"input":140,"output":12,"cache_read":5,"cache_write":7,"reasoning":4}
    and (.cost - 0.014 | fabs) < 1e-9
    and .first_seen == "2026-09-01T11:00:00.000Z"
    and .last_seen == "2026-09-01T11:00:03.000Z"
    and .usage_source == "pi"
  ' "$case_dir/data/usage.jsonl" >/dev/null \
    || fail "pi-sum: ledger line wrong: $(cat "$case_dir/data/usage.jsonl")"
  pass "teardown sums per-turn pi usage including reported cost"
}

test_teardown_missing_log_records_zero_line() {
  local case_dir
  case_dir=$(make_teardown_case missing-log)
  write_usage_meta "$case_dir" claude claude "$case_dir/nothing-here/*.jsonl"
  expect_force_teardown_ok "$case_dir" "missing-log"
  jq -e '
    .tokens == {"input":0,"output":0,"cache_read":0,"cache_write":0,"reasoning":0}
    and .cost == null and .first_seen == null and .last_seen == null
    and .usage_source == "missing"
  ' "$case_dir/data/usage.jsonl" >/dev/null \
    || fail "missing-log: ledger line wrong: $(cat "$case_dir/data/usage.jsonl")"
  pass "a missing bound log records a zero-token missing line, not a failure"
}

test_teardown_unparseable_log_records_missing() {
  local case_dir
  case_dir=$(make_teardown_case bad-log)
  printf '%s\n' 'this is not json' > "$case_dir/broken.jsonl"
  write_usage_meta "$case_dir" claude claude "$case_dir/broken.jsonl"
  expect_force_teardown_ok "$case_dir" "bad-log"
  jq -e '.usage_source == "missing" and .tokens.input == 0' \
    "$case_dir/data/usage.jsonl" >/dev/null \
    || fail "bad-log: ledger line wrong: $(cat "$case_dir/data/usage.jsonl")"
  pass "an unparseable bound log degrades to a zero-token missing line"
}

test_teardown_unbound_task_appends_nothing() {
  local case_dir
  case_dir=$(make_teardown_case unbound)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=usage-test-task-x1"
  expect_force_teardown_ok "$case_dir" "unbound"
  [ ! -e "$case_dir/data/usage.jsonl" ] \
    || fail "unbound: a task with no usage binding appended a ledger line"
  pass "a task spawned before the ledger contract appends nothing"
}

test_teardown_none_source_records_zero_line() {
  local case_dir
  case_dir=$(make_teardown_case none-source)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=grok" \
    "kind=scout" \
    "mode=no-mistakes" \
    "model=grok-4" \
    "effort=high" \
    "spawn_gen=usage-test-task-x1" \
    "usage_source=none"
  expect_force_teardown_ok "$case_dir" "none-source"
  jq -e '
    .harness == "grok" and .kind == "scout" and .usage_source == "none"
    and .tokens == {"input":0,"output":0,"cache_read":0,"cache_write":0,"reasoning":0}
    and .cost == null
  ' "$case_dir/data/usage.jsonl" >/dev/null \
    || fail "none-source: ledger line wrong: $(cat "$case_dir/data/usage.jsonl")"
  pass "a none-source harness records a zero-token line naming the harness"
}

test_bind_rules_for_fixed_paths
test_spawn_binds_claude_session_dir
test_spawn_binds_claude_config_dir_store
test_spawn_binds_codex_date_glob
test_spawn_binds_pi_session_dir
test_spawn_records_none_for_other_harness
test_teardown_sums_claude_log
test_teardown_sums_codex_glob_with_cwd_filter
test_teardown_sums_pi_log_with_cost
test_teardown_missing_log_records_zero_line
test_teardown_unparseable_log_records_missing
test_teardown_unbound_task_appends_nothing
test_teardown_none_source_records_zero_line
