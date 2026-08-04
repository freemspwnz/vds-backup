#!/usr/bin/env bash

set -euo pipefail

backup_require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        log_error "Required variable '${name}' is not set."
        return 1
    fi
}

backup_load_env_file() {
    local env_file="${1:-}"
    if [[ -z "$env_file" || ! -f "$env_file" ]]; then
        [[ -n "$env_file" ]] && log_warn "Env file not found: ${env_file}"
        return 0
    fi
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    log_debug "Loaded env: ${env_file}"
}
