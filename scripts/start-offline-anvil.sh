#!/bin/sh
set -eu

MANIFEST="${ANVIL_OFFLINE_STATE_MANIFEST:-/app/fixtures/anvil-state/manifest.json}"
CHAIN_SELECTOR="${CHAIN_ID:-${CHAIN_NAME:-ethereum}}"
RPC_HOST="${RPC_HOST:-0.0.0.0}"
RPC_PORT="${RPC_PORT:-8545}"
SHIM_HOST="${SHIM_HOST:-127.0.0.1}"
SHIM_PORT="${SHIM_PORT:-18549}"
CACHE_ROOT="${CACHE_ROOT:-/tmp/chainsentry-foundry-cache}"
ANVIL_OFFLINE_MODE="${ANVIL_OFFLINE_MODE:-cache-fork}"
ANVIL_FORK_TIMEOUT_MS="${ANVIL_FORK_TIMEOUT_MS:-5000}"
ANVIL_FORK_RETRIES="${ANVIL_FORK_RETRIES:-2}"

metadata_file="$(mktemp)"
python3 - "$MANIFEST" "$CHAIN_SELECTOR" >"$metadata_file" <<'PY'
import json
import shlex
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
selector = sys.argv[2].lower()
manifest = json.loads(manifest_path.read_text())

match = None
for fixture in manifest["fixtures"]:
    if str(fixture["chain_id"]) == selector or fixture["chain_name"].lower() == selector:
        match = fixture
        break

if match is None:
    valid = ", ".join(
        f"{fixture['chain_name']}({fixture['chain_id']})"
        for fixture in manifest["fixtures"]
    )
    raise SystemExit(f"unknown offline Anvil fixture {selector}; valid fixtures: {valid}")

root = manifest_path.parent.parent.parent
cache_archive = root / match["cache_archive"]
state_file = root / match["state_file"]

for key, value in {
    "OFFLINE_CHAIN_ID": str(match["chain_id"]),
    "OFFLINE_CHAIN_NAME": match["chain_name"],
    "OFFLINE_FORK_BLOCK": str(match["fork_block"]),
    "OFFLINE_CACHE_ARCHIVE": str(cache_archive),
    "OFFLINE_STATE_FILE": str(state_file),
}.items():
    print(f"{key}={shlex.quote(value)}")
PY
. "$metadata_file"
rm -f "$metadata_file"

if [ ! -f "$OFFLINE_CACHE_ARCHIVE" ]; then
  printf 'offline cache archive not found: %s\n' "$OFFLINE_CACHE_ARCHIVE" >&2
  exit 1
fi

cleanup() {
  if [ -n "${anvil_pid:-}" ]; then
    kill "$anvil_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "${shim_pid:-}" ]; then
    kill "$shim_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup INT TERM EXIT

if [ "$ANVIL_OFFLINE_MODE" = "load-state" ]; then
  if [ ! -f "$OFFLINE_STATE_FILE" ]; then
    printf 'offline state file not found: %s\n' "$OFFLINE_STATE_FILE" >&2
    exit 1
  fi
  printf 'starting offline Anvil for %s at %s:%s from state=%s\n' "$OFFLINE_CHAIN_NAME" "$RPC_HOST" "$RPC_PORT" "$OFFLINE_STATE_FILE"
  anvil \
    --host "$RPC_HOST" \
    --port "$RPC_PORT" \
    --chain-id "$OFFLINE_CHAIN_ID" \
    --load-state "$OFFLINE_STATE_FILE" &
  anvil_pid="$!"
else
  rm -rf "$CACHE_ROOT"
  mkdir -p "$CACHE_ROOT"
  tar -xzf "$OFFLINE_CACHE_ARCHIVE" -C "$CACHE_ROOT"
  CACHE_FILE="$(find "$CACHE_ROOT" -path "*/${OFFLINE_FORK_BLOCK}/storage.json" -type f | head -n 1)"
  if [ -z "$CACHE_FILE" ]; then
    printf 'restored cache for %s did not include block %s storage.json\n' "$OFFLINE_CHAIN_NAME" "$OFFLINE_FORK_BLOCK" >&2
    exit 1
  fi

  printf 'starting offline RPC shim for %s chain_id=%s cache=%s\n' "$OFFLINE_CHAIN_NAME" "$OFFLINE_CHAIN_ID" "$CACHE_FILE"
  python3 /usr/local/bin/offline-anvil-rpc-shim.py \
    --cache-file "$CACHE_FILE" \
    --chain-id "$OFFLINE_CHAIN_ID" \
    --host "$SHIM_HOST" \
    --port "$SHIM_PORT" &
  shim_pid="$!"

  shim_url="http://${SHIM_HOST}:${SHIM_PORT}"
  for _ in $(seq 1 30); do
    if python3 - "$shim_url" "$OFFLINE_CHAIN_ID" <<'PY'
import json
import sys
import urllib.request

url = sys.argv[1]
expected = hex(int(sys.argv[2]))
payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}).encode()
request = urllib.request.Request(url, data=payload, headers={"content-type": "application/json"})
try:
    with urllib.request.urlopen(request, timeout=1) as response:
        body = json.loads(response.read())
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if body.get("result") == expected else 1)
PY
    then
      break
    fi
    if ! kill -0 "$shim_pid" >/dev/null 2>&1; then
      printf 'offline RPC shim exited during startup\n' >&2
      exit 1
    fi
    sleep 1
  done

  printf 'starting offline Anvil for %s at %s:%s fork_block=%s\n' "$OFFLINE_CHAIN_NAME" "$RPC_HOST" "$RPC_PORT" "$OFFLINE_FORK_BLOCK"
  anvil \
    --host "$RPC_HOST" \
    --port "$RPC_PORT" \
    --chain-id "$OFFLINE_CHAIN_ID" \
    --fork-url "$shim_url" \
    --fork-block-number "$OFFLINE_FORK_BLOCK" \
    --fork-chain-id "$OFFLINE_CHAIN_ID" \
    --cache-path "$CACHE_ROOT" \
    --timeout "$ANVIL_FORK_TIMEOUT_MS" \
    --retries "$ANVIL_FORK_RETRIES" &
  anvil_pid="$!"
fi

rpc_url="http://127.0.0.1:${RPC_PORT}"
for _ in $(seq 1 30); do
  if cast block-number --rpc-url "$rpc_url" >/dev/null 2>&1; then
    printf 'offline Anvil ready for %s chain_id=%s rpc=%s\n' "$OFFLINE_CHAIN_NAME" "$OFFLINE_CHAIN_ID" "$rpc_url"
    wait "$anvil_pid"
    exit $?
  fi
  if ! kill -0 "$anvil_pid" >/dev/null 2>&1; then
    printf 'offline Anvil exited during startup\n' >&2
    exit 1
  fi
  sleep 1
done

printf 'offline Anvil did not become ready for %s at %s\n' "$OFFLINE_CHAIN_NAME" "$rpc_url" >&2
exit 1
