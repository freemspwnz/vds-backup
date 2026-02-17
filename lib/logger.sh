#!/usr/bin/env bash

# Lightweight logging module:
#  - all levels print to stderr (one line with timestamp and level); stdout is for data only
#  - under systemd, use ExecStart with exec -a backup so journal shows SYSLOG_IDENTIFIER=backup
#
# Levels: INFO, WARN, ERROR, DEBUG

# When BACKUP_DEBUG=1, DEBUG logs are emitted; otherwise DEBUG is skipped
_log() {
    local level="$1"
    local msg="$2"

    [[ "$level" == "DEBUG" && "${BACKUP_DEBUG:-0}" != "1" ]] && return 0

    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >&2
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

