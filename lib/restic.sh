#!/usr/bin/env bash

set -euo pipefail

# All restic ops go through SFTP (current job globals).

RESTIC_BIN="${RESTIC_BIN:-restic}"

backup_restic_env() {
    export RESTIC_PASSWORD
}

backup_restic() {
    # backup_restic <restic-subcommand-and-args...>
    local sftp_cmd
    sftp_cmd="$(backup_build_sftp_command)"
    backup_require_var RESTIC_PASSWORD
    backup_require_var RESTIC_REPOSITORY
    backup_restic_env
    "${RESTIC_BIN}" -r "${RESTIC_REPOSITORY}" -o "sftp.command=${sftp_cmd}" "$@"
}

backup_restic_probe() {
    log_info "Probing repository: ${RESTIC_REPOSITORY}"
    if ! backup_restic snapshots --last 1 >/dev/null 2>&1; then
        log_error "Repository not accessible or not initialized: ${RESTIC_REPOSITORY}"
        return 1
    fi
    log_info "Repository is accessible."
}

backup_restic_init() {
    backup_require_var RESTIC_PASSWORD
    backup_restic_env
    if backup_restic snapshots --last 1 >/dev/null 2>&1; then
        log_info "Repository already initialized: ${RESTIC_REPOSITORY}"
        return 0
    fi
    log_info "Initializing repository: ${RESTIC_REPOSITORY}"
    backup_restic init
}

backup_restic_backup() {
    local tmp_log
    tmp_log="$(mktemp "${TMPDIR:-/tmp}/restic_backup.XXXXXX")"
    BACKUP_RESTIC_LOG_FILE="$tmp_log"

    log_info "Starting restic backup → ${RESTIC_REPOSITORY}"

    set +e
    backup_restic backup "$@" >"$tmp_log" 2>&1
    BACKUP_RESTIC_EXIT=$?
    set -e

    if [[ -s "$tmp_log" ]]; then
        local summary line
        summary="$(grep -E 'Files:|Dirs:|Added to the repository|snapshot [0-9a-f]+ saved|Fatal|Error|unable' "$tmp_log" | tail -n 25 || true)"
        if [[ -n "$summary" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && log_info "restic: ${line}"
            done <<<"$summary"
        fi
    else
        log_warn "restic produced no output."
    fi

    return "${BACKUP_RESTIC_EXIT}"
}

backup_extract_restic_stats() {
    if [[ -z "${BACKUP_RESTIC_LOG_FILE:-}" || ! -f "${BACKUP_RESTIC_LOG_FILE}" ]]; then
        printf 'no stats\n'
        return 0
    fi
    grep -E 'Files:|Dirs:|Added to the repository|snapshot [0-9a-f]+ saved' "${BACKUP_RESTIC_LOG_FILE}" \
        || printf 'no stats\n'
}

backup_restic_log_tail() {
    if [[ -z "${BACKUP_RESTIC_LOG_FILE:-}" || ! -f "${BACKUP_RESTIC_LOG_FILE}" ]]; then
        return 0
    fi
    tail -n 40 "${BACKUP_RESTIC_LOG_FILE}"
}

backup_restic_forget() {
    local keep_daily="${KEEP_DAILY:-7}"
    local keep_weekly="${KEEP_WEEKLY:-4}"
    local keep_monthly="${KEEP_MONTHLY:-3}"
    local tmp_out rc prune_stats

    tmp_out="$(mktemp "${TMPDIR:-/tmp}/restic_forget.XXXXXX")"

    log_info "forget/prune ${RESTIC_REPOSITORY} (daily=${keep_daily} weekly=${keep_weekly} monthly=${keep_monthly})"

    set +e
    backup_restic forget \
        --keep-daily "$keep_daily" \
        --keep-weekly "$keep_weekly" \
        --keep-monthly "$keep_monthly" \
        --prune >"$tmp_out" 2>&1
    rc=$?
    set -e

    prune_stats="$(grep -E 'keep [0-9]+ snapshots|removed|remaining|frees|prune|unchanged|Applying Policy' "$tmp_out" | head -n 20 || true)"
    [[ -z "$prune_stats" ]] && prune_stats="$(tail -n 10 "$tmp_out")"
    FORGET_REPORT_STATS="$prune_stats"

    if [[ "$rc" -ne 0 ]]; then
        log_warn "forget/prune failed (exit ${rc})"
        log_debug "$(tail -n 20 "$tmp_out")"
        rm -f "$tmp_out"
        return "$rc"
    fi
    log_info "forget/prune OK"
    rm -f "$tmp_out"
    return 0
}

backup_restic_check() {
    local tmp_out rc check_stats

    tmp_out="$(mktemp "${TMPDIR:-/tmp}/restic_check.XXXXXX")"

    log_info "restic check ${RESTIC_REPOSITORY}"

    set +e
    backup_restic check >"$tmp_out" 2>&1
    rc=$?
    set -e

    check_stats="$(grep -E 'check|no errors|pack|snapshot|error' "$tmp_out" | head -n 15 || true)"
    [[ -z "$check_stats" ]] && check_stats="$(tail -n 10 "$tmp_out")"
    CHECK_REPORT_STATS="$check_stats"

    if [[ "$rc" -ne 0 ]]; then
        log_warn "restic check failed (exit ${rc})"
        rm -f "$tmp_out"
        return "$rc"
    fi
    log_info "restic check OK"
    rm -f "$tmp_out"
    return 0
}
