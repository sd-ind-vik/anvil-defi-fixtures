#!/usr/bin/env bash
# ingest-offline.sh
#
# Boots 4 offline Anvil nodes and continuously ingests blocks, Aave positions,
# and prices from each chain, printing every event to the console.
#
# Usage:
#   bash scripts/ingest-offline.sh [--no-docker]  [--mine-interval SECS]
#
# Flags:
#   --no-docker      Skip starting Docker containers (assume anvils already up)
#   --mine-interval  Seconds between synthetic block mines (default: 3)
#
# Requires: cast, jq, docker (unless --no-docker)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ── Config ────────────────────────────────────────────────────────────────────

MINE_INTERVAL="${MINE_INTERVAL:-3}"
START_DOCKER=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-docker)     START_DOCKER=false ;;
    --mine-interval) shift; MINE_INTERVAL="$1" ;;
    *) ;;
  esac
  shift
done

AAVE_ACCOUNTS="${AAVE_ACCOUNTS:-0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266}"

# Chain definitions: "chain_id:name:rpc:pool:data_provider:oracle:reserves"
# data_provider may be empty (optimism has no DP in this config)
CHAINS=(
  "1|ethereum|http://127.0.0.1:18545|0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2|0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3|0x54586bE62E3c3580375aE3723C145253060Ca0C2|0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599,0x6B175474E89094C44Da98b954EedeAC495271d0F"
  "8453|base|http://127.0.0.1:18546|0xA238Dd80C259a72e81d7e4664a9801593F98d1c5|0x0F43731EB8d45A581f4a36DD74F5f358bc90C73A|0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156|0x4200000000000000000000000000000000000006,0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA"
  "42161|arbitrum|http://127.0.0.1:18547|0x794a61358D6845594F94dc1DB02A252b5b4814aD|0x243Aa95cAC2a25651eda86e80bEe66114413c43b|0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7|0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,0xaf88d065e77c8cC2239327C5EDb3A432268e5831,0x912CE59144191C1204E64559FE8253a0e49E6548"
  "10|optimism|http://127.0.0.1:18548|0x794a61358D6845594F94dc1DB02A252b5b4814aD||0xD81eb3728a631871a7eBBaD631b5f424909f0c77|0x4200000000000000000000000000000000000006,0x7F5c764cBc14f9669B88837ca1490cCa17c31607,0x4200000000000000000000000000000000000042"
)

# Token symbols for pretty-printing
declare -A SYMBOLS=(
  ["0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"]="USDC"
  ["0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"]="WETH"
  ["0x2260fac5e5542a773aa44fbcfedf7c193bc2c599"]="WBTC"
  ["0x6b175474e89094c44da98b954eedeac495271d0f"]="DAI"
  ["0x4200000000000000000000000000000000000006"]="WETH"
  ["0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"]="USDC"
  ["0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca"]="USDbC"
  ["0x82af49447d8a07e3bd95bd0d56f35241523fbab1"]="WETH"
  ["0xaf88d065e77c8cc2239327c5edb3a432268e5831"]="USDC"
  ["0x912ce59144191c1204e64559fe8253a0e49e6548"]="ARB"
  ["0x7f5c764cbc14f9669b88837ca1490cca17c31607"]="USDC.e"
  ["0x4200000000000000000000000000000000000042"]="OP"
)

# ── Colours ───────────────────────────────────────────────────────────────────

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_BLOCK='\033[36m'     # cyan   — block events
C_PRICE='\033[33m'     # yellow — price / reserve data
C_POS='\033[35m'       # magenta — positions
C_OK='\033[32m'        # green
C_WARN='\033[31m'      # red

ts()  { date '+%H:%M:%S'; }
sym() { local k; k="$(tr '[:upper:]' '[:lower:]' <<<"$1")"; echo "${SYMBOLS[$k]:-${1:0:8}..}"; }

log_block()  { printf "${C_BLOCK}${C_BOLD}[%s][%s]${C_RESET} ${C_BLOCK}BLOCK${C_RESET}  %s\n" "$(ts)" "$1" "$2"; }
log_price()  { printf "${C_PRICE}[%s][%s]${C_RESET} PRICE  %s\n"    "$(ts)" "$1" "$2"; }
log_pos()    { printf "${C_POS}[%s][%s]${C_RESET} POSIT  %s\n"      "$(ts)" "$1" "$2"; }
log_rsv()    { printf "${C_PRICE}${C_DIM}[%s][%s]${C_RESET} RESRV  %s\n"    "$(ts)" "$1" "$2"; }
log_info()   { printf "${C_OK}[%s] %s${C_RESET}\n"                  "$(ts)" "$1"; }
log_warn()   { printf "${C_WARN}[%s] WARN: %s${C_RESET}\n"          "$(ts)" "$1" >&2; }

