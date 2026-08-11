#!/usr/bin/env bash

set -euo pipefail

# Orchestration: dumps → backup → optional forget/check → Telegram.

CMD_JOB_FILTER=""
FORCE_NO_FORGET=0
FORCE_NO_CHECK=0

BACKUP_TIMESTAMP=""
BACKUP_TMP_DIR=""

backup_parse_args() {
    local arg
    CMD_JOB_FILTER=""
    FORCE_NO_FORGET=0
    FORCE_NO_CHECK=0
    for arg in "$@"; do
        case "$arg" in
            --job=*)
                CMD_JOB_FILTER="${arg#--job=}"
                ;;
            --no-forget)
                FORCE_NO_FORGET=1
                ;;
            --no-check)
                FORCE_NO_CHECK=1
                ;;
        esac
    done
}

backup_cleanup_tmp() {
    if [[ -n "${BACKUP_TMP_DIR:-}" && -d "${BACKUP_TMP_DIR}" ]]; then
        log_info "Removing temporary dump directory: ${BACKUP_TMP_DIR}"
        rm -rf -- "${BACKUP_TMP_DIR}" || true
        BACKUP_TMP_DIR=""
    fi
    rm -f "${BACKUP_RESTIC_LOG_FILE:-}" 2>/dev/null || true
    BACKUP_RESTIC_LOG_FILE=""
}

# Single cleanup owner for orchestrator EXIT traps (idempotent).
backup_job_cleanup() {
    backup_cleanup_tmp
    backup_lock_release
}

backup_job_install_trap() {
    trap 'backup_job_cleanup' EXIT
    trap 'log_warn "Interrupted"; exit 130' INT TERM HUP
}

backup_job_clear_trap() {
    trap - EXIT INT TERM HUP
}

# Check after backup if DO_CHECK_AFTER_BACKUP=1, or today matches CHECK_WEEKDAY (1=Mon…7=Sun).
backup_should_run_check() {
    if [[ "${FORCE_NO_CHECK:-0}" -eq 1 ]]; then
        return 1
    fi
    if [[ "${DO_CHECK_AFTER_BACKUP}" == "1" ]]; then
        return 0
    fi
    local wd="${CHECK_WEEKDAY:-0}"
    if [[ -z "$wd" || "$wd" == "0" ]]; then
        return 1
    fi
    local today
    today="$(date +%u)"
    [[ "$today" == "$wd" ]]
}

backup_prepare_tmp() {
    local base="${BACKUP_TMP_BASE_DIR:-/var/tmp}"
    mkdir -p "$base"
    BACKUP_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    BACKUP_TMP_DIR="$(mktemp -d "${base%/}/backup_dumps.${BACKUP_TIMESTAMP}.XXXXXX")"
    log_info "Temporary dump directory: ${BACKUP_TMP_DIR}"
}

backup_build_backup_args() {
    BACKUP_RESTIC_ARGS=()
    BACKUP_TARGETS=()

    local p ex
    for p in "${BACKUP_PATHS[@]}"; do
        BACKUP_TARGETS+=("$p")
    done
    if [[ -n "${BACKUP_TMP_DIR:-}" && -d "${BACKUP_TMP_DIR}" ]]; then
        BACKUP_TARGETS+=("${BACKUP_TMP_DIR}")
    fi

    if [[ -n "${RESTIC_TAGS:-}" ]]; then
        BACKUP_RESTIC_ARGS+=(--tag "${RESTIC_TAGS}")
    fi
    if [[ -n "${RESTIC_HOST:-}" ]]; then
        BACKUP_RESTIC_ARGS+=(--host "${RESTIC_HOST}")
    fi
    if [[ "${#EXCLUDES[@]}" -gt 0 ]]; then
        for ex in "${EXCLUDES[@]}"; do
            BACKUP_RESTIC_ARGS+=(--exclude "${ex}")
        done
    fi
}

backup_foreach_job() {
    # Prints job file paths that are enabled (or all if include_disabled=1 as $2)
    local filter="${1:-}"
    local include_disabled="${2:-0}"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        backup_load_job_file "$line" || continue
        if [[ "$include_disabled" != "1" && "${JOB_ENABLED}" != "1" ]]; then
            log_info "Job '${JOB_NAME}' disabled, skipping."
            continue
        fi
        printf '%s\n' "$line"
    done < <(backup_resolve_jobs "$filter")
}

