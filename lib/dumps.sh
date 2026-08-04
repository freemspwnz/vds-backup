#!/usr/bin/env bash

set -euo pipefail

# SQLite discovery/dump + PostgreSQL dump via docker.
# When a dump type is enabled, failures are fatal (fail-closed).

backup_sqlite_find_in_root() {
    local root_dir="$1"

    if [[ -z "$root_dir" ]]; then
        log_error "sqlite find: root_dir is empty."
        return 1
    fi
    if [[ ! -d "$root_dir" ]]; then
        log_error "sqlite find: directory not found: ${root_dir}"
        return 1
    fi

    find "$root_dir" -type f \( \
        -name '*.sqlite' -o \
        -name '*.db' -o \
        -name '*.sqlite3' \
    \) 2>/dev/null
}

backup_sqlite_collect_db_paths() {
    local -a found=()
    local root f
    local scan_out

    if [[ "${#SQLITE_DB_FILES[@]}" -gt 0 ]]; then
        for f in "${SQLITE_DB_FILES[@]}"; do
            [[ -n "$f" ]] && found+=("$f")
        done
    fi

    if [[ "${#SQLITE_SCAN_ROOTS[@]}" -gt 0 ]]; then
        for root in "${SQLITE_SCAN_ROOTS[@]}"; do
            scan_out="$(backup_sqlite_find_in_root "$root")" || return 1
            while IFS= read -r f; do
                [[ -n "$f" ]] && found+=("$f")
            done <<<"$scan_out"
        done
    fi

    if [[ "${#found[@]}" -eq 0 ]]; then
        return 0
    fi

    printf '%s\n' "${found[@]}" | awk 'NF && !seen[$0]++'
}

backup_sqlite_dump_all() {
    local tmp_dir="$1"
    local timestamp="$2"
    local sqlite_dir dump_path rel safe_name db count=0 failed=0
    local -a paths=()
    local paths_raw

    if [[ "${SQLITE_DUMP_ENABLED}" != "1" ]]; then
        log_info "SQLite dump disabled."
        return 0
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        log_error "sqlite3 not found; required when SQLITE_DUMP_ENABLED=1."
        return 1
    fi

    if [[ "${#SQLITE_DB_FILES[@]}" -eq 0 && "${#SQLITE_SCAN_ROOTS[@]}" -eq 0 ]]; then
        log_error "SQLITE_DUMP_ENABLED=1 but SQLITE_DB_FILES and SQLITE_SCAN_ROOTS are empty."
        return 1
    fi

    paths_raw="$(backup_sqlite_collect_db_paths)" || return 1
    if [[ -n "$paths_raw" ]]; then
        mapfile -t paths <<<"$paths_raw"
    fi

    if [[ "${#paths[@]}" -eq 0 ]]; then
        log_error "SQLITE_DUMP_ENABLED=1 but no SQLite databases found."
        return 1
    fi

    sqlite_dir="${tmp_dir}/sqlite"
    mkdir -p "$sqlite_dir"

    for db in "${paths[@]}"; do
        [[ -z "$db" ]] && continue
        if [[ ! -f "$db" ]]; then
            log_error "SQLite file not found: ${db}"
            failed=1
            continue
        fi

        rel="${db#/}"
        safe_name="${rel//\//_}"
        dump_path="${sqlite_dir}/${safe_name}.${timestamp}.sql"

        log_info "Dumping SQLite '${db}' → '${dump_path}'"
        if sqlite3 "$db" ".dump" >"$dump_path" 2>"${dump_path}.err"; then
            rm -f "${dump_path}.err" || true
            count=$((count + 1))
        else
            log_error "Failed to dump '${db}' (see ${dump_path}.err)"
            rm -f "$dump_path" || true
            failed=1
        fi
    done

    log_info "SQLite dumps created: ${count}"
    [[ "$failed" -eq 0 ]]
}

backup_postgres_dump() {
    local tmp_dir="$1"
    local timestamp="$2"
    local pg_dir dump_path user

    if [[ "${POSTGRES_DUMP_ENABLED}" != "1" ]]; then
        log_info "PostgreSQL dump disabled."
        return 0
    fi

    if [[ -z "${POSTGRES_DOCKER_CONTAINER:-}" ]]; then
        log_error "POSTGRES_DUMP_ENABLED=1 but POSTGRES_DOCKER_CONTAINER is not set."
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker not found; required when POSTGRES_DUMP_ENABLED=1."
        return 1
    fi

    pg_dir="${tmp_dir}/postgres"
    mkdir -p "$pg_dir"
    user="${POSTGRES_DUMP_USER:-postgres}"
    dump_path="${pg_dir}/postgres_all_${timestamp}.sql"

    log_info "Dumping PostgreSQL from container '${POSTGRES_DOCKER_CONTAINER}' as '${user}'"

    if docker exec "${POSTGRES_DOCKER_CONTAINER}" pg_dumpall -c -U "${user}" \
        >"${dump_path}" 2>"${dump_path}.err"; then
        rm -f "${dump_path}.err" || true
        log_info "PostgreSQL dump OK: ${dump_path}"
        return 0
    fi

    log_error "PostgreSQL dump failed (see ${dump_path}.err)"
    rm -f "$dump_path" || true
    return 1
}

backup_dumps_needed() {
    [[ "${SQLITE_DUMP_ENABLED}" == "1" ]] || [[ "${POSTGRES_DUMP_ENABLED}" == "1" ]]
}

backup_run_dumps() {
    local tmp_dir="$1"
    local timestamp="$2"

    backup_sqlite_dump_all "$tmp_dir" "$timestamp"
    backup_postgres_dump "$tmp_dir" "$timestamp"
}
