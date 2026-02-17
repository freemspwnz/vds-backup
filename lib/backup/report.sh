#!/usr/bin/env bash

set -euo pipefail

# Reporting helpers for backup.
#
# Currently focuses on building Telegram-friendly HTML messages based on:
#   - host
#   - disk check status (from DISK_STATUS)
#   - repository name and backup status
#   - restic statistics extracted from BACKUP_RESTIC_LOG
#
# Uses:
#   tg_send_html    - from lib/telegram.sh
#   DISK_STATUS     - set by backup_disk_check

backup_build_telegram_message() {
    local host="$1"
    local repo_name="$2"
    local backup_status="$3"
    local backup_status_text="$4"
    local stats="$5"
    local disk_status="${DISK_STATUS:-[UNKNOWN]}"

    cat <<EOF
<b>Host:</b> ${host}
<b>Disk checkup:</b> ${disk_status}
<b>Repo '${repo_name}' backup:</b> ${backup_status}
<b>Stats:</b>
<pre>${stats}</pre>
Backup ${backup_status_text}.
EOF
}

backup_send_telegram_report() {
    local host="$1"
    local repo_name="$2"
    local backup_status="$3"
    local backup_status_text="$4"
    local stats="$5"

    local msg
    msg="$(backup_build_telegram_message "$host" "$repo_name" "$backup_status" "$backup_status_text" "$stats")"
    tg_send_html "${msg}"
}

