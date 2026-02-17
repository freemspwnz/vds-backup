#!/usr/bin/env bash

# Lightweight logging module:
#  - single source: logger(1) with LEVEL: msg (no timestamp; journal adds its own)
#  - stdout is reserved for data only; on logger failure fallback to stderr
#
# Levels: INFO, WARN, ERROR, DEBUG

LOG_TAG="${LOG_TAG:-backup}"

# When BACKUP_DEBUG=1, DEBUG logs are emitted; otherwise DEBUG is skipped
_log() {
    local level="$1"
    local msg="$2"
    local priority line

    [[ "$level" == "DEBUG" && "${BACKUP_DEBUG:-0}" != "1" ]] && return 0

    line="${level}: ${msg}"

    case "$level" in
        INFO)  priority="user.info" ;;
        WARN)  priority="user.warning" ;;
        ERROR) priority="user.err" ;;
        DEBUG) priority="user.debug" ;;
        *)     priority="user.notice" ;;
    esac

    if command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" -p "$priority" -- "$line" || printf '%s\n' "$line" >&2
    else
        printf '%s\n' "$line" >&2
    fi
}

log_info() {
    _log "INFO" "$*"
}

log_warn() {
    _log "WARN" "$*"
}

log_error() {
    _log "ERROR" "$*"
}

log_debug() {
    _log "DEBUG" "$*"
}

