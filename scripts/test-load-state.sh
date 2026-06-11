#!/usr/bin/env bash
# test-load-state.sh
#
# Builds the Docker image, starts all 4 offline Anvil nodes in load-state mode
# (self-contained full JSON, no shim or tar.gz), and runs a comprehensive
# suite of protocol calls verifying Aave V3, Uniswap V3, Multicall3, and ERC20
# reads all resolve correctly from the embedded state.
#
# Usage:
#   bash scripts/test-load-state.sh [--skip-build] [--keep]
#
# Options:
#   --skip-build   Reuse existing Docker image (skip docker build)
#   --keep         Leave containers running after the suite finishes
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_BUILD=false
KEEP=false
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    --keep)       KEEP=true ;;
  esac
done

# ── Colours ───────────────────────────────────────────────────────────────────

C_OK='\033[32m'
C_FAIL='\033[31m'
C_WARN='\033[33m'
C_DIM='\033[2m'
C_BOLD='\033[1m'
C_RESET='\033[0m'

PASS=0
FAIL=0
SKIP=0

ok()   { printf "${C_OK}  [PASS]${C_RESET} %s\n"     "$1"; ((PASS++))  || true; }
fail() { printf "${C_FAIL}  [FAIL]${C_RESET} %s\n"   "$1" >&2; ((FAIL++)) || true; }
skip() { printf "${C_DIM}  [SKIP]${C_RESET} %s\n"    "$1"; ((SKIP++))  || true; }
info() { printf "         %s\n" "$1"; }
hdr()  { printf "\n${C_DIM}--- %s ---${C_RESET}\n" "$1"; }

# ── Chain definitions ─────────────────────────────────────────────────────────
# "chain_id|name|rpc|pool|data_provider|oracle|reserves_csv|uni_pool"
# data_provider may be empty (optimism has none in this config)
CHAINS=(
  "1|ethereum|http://127.0.0.1:8545\
|0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2\
|0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3\
|0x54586bE62E3c3580375aE3723C145253060Ca0C2\
|0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599,0x6B175474E89094C44Da98b954EedeAC495271d0F\
|0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"

  "8453|base|http://127.0.0.1:8546\
|0xA238Dd80C259a72e81d7e4664a9801593F98d1c5\
|0x0F43731EB8d45A581f4a36DD74F5f358bc90C73A\
|0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156\
|0x4200000000000000000000000000000000000006,0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA\
|0x4C36388bE6F416A29C8d8Eee81C771cE6bE14B18"

  "42161|arbitrum|http://127.0.0.1:8547\
|0x794a61358D6845594F94dc1DB02A252b5b4814aD\
|0x243Aa95cAC2a25651eda86e80bEe66114413c43b\
|0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7\
|0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,0xaf88d065e77c8cC2239327C5EDb3A432268e5831,0x912CE59144191C1204E64559FE8253a0e49E6548\
|0xC31E54c7a869B9FcBEcc14363CF510d1c41FA443"

  "10|optimism|http://127.0.0.1:8548\
|0x794a61358D6845594F94dc1DB02A252b5b4814aD\
|0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654\
|0xD81eb3728a631871a7eBBaD631b5f424909f0c77\
|0x4200000000000000000000000000000000000006,0x7F5c764cBc14f9669B88837ca1490cCa17c31607,0x4200000000000000000000000000000000000042\
|0x85149247691df622eaF1a8Bd0CaFd40BC45154a9"
)

MULTICALL3="0xcA11bde05977b3631167028862bE2a173976CA11"
PROBE_ACCOUNT="0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

# ── Helpers ───────────────────────────────────────────────────────────────────

nonzero_hex() {
  # Return 0 if the value is a non-zero number (hex or decimal).
  # Strips cast's [N.Ne+X] annotation suffix before parsing.
  local v="${1:-0}"
  python3 -c "
v = '$v'.split('[')[0].strip()
if not v or v in ('0x', '0', ''):
    exit(1)
try:
    n = int(v, 16) if v.startswith('0x') else int(v)
    exit(0 if n > 0 else 1)
except Exception:
    exit(1)
" 2>/dev/null
}

nonzero_addr() {
  # Return 0 if the value looks like a non-zero address
  local v="${1:-0x0000000000000000000000000000000000000000}"
  v="${v//\"/}"
  [[ "${#v}" -ge 42 ]] && [[ "$v" != "0x0000000000000000000000000000000000000000" ]]
}

cast_call() {
  cast call --rpc-url "$1" "$2" "$3" "${@:4}" 2>/dev/null || true
}

