#!/usr/bin/env bash

set -euo pipefail

# Build a labeled HTML block: "Label: <b>status</b>" + optional <pre>body</pre>.
backup_report_section() {
    local label="$1"
    local status="$2"
    local body="${3:-}"
    local out

    out="$(tg_html_escape "$label"): <b>$(tg_html_escape "$status")</b>"
    if [[ -n "$body" ]]; then
        out+="
<pre>$(tg_html_escape "$body")</pre>"
    fi
    printf '%s\n' "$out"
}

# Telegram job report. Orchestrator passes plain status/stats — HTML lives here.
# Args: job host status text [stats] [raw_tail] [prune_status] [prune_stats] [check_status] [check_stats]
# Empty prune_status / check_status omits that section.
backup_send_report() {
    local job host status text stats raw_tail
    local prune_st prune_stats check_st check_stats
    job="$(tg_html_escape "${1:-}")"
    host="$(tg_html_escape "${2:-}")"
    status="$(tg_html_escape "${3:-}")"
    text="$(tg_html_escape "${4:-}")"
    stats="$(tg_html_escape "${5:-}")"
    raw_tail="$(tg_html_escape "${6:-}")"
    prune_st="${7:-}"
    prune_stats="${8:-}"
    check_st="${9:-}"
    check_stats="${10:-}"

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

    if [[ -n "$prune_st" ]]; then
        msg+="

$(backup_report_section "Prune" "$prune_st" "$prune_stats")"
    fi

    if [[ -n "$check_st" ]]; then
        msg+="

$(backup_report_section "Check" "$check_st" "$check_stats")"
    fi

    tg_send_html "$msg"
}
