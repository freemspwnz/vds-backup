#!/usr/bin/env bash

# Lightweight logging module:
#  - prints to stdout/stderr
#  - mirrors important events to systemd-journald via `logger`
#
# Levels: INFO, WARN, ERROR, DEBUG

LOG_TAG="${LOG_TAG:-backup}"
# When BACKUP_DEBUG=1, DEBUG logs are enabled

_log() {
    local level="$1"
    local msg="$2"
    local priority ts

    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    case "$level" in
        INFO)  priority="user.info" ;;
        WARN)  priority="user.warning" ;;
        ERROR) priority="user.err" ;;
        DEBUG) priority="user.debug" ;;
        *)     priority="user.notice" ;;
    esac

    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
        printf '[%s] %s: %s\n' "$ts" "$level" "$msg" >&2
    else
        printf '[%s] %s: %s\n' "$ts" "$level" "$msg"
    fi

    # In non-debug mode, skip DEBUG messages for journald
    if [[ "$level" == "DEBUG" && "${BACKUP_DEBUG:-0}" != "1" ]]; then
        return 0
    fi

    if command -v logger >/dev/null 2>&1; then
        logger -t "$LOG_TAG" -p "$priority" -- "$msg" || true
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

