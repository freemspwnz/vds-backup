#!/usr/bin/env bash

set -euo pipefail

# PostgreSQL dump helper.
# Creates a logical dump from a PostgreSQL instance running in Docker.
#
# Configuration (from /etc/backup.conf):
#   POSTGRES_DOCKER_CONTAINER  - name of the postgres container (optional)
#   POSTGRES_DUMP_USER         - database user for pg_dumpall (default: postgres)
#   POSTGRES_DUMP_ENABLED      - if set to "false", postgres dump is skipped
#
# Uses globals:
#   BACKUP_TMP_DIR  - directory for placing dump files
#   TIMESTAMP       - timestamp suffix used for file names
#
# Output:
#   - On success: creates ${BACKUP_TMP_DIR}/postgres_all_${TIMESTAMP}.sql
#   - On error: logs a warning/error and continues without failing the whole backup.

backup_postgres_dump() {
    # Respect explicit disable flag
    if [[ "${POSTGRES_DUMP_ENABLED:-true}" == "false" ]]; then
        log_info "PostgreSQL dump is disabled by configuration."
        return 0
    fi

    if [[ -z "${POSTGRES_DOCKER_CONTAINER:-}" ]]; then
        log_info "POSTGRES_DOCKER_CONTAINER is not set; skipping PostgreSQL dump."
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_warn "Docker CLI is not available; skipping PostgreSQL dump."
        return 0
    fi

    if [[ -z "${BACKUP_TMP_DIR:-}" || ! -d "${BACKUP_TMP_DIR}" ]]; then
        log_warn "BACKUP_TMP_DIR is not set or does not exist; skipping PostgreSQL dump."
        return 0
    fi

    local user dump_path
    user="${POSTGRES_DUMP_USER:-postgres}"
    dump_path="${BACKUP_TMP_DIR}/postgres_all_${TIMESTAMP}.sql"

    log_info "Dumping PostgreSQL from container '${POSTGRES_DOCKER_CONTAINER}' as user '${user}' to '${dump_path}'..."

    if docker exec "${POSTGRES_DOCKER_CONTAINER}" pg_dumpall -c -U "${user}" >"${dump_path}" 2>"${dump_path}.err"; then
        rm -f "${dump_path}.err" || true
        log_info "PostgreSQL dump completed successfully."
        return 0
    else
        log_error "Failed to dump PostgreSQL from container '${POSTGRES_DOCKER_CONTAINER}'. See ${dump_path}.err for details."
        rm -f "${dump_path}" || true
        return 1
    fi
}

