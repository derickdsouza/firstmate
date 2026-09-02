# Evidence: global no-mistakes reviewer chain documented as [pi, claude] (issue #7)

Commit under test: 034713f docs(config): record global no-mistakes reviewer chain as [pi, claude] (#7)
Tracked diff: .no-mistakes.yaml (+6 comment lines), CONTRIBUTING.md (+1), docs/configuration.md (+8) - docs/comments only.

## 1. docs/configuration.md - Gate defaults (.no-mistakes.yaml), final section

```markdown

The reviewer chain is global, in `~/.no-mistakes/config.yaml`, not a per-repo override.
Set `agent: [pi, claude]`.
No-mistakes refuses to launch a gate agent that cannot neutralize the target repo's `AGENTS.md` or `CLAUDE.md`; only pi, claude, and codex have a verified neutralization knob.
Grok and cursor do not, so they cannot sit in the chain for this repo or any other fleet checkout that carries those files.
Codex is the only other eligible fallback; the fleet default does not include it.
Do not add `agent:` to the tracked `.no-mistakes.yaml` unless a repo needs a different chain than that fleet default, and then record why.
A new firstmate home does not write that global file; apply the chain in `~/.no-mistakes/config.yaml` after installing no-mistakes, then confirm with `no-mistakes doctor` that gate validation names pi or claude rather than grok or cursor.
```

## 2. CONTRIBUTING.md pointer (line 73)

```markdown
The global reviewer chain is owned by [`docs/configuration.md`](docs/configuration.md) ("Gate defaults"); the tracked file does not set `agent:`.
```

## 3. .no-mistakes.yaml comment block (tracked file keeps NO agent: key)

```yaml
# Keep the chain global so harbor and other fleet repos share it. See
# docs/configuration.md "Gate defaults".

# Trusted documentation placement policy for the Document step.
# The audience inventory and coding guideline own the detail; keep this as a
# pointer so gate instructions cannot become a second prose policy.
```

## 4. Semantic verification of the tracked YAML (PyYAML parse)

```
PASS - tracked .no-mistakes.yaml parses into a mapping
PASS - no top-level "agent" key (intent forbids repo-level override)
PASS - no "agent_config" key invented anywhere
PASS - disable_project_settings still true (neutralization opt-out intact)
PASS - commands.lint pin intact
PASS - test.evidence.store_in_repo intact
PASS - semantic model identical to base commit => tracked diff is comments-only

current semantic model:
{"commands": {"lint": "bin/fm-lint.sh"},
 "disable_project_settings": true,
 "document": {"instructions": "Read docs/documentation-audiences.md ... branch diff again after every documentation or lint fix.\n"},
 "test": {"evidence": {"store_in_repo": true}}}
```

## 5. Operator-local global config (outside tracked diff, per intent)

```
path: /root/.no-mistakes/config.yaml exists: True
agent: ['pi', 'claude']
matches documented policy [pi, claude]: True
```

## 6. Adjacent automated suite (gate-agent refusal boundary around the tracked config)

```
ok - fm-gate-refuse-lib: refuses when NO_MISTAKES_GATE is set
ok - fm-gate-refuse-lib: refuses when NO_MISTAKES_GATE is set empty
ok - fm-gate-refuse-lib: refuses from a gate worktree via git-common-dir (marker unset)
ok - fm-gate-refuse-lib: no-op for a normal session (neither signal, set -eu clean)
ok - fm-spawn: refuses on marker and gate-worktree backstop; a normal crew spawn is unaffected
ok - fm-send: refuses on marker and gate-worktree backstop; a normal steer uses the inbox
ok - fm-teardown: refuses on marker and gate-worktree backstop; a normal teardown is unaffected
```
