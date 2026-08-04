#!/usr/bin/env bash

set -euo pipefail

# mkdir-based lock. Caller must release (orchestrator EXIT trap).

BACKUP_ACTIVE_LOCK=""

backup_lock_acquire() {
    local lock_dir="${1:-${LOCK_DIR:-/var/run/backup.lock.d}}"
    mkdir -p "$(dirname "$lock_dir")"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        log_info "Already running (lock held at ${lock_dir}), skipping."
        return 1
    fi
    BACKUP_ACTIVE_LOCK="$lock_dir"
    log_debug "Acquired lock: ${lock_dir}"
    return 0
}

backup_lock_release() {
    if [[ -n "${BACKUP_ACTIVE_LOCK:-}" ]]; then
        rmdir "${BACKUP_ACTIVE_LOCK}" 2>/dev/null || true
        BACKUP_ACTIVE_LOCK=""
    fi
}
