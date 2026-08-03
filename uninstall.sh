#!/usr/bin/env bash
#
# Uninstall vds-backup from /usr/local and systemd.
# Removes only files/dirs installed by install.sh (and related config/secrets).
# Does NOT touch: restic binary, remote restic repo, SSH keys, Docker data,
# /usr/local/{bin,lib,etc,secrets} themselves, or this source tree.
#
# Usage: sudo ./uninstall.sh

set -euo pipefail

BIN_DIR="/usr/local/bin"
LIB_ROOT="/usr/local/lib"
BACKUP_LIB_DIR="${LIB_ROOT}/backup"
SYSTEMD_DIR="/etc/systemd/system"
LOCAL_ETC="/usr/local/etc"
SECRETS_FILE="/usr/local/secrets/.backup.env"
CONF_FILE="${LOCAL_ETC}/backup.conf"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Must run as root (e.g. sudo ./uninstall.sh)" >&2
  exit 1
fi

echo "Uninstalling vds-backup…"

# Stop scheduling and any in-flight oneshot before removing units/files
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now backup.timer 2>/dev/null || true
  systemctl stop backup.service 2>/dev/null || true
  systemctl reset-failed backup.service backup.timer 2>/dev/null || true
fi

# Entrypoint (install -m 755 … → /usr/local/bin/backup.sh)
rm -f -- "${BIN_DIR}/backup.sh"

# System-wide libs from this repo
rm -f -- "${LIB_ROOT}/logger.sh" "${LIB_ROOT}/telegram.sh"

# Backup domain libs (directory created by install)
if [[ -d "${BACKUP_LIB_DIR}" ]]; then
  rm -f -- \
    "${BACKUP_LIB_DIR}/config.sh" \
    "${BACKUP_LIB_DIR}/disk_check.sh" \
    "${BACKUP_LIB_DIR}/main.sh" \
    "${BACKUP_LIB_DIR}/postgres_dump.sh" \
    "${BACKUP_LIB_DIR}/report.sh" \
    "${BACKUP_LIB_DIR}/restic.sh" \
    "${BACKUP_LIB_DIR}/sqlite_discovery.sh" \
    "${BACKUP_LIB_DIR}/sqlite_dump.sh"
  rmdir -- "${BACKUP_LIB_DIR}" 2>/dev/null || true
  if [[ -d "${BACKUP_LIB_DIR}" ]]; then
    echo "Note: ${BACKUP_LIB_DIR} not empty; left in place."
  fi
fi

# systemd units and optional drop-ins (e.g. backup.timer.d/override.conf)
rm -f -- "${SYSTEMD_DIR}/backup.service" "${SYSTEMD_DIR}/backup.timer"
rm -rf -- "${SYSTEMD_DIR}/backup.service.d" "${SYSTEMD_DIR}/backup.timer.d"

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi

# Config and secrets created for this tool (install leaves them alone; uninstall removes)
rm -f -- "${CONF_FILE}" "${SECRETS_FILE}"

# Leftover temp dump dirs from crashed runs (pattern from main.sh)
shopt -s nullglob
for d in /tmp/backup_dumps.*; do
  [[ -d "$d" ]] && rm -rf -- "$d"
done
shopt -u nullglob

echo "Done. Removed installed scripts, systemd units, config, and secrets."
echo "Not removed: restic, remote repository, SSH keys, Docker data, source clone."