# ── Docker lifecycle ──────────────────────────────────────────────────────────

cleanup() {
  if [[ "$KEEP" == false ]]; then
    printf '\n==> Stopping load-state containers\n'
    docker compose \
      down --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ── 1. Build ──────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == false ]]; then
  printf '\n==> Building Docker image\n'
  docker compose build
fi

# ── 2. Start containers in load-state mode ────────────────────────────────────

printf '\n==> Starting containers (ANVIL_OFFLINE_MODE=load-state)\n'
docker compose up -d

# ── 3. Wait for all 4 RPCs ────────────────────────────────────────────────────

printf '\n==> Waiting for RPC readiness\n'
for entry in "${CHAINS[@]}"; do
  IFS='|' read -r _ name rpc _ _ _ _ _ <<<"$entry"
  printf '  %s (%s)...' "$name" "$rpc"
  ready=false
  for i in $(seq 1 90); do
    if cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; then
      ready=true; break
    fi
    sleep 1
  done
  if [[ "$ready" == true ]]; then
    block="$(cast block-number --rpc-url "$rpc" 2>/dev/null || echo '?')"
    printf ' ready  block=%s\n' "$block"
  else
    printf ' TIMEOUT\n'
    docker compose \
      logs --tail 40 "anvil-$name" || true
    exit 1
  fi
done

# ── 4. Test suite ─────────────────────────────────────────────────────────────

printf "\n${C_BOLD}=== load-state protocol test suite ===${C_RESET}\n"

