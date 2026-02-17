#!/usr/bin/env bash
#
# Install vds-backup into /usr/local (and systemd).
# Does NOT overwrite /usr/local/etc/backup.conf or /usr/local/secrets/.backup.env.
#
# Usage: sudo ./scripts/install.sh [REPO_ROOT]
#   REPO_ROOT defaults to the directory containing this script's repo (one level up from scripts/).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-$SCRIPT_DIR}"

BIN_DIR="/usr/local/bin"
LIB_ROOT="/usr/local/lib"
BACKUP_LIB_DIR="${LIB_ROOT}/backup"
SYSTEMD_DIR="/etc/systemd/system"
LOCAL_ETC="/usr/local/etc"

echo "Installing from: ${REPO_ROOT}"

# Directories
mkdir -p "${BIN_DIR}"
mkdir -p "${LIB_ROOT}"
mkdir -p "${BACKUP_LIB_DIR}"
mkdir -p "${SYSTEMD_DIR}"
mkdir -p "${LOCAL_ETC}"

# Entrypoint
install -m 755 "${REPO_ROOT}/bin/backup.sh" "${BIN_DIR}/backup.sh"

# System-wide libs
install -m 644 "${REPO_ROOT}/lib/logger.sh"   "${LIB_ROOT}/logger.sh"
install -m 644 "${REPO_ROOT}/lib/telegram.sh" "${LIB_ROOT}/telegram.sh"

# Backup domain libs
for f in config.sh disk_check.sh main.sh postgres_dump.sh report.sh restic.sh sqlite_discovery.sh sqlite_dump.sh; do
  install -m 644 "${REPO_ROOT}/lib/backup/${f}" "${BACKUP_LIB_DIR}/${f}"
done

# systemd units
install -m 644 "${REPO_ROOT}/systemd/backup.service" "${SYSTEMD_DIR}/backup.service"
install -m 644 "${REPO_ROOT}/systemd/backup.timer"   "${SYSTEMD_DIR}/backup.timer"

# Example config: only install if missing (do not overwrite real config)
if [[ ! -f "${LOCAL_ETC}/backup.conf" ]]; then
  if [[ -f "${REPO_ROOT}/etc/backup.conf.example" ]]; then
    install -m 640 "${REPO_ROOT}/etc/backup.conf.example" "${LOCAL_ETC}/backup.conf"
    echo "Created ${LOCAL_ETC}/backup.conf from example; edit and set secrets."
  fi
else
  echo "Leaving existing ${LOCAL_ETC}/backup.conf unchanged."
fi

# Secrets: never touch
if [[ -f /usr/local/secrets/.backup.env ]]; then
  echo "Leaving existing /usr/local/secrets/.backup.env unchanged."
else
  echo "Create /usr/local/secrets/.backup.env and set RESTIC_PASSWORD (and optionally TG_*)."
fi

echo "Done. Reload systemd: systemctl daemon-reload"