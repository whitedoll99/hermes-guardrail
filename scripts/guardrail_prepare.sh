#!/usr/bin/env bash
# guardrail_prepare.sh — Pre-task: freeze safety constraints before Kanban task creation.
#
# Generates a source.yaml snapshot with git base SHA, forbidden paths, and
# acceptance criteria. Prints a suggested `hermes kanban create` command.
#
# Usage:
#   bash scripts/guardrail_prepare.sh \
#     --project-dir ~/mastra-agent \
#     --title "Fix memory leak" \
#     --risk-level medium \
#     --forbidden-path "secrets/" \
#     --ac "Memory usage stays under 512MB" \
#     --ac "All existing tests pass"
#
# Exit: 0 = success, 1 = error

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ── Argument parsing ────────────────────────────────────────────────

PROJECT_DIR=""
TITLE=""
RISK_LEVEL="medium"
EXTRA_FORBIDDEN=()
ALLOWED_FILES=()
AC_LIST=()
ASSIGNEE="kanban-worker"
MAX_RUNTIME="300"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)     PROJECT_DIR="$2"; shift 2 ;;
        --title)           TITLE="$2"; shift 2 ;;
        --risk-level)      RISK_LEVEL="$2"; shift 2 ;;
        --forbidden-path)  EXTRA_FORBIDDEN+=("$2"); shift 2 ;;
        --allowed-file)    ALLOWED_FILES+=("$2"); shift 2 ;;
        --ac)              AC_LIST+=("$2"); shift 2 ;;
        --assignee)        ASSIGNEE="$2"; shift 2 ;;
        --max-runtime)     MAX_RUNTIME="$2"; shift 2 ;;
        -h|--help)
            cat <<'EOF'
Usage: guardrail_prepare.sh [OPTIONS]

Options:
  --project-dir DIR     Target project directory (required)
  --title TEXT          Task title (required)
  --risk-level LEVEL   low/medium/high (default: medium)
  --forbidden-path PAT  Additional forbidden path pattern (repeatable)
  --allowed-file FILE   Allowed file (repeatable, optional)
  --ac TEXT             Acceptance criterion (repeatable, auto-numbered)
  --assignee PROFILE   Kanban assignee (default: kanban-worker)
  --max-runtime SEC    Per-task runtime cap (default: 300)
EOF
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ -n "$PROJECT_DIR" ]] || fail "--project-dir is required"
[[ -d "$PROJECT_DIR" ]] || fail "project-dir does not exist: $PROJECT_DIR"
[[ -n "$TITLE" ]]       || fail "--title is required"

case "$RISK_LEVEL" in
    low|medium|high) ;;
    *) log "WARN: invalid risk_level '$RISK_LEVEL', defaulting to medium"; RISK_LEVEL="medium" ;;
esac

# ── Resolve project dir to absolute path ────────────────────────────

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# ── Git base SHA ────────────────────────────────────────────────────

GIT_BASE_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null) \
    || fail "Cannot resolve HEAD in $PROJECT_DIR (is it a git repo?)"

# ── Guardrail ID ────────────────────────────────────────────────────

GUARDRAIL_ID="G-$(date +%Y%m%d-%H%M%S)"

# ── Forbidden paths (defaults + risk-level extras + user extras) ────

DEFAULT_FORBIDDEN=(
    ".env"
    ".env.*"
    "profiles/**/auth.json"
    "profiles/**/.env"
)

HIGH_RISK_EXTRA=(
    "config/"
    "*.key"
    "*.pem"
    "*.p12"
)

FORBIDDEN_PATHS=("${DEFAULT_FORBIDDEN[@]}")
if [[ "$RISK_LEVEL" == "high" ]]; then
    FORBIDDEN_PATHS+=("${HIGH_RISK_EXTRA[@]}")
fi
FORBIDDEN_PATHS+=("${EXTRA_FORBIDDEN[@]}")

# Deduplicate
mapfile -t FORBIDDEN_PATHS < <(printf '%s\n' "${FORBIDDEN_PATHS[@]}" | sort -u)

# ── Acceptance criteria with IDs ────────────────────────────────────

