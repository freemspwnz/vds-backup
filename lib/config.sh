#!/usr/bin/env bash

set -euo pipefail

# Global defaults + jobs.d/*.conf (one file = one restic repository / backup set).

BACKUP_CONF_DEFAULT="/usr/local/etc/backup/backup.conf"
JOBS_DIR_DEFAULT="/usr/local/etc/backup/jobs.d"
ENV_FILE_DEFAULT="/usr/local/etc/backup/.env"

backup_resolve_env_file() {
    if [[ -n "${ENV_FILE:-}" ]]; then
        printf '%s\n' "$ENV_FILE"
        return 0
    fi
    if [[ -f "$ENV_FILE_DEFAULT" ]]; then
        printf '%s\n' "$ENV_FILE_DEFAULT"
        return 0
    fi
    if [[ -n "${BACKUP_REPO_ROOT:-}" && -f "${BACKUP_REPO_ROOT}/.env" ]]; then
        printf '%s\n' "${BACKUP_REPO_ROOT}/.env"
        return 0
    fi
    printf '%s\n' "$ENV_FILE_DEFAULT"
}

backup_load_global() {
    local conf_path="${BACKUP_CONF_PATH:-$BACKUP_CONF_DEFAULT}"
    local env_file

    if [[ ! -f "$conf_path" ]]; then
        log_error "Config not found: ${conf_path} (install backup.conf or set BACKUP_CONF_PATH)"
        return 1
    fi

    # shellcheck source=/dev/null
    # Trusted admin-owned file only: sourced as bash (arbitrary code).
    source "$conf_path"
    log_debug "Loaded global config: ${conf_path}"

    JOBS_DIR="${JOBS_DIR:-$JOBS_DIR_DEFAULT}"
    LOCK_DIR_BASE="${LOCK_DIR_BASE:-/var/run/backup}"
    RESTIC_BIN="${RESTIC_BIN:-restic}"
    BACKEND="${BACKEND:-sftp}"
    SFTP_PORT="${SFTP_PORT:-22}"
    SFTP_USER="${SFTP_USER:-backup}"
    REST_SCHEME="${REST_SCHEME:-https}"
    REST_PORT="${REST_PORT:-8000}"
    BACKUP_TMP_BASE_DIR="${BACKUP_TMP_BASE_DIR:-/var/tmp}"
    KEEP_DAILY="${KEEP_DAILY:-7}"
    KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
    KEEP_MONTHLY="${KEEP_MONTHLY:-3}"
    DO_FORGET_AFTER_BACKUP="${DO_FORGET_AFTER_BACKUP:-1}"
    DO_CHECK_AFTER_BACKUP="${DO_CHECK_AFTER_BACKUP:-0}"
    # ISO weekday: 1=Mon … 7=Sun. 0/empty = no weekday schedule.
    CHECK_WEEKDAY="${CHECK_WEEKDAY:-7}"

    BACKUP_KEEP_DAILY_DEFAULT="${KEEP_DAILY}"
    BACKUP_KEEP_WEEKLY_DEFAULT="${KEEP_WEEKLY}"
    BACKUP_KEEP_MONTHLY_DEFAULT="${KEEP_MONTHLY}"
    BACKUP_BACKEND_DEFAULT="${BACKEND}"
    BACKUP_SFTP_HOST_DEFAULT="${SFTP_HOST:-}"
    BACKUP_SFTP_PORT_DEFAULT="${SFTP_PORT}"
    BACKUP_SFTP_USER_DEFAULT="${SFTP_USER}"
    BACKUP_SFTP_IDENTITY_DEFAULT="${SFTP_IDENTITY:-}"
    BACKUP_SFTP_COMMAND_DEFAULT="${SFTP_COMMAND:-}"
    BACKUP_REST_SCHEME_DEFAULT="${REST_SCHEME}"
    BACKUP_REST_HOST_DEFAULT="${REST_HOST:-}"
    BACKUP_REST_PORT_DEFAULT="${REST_PORT}"
    BACKUP_REST_PATH_PREFIX_DEFAULT="${REST_PATH_PREFIX:-}"
    BACKUP_RESTIC_CACERT_DEFAULT="${RESTIC_CACERT:-}"
    BACKUP_DO_FORGET_DEFAULT="${DO_FORGET_AFTER_BACKUP}"
    BACKUP_DO_CHECK_DEFAULT="${DO_CHECK_AFTER_BACKUP}"
    BACKUP_CHECK_WEEKDAY="${CHECK_WEEKDAY}"

    env_file="$(backup_resolve_env_file)"
    ENV_FILE="$env_file"
    backup_load_env_file "$env_file"
    BACKUP_RESTIC_PASSWORD_DEFAULT="${RESTIC_PASSWORD:-}"
    BACKUP_REST_USER_DEFAULT="${REST_USER:-}"
    BACKUP_REST_PASS_DEFAULT="${REST_PASS:-}"
}

