#!/usr/bin/env bash

set -euo pipefail

backup_require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        log_error "Required variable '${name}' is not set."
        return 1
    fi
}

backup_require_cmd() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        log_error "Preflight: '${name}' not found in PATH"
        return 1
    fi
}

# Check required binaries before jobs run.
# Optional $1: newline-separated job files (to detect BACKEND=sftp overrides).
backup_preflight() {
    local job_list="${1:-}"
    local missing=0 need_ssh=0 line

    backup_require_cmd flock || missing=1
    backup_require_cmd "${RESTIC_BIN:-restic}" || missing=1

    if [[ -n "${TG_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; then
        backup_require_cmd curl || missing=1
    fi

    if [[ "${BACKUP_BACKEND_DEFAULT:-${BACKEND:-sftp}}" == "sftp" ]]; then
        need_ssh=1
    elif [[ -n "$job_list" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if backup_load_job_file "$line"; then
                if [[ "${BACKEND}" == "sftp" ]]; then
                    need_ssh=1
                    break
                fi
            fi
        done <<< "$job_list"
    fi

    if [[ "$need_ssh" -eq 1 ]]; then
        backup_require_cmd ssh || missing=1
    fi

    [[ "$missing" -eq 0 ]]
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
