#!/usr/bin/env bash

set -euo pipefail

# flock-based lock. Held via an open FD until release or process exit (incl. SIGKILL).
# Caller should still release on EXIT trap for tidy unlock before exit.
# Return codes: 0 = acquired, 1 = busy (already running), 2 = error (e.g. permissions).
#
# Uses fixed FD BACKUP_LOCK_FD_NUM so this works on bash 3.2+ (no {fd} realloc).

BACKUP_ACTIVE_LOCK=""
BACKUP_LOCK_FD=""
BACKUP_LOCK_FD_NUM=200

backup_lock_acquire() {
    local lock_file="${1:-${LOCK_FILE:-/var/run/backup/backup.lock}}"
    local parent

    if [[ -n "${BACKUP_LOCK_FD:-}" ]]; then
        log_error "Lock already held by this process (${BACKUP_ACTIVE_LOCK})"
        return 2
    fi

    if ! command -v flock >/dev/null 2>&1; then
        log_error "flock not found (install util-linux)"
        return 2
    fi

    parent="$(dirname "$lock_file")"
    if ! mkdir -p "$parent" 2>/dev/null; then
        log_error "Cannot create lock parent ${parent}"
        return 2
    fi

    # Open/create lock file; keep FD open for the lifetime of the lock.
    if ! eval "exec ${BACKUP_LOCK_FD_NUM}>\"\${lock_file}\""; then
        log_error "Cannot open lock file ${lock_file}"
        return 2
    fi

    if ! flock -n "${BACKUP_LOCK_FD_NUM}"; then
        eval "exec ${BACKUP_LOCK_FD_NUM}>&-" 2>/dev/null || true
        log_info "Already running (lock held at ${lock_file}), skipping."
        return 1
    fi

    BACKUP_LOCK_FD="${BACKUP_LOCK_FD_NUM}"
    BACKUP_ACTIVE_LOCK="$lock_file"
    # Best-effort owner hint for operators (not used for lock logic).
    printf '%s\n' "$$" >"${lock_file}.pid" 2>/dev/null || true
    log_debug "Acquired lock: ${lock_file} (fd ${BACKUP_LOCK_FD})"
    return 0
}

backup_lock_release() {
    if [[ -n "${BACKUP_LOCK_FD:-}" ]]; then
        flock -u "${BACKUP_LOCK_FD}" 2>/dev/null || true
        eval "exec ${BACKUP_LOCK_FD}>&-" 2>/dev/null || true
        BACKUP_LOCK_FD=""
    fi
    if [[ -n "${BACKUP_ACTIVE_LOCK:-}" ]]; then
        rm -f -- "${BACKUP_ACTIVE_LOCK}.pid" 2>/dev/null || true
        BACKUP_ACTIVE_LOCK=""
    fi
}
