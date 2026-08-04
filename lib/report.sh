#!/usr/bin/env bash

set -euo pipefail

backup_send_report() {
    local job="$1"
    local host="$2"
    local status="$3"
    local text="$4"
    local stats="${5:-}"
    local raw_tail="${6:-}"
    local extra="${7:-}"

    local msg
    msg="$(cat <<EOF
Job: <b>${job}</b>
Host: <b>${host}</b>
Status: <b>${status}</b>
${text}
EOF
)"

    if [[ -n "$stats" ]]; then
        msg+="

Stats:
<pre>${stats}</pre>"
    fi

    if [[ -n "$raw_tail" ]]; then
        msg+="

<b>Restic log (tail):</b>
<pre>${raw_tail}</pre>"
    fi

    if [[ -n "$extra" ]]; then
        msg+="

${extra}"
    fi

    tg_send_html "$msg"
}
