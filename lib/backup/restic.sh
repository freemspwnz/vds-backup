#!/usr/bin/env bash

set -euo pipefail

# Restic-related helpers for backup.
#
# Uses the following variables from the environment/config:
#   RESTIC_BIN         - path to restic binary (optional, defaults to `restic`)
#   RESTIC_REPOSITORY  - restic repository URL (required)
#
# Exposes:
#   backup_check_repository
#   backup_run_restic_backup
#   BACKUP_RESTIC_LOG   - captures last restic backup output (stdout+stderr)
#   BACKUP_RESTIC_EXIT  - exit code of last restic backup command

RESTIC_BIN="${RESTIC_BIN:-restic}"

backup_check_repository() {
    log_info "Checking restic repository accessibility: ${RESTIC_REPOSITORY}"
    if ! "${RESTIC_BIN}" -r "${RESTIC_REPOSITORY}" snapshots --last 1 >/dev/null 2>&1; then
        log_error "Restic repository is not accessible or not initialized: ${RESTIC_REPOSITORY}"
        return 1
    fi
    log_info "Restic repository is accessible."
}

backup_run_restic_backup() {
    # All arguments are passed directly to `restic backup` after the repository.
    # Example call:
    #   backup_run_restic_backup "${BACKUP_TARGETS[@]}" "${RESTIC_ARGS[@]}"
    #
    # This function:
    #   - mirrors the restic output to stdout,
    #   - captures the full output in BACKUP_RESTIC_LOG,
    #   - stores the exit code in BACKUP_RESTIC_EXIT.

    BACKUP_RESTIC_LOG="$(
        "${RESTIC_BIN}" -r "${RESTIC_REPOSITORY}" backup "$@" 2>&1
    )"
    BACKUP_RESTIC_EXIT=$?
}

backup_extract_restic_stats() {
    # Extract key stats lines from BACKUP_RESTIC_LOG
    printf '%s\n' "${BACKUP_RESTIC_LOG:-}" | grep -E 'Files:|Dirs:|Added to the repository' || true
}

