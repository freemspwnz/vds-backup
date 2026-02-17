#!/usr/bin/env bash

set -euo pipefail

# Backup configuration loader.
# Responsible for reading:
#   - /usr/local/etc/backup.conf        (Bash config with paths, arrays, etc.)
#   - /usr/local/secrets/.backup.env    (ENV-style secrets: RESTIC_PASSWORD, TG_TOKEN, ...)
#
# We intentionally do NOT use the generic import_file/import_lib from the
# reference implementation here because:
#   - /etc/backup.conf is a Bash script with arrays and expressions, not a
#     simple KEY=VALUE file, so import_file's line-based parser would reject it.
#   - For .env files we prefer to rely on Bash's own parser with `set -a`,
#     which correctly handles quoting and special characters.

BACKUP_CONF_PATH_DEFAULT="/usr/local/etc/backup.conf"
BACKUP_SECRETS_PATH_DEFAULT="/usr/local/secrets/.backup.env"

backup_require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        log_error "Required environment/config variable '${name}' is not set."
        return 1
    fi
}

backup_load_config() {
    local conf_path="${BACKUP_CONF_PATH:-$BACKUP_CONF_PATH_DEFAULT}"
    local secrets_path="${BACKUP_SECRETS_PATH:-$BACKUP_SECRETS_PATH_DEFAULT}"

    if [[ -f "$conf_path" ]]; then
        # shellcheck source=/dev/null
        source "$conf_path"
        log_debug "Loaded config file: ${conf_path}"
        # Ensure array vars are set so ${#VAR[@]} is safe in main.sh (no :-0 needed)
        [[ -z "${EXTRA_BACKUP_PATHS+set}" ]] && EXTRA_BACKUP_PATHS=()
        [[ -z "${RESTIC_EXCLUDES+set}" ]] && RESTIC_EXCLUDES=()
    else
        log_error "Config file not found: ${conf_path}"
        return 1
    fi

    if [[ -f "$secrets_path" ]]; then
        # Export variables from secrets file so they are visible to restic, etc.
        set -a
        # shellcheck source=/dev/null
        source "$secrets_path"
        set +a
        log_debug "Loaded secrets file: ${secrets_path}"
    else
        log_warn "Secrets file not found: ${secrets_path}. Continuing without it."
    fi

    backup_require_var "RESTIC_REPOSITORY"
    backup_require_var "DOCKER_DIR"
}

