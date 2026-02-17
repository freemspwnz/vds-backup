#!/usr/bin/env bash

set -euo pipefail

# High-level backup orchestration.
# This module wires together:
#   - config loading
#   - disk/source checks
#   - SQLite discovery and dumps
#   - restic backup execution
#   - Telegram reporting

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_TMP_DIR=""

backup_cleanup() {
    if [[ -n "${BACKUP_TMP_DIR:-}" && -d "${BACKUP_TMP_DIR}" ]]; then
        log_info "Removing temporary dump directory: ${BACKUP_TMP_DIR}"
        rm -rf -- "${BACKUP_TMP_DIR}" || true
    fi
}

backup_prepare_tmp_dir() {
    local base="${BACKUP_TMP_BASE_DIR:-/tmp}"
    BACKUP_TMP_DIR="$(mktemp -d "${base%/}/backup_dumps.${TIMESTAMP}.XXXXXX")"
    log_info "Temporary directory for DB dumps: ${BACKUP_TMP_DIR}"
}

backup_run() {
    trap backup_cleanup EXIT INT TERM HUP

    backup_load_config
    backup_prepare_tmp_dir

    local host
    host="$(hostname)"

    log_info "Starting backup. Host: ${host}"

    # Disk/source check
    DISK_STATUS="[UNKNOWN]"
    if ! backup_disk_check; then
        log_warn "Continuing backup despite disk check failure."
    fi

    # SQLite auto-discovery and dumps
    log_info "Discovering SQLite databases under docker directory: ${DOCKER_DIR}"
    local -a SQLITE_DB_FILES=()
    mapfile -t SQLITE_DB_FILES < <(sqlite_find_databases "${DOCKER_DIR}") || SQLITE_DB_FILES=()

    local -a SQLITE_DUMPS=()
    if ((${#SQLITE_DB_FILES[@]} > 0)); then
        log_info "Found SQLite databases: ${#SQLITE_DB_FILES[@]}"
        mapfile -t SQLITE_DUMPS < <(
            printf '%s\n' "${SQLITE_DB_FILES[@]}" | sqlite_dump_databases "-" "${BACKUP_TMP_DIR}" "${TIMESTAMP}"
        ) || SQLITE_DUMPS=()
    else
        log_info "No SQLite databases found under docker directory."
    fi

    if ((${#SQLITE_DUMPS[@]} > 0)); then
        log_info "Created SQLite dumps: ${#SQLITE_DUMPS[@]}"
    else
        log_info "No SQLite dumps were created."
    fi

    # PostgreSQL dump (optional, via Docker)
    backup_postgres_dump || log_warn "PostgreSQL dump step reported an error; continuing with backup."

    backup_check_repository

    # Build backup targets
    local -a BACKUP_TARGETS=()
    BACKUP_TARGETS+=("${DOCKER_DIR}")
    BACKUP_TARGETS+=("${BACKUP_TMP_DIR}")

    if [[ "${#EXTRA_BACKUP_PATHS[@]}" -gt 0 ]]; then
        local p
        for p in "${EXTRA_BACKUP_PATHS[@]}"; do
            BACKUP_TARGETS+=("$p")
        done
    fi

    # Build restic args
    local -a RESTIC_ARGS=()
    if [[ -n "${RESTIC_TAGS:-}" ]]; then
        RESTIC_ARGS+=(--tag "${RESTIC_TAGS}")
    fi
    if [[ -n "${RESTIC_HOST:-}" ]]; then
        RESTIC_ARGS+=(--host "${RESTIC_HOST}")
    fi
    if [[ "${#RESTIC_EXCLUDES[@]}" -gt 0 ]]; then
        local ex
        for ex in "${RESTIC_EXCLUDES[@]}"; do
            RESTIC_ARGS+=(--exclude "${ex}")
        done
    fi

    log_info "Running restic backup..."
    log_debug "Backup targets: ${BACKUP_TARGETS[*]}"

    # Execute restic backup and capture output
    backup_run_restic_backup "${BACKUP_TARGETS[@]}" "${RESTIC_ARGS[@]}"

    local restic_stats
    restic_stats="$(backup_extract_restic_stats)"

    local repo_name
    repo_name="${RESTIC_REPOSITORY##*/}"

    if [[ "${BACKUP_RESTIC_EXIT:-1}" -ne 0 ]]; then
        log_error "Restic backup finished with errors."
        backup_send_telegram_report "${host}" "${repo_name}" "[FAIL]" "failed" "${restic_stats:-no stats available}"
        return 1
    fi

    log_info "Restic backup finished successfully."
    backup_send_telegram_report "${host}" "${repo_name}" "[OK]" "completed successfully" "${restic_stats:-no stats available}"
    return 0
}

