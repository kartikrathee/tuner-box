#!/usr/bin/env bash

# Wait for a Hugging Face model download to finish, load the model, and verify
# that the backend reports it as ready. Requires curl and Python 3.
#
# Examples:
#   ./scripts/monitor-model-download.sh
#   ./scripts/monitor-model-download.sh qwen-tts-0.6B 0.6B
#   START_DOWNLOAD=1 ./scripts/monitor-model-download.sh qwen-tts-1.7B 1.7B

set -euo pipefail

BASE_URL="${TUNER_BOX_URL:-http://127.0.0.1:17493}"
MODEL_NAME="${1:-qwen-tts-1.7B}"
MODEL_SIZE="${2:-1.7B}"
POLL_SECONDS="${POLL_SECONDS:-5}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-7200}"
START_DOWNLOAD="${START_DOWNLOAD:-0}"

for command in curl python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: required command not found: $command" >&2
    exit 127
  fi
done

url() {
  printf '%s%s' "${BASE_URL%/}" "$1"
}

get_json() {
  curl --fail --silent --show-error --max-time 30 "$(url "$1")"
}

post_json() {
  local endpoint="$1"
  shift
  curl --fail --silent --show-error --max-time 30 -X POST "$endpoint" "$@"
}

model_status() {
  get_json "/models/status" | python3 -c '
import json, sys
model_name = sys.argv[1]
data = json.load(sys.stdin)
for model in data.get("models", []):
    if model.get("model_name") == model_name:
        print(json.dumps(model))
        raise SystemExit(0)
print(json.dumps({"model_name": model_name, "missing": True}))
raise SystemExit(2)
' "$MODEL_NAME"
}

health_status() {
  get_json "/health" | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)))
'
}

read_field(){
  python3 -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

start_epoch=$(date +%s)
download_requested=0

echo "Monitoring $MODEL_NAME at $BASE_URL"

while :; do
  now=$(date +%s)
  elapsed=$((now - start_epoch))
  if (( elapsed >= TIMEOUT_SECONDS )); then
    echo "error: timed out after ${TIMEOUT_SECONDS}s waiting for $MODEL_NAME" >&2
    exit 1
  fi

  status_json=$(model_status)
  downloaded=$(printf '%s' "$status_json" | read_field downloaded)
  downloading=$(printf '%s' "$status_json" | read_field downloading)
  loaded=$(printf '%s' "$status_json" | read_field loaded)
  size_mb=$(printf '%s' "$status_json" | read_field size_mb)

  if [[ "$downloaded" == "True" || "$downloaded" == "true" ]]; then
    echo "download complete: ${size_mb:-unknown} MiB"
    break
  fi

  if [[ "$downloading" != "True" && "$downloading" != "true" ]]; then
    if [[ "$START_DOWNLOAD" == "1" && "$download_requested" == "0" ]]; then
      echo "download is not active; starting it"
      post_json "$(url /models/download)" \
        "-H" "Content-Type: application/json" \
        "-d" "{\"model_name\":\"$MODEL_NAME\"}" >/dev/null
      download_requested=1
    else
      echo "waiting: downloaded=$downloaded downloading=$downloading loaded=$loaded"
    fi
  else
    echo "downloading: elapsed=${elapsed}s"
  fi

  sleep "$POLL_SECONDS"
done

health_json=$(health_status)
health_loaded=$(printf '%s' "$health_json" | read_field model_loaded)
if [[ "$health_loaded" == "True" || "$health_loaded" == "true" ]]; then
  echo "model already loaded"
  exit 0
fi

echo "loading model size $MODEL_SIZE"
post_json "$(url "/models/load?model_size=${MODEL_SIZE}")" \
  -H "Accept: application/json" >/dev/null

load_start=$(date +%s)
while :; do
  now=$(date +%s)
  elapsed=$((now - load_start))
  if (( elapsed >= TIMEOUT_SECONDS )); then
    echo "error: timed out after ${TIMEOUT_SECONDS}s waiting for model load" >&2
    exit 1
  fi

  health_json=$(health_status)
  health_loaded=$(printf '%s' "$health_json" | read_field model_loaded)
  health_size=$(printf '%s' "$health_json" | read_field model_size)

  if [[ "$health_loaded" == "True" || "$health_loaded" == "true" ]]; then
    echo "model ready: size=${health_size:-unknown}"
    exit 0
  fi

  echo "loading: elapsed=${elapsed}s"
  sleep "$POLL_SECONDS"
done
