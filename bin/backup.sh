#!/usr/bin/env bash

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

backup_resolve_repo_root() {
    local source="${BASH_SOURCE[0]}"
    local dir
    while [[ -L "$source" ]]; do
        dir="$(cd "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="${dir}/${source}"
    done
    dir="$(cd "$(dirname "$source")" && pwd)"
    cd "${dir}/.." && pwd
}

BACKUP_REPO_ROOT="$(backup_resolve_repo_root)"
LIB_ROOT="${LIB_ROOT:-${BACKUP_REPO_ROOT}/lib}"

# Secrets live under /usr/local/etc/backup; fall back to checkout for local/dev.
if [[ -z "${ENV_FILE:-}" ]]; then
    if [[ -f /usr/local/etc/backup/.env ]]; then
        ENV_FILE="/usr/local/etc/backup/.env"
    elif [[ -f "${BACKUP_REPO_ROOT}/.env" ]]; then
        ENV_FILE="${BACKUP_REPO_ROOT}/.env"
    else
        ENV_FILE="/usr/local/etc/backup/.env"
    fi
fi

if [[ ! -f "${LIB_ROOT}/main.sh" ]]; then
    printf 'ERROR: cannot find libs at %s\n' "${LIB_ROOT}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${LIB_ROOT}/logger.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/telegram.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/common.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/lock.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/config.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/dumps.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/restic.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/report.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/main.sh"

backup_main "$@"
