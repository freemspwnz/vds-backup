#!/usr/bin/env bash

set -euo pipefail

# Telegram Bot API HTML notifications (TG_TOKEN, TG_CHAT_ID) and job reports.

# Escape text for Telegram HTML parse_mode (must run before wrapping in tags).
tg_html_escape() {
    local s="${1:-}"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# Telegram sendMessage text limit is 4096; leave room for truncation marker.
tg_html_truncate() {
    local s="${1:-}"
    local max="${2:-3900}"
    if [[ "${#s}" -le "$max" ]]; then
        printf '%s' "$s"
        return 0
    fi
    printf '%s\n…(truncated)' "${s:0:max}"
}

tg_send_html() {
    local text="${1:-}"

    if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
        log_debug "Telegram credentials not set; skipping notification."
        return 0
    fi

    if [[ -z "$text" ]]; then
        log_warn "Empty Telegram message, nothing to send."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl not found; cannot send Telegram notification."
        return 1
    fi

    text="$(tg_html_truncate "$text")"

    local api_url="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    local response

    response="$(curl -sS -X POST "$api_url" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${text}" 2>/dev/null)" || {
        log_warn "Failed to send Telegram notification (curl error)."
        return 1
    }

    if [[ "$response" != *'"ok":true'* ]]; then
        local desc
        desc="$(printf '%s' "$response" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')"
        log_error "Telegram API error: ${desc:-$response}"
        return 1
    fi

    log_info "Telegram notification sent."
}

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

# Job report. Orchestrator passes plain status/stats — HTML lives here.
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
