# Batch Queue + Execution Protocol

> **This file is the single source of truth.** The cron prompt only says "read this file and follow its protocol" — edit this file to change behavior; crons never need re-arming for protocol changes.

## CONFIG (edit per machine)

- **Windows**: evening main `20:07` local / morning rollover `07:37` local
  <!-- pick times matching your worker backend's off-peak; avoid :00/:30 sharp -->
- **Pre-flight ping**: `timeout 90 hermes -z "reply with exactly: pong" -p kanban-worker`
- **Lane fallback order**: 1. Kanban worker → 2. <your secondary lane> → 3. <your tertiary lane>
- **Retry policy**: infra retries max 3, spaced +1h (self-scheduled one-shot cron); then roll over `[>]`

## Execution protocol

1. **Pre-flight**: run the ping above before touching any real task. On 429/timeout: retreat immediately — schedule a one-shot cron +1h (on the 3rd retreat of the day, mark remaining items `[>]` for the next window), report the retreat in one line, stop.
2. **Serial execution**: process items dated today or earlier, top-down — `[ ]` plus any `[~]` whose `next=` time has passed. One item = dispatch → review → merge/report, completed before the next item starts.
3. **Failure classification**:
   - **Infrastructure** (429 / crashed / gave_up with API errors): set `[~ retry n/3 next=HH:MM]`, self-schedule a one-shot +1h for the remainder. Past 3 retries → `[>]` next window.
   - **Task-inherent** (acceptance criteria unmet, genuine contract violation, bad spec): set `[!]` + one-line reason. **Never auto-retry.** Continue to the next item.
   - **Timeout**: one retry with doubled max-runtime; on recurrence → `[!]`.
   - Automated verdict failures can be false positives — verify against the actual commits before classifying as task-inherent.
4. **States**: `[ ]` pending / `[~ retry n/3 next=HH:MM]` / `[x]` done + one-line result / `[!]` needs human + reason / `[>]` rolled over.
5. **Reporting**: always emit one summary — partial, retreat, or success. Flag any `[!]` items as requiring a human decision.
6. **Never execute work that is not in this queue.** Items are appended only after being agreed with the operator during the day.
7. Items tagged `window: morning` run only in the morning window (untagged = evening).

## Queue

<!-- append items below, newest section per date -->

## YYYY-MM-DD

- [ ] example item — description, acceptance criteria or pointer to them, guardrail yes/no
