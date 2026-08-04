#!/usr/bin/env bash

# Logging: stderr (journald-friendly). If LOG_FILE is set, also append there.

LOG_FILE="${LOG_FILE:-}"

_log() {
    local level="$1"
    local msg="$2"
    local line

    [[ "$level" == "DEBUG" && "${DEBUG_FLG:-0}" != "1" && "${BACKUP_DEBUG:-0}" != "1" ]] && return 0

    line="$(printf '%s [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg")"
    printf '%s\n' "$line" >&2

    if [[ -n "${LOG_FILE}" ]]; then
        mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
        printf '%s\n' "$line" >> "${LOG_FILE}"
    fi
}

log_info()  { _log "INFO"  "$*"; }
log_warn()  { _log "WARN"  "$*"; }
log_error() { _log "ERROR" "$*"; }
log_debug() { _log "DEBUG" "$*"; }