# ── Docker helpers ────────────────────────────────────────────────────────────

DOCKER_PIDS=()
cleanup() {
  printf '\n'
  log_info "Shutting down..."
  [[ "$START_DOCKER" == true ]] && \
    docker compose stop \
      anvil-ethereum anvil-base anvil-arbitrum anvil-optimism \
      >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

start_anvils() {
  log_info "Starting offline Anvil containers..."
  docker compose up -d \
    anvil-ethereum anvil-base anvil-arbitrum anvil-optimism \
    >/dev/null 2>&1
}

wait_for_rpc() {
  local rpc="$1" name="$2"
  for i in $(seq 1 60); do
    cast chain-id --rpc-url "$rpc" >/dev/null 2>&1 && return 0
    sleep 1
  done
  log_warn "$name RPC not ready at $rpc after 60s"
  return 1
}

# ── Math helpers (no bc needed) ───────────────────────────────────────────────

# Convert a hex or decimal uint256 to a float divided by 10^N
scale_down() {
  local val="$1" decimals="$2"
  # strip 0x if present, convert to decimal via python
  python3 -c "
v = int('$val', 16) if '$val'.startswith('0x') else int('$val')
d = $decimals
if v == 0:
    print('0')
elif d <= 0:
    print(str(v))
else:
    s = str(v).zfill(d+1)
    integer = s[:-d] or '0'
    fraction = s[-d:].rstrip('0') or '0'
    print(f'{integer}.{fraction}')
" 2>/dev/null || echo "?"
}

ray_to_pct() {
  # 1 RAY = 10^27; multiply by 100 for percentage
  python3 -c "
v = int('$1', 16) if '$1'.startswith('0x') else int('$1' or '0')
print(f'{v / 1e27 * 100:.4f}%')
" 2>/dev/null || echo "?"
}

price_8dec() {
  python3 -c "
v = int('$1', 16) if '$1'.startswith('0x') else int('$1' or '0')
print(f'\${v / 1e8:,.2f}')
" 2>/dev/null || echo "?"
}

hf_display() {
  python3 -c "
import sys
MAX = 2**256 - 1
v = int('$1', 16) if '$1'.startswith('0x') else int('$1' or '0')
if v >= MAX // 2:
    print('∞ (no debt)')
else:
    print(f'{v / 1e18:.4f}')
" 2>/dev/null || echo "?"
}

usd_18dec() {
  python3 -c "
v = int('$1', 16) if '$1'.startswith('0x') else int('$1' or '0')
# Aave account data base currency = USD with 8 decimals
print(f'\${v / 1e8:,.2f}')
" 2>/dev/null || echo "?"
}

# ── Per-chain ingestion ───────────────────────────────────────────────────────

# Associative array tracking last seen block per chain
declare -A LAST_BLOCK=()

ingest_chain() {
  local entry="$1"
  IFS='|' read -r chain_id name rpc pool dp oracle reserves_csv <<<"$entry"
  IFS=',' read -ra reserves <<<"$reserves_csv"

  # ── Block ──────────────────────────────────────────────────────────────────
  local block_hex block_num
  block_hex="$(cast rpc --rpc-url "$rpc" eth_blockNumber 2>/dev/null || echo '')"
  block_hex="${block_hex//\"/}"   # strip JSON quotes: "0x1a2b" → 0x1a2b
  block_num="$(python3 -c "print(int('${block_hex:-0x0}',16))" 2>/dev/null || echo 0)"
  local last="${LAST_BLOCK[$chain_id]:-}"
  [[ "$block_num" == "$last" ]] && return 0   # no new block yet
  LAST_BLOCK[$chain_id]="$block_num"

  # Block header
  local blk_json
  blk_json="$(cast rpc --rpc-url "$rpc" eth_getBlockByNumber "$block_hex" false 2>/dev/null || echo '{}')"
  local base_fee gas_used ts_hex ts
  base_fee="$(jq -r '.baseFeePerGas // "0x0"' <<<"$blk_json")"
  gas_used="$(jq -r '.gasUsed       // "0x0"' <<<"$blk_json")"
  ts_hex="$(  jq -r '.timestamp     // "0x0"' <<<"$blk_json")"
  ts="$(python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp(int('${ts_hex:-0x0}',16)).strftime('%Y-%m-%d %H:%M:%S UTC'))" 2>/dev/null || echo '')"
  base_fee_gwei="$(python3 -c "print(f\"{int('${base_fee:-0x0}',16)/1e9:.3f} gwei\")" 2>/dev/null || echo '?')"

  log_block "$name" "#${block_num}  ts=${ts}  baseFee=${base_fee_gwei}  gasUsed=$(python3 -c "print(int('${gas_used:-0x0}',16))" 2>/dev/null)"

  # ── Oracle prices ──────────────────────────────────────────────────────────
  [[ -n "$oracle" ]] && for asset in "${reserves[@]}"; do
    local price_raw
    price_raw="$(cast call --rpc-url "$rpc" "$oracle" \
      'getAssetPrice(address)(uint256)' "$asset" 2>/dev/null | awk '{print $1}' || echo '')"
    [[ -z "$price_raw" ]] && continue
    log_price "$name" "$(sym "$asset") = $(price_8dec "$price_raw")"
  done

  # ── Reserve data (rates) ───────────────────────────────────────────────────
  for asset in "${reserves[@]}"; do
    local rd
    rd="$(cast call --rpc-url "$rpc" "$pool" \
      'getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)' \
      "$asset" 2>/dev/null || echo '')"
    [[ -z "$rd" ]] && continue
    local liq_rate var_rate
    liq_rate="$(awk 'NR==3{print $1}' <<<"$rd")"
    var_rate="$(awk 'NR==5{print $1}' <<<"$rd")"
    log_rsv "$name" "$(sym "$asset")  supplyAPR=$(ray_to_pct "$liq_rate")  varBorrowAPR=$(ray_to_pct "$var_rate")"
  done

  # ── Positions (getUserAccountData) ─────────────────────────────────────────
  IFS=',' read -ra accounts <<<"$AAVE_ACCOUNTS"
  for acct in "${accounts[@]}"; do
    [[ -z "$acct" ]] && continue
    local ud
    ud="$(cast call --rpc-url "$rpc" "$pool" \
      'getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)' \
      "$acct" 2>/dev/null || echo '')"
    [[ -z "$ud" ]] && continue
    local collateral debt hf
    collateral="$(awk 'NR==1{print $1}' <<<"$ud")"
    debt="$(      awk 'NR==2{print $1}' <<<"$ud")"
    hf="$(        awk 'NR==6{print $1}' <<<"$ud")"
    log_pos "$name" "${acct:0:10}..  collateral=$(usd_18dec "$collateral")  debt=$(usd_18dec "$debt")  HF=$(hf_display "$hf")"
  done
}

