#!/usr/bin/env bash
#
# Install backup-utils on a Linux host (systemd).
# Usage: ./install.sh [REPO_ROOT]
#
# Code stays in the git checkout (symlink). Configs and secrets under /usr/local/etc/backup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${1:-$SCRIPT_DIR}" && pwd)"

BIN_DIR="/usr/local/bin"
ETC_BACKUP="/usr/local/etc/backup"
JOBS_DIR="${ETC_BACKUP}/jobs.d"
SYSTEMD_DIR="/etc/systemd/system"

usage() {
    cat <<'EOF'
Usage: ./install.sh [REPO_ROOT]

Linux only (systemd). Symlinks backup.sh; installs units and example configs.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -f "${REPO_ROOT}/bin/backup.sh" ]]; then
    echo "ERROR: ${REPO_ROOT} does not look like a backup-utils checkout." >&2
    exit 1
fi

link_force() {
    local target="$1"
    local linkpath="$2"
    mkdir -p "$(dirname "$linkpath")"
    ln -sfn "$target" "$linkpath"
    echo "symlink ${linkpath} -> ${target}"
}

echo "Installing backup-utils from: ${REPO_ROOT}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "WARN: install usually needs root for ${BIN_DIR} / systemd." >&2
fi

mkdir -p "${BIN_DIR}" "${ETC_BACKUP}" "${JOBS_DIR}"

link_force "${REPO_ROOT}/bin/backup.sh" "${BIN_DIR}/backup.sh"

if [[ ! -f "${ETC_BACKUP}/backup.conf" ]]; then
    install -m 640 "${REPO_ROOT}/etc/backup.conf.example" "${ETC_BACKUP}/backup.conf"
    echo "Created ${ETC_BACKUP}/backup.conf"
else
    echo "Leaving existing ${ETC_BACKUP}/backup.conf unchanged."
fi

shopt -s nullglob
for ex in "${REPO_ROOT}/etc/jobs.d/"*.conf.example; do
    base="$(basename "$ex" .example)"
    if [[ ! -f "${JOBS_DIR}/${base}" && ! -f "${JOBS_DIR}/$(basename "$ex")" ]]; then
        install -m 640 "$ex" "${JOBS_DIR}/$(basename "$ex")"
        echo "Installed example ${JOBS_DIR}/$(basename "$ex")"
    fi
done
shopt -u nullglob

# Secrets: prefer /usr/local/etc/backup/.env; migrate from checkout if needed.
if [[ ! -f "${ETC_BACKUP}/.env" ]]; then
    if [[ -f "${REPO_ROOT}/.env" ]]; then
        install -m 600 "${REPO_ROOT}/.env" "${ETC_BACKUP}/.env"
        echo "Migrated ${REPO_ROOT}/.env → ${ETC_BACKUP}/.env (you may remove the checkout copy)."
    elif [[ -f "${REPO_ROOT}/etc/.env.example" ]]; then
        install -m 600 "${REPO_ROOT}/etc/.env.example" "${ETC_BACKUP}/.env"
        echo "Created ${ETC_BACKUP}/.env — set RESTIC_PASSWORD."
    fi
else
    echo "Leaving existing ${ETC_BACKUP}/.env unchanged."
fi

if [[ -d "$SYSTEMD_DIR" ]]; then
    # Drop legacy maintenance units (check now runs on CHECK_WEEKDAY inside `run`).
    if systemctl list-unit-files backup-maintenance.timer &>/dev/null; then
        systemctl disable --now backup-maintenance.timer 2>/dev/null || true
    fi
    rm -f "${SYSTEMD_DIR}/backup-maintenance.service" "${SYSTEMD_DIR}/backup-maintenance.timer"

    install -m 644 "${REPO_ROOT}/etc/systemd/backup.service" "${SYSTEMD_DIR}/backup.service"
    install -m 644 "${REPO_ROOT}/etc/systemd/backup.timer" "${SYSTEMD_DIR}/backup.timer"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now backup.timer 2>/dev/null || echo "Enable: systemctl enable --now backup.timer"
    echo "Installed systemd units (backup.timer only)."
else
    echo "WARN: ${SYSTEMD_DIR} missing — copy units from etc/systemd/ yourself."
fi

echo ""
echo "Done. Update code: cd ${REPO_ROOT} && git pull"
echo "Next:"
echo "  1) Edit ${ETC_BACKUP}/backup.conf"
echo "  2) Copy jobs.d/*.conf.example → *.conf and edit"
echo "  3) Edit ${ETC_BACKUP}/.env (RESTIC_PASSWORD, optional REST_USER/REST_PASS, TG_*)"
echo "  4) Set BACKEND=sftp|rest in backup.conf (and REST_* or SFTP_* as needed)"
echo "  5) backup.sh init --job=NAME && backup.sh status --job=NAME"
echo "  6) backup.sh run --job=NAME"