for entry in "${CHAINS[@]}"; do
  IFS='|' read -r chain_id name rpc pool dp oracle reserves_csv uni_pool <<<"$entry"
  IFS=',' read -ra reserves <<<"$reserves_csv"

  printf "\n${C_BOLD}[$name / chain $chain_id]${C_RESET}\n"

  # ── Basic connectivity ──────────────────────────────────────────────────────
  hdr "Basic connectivity"

  actual_chain_id="$(cast chain-id --rpc-url "$rpc" 2>/dev/null || echo '')"
  if [[ "$actual_chain_id" == "$chain_id" ]]; then
    ok "$name: eth_chainId = $chain_id"
  else
    fail "$name: eth_chainId expected $chain_id, got '${actual_chain_id}'"
  fi

  block_num="$(cast block-number --rpc-url "$rpc" 2>/dev/null || echo '')"
  if [[ "$block_num" =~ ^[0-9]+$ ]] && [[ "$block_num" -gt 0 ]]; then
    ok "$name: eth_blockNumber = $block_num"
  else
    fail "$name: eth_blockNumber returned '${block_num}'"
  fi

  blk_hex="$(printf '0x%x' "${block_num:-0}")"
  blk_json="$(cast rpc --rpc-url "$rpc" eth_getBlockByNumber "$blk_hex" false 2>/dev/null || echo '{}')"
  ts_hex="$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('timestamp','0x0'))" <<<"$blk_json" 2>/dev/null || echo '')"
  if nonzero_hex "${ts_hex:-0x0}"; then
    ok "$name: eth_getBlockByNumber has valid timestamp"
  else
    fail "$name: eth_getBlockByNumber missing/zero timestamp (block $block_num)"
  fi

  # ── Multicall3 ──────────────────────────────────────────────────────────────
  hdr "Multicall3 ($MULTICALL3)"

  mc_bal="$(cast_call "$rpc" "$MULTICALL3" 'getEthBalance(address)(uint256)' "$PROBE_ACCOUNT")"
  mc_bal="${mc_bal// /}"
  if [[ -n "$mc_bal" ]] && [[ "$mc_bal" != "0" || "$mc_bal" == "0" ]]; then
    ok "$name: Multicall3.getEthBalance → $mc_bal"
  else
    fail "$name: Multicall3.getEthBalance failed (got '${mc_bal}')"
  fi

  # ── Aave V3 Oracle ──────────────────────────────────────────────────────────
  hdr "Aave Oracle ($oracle)"

  oracle_code="$(cast code --rpc-url "$rpc" "$oracle" 2>/dev/null || echo '0x')"
  if [[ "${#oracle_code}" -gt 4 ]]; then
    ok "$name: Aave Oracle has bytecode (${#oracle_code} chars)"
  else
    fail "$name: Aave Oracle has no bytecode at $oracle"
  fi

  for asset in "${reserves[@]}"; do
    price="$(cast_call "$rpc" "$oracle" 'getAssetPrice(address)(uint256)' "$asset")"
    price="${price// /}"
    if nonzero_hex "${price:-0x0}"; then
      ok "$name: Oracle.getAssetPrice(${asset:0:10}..) = $price"
    else
      fail "$name: Oracle.getAssetPrice(${asset:0:10}..) returned '${price}'"
    fi
  done

  # ── Aave V3 Pool ────────────────────────────────────────────────────────────
  hdr "Aave Pool ($pool)"

  pool_code="$(cast code --rpc-url "$rpc" "$pool" 2>/dev/null || echo '0x')"
  if [[ "${#pool_code}" -gt 4 ]]; then
    ok "$name: Aave Pool has bytecode (${#pool_code} chars)"
  else
    fail "$name: Aave Pool has no bytecode at $pool"
  fi

  first_atoken=""
  for asset in "${reserves[@]}"; do
    rd="$(cast_call "$rpc" "$pool" \
      'getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)' \
      "$asset")"
    if [[ -z "$rd" ]]; then
      fail "$name: Pool.getReserveData(${asset:0:10}..) returned empty"
      continue
    fi
    # aToken is the 9th field (NR==9 in the multi-line cast output)
    atoken="$(awk 'NR==9{print $1}' <<<"$rd")"
    liq_rate="$(awk 'NR==3{print $1}' <<<"$rd")"
    var_rate="$(awk 'NR==5{print $1}' <<<"$rd")"
    if nonzero_addr "${atoken:-}"; then
      ok "$name: Pool.getReserveData(${asset:0:10}..)  aToken=${atoken:0:10}..  liqRate=$liq_rate"
      [[ -z "$first_atoken" ]] && first_atoken="$atoken"
    else
      fail "$name: Pool.getReserveData(${asset:0:10}..) returned zero aToken (got '${atoken}')"
    fi
  done

  ud="$(cast_call "$rpc" "$pool" \
    'getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)' \
    "$PROBE_ACCOUNT")"
  if [[ -n "$ud" ]]; then
    hf="$(awk 'NR==6{print $1}' <<<"$ud")"
    ok "$name: Pool.getUserAccountData  HF=$hf"
  else
    fail "$name: Pool.getUserAccountData returned empty"
  fi

  # ── Aave DataProvider ───────────────────────────────────────────────────────
  if [[ -n "$dp" ]]; then
    hdr "Aave DataProvider ($dp)"

    dp_code="$(cast code --rpc-url "$rpc" "$dp" 2>/dev/null || echo '0x')"
    if [[ "${#dp_code}" -gt 4 ]]; then
      ok "$name: DataProvider has bytecode"
    else
      fail "$name: DataProvider has no bytecode at $dp"
    fi

    for asset in "${reserves[@]}"; do
      cfg="$(cast_call "$rpc" "$dp" \
        'getReserveConfigurationData(address)(uint256,uint256,uint256,uint256,uint256,bool,bool,bool,bool,bool)' \
        "$asset")"
      ltv="$(awk 'NR==1{print $1}' <<<"$cfg")"
      if [[ -n "$ltv" ]]; then
        ok "$name: DataProvider.getReserveConfigurationData(${asset:0:10}..)  ltv=$ltv"
      else
        fail "$name: DataProvider.getReserveConfigurationData(${asset:0:10}..) returned empty"
      fi

      caps="$(cast_call "$rpc" "$dp" 'getReserveCaps(address)(uint256,uint256)' "$asset")"
      if [[ -n "$caps" ]]; then
        ok "$name: DataProvider.getReserveCaps(${asset:0:10}..)"
      else
        fail "$name: DataProvider.getReserveCaps(${asset:0:10}..) returned empty"
      fi
    done
  else
    skip "$name: DataProvider not configured, skipping DataProvider tests"
  fi

  # ── aToken ──────────────────────────────────────────────────────────────────
  if [[ -n "$first_atoken" ]]; then
    hdr "aToken (${first_atoken:0:10}..)"

    atoken_code="$(cast code --rpc-url "$rpc" "$first_atoken" 2>/dev/null || echo '0x')"
    if [[ "${#atoken_code}" -gt 4 ]]; then
      ok "$name: aToken has bytecode"
    else
      fail "$name: aToken has no bytecode at $first_atoken"
    fi

    sts="$(cast_call "$rpc" "$first_atoken" 'scaledTotalSupply()(uint256)')"
    sts="${sts// /}"
    if [[ -n "$sts" ]]; then
      ok "$name: aToken.scaledTotalSupply = $sts"
    else
      fail "$name: aToken.scaledTotalSupply returned empty"
    fi

    atoken_pool="$(cast_call "$rpc" "$first_atoken" 'POOL()(address)')"
    atoken_pool="${atoken_pool// /}"
    if [[ "${atoken_pool,,}" == "${pool,,}" ]]; then
      ok "$name: aToken.POOL() matches Aave pool address"
    else
      fail "$name: aToken.POOL() = '${atoken_pool}' (expected ${pool})"
    fi

    underlying="$(cast_call "$rpc" "$first_atoken" 'UNDERLYING_ASSET_ADDRESS()(address)')"
    underlying="${underlying// /}"
    if nonzero_addr "${underlying:-}"; then
      ok "$name: aToken.UNDERLYING_ASSET_ADDRESS = ${underlying:0:10}.."
    else
      fail "$name: aToken.UNDERLYING_ASSET_ADDRESS returned '${underlying}'"
    fi
  fi

  # ── ERC20 metadata on reserves ──────────────────────────────────────────────
  hdr "ERC20 metadata (key reserves)"

  for asset in "${reserves[@]}"; do
    sym="$(cast_call "$rpc" "$asset" 'symbol()(string)')"
    dec="$(cast_call "$rpc" "$asset" 'decimals()(uint8)')"
    sym="${sym// /}"
    dec="${dec// /}"
    if [[ -n "$sym" && -n "$dec" ]]; then
      ok "$name: ${asset:0:10}..  symbol=$sym  decimals=$dec"
    else
      fail "$name: ERC20 metadata on ${asset:0:10}.. — sym='$sym' dec='$dec'"
    fi
  done

  # ── Uniswap V3 Pool ─────────────────────────────────────────────────────────
  hdr "Uniswap V3 Pool ($uni_pool)"

  uni_code="$(cast code --rpc-url "$rpc" "$uni_pool" 2>/dev/null || echo '0x')"
  if [[ "${#uni_code}" -gt 4 ]]; then
    ok "$name: Uniswap Pool has bytecode (${#uni_code} chars)"
  else
    fail "$name: Uniswap Pool has no bytecode at $uni_pool"
  fi

  slot0="$(cast_call "$rpc" "$uni_pool" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)')"
  sqrt_price="$(awk 'NR==1{print $1}' <<<"$slot0")"
  if nonzero_hex "${sqrt_price:-0x0}"; then
    ok "$name: Pool.slot0()  sqrtPriceX96=$sqrt_price"
  else
    fail "$name: Pool.slot0() returned zero sqrtPriceX96 ('${sqrt_price}')"
  fi

  liq="$(cast_call "$rpc" "$uni_pool" 'liquidity()(uint128)')"
  liq="${liq// /}"
  if [[ -n "$liq" ]]; then
    ok "$name: Pool.liquidity() = $liq"
  else
    fail "$name: Pool.liquidity() returned empty"
  fi

  token0="$(cast_call "$rpc" "$uni_pool" 'token0()(address)')"
  token1="$(cast_call "$rpc" "$uni_pool" 'token1()(address)')"
  token0="${token0// /}"
  token1="${token1// /}"
  if nonzero_addr "${token0:-}" && nonzero_addr "${token1:-}"; then
    ok "$name: Pool.token0=${token0:0:10}..  token1=${token1:0:10}.."
  else
    fail "$name: Pool.token0/token1 returned zeros ('$token0' / '$token1')"
  fi

  obs="$(cast_call "$rpc" "$uni_pool" 'observe(uint32[])(int56[],uint160[])' '[300,0]')"
  if [[ -n "$obs" ]]; then
    ok "$name: Pool.observe([300,0]) succeeded"
  else
    fail "$name: Pool.observe([300,0]) returned empty"
  fi

  # ── Post-fork block mining sanity check ─────────────────────────────────────
  hdr "Post-fork mining"

  pre_block="$(cast block-number --rpc-url "$rpc" 2>/dev/null || echo 0)"
  cast rpc --rpc-url "$rpc" evm_mine >/dev/null 2>&1 || true
  post_block="$(cast block-number --rpc-url "$rpc" 2>/dev/null || echo 0)"
  if [[ "$post_block" -gt "$pre_block" ]]; then
    ok "$name: evm_mine advanced block $pre_block → $post_block"
  else
    fail "$name: evm_mine did not advance block (before=$pre_block after=$post_block)"
  fi

done

# ── Summary ───────────────────────────────────────────────────────────────────

printf "\n${C_DIM}=== Summary ===${C_RESET}\n"
printf "  ${C_OK}PASS: $PASS${C_RESET}  ${C_FAIL}FAIL: $FAIL${C_RESET}  ${C_DIM}SKIP: $SKIP${C_RESET}\n\n"

[[ "$FAIL" -eq 0 ]]
