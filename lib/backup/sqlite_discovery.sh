#!/usr/bin/env bash

# SQLite discovery module.
# Responsible only for finding SQLite database files under a given root directory.
#
# Functions:
#   sqlite_find_databases <root_dir>
# Output:
#   Prints absolute paths to found databases (one per line).

sqlite_find_databases() {
    local root_dir="$1"

    if [[ -z "$root_dir" ]]; then
        log_error "sqlite_find_databases: root_dir is not set."
        return 1
    fi

    if [[ ! -d "$root_dir" ]]; then
        log_warn "sqlite_find_databases: directory not found: ${root_dir}"
        return 0
    fi

    find "$root_dir" -type f \( \
        -name '*.sqlite' -o \
        -name '*.db' -o \
        -name '*.sqlite3' \
    \) 2>/dev/null
}