backup_clear_job_vars() {
    unset JOB_NAME JOB_ENABLED
    unset RESTIC_REPOSITORY REPO_PATH RESTIC_PASSWORD RESTIC_PASSWORD_FILE
    unset BACKEND SFTP_HOST SFTP_PORT SFTP_USER SFTP_IDENTITY SFTP_COMMAND
    unset REST_SCHEME REST_HOST REST_PORT REST_PATH_PREFIX RESTIC_CACERT
    unset REST_USER REST_PASS
    unset RESTIC_TAGS RESTIC_HOST
    unset SQLITE_DUMP_ENABLED POSTGRES_DUMP_ENABLED POSTGRES_DOCKER_CONTAINER POSTGRES_DUMP_USER
    unset DO_FORGET_AFTER_BACKUP DO_CHECK_AFTER_BACKUP
    BACKUP_PATHS=()
    EXCLUDES=()
    SQLITE_SCAN_ROOTS=()
    SQLITE_DB_FILES=()

    BACKEND="${BACKUP_BACKEND_DEFAULT:-sftp}"
    SFTP_HOST="${BACKUP_SFTP_HOST_DEFAULT:-}"
    SFTP_PORT="${BACKUP_SFTP_PORT_DEFAULT:-22}"
    SFTP_USER="${BACKUP_SFTP_USER_DEFAULT:-backup}"
    SFTP_IDENTITY="${BACKUP_SFTP_IDENTITY_DEFAULT:-}"
    SFTP_COMMAND="${BACKUP_SFTP_COMMAND_DEFAULT:-}"
    REST_SCHEME="${BACKUP_REST_SCHEME_DEFAULT:-https}"
    REST_HOST="${BACKUP_REST_HOST_DEFAULT:-}"
    REST_PORT="${BACKUP_REST_PORT_DEFAULT:-8000}"
    REST_PATH_PREFIX="${BACKUP_REST_PATH_PREFIX_DEFAULT:-}"
    RESTIC_CACERT="${BACKUP_RESTIC_CACERT_DEFAULT:-}"
    KEEP_DAILY="${BACKUP_KEEP_DAILY_DEFAULT:-7}"
    KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY_DEFAULT:-4}"
    KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY_DEFAULT:-3}"
    DO_FORGET_AFTER_BACKUP="${BACKUP_DO_FORGET_DEFAULT:-1}"
    DO_CHECK_AFTER_BACKUP="${BACKUP_DO_CHECK_DEFAULT:-0}"
    CHECK_WEEKDAY="${BACKUP_CHECK_WEEKDAY:-7}"
    RESTIC_PASSWORD="${BACKUP_RESTIC_PASSWORD_DEFAULT:-}"
    REST_USER="${BACKUP_REST_USER_DEFAULT:-}"
    REST_PASS="${BACKUP_REST_PASS_DEFAULT:-}"
    RESTIC_HOST="$(hostname 2>/dev/null || echo backup)"
    RESTIC_TAGS=""
    SQLITE_DUMP_ENABLED=0
    POSTGRES_DUMP_ENABLED=0
    POSTGRES_DUMP_USER=postgres
}

backup_load_job_file() {
    local job_file="$1"
    backup_clear_job_vars

    if [[ ! -f "$job_file" ]]; then
        log_error "Job file not found: ${job_file}"
        return 1
    fi

    # shellcheck source=/dev/null
    # Trusted admin-owned file only: sourced as bash (arbitrary code).
    source "$job_file"

    JOB_ENABLED="${JOB_ENABLED:-1}"
    if [[ -z "${JOB_NAME:-}" ]]; then
        JOB_NAME="$(basename "$job_file" .conf)"
    fi

    [[ -z "${BACKUP_PATHS+set}" ]] && BACKUP_PATHS=()
    [[ -z "${EXCLUDES+set}" ]] && EXCLUDES=()
    [[ -z "${SQLITE_SCAN_ROOTS+set}" ]] && SQLITE_SCAN_ROOTS=()
    [[ -z "${SQLITE_DB_FILES+set}" ]] && SQLITE_DB_FILES=()

    BACKEND="${BACKEND:-${BACKUP_BACKEND_DEFAULT:-sftp}}"
    SFTP_PORT="${SFTP_PORT:-${BACKUP_SFTP_PORT_DEFAULT:-22}}"
    SFTP_USER="${SFTP_USER:-${BACKUP_SFTP_USER_DEFAULT:-backup}}"
    REST_SCHEME="${REST_SCHEME:-${BACKUP_REST_SCHEME_DEFAULT:-https}}"
    REST_PORT="${REST_PORT:-${BACKUP_REST_PORT_DEFAULT:-8000}}"

    if [[ -n "${RESTIC_PASSWORD_FILE:-}" && -f "${RESTIC_PASSWORD_FILE}" ]]; then
        RESTIC_PASSWORD="$(<"${RESTIC_PASSWORD_FILE}")"
        RESTIC_PASSWORD="${RESTIC_PASSWORD//$'\n'/}"
    fi

    backup_resolve_repository
    backup_require_var RESTIC_PASSWORD

    if [[ "${#BACKUP_PATHS[@]}" -eq 0 ]]; then
        # allow empty paths only for forget/check/status/init
        :
    fi
}

