#!/usr/bin/env bash

# SQLite dump module.
# Responsible only for creating logical dumps of SQLite databases using `sqlite3 .dump`.
#
# Functions:
#   sqlite_dump_databases <db_list_file_or_dash> <tmp_dir> <timestamp>
#     - db_list_file_or_dash: path to file with DB paths (one per line) or "-" to read from stdin
#     - tmp_dir: directory where dumps will be placed
#     - timestamp: string appended to dump file names
# Output:
#   Prints paths to successfully created dumps (one per line).

sqlite_dump_databases() {
    local db_list_source="$1"
    local tmp_dir="$2"
    local timestamp="$3"

    if [[ -z "$db_list_source" || -z "$tmp_dir" || -z "$timestamp" ]]; then
        log_error "sqlite_dump_databases: db_list_source/tmp_dir/timestamp are required."
        return 1
    fi

    if [[ ! -d "$tmp_dir" ]]; then
        log_error "sqlite_dump_databases: tmp_dir does not exist: ${tmp_dir}"
        return 1
    fi

    local db
    while IFS= read -r db; do
        [[ -z "$db" ]] && continue
        if [[ ! -f "$db" ]]; then
            log_warn "sqlite_dump_databases: file not found, skipping: ${db}"
            continue
        fi

        local rel safe_name dump_path
        # Use a safe name derived from the path
        rel="${db#/}"
        safe_name="${rel//\//_}"
        dump_path="${tmp_dir}/${safe_name}.${timestamp}.sql"

        log_info "Dumping SQLite database '${db}' to '${dump_path}'..."

        if sqlite3 "$db" ".dump" >"$dump_path" 2>"${dump_path}.err"; then
            rm -f "${dump_path}.err" || true
            printf '%s\n' "$dump_path"
        else
            log_error "Failed to create dump for '${db}'. See ${dump_path}.err"
            rm -f "$dump_path" || true
        fi
    done < <(
        if [[ "$db_list_source" == "-" ]]; then
            cat
        else
            cat "$db_list_source"
        fi
    )
}

