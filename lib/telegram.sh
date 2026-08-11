#!/usr/bin/env bash

set -euo pipefail

# Telegram Bot API HTML notifications (TG_TOKEN, TG_CHAT_ID).

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
