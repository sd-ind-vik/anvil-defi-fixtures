#!/usr/bin/env bash
# test-offline-logs.sh
#
# Checks eth_getLogs availability for Aave V3 and Uniswap V3 events on the 4
# offline Anvil nodes.  Covers two scenarios:
#
#   1. Pre-fork logs served by the shim (requires logs file from capture)
#   2. Post-fork logs from newly mined blocks (always works, empty if no txns)
#
# Usage:
#   bash scripts/test-offline-logs.sh [--no-docker]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

START_DOCKER=true
for arg in "$@"; do
  [[ "$arg" == "--no-docker" ]] && START_DOCKER=false
done

# ── Colours ───────────────────────────────────────────────────────────────────
C_OK='\033[32m'
C_FAIL='\033[31m'
C_WARN='\033[33m'
C_DIM='\033[2m'
C_RESET='\033[0m'

PASS=0
FAIL=0
SKIP=0

ok()   { printf "${C_OK}  [PASS]${C_RESET} %s\n" "$1"; ((PASS++)) || true; }
fail() { printf "${C_FAIL}  [FAIL]${C_RESET} %s\n" "$1" >&2; ((FAIL++)) || true; }
skip() { printf "${C_DIM}  [SKIP]${C_RESET} %s\n" "$1"; ((SKIP++)) || true; }
info() { printf "  %s\n" "$1"; }

# ── Event topics ──────────────────────────────────────────────────────────────
# keccak256("ReserveDataUpdated(address,uint256,uint256,uint256,uint256,uint256)")
TOPIC_AAVE_RESERVE_UPDATED="0x804c9b842b2748a22bb64b345453a3de7ca54a6ca45ce00d415894979e22897a"
# keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)")
TOPIC_UNI_SWAP="0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
# keccak256("Supply(address,address,address,uint256,uint16)")
TOPIC_AAVE_SUPPLY="0xde6857219544bb5b7746f48ed30be6386fefc61b2f864cacf559893bf50fd951"

# ── Chains ────────────────────────────────────────────────────────────────────
# "chain_id|name|rpc|aave_pool|uni_pool|fork_block_file"
CHAINS=(
  "1|ethereum|http://127.0.0.1:8545|0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2|0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"
  "8453|base|http://127.0.0.1:8546|0xA238Dd80C259a72e81d7e4664a9801593F98d1c5|0xd0b53D9277642d899DF5C87A3966A349A798F224"
  "42161|arbitrum|http://127.0.0.1:8547|0x794a61358D6845594F94dc1DB02A252b5b4814aD|0xC6962004f452bE9203591991D15f6b388e09E8D0"
  "10|optimism|http://127.0.0.1:8548|0x794a61358D6845594F94dc1DB02A252b5b4814aD|0x1fb3cf6e48F1E7B10213E7b6d87D4c073C7Fdb7b"
)

