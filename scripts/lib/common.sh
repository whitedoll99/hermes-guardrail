#!/usr/bin/env bash
# hermes-guardrail shared helpers.
# Source with: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

GUARDRAIL_DIR="${GUARDRAIL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DIR="${GUARDRAIL_DIR}/state"

# validate_id — returns 0 if value is a safe identifier (alphanumeric + _ . -)
validate_id() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

# yaml_dq_escape — escapes a value for use inside a YAML double-quoted scalar.
yaml_dq_escape() {
    local v="${1:-$(cat)}"
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    printf '%s' "$v"
}

# yaml_get — read a scalar YAML field value (top-level only, grep-based).
# Usage: val=$(yaml_get file.yaml field_name)
yaml_get() {
    local file="$1" key="$2"
    grep -oP "^${key}:\s*\K[^\n]+" "$file" 2>/dev/null | head -1 \
        | sed -E "s/^['\"]//;s/['\"]$//" || true
}

# read_yaml_list — read a YAML list into a bash array via nameref.
# Usage: read_yaml_list file.yaml forbidden_paths arr
read_yaml_list() {
    local file="$1" key="$2"
    local -n _result="$3"
    mapfile -t _result < <(
        awk -v k="$key" '
            $0 ~ "^"k":" { found=1; next }
            found && /^  - / { val=$0; sub(/^  - "?/,"",val); sub(/"?$/,"",val); print val }
            found && /^[^ ]/ { exit }
        ' "$file" 2>/dev/null || true
    )
}

# log — prefixed stderr logging
log() {
    echo "[guardrail] $*" >&2
}

# fail — log error and exit
fail() {
    log "ERROR: $*"
    exit 1
}