# ── Miner loop (runs in background, mines blocks on all chains) ───────────────

miner_loop() {
  local rpcs=("http://127.0.0.1:18545" "http://127.0.0.1:18546" "http://127.0.0.1:18547" "http://127.0.0.1:18548")
  while true; do
    sleep "$MINE_INTERVAL"
    for rpc in "${rpcs[@]}"; do
      cast rpc --rpc-url "$rpc" evm_mine >/dev/null 2>&1 || true
    done
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────

printf "${C_BOLD}anvil-defi-fixtures offline ingestor${C_RESET}  mine_interval=${MINE_INTERVAL}s  accounts=${AAVE_ACCOUNTS}\n\n"

if [[ "$START_DOCKER" == true ]]; then
  start_anvils
fi

log_info "Waiting for offline Anvil RPCs..."
for entry in "${CHAINS[@]}"; do
  IFS='|' read -r chain_id name rpc _rest <<<"$entry"
  wait_for_rpc "$rpc" "$name"
  log_info "$name  chain_id=$chain_id  block=$(cast block-number --rpc-url "$rpc" 2>/dev/null)"
done

log_info "Starting miner (every ${MINE_INTERVAL}s)..."
miner_loop &
MINER_PID=$!

log_info "Ingesting — Ctrl-C to stop\n"

# ── Poll loop ─────────────────────────────────────────────────────────────────
while true; do
  for entry in "${CHAINS[@]}"; do
    ingest_chain "$entry" || true
  done
  sleep 1
done