AC_NUMBERED=()
for i in "${!AC_LIST[@]}"; do
    n=$((i + 1))
    AC_NUMBERED+=("$(printf 'AC%03d: %s' "$n" "${AC_LIST[$i]}")")
done

# ── Write source.yaml ──────────────────────────────────────────────

TASK_STATE_DIR="${STATE_DIR}/${GUARDRAIL_ID}"
mkdir -p "$TASK_STATE_DIR"

SOURCE_FILE="${TASK_STATE_DIR}/source.yaml"
CREATED_AT=$(date --iso-8601=seconds)

{
    echo "# guardrail source snapshot — immutable after creation"
    printf 'guardrail_id: "%s"\n' "$GUARDRAIL_ID"
    printf 'task_title: "%s"\n' "$(yaml_dq_escape "$TITLE")"
    printf 'project_dir: "%s"\n' "$(yaml_dq_escape "$PROJECT_DIR")"
    printf 'git_base_sha: "%s"\n' "$GIT_BASE_SHA"
    printf 'risk_level: "%s"\n' "$RISK_LEVEL"
    printf 'created_at: "%s"\n' "$CREATED_AT"
    echo 'kanban_task_id: null'

    echo "forbidden_paths:"
    for p in "${FORBIDDEN_PATHS[@]}"; do
        printf '  - "%s"\n' "$(yaml_dq_escape "$p")"
    done

    if [[ ${#ALLOWED_FILES[@]} -eq 0 ]]; then
        echo "allowed_files: []"
    else
        echo "allowed_files:"
        for f in "${ALLOWED_FILES[@]}"; do
            printf '  - "%s"\n' "$(yaml_dq_escape "$f")"
        done
    fi

    if [[ ${#AC_NUMBERED[@]} -eq 0 ]]; then
        echo "acceptance_criteria: []"
    else
        echo "acceptance_criteria:"
        for ac in "${AC_NUMBERED[@]}"; do
            printf '  - "%s"\n' "$(yaml_dq_escape "$ac")"
        done
    fi
} > "$SOURCE_FILE"

log "source.yaml written: $SOURCE_FILE"

# ── Build Kanban body ──────────────────────────────────────────────

BODY="## Task\n${TITLE}\n"
if [[ ${#AC_NUMBERED[@]} -gt 0 ]]; then
    BODY+="\n## Acceptance Criteria\n"
    for ac in "${AC_NUMBERED[@]}"; do
        BODY+="- ${ac}\n"
    done
fi
if [[ ${#FORBIDDEN_PATHS[@]} -gt 0 ]]; then
    BODY+="\n## Constraints\n"
    BODY+="Do NOT modify the following paths:\n"
    for p in "${FORBIDDEN_PATHS[@]}"; do
        BODY+="- \`${p}\`\n"
    done
fi
BODY+="\n## Guardrail\nGuardrail ID: ${GUARDRAIL_ID}\nBase SHA: ${GIT_BASE_SHA}\n"

BODY_FLAT=$(printf '%b' "$BODY")

# ── Output ─────────────────────────────────────────────────────────

echo ""
echo "=== Guardrail Prepared ==="
echo "  ID:         $GUARDRAIL_ID"
echo "  Project:    $PROJECT_DIR"
echo "  Base SHA:   $GIT_BASE_SHA"
echo "  Risk:       $RISK_LEVEL"
echo "  Forbidden:  ${#FORBIDDEN_PATHS[@]} patterns"
echo "  AC:         ${#AC_NUMBERED[@]} criteria"
echo "  Source:     $SOURCE_FILE"
echo ""
echo "=== Suggested Kanban Command ==="
printf 'hermes kanban create --assignee %s --workspace worktree --max-runtime %s \\\n' \
    "$ASSIGNEE" "$MAX_RUNTIME"
printf '  --body "%s" \\\n' '$(cat '"$SOURCE_FILE"' | head -1)...'
printf '  "%s"\n' "$TITLE"
echo ""
echo "Or with full body:"
echo ""
printf 'hermes kanban create --assignee %s --workspace worktree --max-runtime %s --body "$(cat <<'\''BODY'\''\n%s\nBODY\n)" "%s"\n' \
    "$ASSIGNEE" "$MAX_RUNTIME" "$BODY_FLAT" "$TITLE"
