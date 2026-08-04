#!/usr/bin/env bash

set -euo pipefail

# Telegram Bot API HTML notifications (TG_TOKEN, TG_CHAT_ID).

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
