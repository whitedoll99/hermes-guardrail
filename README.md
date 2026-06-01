# hermes-guardrail

Safety and audit harness for [Hermes Agent](https://hermes-agent.nousresearch.com/) Kanban worker lanes.

Provides machine-enforced contract checks (forbidden paths, allowed files) that Kanban's native orchestration does not cover. Successor to [hermes-conductor](https://github.com/whitedoll99/hermes-conductor)'s safety layer, extracted after Kanban v0.15.0 absorbed the orchestration functionality.

## Scripts

| Script | Purpose |
|--------|---------|
| `guardrail_prepare.sh` | Pre-task: freeze git base SHA, define forbidden paths, generate source snapshot |
| `guardrail_finalize.sh` | Post-task: verify contract (forbidden paths, allowed files), emit verdict |

## Usage

```bash
# 1. Prepare guardrail before creating a Kanban task
bash scripts/guardrail_prepare.sh \
  --project-dir ~/my-project \
  --title "Add user auth endpoint" \
  --risk-level medium \
  --ac "POST /auth/login returns 200 with valid credentials" \
  --ac "Invalid credentials return 401"

# 2. Create the Kanban task (use the command printed by prepare)
hermes kanban create --assignee kanban-worker --workspace worktree \
  --body "..." "Add user auth endpoint"

# 3. After the worker completes, finalize
bash scripts/guardrail_finalize.sh --guardrail-id G-20260601-160000

# 4. Read the verdict
cat state/G-20260601-160000/verdict.yaml
```

## State directory

Runtime data lives in `state/` (gitignored):

```
state/{guardrail_id}/
  source.yaml   # Immutable snapshot from prepare (git base SHA, forbidden paths, AC)
  verdict.yaml  # Finalize result (contract check pass/fail, violations)
```

## Background

Hermes Kanban v0.15.0 introduced Triage, Swarm, worktree-per-task, claim TTL, and stalled detection -- absorbing most of hermes-conductor's orchestration. However, two safety gaps remain:

- **S3 (Verifier gate)**: No external verification of worker-reported task completion
- **S5 (forbidden_paths)**: No machine-enforced file access restrictions

This harness fills those gaps with minimal, script-based tooling.

## License

MIT
