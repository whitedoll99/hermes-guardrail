#!/usr/bin/env bash
# guardrail_doctor.sh — Health check for Hermes Kanban + Guardrail runtime.
#
# Checks:
#   1. Hermes Agent availability
#   2. Kanban board health (stuck/blocked tasks, stale ready tasks)
#   3. Worker profiles (on-disk status)
#   4. Guardrail state directory (orphaned source.yaml without verdict)
#   5. Kanban diagnostics (native warnings/errors)
#
# Usage: bash scripts/guardrail_doctor.sh [--no-color] [--json]
#
# Exit: 0 = clean, 1 = errors found, 2 = warnings only

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USE_COLOR=1
JSON_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-color) USE_COLOR=0; shift ;;
        --json)     JSON_MODE=1; USE_COLOR=0; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: guardrail_doctor.sh [--no-color] [--json]

Health check for Hermes Kanban + Guardrail runtime.
EOF
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

# ── Color helpers ──────────────────────────────────────────────────

if [[ "$USE_COLOR" == "1" && -t 1 ]]; then
    C_OK='\033[32m'    C_WARN='\033[33m'    C_ERR='\033[31m'
    C_HDR='\033[1;36m' C_RST='\033[0m'
else
    C_OK='' C_WARN='' C_ERR='' C_HDR='' C_RST=''
fi

ERRORS=0
WARNINGS=0
RESULTS=()

ok()   { RESULTS+=("OK|$1");   printf "${C_OK}  [OK]${C_RST}  %s\n" "$1"; }
warn() { RESULTS+=("WARN|$1"); printf "${C_WARN}  [WARN]${C_RST} %s\n" "$1"; ((WARNINGS++)); }
err()  { RESULTS+=("ERR|$1");  printf "${C_ERR}  [ERR]${C_RST}  %s\n" "$1"; ((ERRORS++)); }
hdr()  { printf "\n${C_HDR}── %s ──${C_RST}\n" "$1"; }

# ── 1. Hermes Agent ───────────────────────────────────────────────

hdr "Hermes Agent"

if command -v hermes &>/dev/null; then
    HERMES_VER=$(hermes --version 2>&1 | head -1)
    ok "hermes available: $HERMES_VER"
else
    err "hermes command not found"
fi

# ── 2. Kanban board health ────────────────────────────────────────

hdr "Kanban Board"

STATS_JSON=$(hermes kanban stats --json 2>/dev/null || echo '')

if [[ -z "$STATS_JSON" || "$STATS_JSON" == "{}" ]]; then
    warn "kanban stats returned no data — hermes kanban may not be responding"
    STATS_JSON='{"by_status":{}}'
fi

READY_COUNT=$(printf '%s' "$STATS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('by_status', {})
print(d.get('ready', 0))
" 2>/dev/null || echo 0)

BLOCKED_COUNT=$(printf '%s' "$STATS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('by_status', {})
print(d.get('blocked', 0))
" 2>/dev/null || echo 0)

RUNNING_COUNT=$(printf '%s' "$STATS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('by_status', {})
print(d.get('running', 0))
" 2>/dev/null || echo 0)

DONE_COUNT=$(printf '%s' "$STATS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('by_status', {})
print(d.get('done', 0))
" 2>/dev/null || echo 0)

OLDEST_READY=$(printf '%s' "$STATS_JSON" | python3 -c "
import sys, json
v = json.load(sys.stdin).get('oldest_ready_age_seconds')
print(v if v is not None else 'none')
" 2>/dev/null || echo "none")

ok "tasks: ready=$READY_COUNT running=$RUNNING_COUNT blocked=$BLOCKED_COUNT done=$DONE_COUNT"

if [[ "$BLOCKED_COUNT" -gt 0 ]]; then
    warn "$BLOCKED_COUNT blocked task(s) — run 'hermes kanban list' to inspect"
fi

if [[ "$OLDEST_READY" != "none" && "$OLDEST_READY" -gt 3600 ]]; then
    warn "oldest ready task is ${OLDEST_READY}s old (>1h) — may be stuck"
fi

# ── 3. Worker profiles ────────────────────────────────────────────

hdr "Worker Profiles"

ASSIGNEES_OUT=$(hermes kanban assignees 2>/dev/null || echo "")

if echo "$ASSIGNEES_OUT" | grep -q 'kanban-worker.*yes'; then
    ok "kanban-worker profile: installed"
else
    err "kanban-worker profile: not installed or not on disk"
fi

if echo "$ASSIGNEES_OUT" | grep -q 'kanban-hub.*yes'; then
    ok "kanban-hub profile: installed"
else
    warn "kanban-hub profile: not installed (optional)"
fi

# Check for stale conductor-* profiles still having tasks
STALE_PROFILES=$(echo "$ASSIGNEES_OUT" | grep -E 'conductor-.*no' | awk '{print $1}' || true)
if [[ -n "$STALE_PROFILES" ]]; then
    warn "stale conductor profiles with tasks: $(echo $STALE_PROFILES | tr '\n' ' ')"
fi

# ── 4. Guardrail state ───────────────────────────────────────────

hdr "Guardrail State"

if [[ ! -d "$STATE_DIR" ]]; then
    ok "state directory empty (no guardrail runs yet)"
else
    TOTAL_GUARDS=$(find "$STATE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    ORPHANS=0
    ORPHAN_LIST=()

    for dir in "$STATE_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        gid=$(basename "$dir")
        if [[ -f "$dir/source.yaml" && ! -f "$dir/verdict.yaml" ]]; then
            KANBAN_ID=$(yaml_get "$dir/source.yaml" "kanban_task_id")
            if [[ -n "$KANBAN_ID" && "$KANBAN_ID" != "null" ]]; then
                # Has kanban task but no verdict — check if task is done
                TASK_STATUS=$(hermes kanban show "$KANBAN_ID" --json 2>/dev/null \
                    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null || echo "unknown")
                if [[ "$TASK_STATUS" == "done" ]]; then
                    ORPHAN_LIST+=("$gid (task $KANBAN_ID done, finalize pending)")
                    ((ORPHANS++))
                fi
            else
                # No kanban task ID — prepare ran but create didn't
                ORPHAN_LIST+=("$gid (no kanban_task_id)")
                ((ORPHANS++))
            fi
        fi
    done

    ok "guardrail runs: $TOTAL_GUARDS total"

    if [[ $ORPHANS -gt 0 ]]; then
        warn "$ORPHANS guardrail(s) need attention:"
        for o in "${ORPHAN_LIST[@]}"; do
            printf "         - %s\n" "$o"
        done
    fi
fi

# ── 5. Kanban diagnostics ────────────────────────────────────────

hdr "Kanban Diagnostics"

DIAG_JSON=$(hermes kanban diagnostics --json 2>/dev/null || echo '[]')
DIAG_COUNT=$(printf '%s' "$DIAG_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [[ "$DIAG_COUNT" -eq 0 ]]; then
    ok "no active diagnostics"
else
    warn "$DIAG_COUNT active diagnostic(s) — run 'hermes kanban diagnostics' for details"
fi

# ── Summary ───────────────────────────────────────────────────────

hdr "Summary"

if [[ $ERRORS -gt 0 ]]; then
    printf "${C_ERR}  %d error(s), %d warning(s)${C_RST}\n" "$ERRORS" "$WARNINGS"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    printf "${C_WARN}  %d warning(s)${C_RST}\n" "$WARNINGS"
    exit 2
else
    printf "${C_OK}  All checks passed${C_RST}\n"
    exit 0
fi
