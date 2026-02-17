#!/usr/bin/env bash

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LIB_ROOT_DEFAULT="/usr/local/lib"
LIB_ROOT="${LIB_ROOT:-$LIB_ROOT_DEFAULT}"
BACKUP_LIB_DIR="${LIB_ROOT}/backup"

# Core logging and utilities (system-wide)
# shellcheck source=/dev/null
source "${LIB_ROOT}/logger.sh"

# Domain-specific backup modules
# shellcheck source=/dev/null
source "${BACKUP_LIB_DIR}/config.sh"
# shellcheck source=/dev/null
source "${BACKUP_LIB_DIR}/disk_check.sh"
# shellcheck source=/dev/null
source "${BACKUP_LIB_DIR}/restic.sh"
# shellcheck source=/dev/null
source "${BACKUP_LIB_DIR}/report.sh"
# shellcheck source=/dev/null
source "${BACKUP_LIB_DIR}/postgres_dump.sh"
# shellcheck source=/dev/null
source "${BACKUP_LIB_DIR}/main.sh"

# Shared helpers
# shellcheck source=/dev/null
source "${BACKUP_LIB_DIR}/sqlite_discovery.sh"
# shellcheck source=/dev/null
source "${BACKUP_LIB_DIR}/sqlite_dump.sh"
# shellcheck source=/dev/null
source "${LIB_ROOT}/telegram.sh"

backup_run "$@"

