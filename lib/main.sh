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

backup_job_dumps_dir() {
    local base="${BACKUP_TMP_BASE_DIR:-/var/tmp}"
    printf '%s/backup_dumps/%s\n' "${base%/}" "${JOB_NAME}"
}

# Remove dump artifacts only (stable dir is kept). Honors KEEP_DUMPS=1.
backup_cleanup_dump_files() {
    local dir="${1:-${BACKUP_TMP_DIR:-}}"
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        return 0
    fi
    if [[ "${KEEP_DUMPS:-0}" == "1" ]]; then
        log_info "KEEP_DUMPS=1 — dump files kept in ${dir}"
        return 0
    fi
    log_info "Removing dump files in ${dir}"
    find "$dir" -type f \( -name '*.sql' -o -name '*.err' \) -delete 2>/dev/null || true
}

backup_cleanup_tmp() {
    rm -f "${BACKUP_RESTIC_LOG_FILE:-}" 2>/dev/null || true
    BACKUP_RESTIC_LOG_FILE=""
    BACKUP_TMP_DIR=""
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

# Acquire per-job flock and install cleanup trap.
# Return codes: 0 = acquired, 1 = busy, 2 = error.
# Busy policy (intentional): run/maintenance soft-skip; forget/check/init fail.
# See README "Per-job locks (busy policy)".
backup_job_with_lock_begin() {
    local lock_file lock_rc=0
    lock_file="$(backup_job_lock_file)"
    backup_lock_acquire "$lock_file" || lock_rc=$?
    if [[ "$lock_rc" -eq 0 ]]; then
        backup_job_install_trap
    fi
    return "$lock_rc"
}

backup_job_with_lock_end() {
    backup_job_cleanup
    backup_job_clear_trap
}

# Run fn under the current job's flock; always release if acquired.
# busy_policy: soft (busy → 0) | fail (busy → 1). Lock errors always → 1.
backup_with_job_lock() {
    local busy_policy="$1"
    local fn="$2"
    shift 2
    local lock_rc=0 rc=0

    backup_job_with_lock_begin || lock_rc=$?
    if [[ "$lock_rc" -eq 1 ]]; then
        if [[ "$busy_policy" == "soft" ]]; then
            return 0
        fi
        return 1
    fi
    if [[ "$lock_rc" -ne 0 ]]; then
        return 1
    fi

    "$fn" "$@" || rc=$?
    backup_job_with_lock_end
    return "$rc"
}

# Collect jobs, preflight, call fn once per job file. Aggregates failures.
# backup_foreach_job <filter> <include_disabled> <fn>
backup_foreach_job() {
    local filter="${1:-}"
    local include_disabled="${2:-0}"
    local fn="$3"
    local list enum_rc=0 failed=0 line

    list="$(backup_collect_jobs "$filter" "$include_disabled")" || enum_rc=$?
    backup_preflight "$list" || return 1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! "$fn" "$line"; then
            failed=1
        fi
    done <<< "$list"

    [[ "$failed" -eq 0 && "$enum_rc" -eq 0 ]]
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

backup_prepare_dumps_dir() {
    BACKUP_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    BACKUP_TMP_DIR="$(backup_job_dumps_dir)"
    mkdir -p "${BACKUP_TMP_DIR}"
    log_info "Dump directory: ${BACKUP_TMP_DIR}"
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

backup_collect_jobs() {
    # Prints enabled job file paths (or all if include_disabled=1 as $2).
    # Returns 1 if resolve fails or any matched job file fails to load.
    local filter="${1:-}"
    local include_disabled="${2:-0}"
    local line out rc=0

    out="$(backup_resolve_jobs "$filter")" || return 1

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! backup_load_job_file "$line"; then
            log_error "Invalid job config: ${line}"
            rc=1
            continue
        fi
        if [[ "$include_disabled" != "1" && "${JOB_ENABLED}" != "1" ]]; then
            log_info "Job '${JOB_NAME}' disabled, skipping."
            continue
        fi
        printf '%s\n' "$line"
    done <<< "$out"

    return "$rc"
}

backup_run_job_locked() {
    local host rc=0 stats raw_tail="" forget_st="" check_st=""

    host="$(hostname 2>/dev/null || echo backup)"
    log_info "=== Job '${JOB_NAME}' on ${host} ==="

    BACKUP_TMP_DIR=""
    FORGET_REPORT_STATS=""
    CHECK_REPORT_STATS=""

    if backup_dumps_needed; then
        backup_prepare_dumps_dir
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
    rc=$?
    set -e

    stats="$(backup_extract_restic_stats)"

    if [[ "$rc" -ne 0 ]]; then
        raw_tail="$(backup_restic_log_tail || true)"
        log_error "Job '${JOB_NAME}' backup failed (exit ${rc})."
        backup_send_report "${JOB_NAME}" "$host" "[FAIL]" "backup failed" "${stats}" "${raw_tail}"
        return 1
    fi

    log_info "Job '${JOB_NAME}' backup OK."

    if backup_dumps_needed; then
        backup_cleanup_dump_files
    fi

    if [[ "${FORCE_NO_FORGET}" -eq 0 && "${DO_FORGET_AFTER_BACKUP}" == "1" ]]; then
        if backup_restic_forget; then
            forget_st="[OK]"
        else
            forget_st="[FAIL]"
            rc=1
        fi
    fi

    if backup_should_run_check; then
        if backup_restic_check; then
            check_st="[OK]"
        else
            check_st="[FAIL]"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        backup_send_report "${JOB_NAME}" "$host" "[OK]" "completed successfully" "${stats}" "" \
            "$forget_st" "${FORGET_REPORT_STATS:-}" \
            "$check_st" "${CHECK_REPORT_STATS:-}"
    else
        backup_send_report "${JOB_NAME}" "$host" "[FAIL]" "backup OK, maintenance failed" "${stats}" "" \
            "$forget_st" "${FORGET_REPORT_STATS:-}" \
            "$check_st" "${CHECK_REPORT_STATS:-}"
    fi

    return "$rc"
}

backup_run_one_job() {
    local job_file="$1"
    backup_load_job_file "$job_file"

    if [[ "${#BACKUP_PATHS[@]}" -eq 0 ]]; then
        log_error "Job '${JOB_NAME}': BACKUP_PATHS is empty."
        return 1
    fi

    # run: busy → soft-skip (overlapping timer is OK)
    backup_with_job_lock soft backup_run_job_locked
}

backup_job_do_dump() {
    local job_file="$1"
    local rc=0

    backup_load_job_file "$job_file"
    backup_job_install_trap
    backup_prepare_dumps_dir
    if ! backup_run_dumps "${BACKUP_TMP_DIR}" "${BACKUP_TIMESTAMP}"; then
        rc=1
    else
        backup_cleanup_dump_files
    fi
    backup_job_cleanup
    backup_job_clear_trap
    return "$rc"
}

backup_job_do_forget() {
    local job_file="$1"
    backup_load_job_file "$job_file"
    # forget: busy → fail (manual op must not silently no-op)
    backup_with_job_lock fail backup_restic_forget
}

backup_job_do_check() {
    local job_file="$1"
    backup_load_job_file "$job_file"
    # check: busy → fail (manual op must not silently no-op)
    backup_with_job_lock fail backup_restic_check
}

backup_job_do_maintenance() {
    local job_file="$1"
    backup_load_job_file "$job_file"
    # maintenance: busy → soft-skip (same overlap policy as run)
    backup_with_job_lock soft backup_maintenance_locked
}

backup_maintenance_locked() {
    local host st="[OK]" job_failed=0 forget_st check_st=""

    host="$(hostname 2>/dev/null || echo backup)"
    FORGET_REPORT_STATS=""
    CHECK_REPORT_STATS=""

    if backup_restic_forget; then
        forget_st="[OK]"
    else
        forget_st="[FAIL]"
        job_failed=1
    fi

    if [[ "${FORCE_NO_CHECK}" -eq 0 ]]; then
        if backup_restic_check; then
            check_st="[OK]"
        else
            check_st="[FAIL]"
            job_failed=1
        fi
    fi

    if [[ "$job_failed" -ne 0 ]]; then
        st="[FAIL]"
    fi
    backup_send_report "${JOB_NAME}" "$host" "$st" "maintenance" "" "" \
        "$forget_st" "${FORGET_REPORT_STATS:-}" \
        "$check_st" "${CHECK_REPORT_STATS:-}"

    return "$job_failed"
}

backup_job_do_init() {
    local job_file="$1"
    backup_load_job_file "$job_file"
    # init: busy → fail (manual op must not silently no-op)
    backup_with_job_lock fail backup_restic_init
}

backup_job_do_status() {
    local job_file="$1"
    backup_load_job_file "$job_file"
    log_info "Job '${JOB_NAME}': repo=${RESTIC_REPOSITORY} enabled=${JOB_ENABLED} backend=${BACKEND}"
    case "${BACKEND}" in
        rest)
            log_info "REST: ${REST_SCHEME}://${REST_HOST:-?}:${REST_PORT}"
            ;;
        *)
            log_info "SFTP: ${SFTP_USER}@${SFTP_HOST:-?} port=${SFTP_PORT}"
            ;;
    esac
    set +e
    backup_restic_probe
    backup_restic snapshots --latest 5
    set -e
    return 0
}

backup_cmd_run() {
    backup_parse_args "$@"
    backup_load_global
    backup_foreach_job "${CMD_JOB_FILTER}" 0 backup_run_one_job
}

backup_cmd_dump() {
    backup_parse_args "$@"
    backup_load_global
    backup_foreach_job "${CMD_JOB_FILTER}" 0 backup_job_do_dump
}

backup_cmd_forget() {
    backup_parse_args "$@"
    backup_load_global
    backup_foreach_job "${CMD_JOB_FILTER}" 0 backup_job_do_forget
}

backup_cmd_check() {
    backup_parse_args "$@"
    backup_load_global
    backup_foreach_job "${CMD_JOB_FILTER}" 0 backup_job_do_check
}

backup_cmd_maintenance() {
    backup_parse_args "$@"
    backup_load_global
    backup_foreach_job "${CMD_JOB_FILTER}" 0 backup_job_do_maintenance
}

backup_cmd_init() {
    backup_parse_args "$@"
    backup_load_global
    backup_foreach_job "${CMD_JOB_FILTER}" 1 backup_job_do_init
}

backup_cmd_status() {
    backup_parse_args "$@"
    backup_load_global
    backup_foreach_job "${CMD_JOB_FILTER}" 1 backup_job_do_status
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

Locks (per job, flock):
  run, maintenance   if busy: soft-skip that job (overlap-safe)
  forget, check, init  if busy: fail the command (no silent no-op)

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