backup_run_one_job() {
    local job_file="$1"
    backup_load_job_file "$job_file"

    if [[ "${#BACKUP_PATHS[@]}" -eq 0 ]]; then
        log_error "Job '${JOB_NAME}': BACKUP_PATHS is empty."
        return 1
    fi

    local lock_dir host lock_rc=0
    lock_dir="$(backup_job_lock_dir)"
    backup_lock_acquire "$lock_dir" || lock_rc=$?
    if [[ "$lock_rc" -eq 1 ]]; then
        return 0
    fi
    if [[ "$lock_rc" -ne 0 ]]; then
        return 1
    fi

    backup_job_install_trap

    host="$(hostname 2>/dev/null || echo backup)"
    log_info "=== Job '${JOB_NAME}' on ${host} ==="

    BACKUP_TMP_DIR=""
    FORGET_REPORT_STATS=""
    CHECK_REPORT_STATS=""

    if backup_dumps_needed; then
        backup_prepare_tmp
        if ! backup_run_dumps "${BACKUP_TMP_DIR}" "${BACKUP_TIMESTAMP}"; then
            log_error "Job '${JOB_NAME}' dumps failed."
            backup_send_report "${JOB_NAME}" "$host" "[FAIL]" "dumps failed" "n/a" ""
            return 1
        fi
    fi

    if ! backup_restic_probe; then
        backup_send_report "${JOB_NAME}" "$host" "[FAIL]" "repository not accessible" "n/a" ""
        return 1
    fi

    backup_build_backup_args

    set +e
    backup_restic_backup "${BACKUP_RESTIC_ARGS[@]}" "${BACKUP_TARGETS[@]}"
    local rc=$?
    set -e

    local stats raw_tail extra="" forget_st="" check_st=""
    stats="$(backup_extract_restic_stats)"

    if [[ "$rc" -ne 0 ]]; then
        raw_tail="$(backup_restic_log_tail || true)"
        log_error "Job '${JOB_NAME}' backup failed (exit ${rc})."
        backup_send_report "${JOB_NAME}" "$host" "[FAIL]" "backup failed" "${stats}" "${raw_tail}"
        return 1
    fi

    log_info "Job '${JOB_NAME}' backup OK."

    if [[ "${FORCE_NO_FORGET}" -eq 0 && "${DO_FORGET_AFTER_BACKUP}" == "1" ]]; then
        if backup_restic_forget; then
            forget_st="[OK]"
        else
            forget_st="[FAIL]"
            rc=1
        fi
        extra+="Prune: <b>${forget_st}</b>
<pre>${FORGET_REPORT_STATS:-}</pre>
"
    fi

    if backup_should_run_check; then
        if backup_restic_check; then
            check_st="[OK]"
        else
            check_st="[FAIL]"
            rc=1
        fi
        extra+="Check: <b>${check_st}</b>
<pre>${CHECK_REPORT_STATS:-}</pre>
"
    fi

    if [[ "$rc" -eq 0 ]]; then
        backup_send_report "${JOB_NAME}" "$host" "[OK]" "completed successfully" "${stats}" "" "${extra}"
    else
        backup_send_report "${JOB_NAME}" "$host" "[FAIL]" "backup OK, maintenance failed" "${stats}" "" "${extra}"
    fi

    backup_job_cleanup
    backup_job_clear_trap
    return "$rc"
}

backup_cmd_run() {
    backup_parse_args "$@"
    backup_load_global

    local failed=0 line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! backup_run_one_job "$line"; then
            failed=1
        fi
    done < <(backup_foreach_job "${CMD_JOB_FILTER}")

    [[ "$failed" -eq 0 ]]
}

backup_cmd_dump() {
    backup_parse_args "$@"
    backup_load_global

    local line kept_dir
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        backup_load_job_file "$line"
        backup_job_install_trap
        backup_prepare_tmp
        if ! backup_run_dumps "${BACKUP_TMP_DIR}" "${BACKUP_TIMESTAMP}"; then
            return 1
        fi
        if [[ "${KEEP_DUMPS:-0}" == "1" ]]; then
            kept_dir="${BACKUP_TMP_DIR}"
            BACKUP_TMP_DIR=""
            backup_job_clear_trap
            log_info "KEEP_DUMPS=1 — dumps kept in ${kept_dir}"
        else
            backup_job_cleanup
            backup_job_clear_trap
        fi
    done < <(backup_foreach_job "${CMD_JOB_FILTER}")
}

backup_cmd_forget() {
    backup_parse_args "$@"
    backup_load_global
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        backup_load_job_file "$line"
        backup_restic_forget || true
    done < <(backup_foreach_job "${CMD_JOB_FILTER}")
}

