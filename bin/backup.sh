#!/usr/bin/env bash

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${PROJECT_ROOT}/lib"

# shellcheck source=/dev/null
source "${LIB_DIR}/logger.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/sqlite_discovery.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/sqlite_dump.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/telegram.sh"

BACKUP_CONF_PATH_DEFAULT="/etc/backup.conf"
BACKUP_SECRETS_PATH_DEFAULT="/secrets/.backup.env"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
RESTIC_BIN="${RESTIC_BIN:-restic}"

cleanup() {
    if [[ -n "${BACKUP_TMP_DIR:-}" && -d "${BACKUP_TMP_DIR}" ]]; then
        log_info "Removing temporary dump directory: ${BACKUP_TMP_DIR}"
        rm -rf -- "${BACKUP_TMP_DIR}" || true
    fi
}

trap cleanup EXIT INT TERM HUP

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        log_error "Required environment/config variable '${name}' is not set."
        exit 1
    fi
}

load_config() {
    local conf_path="${BACKUP_CONF_PATH:-$BACKUP_CONF_PATH_DEFAULT}"
    local secrets_path="${BACKUP_SECRETS_PATH:-$BACKUP_SECRETS_PATH_DEFAULT}"

    if [[ -f "$conf_path" ]]; then
        # shellcheck source=/dev/null
        source "$conf_path"
        log_debug "Loaded config file: ${conf_path}"
    else
        log_error "Config file not found: ${conf_path}"
        exit 1
    fi

    if [[ -f "$secrets_path" ]]; then
        # Экспортируем переменные из файла с секретами
        set -a
        # shellcheck source=/dev/null
        source "$secrets_path"
        set +a
        log_debug "Loaded secrets file: ${secrets_path}"
    else
        log_warn "Secrets file not found: ${secrets_path}. Continuing without it."
    fi

    require_var "RESTIC_REPOSITORY"
    require_var "DOCKER_DIR"
}

check_restic_repository() {
    log_info "Checking restic repository accessibility: ${RESTIC_REPOSITORY}"
    if ! "${RESTIC_BIN}" -r "${RESTIC_REPOSITORY}" snapshots --last 1 >/dev/null 2>&1; then
        log_error "Restic repository is not accessible or not initialized: ${RESTIC_REPOSITORY}"
        exit 1
    fi
    log_info "Restic repository is accessible."
}

prepare_tmp_dir() {
    local base="${BACKUP_TMP_BASE_DIR:-/tmp}"
    BACKUP_TMP_DIR="$(mktemp -d "${base%/}/backup_dumps.${TIMESTAMP}.XXXXXX")"
    log_info "Temporary directory for DB dumps: ${BACKUP_TMP_DIR}"
}

disk_checkup() {
    local path="${DOCKER_DIR:-/}"

    if df -h "$path" >/dev/null 2>&1; then
        DISK_STATUS="[OK]"
        log_info "Disk checkup for '${path}' passed."
        return 0
    else
        DISK_STATUS="[FAIL]"
        log_warn "Disk checkup for '${path}' failed."
        return 1
    fi
}

send_telegram_report() {
    local host="$1"
    local repo_name="$2"
    local backup_status="$3"
    local backup_status_text="$4"
    local stats="$5"
    local disk_status="${DISK_STATUS:-[UNKNOWN]}"

    local msg
    msg="$(cat <<EOF
<b>Host:</b> ${host}
<b>Disk checkup:</b> ${disk_status}
<b>Repo '${repo_name}' backup:</b> ${backup_status}
<b>Stats:</b>
<pre>${stats}</pre>
Backup ${backup_status_text}.
EOF
)"

    tg_send_html "${msg}"
}

run_backup() {
    load_config
    prepare_tmp_dir

    local host
    host="$(hostname)"

    log_info "Starting backup. Host: ${host}"

    # Disk checkup
    DISK_STATUS="[UNKNOWN]"
    if ! disk_checkup; then
        log_warn "Continuing backup despite disk check failure."
    fi

    # SQLite auto-discovery
    log_info "Discovering SQLite databases under docker directory: ${DOCKER_DIR}"
    mapfile -t SQLITE_DB_FILES < <(sqlite_find_databases "${DOCKER_DIR}") || SQLITE_DB_FILES=()

    if ((${#SQLITE_DB_FILES[@]} > 0)); then
        log_info "Found SQLite databases: ${#SQLITE_DB_FILES[@]}"
        # Dump all discovered SQLite databases
        # Pass the list via stdin to avoid temp list files
        mapfile -t SQLITE_DUMPS < <(
            printf '%s\n' "${SQLITE_DB_FILES[@]}" | sqlite_dump_databases "-" "${BACKUP_TMP_DIR}" "${TIMESTAMP}"
        ) || SQLITE_DUMPS=()
    else
        SQLITE_DUMPS=()
        log_info "No SQLite databases found under docker directory."
    fi

    if ((${#SQLITE_DUMPS[@]} > 0)); then
        log_info "Created SQLite dumps: ${#SQLITE_DUMPS[@]}"
    else
        log_info "No SQLite dumps were created."
    fi

    check_restic_repository

    # Backup targets
    local -a BACKUP_TARGETS=()
    BACKUP_TARGETS+=("${DOCKER_DIR}")
    BACKUP_TARGETS+=("${BACKUP_TMP_DIR}")

    if [[ "${#EXTRA_BACKUP_PATHS[@]:-0}" -gt 0 ]]; then
        for p in "${EXTRA_BACKUP_PATHS[@]}"; do
            BACKUP_TARGETS+=("$p")
        done
    fi

    local -a RESTIC_ARGS=()
    
    if [[ -n "${RESTIC_TAGS:-}" ]]; then
        RESTIC_ARGS+=(--tag "${RESTIC_TAGS}")
    fi

    if [[ -n "${RESTIC_HOST:-}" ]]; then
        RESTIC_ARGS+=(--host "${RESTIC_HOST}")
    fi

    if [[ "${#RESTIC_EXCLUDES[@]:-0}" -gt 0 ]]; then
        for ex in "${RESTIC_EXCLUDES[@]}"; do
            RESTIC_ARGS+=(--exclude "${ex}")
        done
    fi

    log_info "Running restic backup..."
    log_debug "Backup targets: ${BACKUP_TARGETS[*]}"

    local restic_log
    local restic_exit

    # Capture restic output while mirroring it to stdout
    restic_log="$(
        "${RESTIC_BIN}" -r "${RESTIC_REPOSITORY}" backup \
            "${BACKUP_TARGETS[@]}" \
            "${RESTIC_ARGS[@]}" 2>&1 | tee /dev/stdout
    )"
    restic_exit=$?

    local restic_stats
    restic_stats="$(printf '%s\n' "$restic_log" | grep -E 'Files:|Dirs:|Added to the repository' || true)"

    local repo_name
    repo_name="${RESTIC_REPOSITORY##*/}"

    if [[ $restic_exit -ne 0 ]]; then
        log_error "Restic backup finished with errors."
        send_telegram_report "${host}" "${repo_name}" "[FAIL]" "failed" "${restic_stats:-no stats available}"
        exit 1
    fi

    log_info "Restic backup finished successfully."
    send_telegram_report "${host}" "${repo_name}" "[OK]" "completed successfully" "${restic_stats:-no stats available}"
}

run_backup "$@"

