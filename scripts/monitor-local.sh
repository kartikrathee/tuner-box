#!/usr/bin/env bash
set -u

WEB_URL="${WEB_URL:-http://127.0.0.1:5173/}"
API_HEALTH_URL="${API_HEALTH_URL:-http://127.0.0.1:17493/health}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-5}"
CURL_TIMEOUT="${CURL_TIMEOUT:-3}"

printf 'Monitoring Tuner Box local services every %s seconds (Ctrl+C to stop)\n' "$MONITOR_INTERVAL"
printf 'Web: %s\nBackend: %s\n\n' "$WEB_URL" "$API_HEALTH_URL"

while true; do
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    web_code="$(/usr/bin/curl --silent --show-error --output /dev/null \
        --write-out '%{http_code}' --max-time "$CURL_TIMEOUT" "$WEB_URL" 2>/dev/null || true)"
    case "$web_code" in
        2??|3??) web_state="UP" ;;
        *)       web_state="DOWN" ;;
    esac

    api_result="$(/usr/bin/curl --silent --show-error --max-time "$CURL_TIMEOUT" \
        --write-out $'\n%{http_code}' "$API_HEALTH_URL" 2>/dev/null || true)"
    api_code="${api_result##*$'\n'}"
    api_body="${api_result%$'\n'*}"

    if [[ "$api_code" == 2?? && ( "$api_body" == *'"status":"healthy"'* || "$api_body" == *'"status": "healthy"'* ) ]]; then
        api_state="HEALTHY"
    elif [[ "$api_code" == 2?? ]]; then
        api_state="RESPONDING"
    else
        api_state="DOWN"
    fi

    printf '[%s] web=%s (%s)  backend=%s (%s)\n' \
        "$timestamp" "$web_state" "${web_code:-000}" "$api_state" "${api_code:-000}"
    sleep "$MONITOR_INTERVAL"
done
