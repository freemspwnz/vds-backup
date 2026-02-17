#!/usr/bin/env bash

# Lightweight logging module:
#  - single source: stderr with prefixes and LEVEL: msg
#  - stdout is reserved for data only;
#
# Levels: INFO, WARN, ERROR, DEBUG

LOG_TAG="${LOG_TAG:-backup}"

# When BACKUP_DEBUG=1, DEBUG logs are emitted; otherwise DEBUG is skipped
_log() {
    local level="$1"
    local msg="$2"
    local prefix

    [[ "$level" == "DEBUG" && "${BACKUP_DEBUG:-0}" != "1" ]] && return 0

    case "$level" in
        ERROR) prefix="<3>" ;;
        WARN)  prefix="<4>" ;;
        INFO)  prefix="<6>" ;;
        DEBUG) prefix="<7>" ;;
        *)     prefix="<5>" ;;
    esac

    printf '%s%s: %s\n' "$prefix" "$level" "$msg" >&2
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