backup_cmd_check() {
    backup_parse_args "$@"
    backup_load_global
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        backup_load_job_file "$line"
        backup_restic_check || true
    done < <(backup_foreach_job "${CMD_JOB_FILTER}")
}

backup_cmd_maintenance() {
    backup_parse_args "$@"
    backup_load_global

    local failed=0 line host extra forget_st check_st job_failed
    host="$(hostname 2>/dev/null || echo backup)"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        backup_load_job_file "$line"
        local lock_dir lock_rc=0
        lock_dir="$(backup_job_lock_dir)"
        backup_lock_acquire "$lock_dir" || lock_rc=$?
        if [[ "$lock_rc" -eq 1 ]]; then
            continue
        fi
        if [[ "$lock_rc" -ne 0 ]]; then
            failed=1
            continue
        fi
        backup_job_install_trap

        job_failed=0
        extra=""
        FORGET_REPORT_STATS=""
        CHECK_REPORT_STATS=""

        if backup_restic_forget; then
            forget_st="[OK]"
        else
            forget_st="[FAIL]"
            job_failed=1
        fi
        extra+="Prune: <b>${forget_st}</b>
<pre>${FORGET_REPORT_STATS:-}</pre>
"

        if [[ "${FORCE_NO_CHECK}" -eq 0 ]]; then
            if backup_restic_check; then
                check_st="[OK]"
            else
                check_st="[FAIL]"
                job_failed=1
            fi
            extra+="Check: <b>${check_st}</b>
<pre>${CHECK_REPORT_STATS:-}</pre>
"
        fi

        local st="[OK]"
        if [[ "$job_failed" -ne 0 ]]; then
            st="[FAIL]"
            failed=1
        fi
        backup_send_report "${JOB_NAME}" "$host" "$st" "maintenance" "" "" "${extra}"

        backup_job_cleanup
        backup_job_clear_trap
    done < <(backup_foreach_job "${CMD_JOB_FILTER}")

    [[ "$failed" -eq 0 ]]
}

backup_cmd_init() {
    backup_parse_args "$@"
    backup_load_global
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        backup_load_job_file "$line"
        backup_restic_init
    done < <(backup_foreach_job "${CMD_JOB_FILTER}" 1)
}

backup_cmd_status() {
    backup_parse_args "$@"
    backup_load_global
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        backup_load_job_file "$line"
        log_info "Job '${JOB_NAME}': repo=${RESTIC_REPOSITORY} enabled=${JOB_ENABLED}"
        log_info "SFTP: ${SFTP_USER}@${SFTP_HOST:-?} port=${SFTP_PORT}"
        set +e
        backup_restic_probe
        backup_restic snapshots --latest 5
        set -e
    done < <(backup_foreach_job "${CMD_JOB_FILTER}" 1)
}

backup_usage() {
    cat <<'EOF'
Usage: backup.sh <command> [options]

Commands:
  run              Dumps → restic backup → optional forget/check → Telegram
  dump             Only DB dump hooks (debug); KEEP_DUMPS=1 to keep files
  forget           restic forget --prune
  check            restic check
  maintenance      forget + check (+ Telegram); for manual runs
  init             restic init for job repo(s)
  status           Probe repo and list recent snapshots

Options:
  --job=NAME       Only this job (filename without .conf or JOB_NAME)
  --no-forget      Skip prune after backup / in maintenance skip nothing for forget
  --no-check       Skip check after backup / in maintenance

Config:
  BACKUP_CONF_PATH   default /usr/local/etc/backup/backup.conf
  ENV_FILE           default /usr/local/etc/backup/.env
  jobs: JOBS_DIR/*.conf
  CHECK_WEEKDAY      ISO 1=Mon…7=Sun; run restic check on that day (default 7)
EOF
}

backup_main() {
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        run)          backup_cmd_run "$@" ;;
        dump)         backup_cmd_dump "$@" ;;
        forget)       backup_cmd_forget "$@" ;;
        check)        backup_cmd_check "$@" ;;
        maintenance)  backup_cmd_maintenance "$@" ;;
        init)         backup_cmd_init "$@" ;;
        status)       backup_cmd_status "$@" ;;
        -h|--help|help|"")
            backup_usage
            [[ -n "$cmd" ]] || return 1
            ;;
        *)
            log_error "Unknown command: ${cmd}"
            backup_usage
            return 1
            ;;
    esac
}
