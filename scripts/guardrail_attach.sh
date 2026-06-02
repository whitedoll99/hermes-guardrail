#!/usr/bin/env bash
# guardrail_attach.sh — Link a Kanban task ID to an existing guardrail source.yaml.
#
# Usage:
#   bash scripts/guardrail_attach.sh --guardrail-id G-20260601-160000 --task-id t42
#
# Exit: 0 = success, 1 = error

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GUARDRAIL_ID=""
TASK_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --guardrail-id) GUARDRAIL_ID="$2"; shift 2 ;;
        --task-id)      TASK_ID="$2"; shift 2 ;;
        -h|--help)
            cat <<'EOF'
Usage: guardrail_attach.sh [OPTIONS]

Options:
  --guardrail-id ID   Guardrail ID from prepare step (required)
  --task-id ID        Kanban task ID to attach (required)
EOF
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ -n "$GUARDRAIL_ID" ]] || fail "--guardrail-id is required"
[[ -n "$TASK_ID" ]]      || fail "--task-id is required"
validate_id "$GUARDRAIL_ID" || fail "Invalid guardrail ID: $GUARDRAIL_ID"

SOURCE_FILE="${STATE_DIR}/${GUARDRAIL_ID}/source.yaml"
[[ -f "$SOURCE_FILE" ]] || fail "source.yaml not found: $SOURCE_FILE"

CURRENT=$(yaml_get "$SOURCE_FILE" "kanban_task_id")
if [[ -n "$CURRENT" && "$CURRENT" != "null" ]]; then
    fail "kanban_task_id already set to '$CURRENT' — refusing to overwrite"
fi

sed -i "s/^kanban_task_id: .*/kanban_task_id: \"${TASK_ID}\"/" "$SOURCE_FILE"

log "attached task_id=$TASK_ID to guardrail=$GUARDRAIL_ID"
echo "  source.yaml: $SOURCE_FILE"
