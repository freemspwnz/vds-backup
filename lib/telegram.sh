#!/usr/bin/env bash

set -euo pipefail

# Telegram send module
# Sends HTML-formatted messages using Telegram Bot API and curl.
#
# Environment variables:
#   TG_TOKEN   - Telegram bot token (required)
#   TG_CHAT_ID - Target chat ID (required)
#
# Functions:
#   tg_send_html "<html_message>"

tg_send_html() {
    local text="${1:-}"

    if [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
        log_debug "Telegram credentials are not set; skipping notification."
        return 0
    fi

    if [[ -z "$text" ]]; then
        log_warn "Empty Telegram message, nothing to send."
        return 0
    fi

    local api_url="https://api.telegram.org/bot${TG_TOKEN}/sendMessage"

    if ! curl -sS -X POST "$api_url" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${text}" >/dev/null; then
        log_warn "Failed to send Telegram notification."
        return 1
    fi

    log_info "Telegram notification sent successfully."
}

