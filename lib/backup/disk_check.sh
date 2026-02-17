#!/usr/bin/env bash

set -euo pipefail

# Disk / source directory check for backup.
#
# This module is conceptually inspired by the reference `disk_checkup.sh`,
# but adapted to this project's model, where:
#   - we run on the VDS host,
#   - the local data to be backed up is under DOCKER_DIR,
#   - the actual restic repository lives remotely (SFTP on router SSD).
#
# Here we validate that DOCKER_DIR exists, is readable, and contains at least
# one reasonable subdirectory entry to back up. This is the closest equivalent
# to a "disk check" we can do from the VDS side without mounting the router SSD.
#
# Side effects:
#   - Sets global DISK_STATUS to one of: [OK], [FAIL].

backup_disk_check() {
    local root="${DOCKER_DIR:-}"
    local has_entries=0
    local invalid_entries=""

    DISK_STATUS="[FAIL]"

    if [[ -z "$root" ]]; then
        log_error "backup_disk_check: DOCKER_DIR is not set."
        return 1
    fi

    if [[ ! -d "$root" ]]; then
        log_error "backup_disk_check: directory does not exist: ${root}"
        return 1
    fi

    if [[ ! -r "$root" ]]; then
        log_error "backup_disk_check: directory is not readable: ${root}"
        return 1
    fi

    local entry
    shopt -s nullglob
    for entry in "$root"/*; do
        # No entries at all is handled after the loop
        [[ ! -e "$entry" ]] && continue

        if [[ -f "$entry" ]]; then
            invalid_entries+="${entry##*/} (file), "
            continue
        fi

        if [[ -d "$entry" ]]; then
            # Skip common system directories if needed (none by default)
            has_entries=1
            continue
        fi

        # Unsupported type (symlink, socket, etc.)
        invalid_entries+="${entry##*/} (unsupported type), "
    done
    shopt -u nullglob

    if [[ -n "$invalid_entries" ]]; then
        invalid_entries="$(printf '%s\n' "$invalid_entries" | sed 's/, $//')"
        log_warn "Invalid entries in ${root}: ${invalid_entries}"
        log_error "Disk checkup: [FAIL]"
        DISK_STATUS="[FAIL]"
        return 1
    fi

    if [[ "$has_entries" -eq 0 ]]; then
        log_warn "No directories found under ${root} for backup."
        log_error "Disk checkup: [FAIL]"
        DISK_STATUS="[FAIL]"
        return 1
    fi

    DISK_STATUS="[OK]"
    log_info "Disk checkup: [OK] for ${root}"
    return 0
}

