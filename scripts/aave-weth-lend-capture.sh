#!/usr/bin/env bash
# aave-weth-lend-capture.sh
#
# Against the offline Ethereum Anvil (port 8545):
#   1. Wraps ETH → WETH
#   2. Supplies WETH to Aave V3 Pool (lend position opened)
#   3. Captures pre-supply state snapshot
#   4. Mines 5 blocks, advancing 1 day per block (5 days of interest accrual)
#   5. Reports position delta (aToken balance growth, accrued interest)
#
# Usage:
#   bash scripts/aave-weth-lend-capture.sh [--start-docker] [--supply-eth N]
#
# Options:
#   --start-docker   Run docker compose up -d before starting (default: skip)
#   --supply-eth N   Amount of ETH to wrap and supply (default: 10)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RPC="${ANVIL_ETH_RPC:-http://127.0.0.1:8545}"
POOL="0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2"
WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
ACCOUNT="0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
PRIVKEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
SUPPLY_ETH="10"
START_DOCKER=false
BLOCKS=5
SECS_PER_BLOCK=86400  # 1 day per mined block — makes interest accrual visible


for arg in "$@"; do
  case "$arg" in
    --start-docker) START_DOCKER=true ;;
    --supply-eth)   shift; SUPPLY_ETH="$1" ;;
  esac
done

SUPPLY_WEI="$(python3 -c "print(int('$SUPPLY_ETH') * 10**18)")"

# ── Colors ────────────────────────────────────────────────────────────────────
C_BOLD='\033[1m'; C_DIM='\033[2m'; C_OK='\033[32m'; C_CYAN='\033[36m'
C_YELLOW='\033[33m'; C_RESET='\033[0m'

