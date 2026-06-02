#!/usr/bin/env bash
# guardrail_finalize.sh — Post-task: verify contract compliance after Kanban task completion.
#
# Reads the source.yaml snapshot created by guardrail_prepare.sh, computes
# git diff since the base SHA, and checks for forbidden_paths violations.
# Writes a verdict.yaml with the result.
#
# Usage:
#   bash scripts/guardrail_finalize.sh --guardrail-id G-20260601-160000
#   bash scripts/guardrail_finalize.sh --guardrail-id G-20260601-160000 --project-dir ~/alt
#
# Exit: 0 = pass, 1 = fail (violations), 2 = inconclusive (missing data)

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# ── Argument parsing ────────────────────────────────────────────────

GUARDRAIL_ID=""
PROJECT_DIR_OVERRIDE=""
BRANCH_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --guardrail-id) GUARDRAIL_ID="$2"; shift 2 ;;
        --project-dir)  PROJECT_DIR_OVERRIDE="$2"; shift 2 ;;
        --branch)       BRANCH_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            cat <<'EOF'
Usage: guardrail_finalize.sh [OPTIONS]

Options:
  --guardrail-id ID   Guardrail ID from prepare step (required)
  --project-dir DIR   Override project directory (default: from source.yaml)
  --branch BRANCH     Compare against this branch instead of HEAD (for worktree tasks)
EOF
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ -n "$GUARDRAIL_ID" ]] || fail "--guardrail-id is required"
validate_id "$GUARDRAIL_ID" || fail "Invalid guardrail ID: $GUARDRAIL_ID"

# ── Read source.yaml ───────────────────────────────────────────────

SOURCE_FILE="${STATE_DIR}/${GUARDRAIL_ID}/source.yaml"
[[ -f "$SOURCE_FILE" ]] || inconclusive "source.yaml not found: $SOURCE_FILE"

PROJECT_DIR=$(yaml_get "$SOURCE_FILE" "project_dir")
GIT_BASE_SHA=$(yaml_get "$SOURCE_FILE" "git_base_sha")

if [[ -n "$PROJECT_DIR_OVERRIDE" ]]; then
    PROJECT_DIR="$PROJECT_DIR_OVERRIDE"
fi

[[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]] || inconclusive "project_dir invalid: ${PROJECT_DIR:-<empty>}"
[[ -n "$GIT_BASE_SHA" && "$GIT_BASE_SHA" != "null" ]] || inconclusive "git_base_sha missing in source.yaml"

# Read forbidden_paths
FORBIDDEN_PATHS=()
read_yaml_list "$SOURCE_FILE" "forbidden_paths" FORBIDDEN_PATHS

# Read allowed_files
ALLOWED_FILES=()
read_yaml_list "$SOURCE_FILE" "allowed_files" ALLOWED_FILES

log "guardrail_id=$GUARDRAIL_ID project_dir=$PROJECT_DIR base_sha=${GIT_BASE_SHA:0:12}"
log "forbidden_paths=${#FORBIDDEN_PATHS[@]} allowed_files=${#ALLOWED_FILES[@]}"

# ── Determine comparison target ───────────────────────────────────

COMPARE_REF="HEAD"
if [[ -n "$BRANCH_OVERRIDE" ]]; then
    if git -C "$PROJECT_DIR" rev-parse --verify "$BRANCH_OVERRIDE" &>/dev/null; then
        COMPARE_REF="$BRANCH_OVERRIDE"
        log "comparing against branch: $COMPARE_REF"
    else
        inconclusive "branch not found: $BRANCH_OVERRIDE"
    fi
else
    KANBAN_TASK_ID=$(yaml_get "$SOURCE_FILE" "kanban_task_id")
    if [[ -n "$KANBAN_TASK_ID" && "$KANBAN_TASK_ID" != "null" ]]; then
        AUTO_BRANCH="wt/${KANBAN_TASK_ID}"
        if git -C "$PROJECT_DIR" rev-parse --verify "$AUTO_BRANCH" &>/dev/null; then
            COMPARE_REF="$AUTO_BRANCH"
            log "auto-detected worker branch: $COMPARE_REF"
        fi
    fi
fi

# ── Collect changed files ──────────────────────────────────────────

COMMITTED_CHANGES=$(git -C "$PROJECT_DIR" diff --name-only "${GIT_BASE_SHA}" "$COMPARE_REF" 2>/dev/null || true)
UNCOMMITTED_CHANGES=$(git -C "$PROJECT_DIR" diff --name-only "$COMPARE_REF" 2>/dev/null || true)
UNTRACKED=$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard 2>/dev/null || true)

ALL_CHANGED=$(printf '%s\n%s\n%s\n' "$COMMITTED_CHANGES" "$UNCOMMITTED_CHANGES" "$UNTRACKED" \
    | sort -u | grep -v '^$' || true)

if [[ -z "$ALL_CHANGED" ]]; then
    log "No changed files detected"
fi

if [[ -z "$ALL_CHANGED" ]]; then
    CHANGED_COUNT=0