cleanup() {
  [[ "$START_DOCKER" == true ]] && \
    docker compose --profile offline-anvil stop \
      offline-anvil-ethereum offline-anvil-base offline-anvil-arbitrum offline-anvil-optimism \
      >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# ── Start anvils ──────────────────────────────────────────────────────────────
if [[ "$START_DOCKER" == true ]]; then
  printf "Starting offline Anvil containers...\n"
  docker compose --profile offline-anvil up -d \
    offline-anvil-ethereum offline-anvil-base offline-anvil-arbitrum offline-anvil-optimism \
    >/dev/null 2>&1
  for entry in "${CHAINS[@]}"; do
    IFS='|' read -r _ name rpc _ _ <<<"$entry"
    for i in $(seq 1 60); do
      cast chain-id --rpc-url "$rpc" >/dev/null 2>&1 && break
      sleep 1
    done
    cast chain-id --rpc-url "$rpc" >/dev/null 2>&1 || { echo "FAIL: $name not ready"; exit 1; }
  done
fi

# helper: call eth_getLogs and return JSON array or error string
get_logs() {
  local rpc="$1" addr="$2" topic="$3" from_hex="$4" to_hex="$5"
  local filter
  if [[ -n "$topic" ]]; then
    filter="{\"address\":\"$addr\",\"topics\":[\"$topic\"],\"fromBlock\":\"$from_hex\",\"toBlock\":\"$to_hex\"}"
  else
    filter="{\"address\":\"$addr\",\"fromBlock\":\"$from_hex\",\"toBlock\":\"$to_hex\"}"
  fi
  cast rpc --rpc-url "$rpc" eth_getLogs "$filter" 2>&1 || true
}

count_logs() {
  python3 -c "
import json,sys
d=sys.stdin.read().strip()
try:
    arr=json.loads(d)
    print(len(arr) if isinstance(arr,list) else 'err')
except Exception:
    print('err')
"
}

printf "\n${C_DIM}=== Offline Anvil log/event test ===${C_RESET}\n\n"

for entry in "${CHAINS[@]}"; do
  IFS='|' read -r chain_id name rpc aave_pool uni_pool <<<"$entry"

  # Get current head and the fork block from manifest
  head_dec="$(cast block-number --rpc-url "$rpc" 2>/dev/null || echo 0)"
  fork_block="$(python3 -c "
import json
m=json.load(open('fixtures/anvil-state/manifest.json'))
fb=[f['fork_block'] for f in m['fixtures'] if str(f['chain_id'])=='$chain_id']
print(fb[0] if fb else 0)
" 2>/dev/null || echo 0)"
  fork_hex="$(printf '0x%x' "$fork_block")"
  from_hex="$(printf '0x%x' $(( fork_block > 50 ? fork_block - 50 : 0 )))"
  head_hex="$(printf '0x%x' "$head_dec")"
  post_hex="$(printf '0x%x' $((head_dec - 1)))"

  printf "${C_DIM}--- $name (chain $chain_id)  fork=$fork_block  head=$head_dec ---${C_RESET}\n"

  # ── Test 1: pre-fork Aave ReserveDataUpdated ─────────────────────────────
  result="$(get_logs "$rpc" "$aave_pool" "$TOPIC_AAVE_RESERVE_UPDATED" "$from_hex" "$fork_hex")"
  if echo "$result" | grep -q "offline cache miss\|no logs file\|no logs captured"; then
    fail "$name: pre-fork Aave logs — shim missing eth_getLogs or no logs file (run capture to fix)"
    info "  → recapture fixtures to generate logs file, then restart offline-anvil containers"
  elif echo "$result" | grep -q "error"; then
    fail "$name: pre-fork Aave logs — unexpected error: $(echo "$result" | head -1)"
  else
    count="$(echo "$result" | count_logs)"
    if [[ "$count" == "err" ]]; then
      fail "$name: pre-fork Aave logs — bad JSON response"
    elif [[ "$count" -gt 0 ]]; then
      ok "$name: pre-fork Aave ReserveDataUpdated — $count log(s) in last 50 blocks"
    else
      skip "$name: pre-fork Aave logs — 0 logs (no ReserveDataUpdated in last 50 blocks)"
    fi
  fi

  # ── Test 2: pre-fork Uniswap Swap ─────────────────────────────────────────
  result="$(get_logs "$rpc" "$uni_pool" "$TOPIC_UNI_SWAP" "$from_hex" "$fork_hex")"
  if echo "$result" | grep -q "offline cache miss\|no logs file\|no logs captured"; then
    fail "$name: pre-fork Uniswap Swap logs — no logs file"
  elif echo "$result" | grep -q "error"; then
    fail "$name: pre-fork Uniswap Swap logs — unexpected error: $(echo "$result" | head -1)"
  else
    count="$(echo "$result" | count_logs)"
    if [[ "$count" == "err" ]]; then
      fail "$name: pre-fork Uniswap logs — bad JSON response"
    elif [[ "$count" -gt 0 ]]; then
      ok "$name: pre-fork Uniswap Swap — $count log(s)"
    else
      skip "$name: pre-fork Uniswap logs — 0 Swap events in last 50 blocks"
    fi
  fi

  # ── Test 3: post-fork logs endpoint works — mine a block then query it ────
  cast rpc --rpc-url "$rpc" evm_mine >/dev/null 2>&1 || true
  new_head_dec="$(cast block-number --rpc-url "$rpc" 2>/dev/null || echo "$head_dec")"
  new_head_hex="$(printf '0x%x' "$new_head_dec")"
  result="$(get_logs "$rpc" "$aave_pool" "" "$new_head_hex" "$new_head_hex")"
  if echo "$result" | grep -q "error"; then
    fail "$name: post-fork eth_getLogs endpoint failed: $(echo "$result" | head -1)"
  else
    count="$(echo "$result" | count_logs)"
    if [[ "$count" == "err" ]]; then
      fail "$name: post-fork eth_getLogs — bad JSON response"
    else
      ok "$name: post-fork eth_getLogs endpoint works (mined block $new_head_dec: $count logs)"
    fi
  fi

  # ── Test 4: any logs at all for aave pool (no topic filter) ──────────────
  result="$(get_logs "$rpc" "$aave_pool" "" "$from_hex" "$fork_hex")"
  if echo "$result" | grep -q "error"; then
    skip "$name: all Aave logs — not available yet"
  else
    count="$(echo "$result" | count_logs)"
    [[ "$count" != "err" && "$count" -gt 0 ]] && \
      ok "$name: all Aave pool events at fork — $count total log(s)"
  fi

  printf "\n"
done

printf "${C_DIM}=== Summary ===${C_RESET}\n"
printf "  ${C_OK}PASS: $PASS${C_RESET}  ${C_FAIL}FAIL: $FAIL${C_RESET}  ${C_DIM}SKIP: $SKIP${C_RESET}\n\n"

if [[ "$FAIL" -gt 0 ]]; then
  printf "${C_WARN}To fix FAIL: recapture fixtures with a live RPC to generate logs files, then restart offline-anvil containers:${C_RESET}\n"
  printf "  ANVIL_CAPTURE_USE_LATEST_BLOCK=true bash scripts/capture-anvil-state.sh\n"
  printf "  docker compose --profile offline-anvil up -d --force-recreate\n\n"
  exit 1
fi
exit 0
