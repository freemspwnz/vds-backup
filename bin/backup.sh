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
# ENV_FILE is resolved in backup_resolve_env_file (config.sh) at load_global time.

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
source "${LIB_ROOT}/main.sh"

backup_main "$@"
