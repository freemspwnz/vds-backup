#!/usr/bin/env bash

set -euo pipefail

backup_send_report() {
    local job host status text stats raw_tail extra
    job="$(tg_html_escape "${1:-}")"
    host="$(tg_html_escape "${2:-}")"
    status="$(tg_html_escape "${3:-}")"
    text="$(tg_html_escape "${4:-}")"
    stats="$(tg_html_escape "${5:-}")"
    raw_tail="$(tg_html_escape "${6:-}")"
    # extra may already contain trusted HTML tags; callers must escape dynamic bits.
    extra="${7:-}"

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