hdr()  { printf "\n${C_BOLD}=== %s ===${C_RESET}\n" "$1"; }
step() { printf "\n${C_CYAN}==> %s${C_RESET}\n" "$1"; }
info() { printf "  ${C_DIM}%s${C_RESET}\n" "$1"; }
ok()   { printf "  ${C_OK}%s${C_RESET}\n" "$1"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

fmt_weth() {
  python3 -c "
v = '$1'.split('[')[0].strip()
n = int(v, 16) if v.startswith('0x') else int(v)
print(f'{n/1e18:.8f} WETH')
" 2>/dev/null || echo "?"
}

fmt_usd8() {
  python3 -c "
v = '$1'.split('[')[0].strip()
n = int(v, 16) if v.startswith('0x') else int(v)
print(f'\${n/1e8:,.4f}')
" 2>/dev/null || echo "?"
}

fmt_ray_pct() {
  python3 -c "
v = '$1'.split('[')[0].strip()
n = int(v, 16) if v.startswith('0x') else int(v)
print(f'{n/1e27*100:.6f}%')
" 2>/dev/null || echo "?"
}

fmt_ts() {
  python3 -c "
import datetime
v = '$1'
n = int(v, 16) if v.startswith('0x') else int(v)
print(datetime.datetime.utcfromtimestamp(n).strftime('%Y-%m-%d %H:%M UTC'))
" 2>/dev/null || echo "?"
}

cast_call() { cast call --rpc-url "$RPC" "$@" 2>/dev/null || true; }

tx_summary() {
  python3 -c "
import json, sys
r = json.load(sys.stdin)
gas = int(r.get('gasUsed','0x0'), 16)
h = r.get('transactionHash', r.get('hash','?'))
print(f'  tx={h}  gasUsed={gas}')
" 2>/dev/null
}

# ── Start docker (optional) ───────────────────────────────────────────────────

if [[ "$START_DOCKER" == true ]]; then
  step "Starting offline Ethereum Anvil container"
  docker compose up -d anvil-ethereum
  for i in $(seq 1 60); do
    cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 1
  done
fi

# ── Connectivity check ────────────────────────────────────────────────────────


chain_id="$(cast chain-id --rpc-url "$RPC" 2>/dev/null || echo '')"
if [[ "$chain_id" != "1" ]]; then
  printf 'ERROR: expected Ethereum (chain 1) at %s, got "%s"\n' "$RPC" "$chain_id" >&2
  exit 1
fi

# ── Discover aWETH from pool ──────────────────────────────────────────────────

rd_init="$(cast_call "$POOL" \
  'getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)' \
  "$WETH")"
AWETH="$(awk 'NR==9{print $1}' <<<"$rd_init")"
LIQ_RATE_PRE="$(awk 'NR==3{print $1}' <<<"$rd_init")"
LIQ_INDEX_PRE="$(awk 'NR==2{print $1}' <<<"$rd_init")"
LAST_UPDATE_PRE="$(awk 'NR==7{print $1}' <<<"$rd_init")"

# ── [0] Pre-supply state ──────────────────────────────────────────────────────

hdr "[0] Pre-supply state  block=$(cast block-number --rpc-url "$RPC")"

ud_pre="$(cast_call "$POOL" \
  'getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)' \
  "$ACCOUNT")"
collateral_pre="$(awk 'NR==1{print $1}' <<<"$ud_pre")"

info "aWETH token address : $AWETH"
info "WETH supply APR     : $(fmt_ray_pct "$LIQ_RATE_PRE")"
info "liquidity index     : $LIQ_INDEX_PRE"
info "last update ts      : $(fmt_ts "$LAST_UPDATE_PRE")"
info "account collateral  : $(fmt_usd8 "$collateral_pre")"

# ── [1] Wrap ETH → WETH ───────────────────────────────────────────────────────

step "Wrapping ${SUPPLY_ETH} ETH → WETH"
cast send --rpc-url "$RPC" --private-key "$PRIVKEY" \
  "$WETH" 'deposit()' --value "${SUPPLY_ETH}ether" --json | tx_summary
weth_bal="$(cast_call "$WETH" 'balanceOf(address)(uint256)' "$ACCOUNT" | tr -d ' ')"
info "WETH balance after wrap: $(fmt_weth "${weth_bal%%\[*}")"

# ── [2] Approve ───────────────────────────────────────────────────────────────

step "Approving ${SUPPLY_ETH} WETH to Aave Pool"
cast send --rpc-url "$RPC" --private-key "$PRIVKEY" \
  "$WETH" 'approve(address,uint256)' "$POOL" "$SUPPLY_WEI" --json | tx_summary

# ── [3] Supply WETH to Aave ───────────────────────────────────────────────────

step "Supplying ${SUPPLY_ETH} WETH to Aave V3 Pool"
cast send --rpc-url "$RPC" --private-key "$PRIVKEY" \
  "$POOL" 'supply(address,uint256,address,uint16)' \
  "$WETH" "$SUPPLY_WEI" "$ACCOUNT" 0 --json | tx_summary

# ── [4] Post-supply snapshot ──────────────────────────────────────────────────

hdr "[1] Post-supply snapshot  block=$(cast block-number --rpc-url "$RPC")"

AWETH_BAL_0="$(cast_call "$AWETH" 'balanceOf(address)(uint256)' "$ACCOUNT" | awk '{print $1}')"
AWETH_SCALED_0="$(cast_call "$AWETH" 'scaledBalanceOf(address)(uint256)' "$ACCOUNT" | awk '{print $1}')"
ud_0="$(cast_call "$POOL" \
  'getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)' \
  "$ACCOUNT")"
collateral_0="$(awk 'NR==1{print $1}' <<<"$ud_0")"
rd_0="$(cast_call "$POOL" \
  'getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)' \
  "$WETH")"
LIQ_INDEX_0="$(awk 'NR==2{print $1}' <<<"$rd_0")"
LAST_UPDATE_0="$(awk 'NR==7{print $1}' <<<"$rd_0")"

ok "aWETH balanceOf       : $(fmt_weth "${AWETH_BAL_0%%\[*}")"
ok "aWETH scaledBalanceOf : $(fmt_weth "${AWETH_SCALED_0%%\[*}")"
info "account collateral   : $(fmt_usd8 "$collateral_0")"
info "liquidity index      : $LIQ_INDEX_0"
info "last update ts       : $(fmt_ts "$LAST_UPDATE_0")"

# ── [5] Mine 5 blocks, 1 day each ────────────────────────────────────────────

step "Mining $BLOCKS blocks  (${SECS_PER_BLOCK}s / block = $((BLOCKS * SECS_PER_BLOCK / 86400)) days)"
printf '\n'
for i in $(seq 1 "$BLOCKS"); do
  cast rpc --rpc-url "$RPC" evm_increaseTime "$SECS_PER_BLOCK" >/dev/null
  cast rpc --rpc-url "$RPC" evm_mine >/dev/null
  blk="$(cast block-number --rpc-url "$RPC")"
  blk_hex="$(printf '0x%x' "$blk")"
  ts_hex="$(cast rpc --rpc-url "$RPC" eth_getBlockByNumber "$blk_hex" false 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('timestamp','0x0'))")"
  printf "  block #%d  ts=%s\n" "$blk" "$(fmt_ts "$ts_hex")"
done

# ── [6] Post-mining snapshot ──────────────────────────────────────────────────

hdr "[2] Post-${BLOCKS}-blocks snapshot  block=$(cast block-number --rpc-url "$RPC")"

AWETH_BAL_5="$(cast_call "$AWETH" 'balanceOf(address)(uint256)' "$ACCOUNT" | awk '{print $1}')"
AWETH_SCALED_5="$(cast_call "$AWETH" 'scaledBalanceOf(address)(uint256)' "$ACCOUNT" | awk '{print $1}')"
ud_5="$(cast_call "$POOL" \
  'getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)' \
  "$ACCOUNT")"
collateral_5="$(awk 'NR==1{print $1}' <<<"$ud_5")"
rd_5="$(cast_call "$POOL" \
  'getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)' \
  "$WETH")"
LIQ_INDEX_5="$(awk 'NR==2{print $1}' <<<"$rd_5")"
LAST_UPDATE_5="$(awk 'NR==7{print $1}' <<<"$rd_5")"
LIQ_RATE_5="$(awk 'NR==3{print $1}' <<<"$rd_5")"

ok "aWETH balanceOf       : $(fmt_weth "${AWETH_BAL_5%%\[*}")"
ok "aWETH scaledBalanceOf : $(fmt_weth "${AWETH_SCALED_5%%\[*}")"
info "account collateral   : $(fmt_usd8 "$collateral_5")"
info "liquidity index      : $LIQ_INDEX_5"
info "last update ts       : $(fmt_ts "$LAST_UPDATE_5")"
info "WETH supply APR      : $(fmt_ray_pct "$LIQ_RATE_5")"

# ── [7] Position delta ────────────────────────────────────────────────────────

hdr "[3] Position delta  ($BLOCKS days of interest accrual)"

python3 - <<PY
bal0    = int('${AWETH_BAL_0%%\[*}'.split('[')[0].strip())
bal5    = int('${AWETH_BAL_5%%\[*}'.split('[')[0].strip())
sc0     = int('${AWETH_SCALED_0%%\[*}'.split('[')[0].strip())
sc5     = int('${AWETH_SCALED_5%%\[*}'.split('[')[0].strip())
idx0    = int('${LIQ_INDEX_0}'.split('[')[0].strip())
idx5    = int('${LIQ_INDEX_5}'.split('[')[0].strip())
supply  = ${SUPPLY_WEI}
days    = ${BLOCKS}

delta      = bal5 - bal0
apr_obs    = (delta / supply) * (365 / days) * 100 if days > 0 else 0
idx_growth = (idx5 - idx0) / 1e27 * 100

print(f"  supplied WETH          : {supply/1e18:.8f} WETH")
print(f"  aWETH balance before   : {bal0/1e18:.8f} WETH")
print(f"  aWETH balance after    : {bal5/1e18:.8f} WETH")
print(f"  interest earned ({days}d)  : {delta/1e18:.8f} WETH  ({delta/1e9:.3f} gwei)")
print(f"  observed APR (annualised): {apr_obs:.6f}%")
print(f"  liquidity index growth   : {idx_growth:.8f}%")
print(f"  scaledBalance unchanged  : {sc0 == sc5}  ({sc5 - sc0:+d} units)")
PY

printf '\n'
