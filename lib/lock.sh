#!/usr/bin/env bash

set -euo pipefail

# mkdir-based lock. Caller must release (orchestrator EXIT trap).
# Return codes: 0 = acquired, 1 = busy (already running), 2 = error (e.g. permissions).

BACKUP_ACTIVE_LOCK=""

backup_lock_acquire() {
    local lock_dir="${1:-${LOCK_DIR:-/var/run/backup.lock.d}}"
    local parent err

    parent="$(dirname "$lock_dir")"
    if ! err="$(mkdir -p "$parent" 2>&1)"; then
        log_error "Cannot create lock parent ${parent}: ${err}"
        return 2
    fi

    if mkdir "$lock_dir" 2>/dev/null; then
        BACKUP_ACTIVE_LOCK="$lock_dir"
        log_debug "Acquired lock: ${lock_dir}"
        return 0
    fi

    if [[ -d "$lock_dir" ]]; then
        log_info "Already running (lock held at ${lock_dir}), skipping."
        return 1
    fi

    err="$(mkdir "$lock_dir" 2>&1)" || true
    log_error "Cannot acquire lock at ${lock_dir}: ${err:-unknown error}"
    return 2
}

backup_lock_release() {
    if [[ -n "${BACKUP_ACTIVE_LOCK:-}" ]]; then
        rmdir "${BACKUP_ACTIVE_LOCK}" 2>/dev/null || true
        BACKUP_ACTIVE_LOCK=""
    fi
}
