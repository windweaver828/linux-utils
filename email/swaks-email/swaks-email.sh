#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env-email"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing email env file: $ENV_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

SUBJECT="${1:-Pi Notification}"
BODY="${2:-}"

SUBJECT="${SUBJECT//$'\r'/ }"
SUBJECT="${SUBJECT//$'\n'/ }"

if [[ -z "$BODY" ]]; then
    echo "Usage: $0 'Subject' 'Message body'" >&2
    exit 1
fi

: "${SMTP_TO:?Missing SMTP_TO}"
: "${SMTP_FROM:?Missing SMTP_FROM}"
: "${SMTP_SERVER:?Missing SMTP_SERVER}"
: "${SMTP_PORT:?Missing SMTP_PORT}"
: "${SMTP_AUTH_USER:?Missing SMTP_AUTH_USER}"
: "${SMTP_PASSWORD:?Missing SMTP_PASSWORD}"
: "${SMTP_HELO:?Missing SMTP_HELO}"

swaks \
    --to "$SMTP_TO" \
    --from "$SMTP_FROM" \
    --server "$SMTP_SERVER" \
    --port "$SMTP_PORT" \
    --auth LOGIN \
    --auth-user "$SMTP_AUTH_USER" \
    --auth-password "$SMTP_PASSWORD" \
    --tls \
    --helo "$SMTP_HELO" \
    --header "Subject: $SUBJECT" \
    --body "$BODY" >/dev/null 2>&1