backup_resolve_jobs() {
    local filter="${1:-}"
    local f
    local -a found=()

    if [[ ! -d "${JOBS_DIR}" ]]; then
        log_error "Jobs directory not found: ${JOBS_DIR}"
        return 1
    fi

    shopt -s nullglob
    local files=("${JOBS_DIR}"/*.conf)
    shopt -u nullglob

    if [[ "${#files[@]}" -eq 0 ]]; then
        log_error "No job files in ${JOBS_DIR}"
        return 1
    fi

    for f in "${files[@]}"; do
        if [[ -z "$filter" ]]; then
            found+=("$f")
            continue
        fi
        local base
        base="$(basename "$f" .conf)"
        if [[ "$base" == "$filter" || "$(basename "$f")" == "$filter" ]]; then
            found+=("$f")
            continue
        fi
        if grep -Eq "^[[:space:]]*JOB_NAME=[\"']?${filter}[\"']?" "$f" 2>/dev/null; then
            found+=("$f")
        fi
    done

    if [[ "${#found[@]}" -eq 0 ]]; then
        log_error "No jobs matched filter '${filter}'"
        return 1
    fi

    printf '%s\n' "${found[@]}"
}

backup_infer_backend_from_repo() {
    case "${RESTIC_REPOSITORY}" in
        rest:*) BACKEND=rest ;;
        sftp:*) BACKEND=sftp ;;
    esac
}

backup_normalize_rest_repo_path() {
    local path="${REPO_PATH#/}"
    local prefix="${REST_PATH_PREFIX:-}"
    prefix="${prefix#/}"
    prefix="${prefix%/}"
    if [[ -n "$prefix" ]]; then
        path="${prefix}/${path}"
    fi
    path="${path#/}"
    path="${path%/}"
    if [[ -n "$path" ]]; then
        printf '%s/\n' "$path"
    else
        printf '\n'
    fi
}

backup_resolve_repository() {
    if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
        backup_infer_backend_from_repo
        case "${BACKEND}" in
            sftp|rest) ;;
            *)
                log_error "Unknown BACKEND='${BACKEND}' (expected sftp|rest)"
                return 1
                ;;
        esac
        return 0
    fi

    BACKEND="${BACKEND:-sftp}"
    case "${BACKEND}" in
        sftp)
            backup_require_var SFTP_HOST
            backup_require_var REPO_PATH
            RESTIC_REPOSITORY="sftp:${SFTP_USER}@${SFTP_HOST}:${REPO_PATH}"
            ;;
        rest)
            case "${REST_SCHEME}" in
                http|https) ;;
                *)
                    log_error "REST_SCHEME must be http or https (got '${REST_SCHEME}')"
                    return 1
                    ;;
            esac
            backup_require_var REST_HOST
            backup_require_var REPO_PATH
            local rest_path
            rest_path="$(backup_normalize_rest_repo_path)"
            RESTIC_REPOSITORY="rest:${REST_SCHEME}://${REST_HOST}:${REST_PORT}/${rest_path}"
            ;;
        *)
            log_error "Unknown BACKEND='${BACKEND}' (expected sftp|rest)"
            return 1
            ;;
    esac
}

backup_build_sftp_command() {
    if [[ -n "${SFTP_COMMAND:-}" ]]; then
        printf '%s\n' "${SFTP_COMMAND}"
        return 0
    fi

    backup_require_var SFTP_HOST

    local cmd="ssh -p ${SFTP_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    if [[ -n "${SFTP_IDENTITY:-}" ]]; then
        cmd+=" -i ${SFTP_IDENTITY} -o IdentitiesOnly=yes"
    fi
    cmd+=" ${SFTP_USER}@${SFTP_HOST} -s sftp"
    printf '%s\n' "$cmd"
}

backup_job_lock_file() {
    printf '%s/%s.lock' "${LOCK_DIR_BASE:-/var/run/backup}" "${JOB_NAME}"
}
