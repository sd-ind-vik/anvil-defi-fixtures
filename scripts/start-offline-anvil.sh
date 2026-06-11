#!/bin/sh
set -eu

MANIFEST="${ANVIL_OFFLINE_STATE_MANIFEST:-/app/fixtures/anvil-state/manifest.json}"
CHAIN_SELECTOR="${CHAIN_ID:-${CHAIN_NAME:-ethereum}}"
RPC_HOST="${RPC_HOST:-0.0.0.0}"
RPC_PORT="${RPC_PORT:-8545}"

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
state_file = str(root / match["state_file"])
full_state_file = str(root / match["full_state_file"]) if match.get("full_state_file") else ""

for key, value in {
    "OFFLINE_CHAIN_ID": str(match["chain_id"]),
    "OFFLINE_CHAIN_NAME": match["chain_name"],
    "OFFLINE_STATE_FILE": state_file,
    "OFFLINE_FULL_STATE_FILE": full_state_file,
}.items():
    print(f"{key}={shlex.quote(value)}")
PY
. "$metadata_file"
rm -f "$metadata_file"

# Prefer the enriched full state (includes protocol contract code + storage slots).
# Fall back to the sparse dump-state if the full state is not present.
_load_state="$OFFLINE_STATE_FILE"
if [ -n "${OFFLINE_FULL_STATE_FILE:-}" ] && [ -f "$OFFLINE_FULL_STATE_FILE" ]; then
  _load_state="$OFFLINE_FULL_STATE_FILE"
fi

if [ ! -f "$_load_state" ]; then
  printf 'offline state file not found: %s\n' "$_load_state" >&2
  exit 1
fi

cleanup() {
  if [ -n "${anvil_pid:-}" ]; then
    kill "$anvil_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup INT TERM EXIT

printf 'starting offline Anvil for %s at %s:%s from state=%s\n' \
  "$OFFLINE_CHAIN_NAME" "$RPC_HOST" "$RPC_PORT" "$_load_state"

anvil \
  --host "$RPC_HOST" \
  --port "$RPC_PORT" \
  --chain-id "$OFFLINE_CHAIN_ID" \
  --preserve-historical-states \
  --load-state "$_load_state" &
anvil_pid="$!"

rpc_url="http://127.0.0.1:${RPC_PORT}"
for _ in $(seq 1 30); do
  if cast block-number --rpc-url "$rpc_url" >/dev/null 2>&1; then
    printf 'offline Anvil ready for %s chain_id=%s rpc=%s\n' \
      "$OFFLINE_CHAIN_NAME" "$OFFLINE_CHAIN_ID" "$rpc_url"
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