else
    CHANGED_COUNT=$(printf '%s\n' "$ALL_CHANGED" | wc -l | tr -d ' ')
fi
log "Changed files: $CHANGED_COUNT"

# ── glob_to_regex ──────────────────────────────────────────────────

glob_to_regex() {
    local pat="$1"
    # Trailing slash means "everything under this directory"
    if [[ "$pat" == */ ]]; then
        pat="${pat}**"
    fi
    pat=$(printf '%s' "$pat" | sed 's/\./\\./g; s/+/\\+/g; s/\[/\\[/g; s/\]/\\]/g')
    pat="${pat//\*\*/___DOUBLESTAR___}"
    pat="${pat//\*/[^\/]*}"
    pat="${pat//___DOUBLESTAR___/.*}"
    pat="${pat//\?/[^\/]}"
    printf '%s' "$pat"
}

# ── Check against forbidden_paths and allowed_files ────────────────

CONTRACT_VIOLATIONS=()
UNEXPECTED_FILES=()

while IFS= read -r changed_file; do
    [[ -z "$changed_file" ]] && continue

    forbidden_hit=""
    for pattern in "${FORBIDDEN_PATHS[@]}"; do
        regex=$(glob_to_regex "$pattern")
        if [[ "$changed_file" =~ ^$regex$ ]]; then
            forbidden_hit="$pattern"
            break
        fi
    done

    if [[ -n "$forbidden_hit" ]]; then
        CONTRACT_VIOLATIONS+=("${changed_file}|${forbidden_hit}")
        continue
    fi

    if [[ ${#ALLOWED_FILES[@]} -gt 0 ]]; then
        allowed=false
        for pattern in "${ALLOWED_FILES[@]}"; do
            regex=$(glob_to_regex "$pattern")
            if [[ "$changed_file" =~ ^$regex$ ]]; then
                allowed=true
                break
            fi
        done
        if [[ "$allowed" != "true" ]]; then
            UNEXPECTED_FILES+=("$changed_file")
        fi
    fi
done <<< "$ALL_CHANGED"

# ── Determine verdict ─────────────────────────────────────────────

if [[ ${#CONTRACT_VIOLATIONS[@]} -gt 0 || ${#UNEXPECTED_FILES[@]} -gt 0 ]]; then
    CONTRACT_CHECK="fail"
    VERDICT="fail"
else
    CONTRACT_CHECK="pass"
    VERDICT="pass"
fi

# ── Write verdict.yaml ─────────────────────────────────────────────

VERDICT_FILE="${STATE_DIR}/${GUARDRAIL_ID}/verdict.yaml"
FINALIZED_AT=$(date --iso-8601=seconds)

{
    echo "# guardrail verdict"
    printf 'guardrail_id: "%s"\n' "$GUARDRAIL_ID"
    printf 'finalized_at: "%s"\n' "$FINALIZED_AT"
    printf 'contract_check: "%s"\n' "$CONTRACT_CHECK"
    printf 'changed_files_count: %d\n' "$CHANGED_COUNT"

    if [[ ${#CONTRACT_VIOLATIONS[@]} -eq 0 ]]; then
        echo "contract_violations: []"
    else
        echo "contract_violations:"
        for v in "${CONTRACT_VIOLATIONS[@]}"; do
            local_file="${v%%|*}"
            local_pattern="${v##*|}"
            printf '  - file: "%s"\n    matched_pattern: "%s"\n' \
                "$(yaml_dq_escape "$local_file")" "$(yaml_dq_escape "$local_pattern")"
        done
    fi

    if [[ ${#UNEXPECTED_FILES[@]} -eq 0 ]]; then
        echo "unexpected_files: []"
    else
        echo "unexpected_files:"
        for f in "${UNEXPECTED_FILES[@]}"; do
            printf '  - "%s"\n' "$(yaml_dq_escape "$f")"
        done
    fi

    echo 'ac_verification: "manual_required"'
    printf 'verdict: "%s"\n' "$VERDICT"
} > "$VERDICT_FILE"

# ── Output ─────────────────────────────────────────────────────────

echo ""
echo "=== Guardrail Verdict ==="
echo "  ID:              $GUARDRAIL_ID"
echo "  Contract check:  $CONTRACT_CHECK"
echo "  AC verification: manual_required"
echo "  Verdict:         $VERDICT"

if [[ ${#CONTRACT_VIOLATIONS[@]} -gt 0 ]]; then
    echo ""
    echo "  Contract violations:"
    for v in "${CONTRACT_VIOLATIONS[@]}"; do
        local_file="${v%%|*}"
        local_pattern="${v##*|}"
        echo "    - $local_file (matches: $local_pattern)"
    done
fi

if [[ ${#UNEXPECTED_FILES[@]} -gt 0 ]]; then
    echo ""
    echo "  Unexpected files (not in allowed_files):"
    for f in "${UNEXPECTED_FILES[@]}"; do
        echo "    - $f"
    done
fi

echo ""
echo "  Verdict file: $VERDICT_FILE"

if [[ "$VERDICT" == "fail" ]]; then
    exit 1
fi
exit 0
