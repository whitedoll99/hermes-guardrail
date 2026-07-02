# Batch Window Protocol

A lightweight convention for running queued Kanban work in scheduled windows — built for worker backends whose availability or pricing varies by time of day (e.g., Z.AI GLM off-peak quota discounts), driven by a **persistent interactive agent session** rather than disposable one-shot instances.

## Why not a plain OS cron?

Two reasons this pattern deliberately wakes a long-lived agent session instead of spawning `claude -p`-style one-shot workers:

1. **Continuity.** A disposable instance completes the task and vanishes — it cannot write the session diary, hand-off notes, or memory that a persistent agent maintains. The batch runs *inside* the same agent that planned the work during the day.
2. **Judgment at review time.** Each queue item ends with the agent reviewing the worker's diff before merging. That review needs the planning context the persistent session already holds.

## Components

| Piece | Where | Role |
|---|---|---|
| `batch-queue.template.md` | copy to a config dir of your choice | Queue **and** protocol in one file — the single source of truth |
| Scheduled wake-ups | your agent runtime's cron facility (session-scoped is fine) | Fire the agent at the window times with a one-line prompt: *"read the queue file and follow its protocol"* |
| Re-arm rule | your agent's standing instructions (e.g., project CLAUDE.md) | Session-scoped crons die with the session — instruct the agent to re-arm on session start |

Keeping the protocol in the queue file (not in the cron prompt) means protocol changes never require re-arming crons — the prompt is just a pointer.

## Setup

1. Copy `batch-queue.template.md` to e.g. `~/.config/<your-project>/batch-queue.md` and edit the CONFIG block (window times, pre-flight ping command, lane fallback order).
2. Arm the window crons in your agent runtime. Example (Claude Code session cron, two windows):
   - evening main window: `7 20 * * *`
   - morning rollover window: `37 7 * * *`
   - prompt for both: `Read <queue-path> and execute pending items strictly per its protocol section.`
3. Add a re-arm rule to your agent's standing instructions:
   > On session start, if the batch window crons are not present in CronList, re-arm them. The protocol source of truth is `<queue-path>`.
4. During the day, append agreed work items to the queue. **The batch executes only what is in the queue.**

## Failure classification (the heart of the retry design)

Naive hourly retries amplify garbage: retrying a badly-specified task burns quota and produces noise. The protocol therefore classifies failures **before** deciding to retry:

| Class | Signals | Action |
|---|---|---|
| **Infrastructure** | HTTP 429, worker crash, gave_up with API errors | retry via self-scheduled one-shot (+1h), max 3, then roll to next window |
| **Task-inherent** | acceptance criteria unmet, genuine contract violation, bad spec | mark `[!]` needs-human; **never auto-retry** |
| **Timeout** | run exceeded max-runtime | one retry with doubled runtime, then `[!]` |

Two false-positive guards:

- **Pre-flight ping**: before dispatching real tasks, ping the worker LLM once (e.g., `timeout 90 hermes -z "reply: pong" -p kanban-worker`). If the backend is down, retreat and self-reschedule without burning task attempts.
- **Verdict double-check**: automated contract verdicts can false-positive (e.g., artifacts from unrelated concurrent work appearing in a diff). The agent verifies findings against the actual commits before classifying a failure as task-inherent.

And one anti-silence guard: **every run ends with a summary report** — partial completion, full retreat, or success alike. Silent failure is not a state this protocol can express.

## Item states

```
[ ]                        pending
[~ retry n/3 next=HH:MM]   infrastructure-blocked, awaiting retry
[x]                        done (+ one-line result)
[!]                        needs human (+ reason) — never auto-retried
[>]                        rolled over to the next window
```
