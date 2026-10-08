#!/usr/bin/env bash
# Auto-merge when clean + green + Evidence (firstmate #14 / harbor #664 R1-R10).
# Does not deploy or enable itself. Callers (watch / release ritual) invoke it.
# While harbor queue-only freeze is on (HARBOR_DO_UNFREEZE unset / not truthy),
# harbor-repo merges are refused. Protected paths always need Derick.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

PROTECTED_REGEX='^(GLOSSARY\.md|AGENTS\.md|docs/adr/)'
REQUIRED_DEFAULT='relay-tests,tui-tests,contract-validators,claim-guard,quint-gate,pr-template'

usage() {
  cat <<'USAGE' >&2
usage: fm-pr-auto-merge.sh <task-id> <pr-url> [--dry-run]

Implements harbor #664 R1-R10 / firstmate #14:
  R1-R2  dirty/conflict -> rebase onto base, push same head, re-check
  R6     clean + required CI green + gates -> squash merge with --match-head-commit
  R8     refuse on red CI, missing gates, unresolved ask-user
  R9     leave an Evidence / ledger note of what landed
  freeze refuse harbor merges while HARBOR_DO_UNFREEZE is unset
  protected refuse if PR touches GLOSSARY.md, AGENTS.md, or docs/adr/*
USAGE
}

ID=${1:-}
URL=${2:-}
DRY=0
shift 2 2>/dev/null || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg: $arg" >&2; usage; exit 2 ;;
  esac
done
[ -n "$ID" ] && [ -n "$URL" ] || { usage; exit 2; }

refuse() { echo "error: fm-pr-auto-merge: $*" >&2; exit 1; }

harbor_frozen() {
  case "${HARBOR_DO_UNFREEZE:-}" in
    1|true|yes|on|TRUE|YES|ON) return 1 ;;
    *) return 0 ;;
  esac
}

pr_has_evidence() {
  local body=$1
  case "$body" in
    *'<!-- harbor-verified-evidence:start -->'*'<!-- harbor-verified-evidence:end -->'*) return 0 ;;
  esac
  printf '%s\n' "$body" | awk '
    BEGIN { in_ev=0; buf="" }
    /^## Evidence[[:space:]]*$/ { in_ev=1; next }
    /^## / { if (in_ev) exit }
    in_ev { buf = buf $0 "\n" }
    END {
      gsub(/<!--[^>]*-->/, "", buf)
      gsub(/[[:space:]]/, "", buf)
      if (length(buf) > 0) exit 0; else exit 1
    }
  '
}

task_has_open_ask_user() {
  local meta="${FM_STATE_OVERRIDE:-${FM_HOME:+$FM_HOME/state}}/${ID}.meta"
  [ -f "$meta" ] || return 1
  grep -Eq '^ask_user=(open|pending|1|true)' "$meta" 2>/dev/null
}

pr_touches_protected() {
  local files
  files=$(gh api --paginate "repos/${OWNER}/${REPO}/pulls/${PR_NUM}/files" 2>/dev/null | jq -r '.[].filename // empty') || return 2
  printf '%s\n' "$files" | grep -Eq "$PROTECTED_REGEX"
}

# Parse https://github.com/owner/repo/pull/N
if [[ "$URL" =~ github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  PR_NUM="${BASH_REMATCH[3]}"
else
  refuse "cannot parse GitHub PR URL: $URL"
fi

if [ "$REPO" = harbor ] && harbor_frozen; then
  refuse "harbor queue-only freeze is on (HARBOR_DO_UNFREEZE unset) — not merging $URL"
fi

if task_has_open_ask_user; then
  refuse "task $ID has unresolved ask-user — not merging (R8)"
fi

BODY=$(gh pr view "$URL" --json body 2>/dev/null | jq -r .body) || refuse "could not read PR body"
pr_has_evidence "$BODY" || refuse "PR body missing Evidence / verified-evidence block (R4/R9)"

prot_rc=0
pr_touches_protected || prot_rc=$?
case "$prot_rc" in
  0) refuse "PR touches protected path (GLOSSARY.md / AGENTS.md / docs/adr/*) — Derick merges" ;;
  2) refuse "could not list PR files for protected-path check" ;;
esac

VIEW_JSON=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup) \
  || refuse "could not read PR mergeability"

STATE=$(printf '%s' "$VIEW_JSON" | jq -r '.state')
DRAFT=$(printf '%s' "$VIEW_JSON" | jq -r '.isDraft')
MERGEABLE=$(printf '%s' "$VIEW_JSON" | jq -r '.mergeable')
MERGE_STATE=$(printf '%s' "$VIEW_JSON" | jq -r '.mergeStateStatus')
HEAD=$(printf '%s' "$VIEW_JSON" | jq -r '.headRefOid')
BASE=$(printf '%s' "$VIEW_JSON" | jq -r '.baseRefName')

[ "$STATE" = OPEN ] || refuse "PR state is $STATE, not OPEN"
[ "$DRAFT" = false ] || refuse "PR is a draft"

if [ "$MERGEABLE" != MERGEABLE ] || [ "$MERGE_STATE" = DIRTY ] || [ "$MERGE_STATE" = BEHIND ]; then
  echo "fm-pr-auto-merge: dirty/behind — rebasing onto $BASE (R1)"
  if [ "$DRY" -eq 1 ]; then
    echo "dry-run: would gh pr rebase $URL"
  else
    gh pr rebase "$URL" || refuse "rebase failed — escalate to Derick (R3)"
    HEAD=$(gh pr view "$URL" --json headRefOid -q .headRefOid)
    MERGEABLE=$(gh pr view "$URL" --json mergeable -q .mergeable)
    [ "$MERGEABLE" = MERGEABLE ] || refuse "still not MERGEABLE after rebase"
    VIEW_JSON=$(gh pr view "$URL" --json state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup)
  fi
fi

REQUIRED=${FM_PR_AUTO_REQUIRED:-$REQUIRED_DEFAULT}
ROLLUP=$(printf '%s' "$VIEW_JSON" | jq -c '.statusCheckRollup')
missing=$(
  printf '%s' "$REQUIRED" | tr ',' '\n' | while read -r name; do
    [ -n "$name" ] || continue
    ok=$(printf '%s' "$ROLLUP" | jq -r --arg n "$name" '
      map(select((.name // .context // "") == $n and .status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")))
      | length')
    [ "$ok" -ge 1 ] || printf '%s\n' "$name"
  done
)
if [ -n "$missing" ]; then
  refuse "required checks not green: $(printf '%s' "$missing" | tr '\n' ' ')(R8)"
fi

echo "fm-pr-auto-merge: clean + green + Evidence — merging $URL at $HEAD (R6)"
if [ "$DRY" -eq 1 ]; then
  echo "dry-run: would gh pr merge --squash --match-head-commit $HEAD $URL"
  exit 0
fi

"$ROOT/bin/fm-pr-merge.sh" "$ID" "$URL" -- --squash --match-head-commit "$HEAD"

NOTE_DIR=${FM_STATE_OVERRIDE:-${FM_HOME:+$FM_HOME/state}}
if [ -n "${NOTE_DIR:-}" ]; then
  mkdir -p "$NOTE_DIR"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) auto-merged $URL head=$HEAD task=$ID evidence=present" \
    >> "$NOTE_DIR/auto-merge.ledger"
fi
echo "fm-pr-auto-merge: landed $URL (ledger note written)"
