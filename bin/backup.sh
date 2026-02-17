#!/usr/bin/env bash

set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${PROJECT_ROOT}/lib"

# Core logging and utilities
# shellcheck source=/dev/null
source "${LIB_DIR}/logger.sh"

# Domain-specific backup modules
# shellcheck source=/dev/null
source "${LIB_DIR}/backup/config.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/backup/disk_check.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/backup/restic.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/backup/report.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/backup/main.sh"

# Shared helpers
# shellcheck source=/dev/null
source "${LIB_DIR}/backup/sqlite_discovery.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/backup/sqlite_dump.sh"
# shellcheck source=/dev/null
source "${LIB_DIR}/telegram.sh"

backup_run "$@"

