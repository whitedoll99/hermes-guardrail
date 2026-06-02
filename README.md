# hermes-guardrail

Post-task contract checker for [Hermes Agent](https://hermes-agent.nousresearch.com/) Kanban worker lanes.

Provides machine-enforced post-task diff checks (forbidden paths, allowed files) that Kanban's native orchestration does not cover. Successor to [hermes-conductor](https://github.com/whitedoll99/hermes-conductor)'s safety layer, extracted after Kanban v0.15.0 absorbed the orchestration functionality.

> **Not a sandbox.** This harness does not prevent workers from reading files, making temporary changes, or communicating externally during execution. It inspects the *final artifacts* — committed and uncommitted changes — against the contract defined at prepare time. Think of it as an audit gate, not a jail.

## How it works

```
prepare ──────────────────────> Kanban task ──────────────────────> finalize
│                               │                                  │
│ freeze git base SHA           │ Worker executes in worktree      │ diff base_sha..worker_branch
│ define forbidden paths        │ (Hermes Kanban orchestrates)     │ check forbidden_paths
│ record acceptance criteria    │                                  │ check allowed_files
│ write source.yaml             │                                  │ write verdict.yaml
```

## Scripts

| Script | Purpose | Exit codes |
|--------|---------|------------|
| `guardrail_prepare.sh` | Pre-task: freeze git base SHA, define forbidden paths, generate source snapshot | 0 = success, 1 = error |
| `guardrail_attach.sh` | Link a Kanban task ID to an existing source.yaml | 0 = success, 1 = error |
| `guardrail_finalize.sh` | Post-task: diff check against contract, emit verdict | 0 = pass, 1 = fail (violations), 2 = inconclusive |
| `guardrail_doctor.sh` | Health check: Hermes Agent, Kanban board, worker profiles, guardrail state | 0 = clean, 1 = errors, 2 = warnings only |

Shared helpers live in `scripts/lib/common.sh` (YAML parsing, logging, validation).

## Usage

```bash
# 1. Prepare guardrail before creating a Kanban task
bash scripts/guardrail_prepare.sh \
  --project-dir ~/my-project \
  --title "Add user auth endpoint" \
  --risk-level medium \
  --ac "POST /auth/login returns 200 with valid credentials" \
  --ac "Invalid credentials return 401"

# 2. Create the Kanban task (prepare prints a suggested command)
hermes kanban create --assignee kanban-worker --workspace worktree \
  --max-runtime 300 --body "..." "Add user auth endpoint"
# → returns task ID, e.g. t42

# 3. Attach the Kanban task ID to the guardrail
bash scripts/guardrail_attach.sh --guardrail-id G-20260601-160000 --task-id t42

# 4. After the worker completes, finalize
bash scripts/guardrail_finalize.sh --guardrail-id G-20260601-160000

# 5. Read the verdict
cat state/G-20260601-160000/verdict.yaml
```

### Finalize options

```bash
# Auto-detects worker branch from source.yaml's kanban_task_id → wt/<task_id>
bash scripts/guardrail_finalize.sh --guardrail-id G-20260601-160000

# Explicit branch override (if auto-detection doesn't apply)
bash scripts/guardrail_finalize.sh --guardrail-id G-20260601-160000 --branch wt/t42

# Override project directory
bash scripts/guardrail_finalize.sh --guardrail-id G-20260601-160000 --project-dir ~/alt
```

### Health check

```bash
bash scripts/guardrail_doctor.sh            # colored terminal output
bash scripts/guardrail_doctor.sh --no-color  # for piping / scripting
```

Doctor checks: Hermes Agent availability, Kanban board health (stuck/blocked tasks), worker profiles, orphaned guardrail runs (source without verdict), and Kanban diagnostics.

## State directory

Runtime data lives in `state/` (gitignored):

```
state/{guardrail_id}/
  source.yaml   # Immutable snapshot from prepare (git base SHA, forbidden paths, AC)
  verdict.yaml  # Finalize result (contract check pass/fail, violations)
```

See `examples/` for sample source.yaml and verdict.yaml files:

- `examples/pass/` — clean run, no violations
- `examples/fail/` — forbidden path violations (`.env.production`, `config/db.yaml`)

## Forbidden paths

Default forbidden patterns (always applied):

| Pattern | Protects |
|---------|----------|
| `.env` | Environment file |
| `.env.*` | Environment variants (.env.production, .env.local, etc.) |
| `profiles/**/auth.json` | Hermes auth credentials |
| `profiles/**/.env` | Hermes profile env files |

High-risk tasks (`--risk-level high`) add:

| Pattern | Protects |
|---------|----------|
| `config/` | Configuration directory |
| `*.key` | Private keys |
| `*.pem` | Certificates |
| `*.p12` | PKCS#12 keystores |

Additional patterns can be added per-task with `--forbidden-path`.

## Background

Hermes Kanban v0.15.0 introduced Triage, Swarm, worktree-per-task, claim TTL, and stalled detection — absorbing most of hermes-conductor's orchestration. However, two safety gaps remain:

- **S5 (forbidden_paths)**: No machine-enforced post-task diff checks for forbidden or out-of-scope file changes
- **S3 (Verifier gate)**: No external verification of worker-reported task completion

This harness starts with S5-style post-task contract checks and is designed to grow toward S3 verifier-gate validation (AC-level pass/fail, structured review reports).

### Design boundaries

- Guardrail does **not** start or stop agents
- Guardrail does **not** manage Kanban state (no task creation, status changes, or claims)
- Guardrail does **not** use tmux or interactive sessions
- Guardrail only runs `prepare` (before) and `finalize` (after)

## License

MIT
