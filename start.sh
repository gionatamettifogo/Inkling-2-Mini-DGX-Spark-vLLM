#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ ! -f .env ]]; then
  echo "Missing $HERE/.env; create it with LLM_API_KEY and PORT=8896." >&2
  exit 1
fi

model_id="$(sed -n 's/^MODEL_ID=//p' .env | tail -n 1)"
if [[ -n "$model_id" && "$model_id" != "thinkingmachines/Inkling-2-Mini" ]]; then
  echo "This service must use MODEL_ID=thinkingmachines/Inkling-2-Mini." >&2
  exit 1
fi

port="$(sed -n 's/^PORT=//p' .env | tail -n 1)"
port="${port:-8896}"
if ss -lntH | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
  echo "Port $port is already listening; refusing to start." >&2
  exit 1
fi

exec docker compose --env-file .env -f compose.yaml up -d
