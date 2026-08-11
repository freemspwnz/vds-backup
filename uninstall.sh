#!/usr/bin/env bash
#
# Uninstall backup-utils from /usr/local and systemd.
# Removes only what install.sh deploys (symlink, units, /usr/local/etc/backup).
# Does NOT touch: git checkout, restic binary, remote restic repo, SSH keys,
# Docker data, or parent dirs like /usr/local/{bin,etc}.
#
# Usage: sudo ./uninstall.sh

set -euo pipefail

BIN_DIR="/usr/local/bin"
ETC_BACKUP="/usr/local/etc/backup"
SYSTEMD_DIR="/etc/systemd/system"
LOCK_DIR_BASE="/var/run/backup"

usage() {
    cat <<'EOF'
Usage: sudo ./uninstall.sh

Stops timers/services and removes install.sh artifacts.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Must run as root (e.g. sudo ./uninstall.sh)" >&2
    exit 1
fi

echo "Uninstalling backup-utils…"

if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now backup.timer 2>/dev/null || true
    systemctl stop backup.service 2>/dev/null || true
    systemctl disable --now backup-maintenance.timer 2>/dev/null || true
    systemctl stop backup-maintenance.service 2>/dev/null || true
    systemctl reset-failed backup.service backup.timer \
        backup-maintenance.service backup-maintenance.timer 2>/dev/null || true
fi

# Symlink from install.sh
rm -f -- "${BIN_DIR}/backup.sh"

# systemd units (+ legacy maintenance) and optional drop-ins
rm -f -- \
    "${SYSTEMD_DIR}/backup.service" \
    "${SYSTEMD_DIR}/backup.timer" \
    "${SYSTEMD_DIR}/backup-maintenance.service" \
    "${SYSTEMD_DIR}/backup-maintenance.timer"
rm -rf -- \
    "${SYSTEMD_DIR}/backup.service.d" \
    "${SYSTEMD_DIR}/backup.timer.d" \
    "${SYSTEMD_DIR}/backup-maintenance.service.d" \
    "${SYSTEMD_DIR}/backup-maintenance.timer.d"

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

# Config, jobs, secrets created under /usr/local/etc/backup
if [[ -d "${ETC_BACKUP}" ]]; then
    rm -rf -- "${ETC_BACKUP}"
    echo "Removed ${ETC_BACKUP}"
fi

# Leftover lock files/dirs and temp dump dirs from crashed runs
if [[ -d "${LOCK_DIR_BASE}" ]]; then
    rm -rf -- "${LOCK_DIR_BASE}"
fi

shopt -s nullglob
for d in /var/tmp/backup_dumps.* /tmp/backup_dumps.*; do
    [[ -d "$d" ]] && rm -rf -- "$d"
done
shopt -u nullglob

echo "Done. Removed symlink, systemd units, config, and secrets."
echo "Not removed: git checkout, restic, remote repository, SSH keys, Docker data."
