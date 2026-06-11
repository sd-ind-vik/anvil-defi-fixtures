#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CAPTURE_MODE="${ANVIL_CAPTURE_MODE:-fork}"
if [[ "$CAPTURE_MODE" == "synthetic" ]]; then
  MANIFEST="${ANVIL_OFFLINE_STATE_MANIFEST:-fixtures/anvil-state/synthetic-manifest.json}"
else
  MANIFEST="${ANVIL_OFFLINE_STATE_MANIFEST:-fixtures/anvil-state/manifest.json}"
fi
CHAIN_CONFIG="${CHAIN_CONFIG:-config/chains.json}"
SYNTHETIC_TIMESTAMP="${ANVIL_SYNTHETIC_TIMESTAMP:-1750000000}"
export ANVIL_SYNTHETIC_TIMESTAMP="$SYNTHETIC_TIMESTAMP"
CAPTURE_PORT="${ANVIL_CAPTURE_PORT:-19545}"
CAPTURE_ONLY="${ANVIL_CAPTURE_CHAINS:-}"
CAPTURE_USE_LATEST_BLOCK="${ANVIL_CAPTURE_USE_LATEST_BLOCK:-false}"
CAPTURE_WARM_MINED_BLOCKS="${ANVIL_CAPTURE_WARM_MINED_BLOCKS:-2}"
FOUNDRY_RPC_CACHE_ROOT="${FOUNDRY_RPC_CACHE_ROOT:-$HOME/.foundry/cache/rpc}"
# Warm the default anvil account plus the deployment's monitored Aave position accounts.
AAVE_WARM_ACCOUNTS="${AAVE_WARM_ACCOUNTS:-0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266}"
if [[ -n "${AAVE_ACCOUNTS:-}" ]]; then
  AAVE_WARM_ACCOUNTS="${AAVE_WARM_ACCOUNTS},${AAVE_ACCOUNTS}"
fi
GAS_TRACKING_WARM_DEPTH="${GAS_TRACKING_WARM_DEPTH:-3}"
ANVIL_CAPTURE_FIND_ACTIVE_BLOCK="${ANVIL_CAPTURE_FIND_ACTIVE_BLOCK:-false}"
ANVIL_CAPTURE_ACTIVE_BLOCK_SCAN_DEPTH="${ANVIL_CAPTURE_ACTIVE_BLOCK_SCAN_DEPTH:-500}"
ANVIL_CAPTURE_LOG_SCAN_DEPTH="${ANVIL_CAPTURE_LOG_SCAN_DEPTH:-50}"
UNISWAP_TWAP_WINDOW_SECS="${UNISWAP_TWAP_WINDOW_SECS:-300}"
EIP1967_IMPLEMENTATION_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
EIP1967_ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
EIP1967_BEACON_SLOT="0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"
export ETH_MAINNET_RPC_URL="${ETH_MAINNET_RPC_URL:-https://ethereum-rpc.publicnode.com}"
export BASE_RPC_URL="${BASE_RPC_URL:-https://base-rpc.publicnode.com}"
export ARBITRUM_RPC_URL="${ARBITRUM_RPC_URL:-https://arbitrum-one-rpc.publicnode.com}"
export OPTIMISM_RPC_URL="${OPTIMISM_RPC_URL:-https://optimism-rpc.publicnode.com}"
ANVIL_PIDS=()

log() {
  printf '\n==> %s\n' "$1"
}

cleanup() {
  local pid
  for pid in "${ANVIL_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill -INT "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
}

trap cleanup EXIT

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '%s is required to capture offline Anvil state\n' "$command_name" >&2
    return 1
  fi
}

fixture_enabled() {
  local chain_id="$1"
  if [[ -z "$CAPTURE_ONLY" ]]; then
    return 0
  fi
  local selected
  IFS=',' read -ra selected <<<"$CAPTURE_ONLY"
  for selected in "${selected[@]}"; do
    if [[ "$selected" == "$chain_id" ]]; then
      return 0
    fi
  done
  return 1
}

wait_for_anvil() {
  local rpc_url="$1"
  local pid="$2"
  local log_file="$3"
  for _ in $(seq 1 60); do
    if cast chain-id --rpc-url "$rpc_url" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      printf 'anvil exited during startup; log follows\n' >&2
      cat "$log_file" >&2
      return 1
    fi
    sleep 1
  done
  printf 'anvil did not become ready at %s; log follows\n' "$rpc_url" >&2
  cat "$log_file" >&2
  return 1
}

warm_contract_code() {
  local rpc_url="$1"
  local chain_id="$2"
  local chain_name="$3"
  local contract="$4"
  local code
  code="$(cast code --rpc-url "$rpc_url" "$contract")"
  if [[ "$code" == "0x" ]]; then
    printf 'expected warmed contract %s on %s chain %s to have code\n' "$contract" "$chain_name" "$chain_id" >&2
    return 1
  fi
}

required_call() {
  local rpc_url="$1"
  local label="$2"
  local contract="$3"
  shift 3
  if ! cast call --rpc-url "$rpc_url" "$contract" "$@" >/dev/null; then
    printf 'required warm call failed for %s at %s: %s\n' "$label" "$contract" "$*" >&2
    return 1
  fi
}

best_effort_call() {
  local rpc_url="$1"
  local contract="$2"
  shift 2
  cast call --rpc-url "$rpc_url" "$contract" "$@" >/dev/null 2>&1 || true
}

best_effort_storage() {
  local rpc_url="$1"
  local contract="$2"
  local slot="$3"
  cast storage --rpc-url "$rpc_url" "$contract" "$slot" >/dev/null 2>&1 || true
}

address_from_storage_word() {
  local word="$1"
  word="${word#0x}"
  if [[ ${#word} -ne 64 ]]; then
    return 1
  fi
  local address="0x${word:24:40}"
  if [[ "$address" == "0x0000000000000000000000000000000000000000" ]]; then
    return 1
  fi
  printf '%s' "$address"
}

warm_proxy_dependencies() {
  local rpc_url="$1"
  local chain_id="$2"
  local chain_name="$3"
  local contract="$4"
  local slot value implementation admin beacon beacon_implementation

  for slot in "$EIP1967_IMPLEMENTATION_SLOT" "$EIP1967_ADMIN_SLOT" "$EIP1967_BEACON_SLOT"; do
    cast storage --rpc-url "$rpc_url" "$contract" "$slot" >/dev/null 2>&1 || true
  done

  value="$(cast storage --rpc-url "$rpc_url" "$contract" "$EIP1967_IMPLEMENTATION_SLOT" 2>/dev/null || true)"
  implementation="$(address_from_storage_word "$value" 2>/dev/null || true)"
  if [[ -n "$implementation" ]]; then
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$implementation" || true
  fi

  value="$(cast storage --rpc-url "$rpc_url" "$contract" "$EIP1967_ADMIN_SLOT" 2>/dev/null || true)"
  admin="$(address_from_storage_word "$value" 2>/dev/null || true)"
  if [[ -n "$admin" ]]; then
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$admin" || true
  fi

  value="$(cast storage --rpc-url "$rpc_url" "$contract" "$EIP1967_BEACON_SLOT" 2>/dev/null || true)"
  beacon="$(address_from_storage_word "$value" 2>/dev/null || true)"
  if [[ -n "$beacon" ]]; then
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$beacon" || true
    beacon_implementation="$(cast call --rpc-url "$rpc_url" "$beacon" 'implementation()(address)' 2>/dev/null || true)"
    if [[ -n "$beacon_implementation" ]]; then
      warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$beacon_implementation" || true
    fi
  fi
}

chain_config_for() {
  local chain_id="$1"
  jq -c --argjson chain_id "$chain_id" '.chains[] | select(.chain_id == $chain_id)' "$CHAIN_CONFIG"
}

config_warmed_contracts_for() {
  local chain_config="$1"
  jq -r '
    [
      (.protocols.aave.pool?),
      (.protocols.aave.data_provider?),
      (.protocols.aave.oracle?),
      (.protocols.uniswap.factories[]?),
      (.protocols.uniswap.routers[]?),
      (.protocols.uniswap.pools[]?),
      (.protocols.uniswap.quoter?),
      (.sequencer_status_feed?),
      (.protocols.bridges[]?.contracts[]?),
      (.protocols.control_plane.governance[]?),
      (.protocols.control_plane.guardians[]?),
      (.protocols.control_plane.proxy_admins[]?),
      (.protocols.control_plane.oracle_admins[]?),
      (.protocols.control_plane.bridge_admins[]?)
    ]
    | .[]?
    | select(. != null and . != "")
  ' <<<"$chain_config"
}

warm_erc20_metadata() {
  local rpc_url="$1"
  local token="$2"
  best_effort_call "$rpc_url" "$token" 'decimals()(uint8)'
  best_effort_call "$rpc_url" "$token" 'symbol()(string)'
  best_effort_call "$rpc_url" "$token" 'name()(string)'
  best_effort_call "$rpc_url" "$token" 'totalSupply()(uint256)'
  best_effort_call "$rpc_url" "$token" 'balanceOf(address)(uint256)' 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
}

warm_aave_reads() {
  local rpc_url="$1"
  local chain_id="$2"
  local chain_name="$3"
  local chain_config="$4"
  local pool data_provider oracle asset account reserve_data reserve_token
  pool="$(jq -r '.protocols.aave.pool // empty' <<<"$chain_config")"
  [[ -z "$pool" ]] && return 0

  warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$pool"
  warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$pool"
  data_provider="$(jq -r '.protocols.aave.data_provider // empty' <<<"$chain_config")"
  oracle="$(jq -r '.protocols.aave.oracle // empty' <<<"$chain_config")"
  if [[ -n "$data_provider" ]]; then
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$data_provider"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$data_provider"
  fi
  if [[ -n "$oracle" ]]; then
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$oracle"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$oracle"
  fi

  while IFS= read -r asset; do
    [[ -z "$asset" || "$asset" == "null" ]] && continue
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$asset"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$asset"
    warm_erc20_metadata "$rpc_url" "$asset"
    reserve_data="$(cast call --rpc-url "$rpc_url" "$pool" \
      'getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)' "$asset")"
    if [[ -z "$reserve_data" ]]; then
      printf 'required warm call failed for %s Aave getReserveData at %s asset %s\n' "$chain_name" "$pool" "$asset" >&2
      return 1
    fi
    for reserve_token in $(printf '%s\n' "$reserve_data" | grep -Eio '0x[0-9a-fA-F]{40}' | sort -u); do
      warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$reserve_token" || true
      warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$reserve_token"
      warm_erc20_metadata "$rpc_url" "$reserve_token"
    done
    if [[ -n "$data_provider" ]]; then
      required_call "$rpc_url" "${chain_name} Aave getReserveConfigurationData" "$data_provider" \
        'getReserveConfigurationData(address)(uint256,uint256,uint256,uint256,uint256,bool,bool,bool,bool,bool)' "$asset"
      required_call "$rpc_url" "${chain_name} Aave getReserveCaps" "$data_provider" \
        'getReserveCaps(address)(uint256,uint256)' "$asset"
      best_effort_call "$rpc_url" "$data_provider" 'getReserveTokensAddresses(address)(address,address,address)' "$asset"
    fi
    if [[ -n "$oracle" ]]; then
      required_call "$rpc_url" "${chain_name} Aave getAssetPrice" "$oracle" \
        'getAssetPrice(address)(uint256)' "$asset"
    fi
  done < <(jq -r '.protocols.aave.key_reserves[]?' <<<"$chain_config")

  IFS=',' read -ra accounts <<<"$AAVE_WARM_ACCOUNTS"
  for account in "${accounts[@]}"; do
    [[ -z "$account" ]] && continue
    required_call "$rpc_url" "${chain_name} Aave getUserAccountData" "$pool" \
      'getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)' "$account"
  done
}

warm_uniswap_reads() {
  local rpc_url="$1"
  local chain_id="$2"
  local chain_name="$3"
  local chain_config="$4"
  local router factory quoter pool token0 token1 observation_index observation_cardinality cardinality_probe

  while IFS= read -r factory; do
    [[ -z "$factory" || "$factory" == "null" ]] && continue
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$factory"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$factory"
  done < <(jq -r '.protocols.uniswap.factories[]?' <<<"$chain_config")

  while IFS= read -r router; do
    [[ -z "$router" || "$router" == "null" ]] && continue
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$router"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$router"
  done < <(jq -r '.protocols.uniswap.routers[]?' <<<"$chain_config")

  quoter="$(jq -r '.protocols.uniswap.quoter // empty' <<<"$chain_config")"
  if [[ -n "$quoter" ]]; then
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$quoter"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$quoter"
  fi

  while IFS= read -r pool; do
    [[ -z "$pool" || "$pool" == "null" ]] && continue
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$pool"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$pool"
    required_call "$rpc_url" "${chain_name} Uniswap slot0" "$pool" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)'
    required_call "$rpc_url" "${chain_name} Uniswap liquidity" "$pool" 'liquidity()(uint128)'
    token0="$(cast call --rpc-url "$rpc_url" "$pool" 'token0()(address)')"
    token1="$(cast call --rpc-url "$rpc_url" "$pool" 'token1()(address)')"
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$token0"
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$token1"
    warm_erc20_metadata "$rpc_url" "$token0"
    warm_erc20_metadata "$rpc_url" "$token1"
    required_call "$rpc_url" "${chain_name} Uniswap observe" "$pool" \
      'observe(uint32[])(int56[],uint160[])' "[$UNISWAP_TWAP_WINDOW_SECS,0]"
    observation_index="$(cast call --rpc-url "$rpc_url" "$pool" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' | awk 'NR==3 {print $1}')"
    observation_cardinality="$(cast call --rpc-url "$rpc_url" "$pool" 'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)' | awk 'NR==4 {print $1}')"
    if [[ "$observation_index" =~ ^[0-9]+$ ]]; then
      best_effort_call "$rpc_url" "$pool" 'observations(uint256)(uint32,int56,uint160,bool)' "$observation_index"
    fi
    if [[ "$observation_cardinality" =~ ^[0-9]+$ && "$observation_cardinality" -gt 0 ]]; then
      cardinality_probe=$((observation_cardinality - 1))
      best_effort_call "$rpc_url" "$pool" 'observations(uint256)(uint32,int56,uint160,bool)' "$cardinality_probe"
    fi
  done < <(jq -r '.protocols.uniswap.pools[]?' <<<"$chain_config")
}

find_active_block() {
  local rpc_url="$1"
  local pool_address="$2"
  local scan_depth="${3:-$ANVIL_CAPTURE_ACTIVE_BLOCK_SCAN_DEPTH}"
  local head from from_hex head_hex result active_block
  # keccak256("ReserveDataUpdated(address,uint256,uint256,uint256,uint256,uint256)")
  local TOPIC_RESERVE_UPDATED="0x804c9b842b2748a22bb64b345453a3de7ca54a6ca45ce00d415894979e22897a"

  head="$(cast block-number --rpc-url "$rpc_url")"
  [[ "$head" =~ ^[0-9]+$ ]] || return 1
  from=$(( head > scan_depth ? head - scan_depth : 0 ))
  from_hex="$(printf '0x%x' "$from")"
  head_hex="$(printf '0x%x' "$head")"

  # First pass: look for ReserveDataUpdated (fires on any supply/borrow/repay/withdraw)
  active_block="$(
    cast rpc --rpc-url "$rpc_url" eth_getLogs \
      "{\"address\":\"$pool_address\",\"topics\":[\"$TOPIC_RESERVE_UPDATED\"],\"fromBlock\":\"$from_hex\",\"toBlock\":\"$head_hex\"}" \
      2>/dev/null | python3 -c "
import json,sys
logs=json.loads(sys.stdin.read())
if not isinstance(logs,list) or not logs: sys.exit(1)
print(max(int(l['blockNumber'],16) for l in logs))
" 2>/dev/null || true)"

  # Second pass: any event on the pool (broader; catches chains where activity is sparse)
  if [[ ! "$active_block" =~ ^[0-9]+$ ]]; then
    active_block="$(
      cast rpc --rpc-url "$rpc_url" eth_getLogs \
        "{\"address\":\"$pool_address\",\"fromBlock\":\"$from_hex\",\"toBlock\":\"$head_hex\"}" \
        2>/dev/null | python3 -c "
import json,sys
logs=json.loads(sys.stdin.read())
if not isinstance(logs,list) or not logs: sys.exit(1)
print(max(int(l['blockNumber'],16) for l in logs))
" 2>/dev/null || true)"
  fi

  [[ "$active_block" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$active_block"
}

warm_log_reads() {
  local source_rpc_url="$1"
  local logs_file="$2"
  local fork_block="$3"
  shift 3
  local addresses=("$@")

  if [[ "${#addresses[@]}" -eq 0 ]]; then
    return 0
  fi

  local from_block to_block from_hex to_hex tmpdir i addr out
  from_block=$(( fork_block > ANVIL_CAPTURE_LOG_SCAN_DEPTH ? fork_block - ANVIL_CAPTURE_LOG_SCAN_DEPTH : 0 ))
  to_block="$fork_block"
  from_hex="$(printf '0x%x' "$from_block")"
  to_hex="$(printf '0x%x' "$to_block")"
  tmpdir="$(mktemp -d)"
  i=0

  for addr in "${addresses[@]}"; do
    [[ -z "$addr" || "$addr" == "null" ]] && continue
    out="$tmpdir/logs_${i}.json"
    cast rpc --rpc-url "$source_rpc_url" eth_getLogs \
      "{\"address\":\"$addr\",\"fromBlock\":\"$from_hex\",\"toBlock\":\"$to_hex\"}" \
      >"$out" 2>/dev/null || echo "[]" >"$out"
    ((i++)) || true
  done

  python3 - "$tmpdir" "$logs_file" <<'PY'
import json, pathlib, sys

tmpdir = pathlib.Path(sys.argv[1])
logs_file = pathlib.Path(sys.argv[2])
merged = []
for f in sorted(tmpdir.glob("logs_*.json")):
    try:
        data = json.loads(f.read_text())
        if isinstance(data, list):
            merged.extend(data)
    except Exception:
        pass
seen: set = set()
deduped = []
for log in merged:
    key = (log.get("blockNumber",""), log.get("logIndex",""), log.get("transactionHash",""))
    if key not in seen:
        seen.add(key)
        deduped.append(log)
deduped.sort(key=lambda l: (int(l.get("blockNumber","0x0"),16), int(l.get("logIndex","0x0"),16)))
logs_file.parent.mkdir(parents=True, exist_ok=True)
logs_file.write_text(json.dumps(deduped, indent=2))
print(f"captured {len(deduped)} logs → {logs_file}", file=sys.stderr)
PY
  rm -rf "$tmpdir"
}

warm_gas_tracking_reads() {
  local rpc_url="$1"
  local head depth block
  head="$(cast block-number --rpc-url "$rpc_url")"
  [[ "$head" =~ ^[0-9]+$ ]] || return 0
  for depth in $(seq 0 "$GAS_TRACKING_WARM_DEPTH"); do
    block=$((head - depth))
    ((block < 0)) && break
    # full-transaction block fetch: caches header (baseFeePerGas/gasUsed/gasLimit)
    # and block hash so offline gas tracking via eth_getBlockByNumber resolves
    cast rpc --rpc-url "$rpc_url" eth_getBlockByNumber "$(printf '0x%x' "$block")" true >/dev/null 2>&1 || true
  done
  cast rpc --rpc-url "$rpc_url" eth_gasPrice >/dev/null 2>&1 || true
  cast rpc --rpc-url "$rpc_url" eth_maxPriorityFeePerGas >/dev/null 2>&1 || true
}

warm_sequencer_reads() {
  local rpc_url="$1"
  local chain_id="$2"
  local chain_name="$3"
  local chain_config="$4"
  local feed
  feed="$(jq -r '.sequencer_status_feed // empty' <<<"$chain_config")"
  [[ -z "$feed" ]] && return 0
  warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$feed"
  required_call "$rpc_url" "${chain_name} sequencer latestRoundData" "$feed" \
    'latestRoundData()(uint80,int256,uint256,uint256,uint80)'
  best_effort_call "$rpc_url" "$feed" 'decimals()(uint8)'
  best_effort_call "$rpc_url" "$feed" 'description()(string)'
}

warm_control_plane_reads() {
  local rpc_url="$1"
  local chain_id="$2"
  local chain_name="$3"
  local chain_config="$4"
  local address
  while IFS= read -r address; do
    [[ -z "$address" || "$address" == "null" ]] && continue
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$address"
    best_effort_storage "$rpc_url" "$address" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
    best_effort_storage "$rpc_url" "$address" 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
    best_effort_storage "$rpc_url" "$address" 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50
    best_effort_call "$rpc_url" "$address" 'paused()(bool)'
    best_effort_call "$rpc_url" "$address" 'owner()(address)'
    best_effort_call "$rpc_url" "$address" 'admin()(address)'
    best_effort_call "$rpc_url" "$address" 'guardian()(address)'
  done < <(
    jq -r '
      [
        (.protocols.bridges[]?.contracts[]?),
        (.protocols.control_plane.governance[]?),
        (.protocols.control_plane.guardians[]?),
        (.protocols.control_plane.proxy_admins[]?),
        (.protocols.control_plane.oracle_admins[]?),
        (.protocols.control_plane.bridge_admins[]?)
      ] | .[]?
    ' <<<"$chain_config"
  )
}

warm_protocol_reads() {
  local rpc_url="$1"
  local fixture="$2"
  local chain_id chain_name chain_config
  chain_id="$(jq -r '.chain_id' <<<"$fixture")"
  chain_name="$(jq -r '.chain_name' <<<"$fixture")"
  chain_config="$(chain_config_for "$chain_id")"
  if [[ -z "$chain_config" ]]; then
    printf 'chain %s is missing from %s\n' "$chain_id" "$CHAIN_CONFIG" >&2
    return 1
  fi

  while IFS= read -r contract; do
    [[ -z "$contract" || "$contract" == "null" ]] && continue
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$contract"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$contract"
  done < <(config_warmed_contracts_for "$chain_config")

  while IFS= read -r contract; do
    [[ -z "$contract" || "$contract" == "null" ]] && continue
    warm_contract_code "$rpc_url" "$chain_id" "$chain_name" "$contract"
    warm_proxy_dependencies "$rpc_url" "$chain_id" "$chain_name" "$contract"
  done < <(jq -r '.warmed_contracts[]?' <<<"$fixture")

  warm_aave_reads "$rpc_url" "$chain_id" "$chain_name" "$chain_config"
  warm_uniswap_reads "$rpc_url" "$chain_id" "$chain_name" "$chain_config"
  warm_sequencer_reads "$rpc_url" "$chain_id" "$chain_name" "$chain_config"
  warm_control_plane_reads "$rpc_url" "$chain_id" "$chain_name" "$chain_config"
  warm_gas_tracking_reads "$rpc_url"
}

stop_anvil_and_wait_for_dump() {
  local pid="$1"
  local dump_file="$2"
  local log_file="$3"
  kill -INT "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  if [[ ! -s "$dump_file" ]]; then
    printf 'expected Anvil dump state file to be written: %s\n' "$dump_file" >&2
    cat "$log_file" >&2
    return 1
  fi
}

foundry_cache_chain_name() {
  local chain_id="$1"
  local chain_name="$2"
  case "$chain_id" in
    1) printf 'mainnet' ;;
    8453) printf 'base' ;;
    42161) printf 'arbitrum' ;;
    10) printf 'optimism' ;;
    *) printf '%s' "$chain_name" ;;
  esac
}

cache_archive_for_fixture() {
  local chain_id="$1"
  local chain_name="$2"
  local fork_block="$3"
  printf 'fixtures/anvil-state/%s/chain-%s-block-%s-foundry-cache.tar.gz' "$chain_name" "$chain_id" "$fork_block"
}

archive_foundry_cache() {
  local chain_id="$1"
  local chain_name="$2"
  local fork_block="$3"
  local cache_archive="$4"
  local cache_chain cache_dir archive_dir tmp_archive
  cache_chain="$(foundry_cache_chain_name "$chain_id" "$chain_name")"
  cache_dir="${FOUNDRY_RPC_CACHE_ROOT}/${cache_chain}/${fork_block}"
  if [[ ! -s "${cache_dir}/storage.json" ]]; then
    printf 'expected warmed Foundry RPC cache at %s/storage.json for %s chain %s block %s\n' \
      "$cache_dir" "$chain_name" "$chain_id" "$fork_block" >&2
    return 1
  fi
  archive_dir="$(dirname "$cache_archive")"
  mkdir -p "$archive_dir"
  tmp_archive="${cache_archive}.tmp"
  rm -f "$tmp_archive"
  tar -C "$FOUNDRY_RPC_CACHE_ROOT" -czf "$tmp_archive" "${cache_chain}/${fork_block}"
  mv "$tmp_archive" "$cache_archive"
  printf 'archived Foundry RPC cache for %s chain %s block %s: %s\n' \
    "$chain_name" "$chain_id" "$fork_block" "$cache_archive"
}

update_manifest_hash() {
  local chain_id="$1"
  local state_file="$2"
  local manifest_tmp sha
  sha="$(sha256sum "$state_file" | awk '{print $1}')"
  manifest_tmp="$(mktemp)"
  jq --argjson chain_id "$chain_id" --arg sha "$sha" \
    '(.fixtures[] | select(.chain_id == $chain_id) | .sha256) = $sha' \
    "$MANIFEST" >"$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST"
  printf 'updated manifest sha256 for chain %s: %s\n' "$chain_id" "$sha"
}

update_manifest_fork_block() {
  local chain_id="$1"
  local fork_block="$2"
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  jq --argjson chain_id "$chain_id" --argjson fork_block "$fork_block" \
    '(.fixtures[] | select(.chain_id == $chain_id) | .fork_block) = $fork_block' \
    "$MANIFEST" >"$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST"
  printf 'updated manifest fork_block for chain %s: %s\n' "$chain_id" "$fork_block"
}

update_manifest_state_file() {
  local chain_id="$1"
  local state_file="$2"
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  jq --argjson chain_id "$chain_id" --arg state_file "$state_file" \
    '(.fixtures[] | select(.chain_id == $chain_id) | .state_file) = $state_file' \
    "$MANIFEST" >"$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST"
  printf 'updated manifest state_file for chain %s: %s\n' "$chain_id" "$state_file"
}

update_manifest_cache_archive() {
  local chain_id="$1"
  local cache_archive="$2"
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  jq --argjson chain_id "$chain_id" --arg cache_archive "$cache_archive" \
    '(.fixtures[] | select(.chain_id == $chain_id) | .cache_archive) = $cache_archive' \
    "$MANIFEST" >"$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST"
  printf 'updated manifest cache_archive for chain %s: %s\n' "$chain_id" "$cache_archive"
}

update_manifest_cache_hash() {
  local chain_id="$1"
  local cache_archive="$2"
  local manifest_tmp sha
  sha="$(sha256sum "$cache_archive" | awk '{print $1}')"
  manifest_tmp="$(mktemp)"
  jq --argjson chain_id "$chain_id" --arg sha "$sha" \
    '(.fixtures[] | select(.chain_id == $chain_id) | .cache_sha256) = $sha' \
    "$MANIFEST" >"$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST"
  printf 'updated manifest cache_sha256 for chain %s: %s\n' "$chain_id" "$sha"
}

update_manifest_anvil_version() {
  local chain_id="$1"
  local anvil_version="$2"
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  jq --argjson chain_id "$chain_id" --arg anvil_version "$anvil_version" \
    '(.fixtures[] | select(.chain_id == $chain_id) | .anvil_version) = $anvil_version' \
    "$MANIFEST" >"$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST"
  printf 'updated manifest anvil_version for chain %s: %s\n' "$chain_id" "$anvil_version"
}

update_manifest_warmed_contracts() {
  local chain_id="$1"
  local chain_config="$2"
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  jq --argjson chain_id "$chain_id" --argjson chain_config "$chain_config" '
    def config_contracts($config):
      [
        ($config.protocols.aave.pool?),
        ($config.protocols.aave.data_provider?),
        ($config.protocols.aave.oracle?),
        ($config.protocols.uniswap.factories[]?),
        ($config.protocols.uniswap.routers[]?),
        ($config.protocols.uniswap.pools[]?),
        ($config.protocols.uniswap.quoter?),
        ($config.sequencer_status_feed?),
        ($config.protocols.bridges[]?.contracts[]?),
        ($config.protocols.control_plane.governance[]?),
        ($config.protocols.control_plane.guardians[]?),
        ($config.protocols.control_plane.proxy_admins[]?),
        ($config.protocols.control_plane.oracle_admins[]?),
        ($config.protocols.control_plane.bridge_admins[]?)
      ]
      | map(select(. != null and . != ""))
      | unique;
    (.fixtures[] | select(.chain_id == $chain_id) | .warmed_contracts) = config_contracts($chain_config)
  ' "$MANIFEST" >"$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST"
  printf 'updated manifest warmed_contracts for chain %s\n' "$chain_id"
}

update_manifest_aave_warmed_contracts() {
  local chain_id="$1"
  local chain_config="$2"
  local manifest_tmp
  manifest_tmp="$(mktemp)"
  jq --argjson chain_id "$chain_id" --argjson chain_config "$chain_config" '
    (.fixtures[] | select(.chain_id == $chain_id) | .warmed_contracts) =
      ([
        ($chain_config.protocols.aave.pool?),
        ($chain_config.protocols.aave.data_provider?),
        ($chain_config.protocols.aave.oracle?),
        ($chain_config.protocols.aave.key_reserves[]?)
      ]
      | map(select(. != null and . != ""))
      | unique)
  ' "$MANIFEST" >"$manifest_tmp"
  mv "$manifest_tmp" "$MANIFEST"
  printf 'updated manifest warmed_contracts for chain %s\n' "$chain_id"
}

capture_synthetic_fixture() {
  local fixture="$1"
  local chain_id chain_name state_file chain_config pool
  local state_dir tmp_state log_file rpc_url_local pid actual_chain_id anvil_version
  local address code
  chain_id="$(jq -r '.chain_id' <<<"$fixture")"
  chain_name="$(jq -r '.chain_name' <<<"$fixture")"
  state_file="$(jq -r '.state_file' <<<"$fixture")"

  if ! fixture_enabled "$chain_id"; then
    printf 'skipping %s chain %s because ANVIL_CAPTURE_CHAINS=%s\n' "$chain_name" "$chain_id" "$CAPTURE_ONLY"
    return 0
  fi

  chain_config="$(chain_config_for "$chain_id")"
  if [[ -z "$chain_config" ]]; then
    printf 'chain %s is missing from %s\n' "$chain_id" "$CHAIN_CONFIG" >&2
    return 1
  fi
  pool="$(jq -r '.protocols.aave.pool // empty' <<<"$chain_config")"
  if [[ -z "$pool" ]]; then
    printf 'skipping %s chain %s: no Aave pool configured\n' "$chain_name" "$chain_id"
    return 0
  fi

  state_dir="$(dirname "$state_file")"
  mkdir -p "$state_dir"
  tmp_state="${state_file}.tmp"
  log_file="/tmp/chainsentry-synthetic-${chain_name}-${chain_id}.log"
  rpc_url_local="http://127.0.0.1:${CAPTURE_PORT}"
  rm -f "$tmp_state"

  log "Generate synthetic Aave state for ${chain_name} chain ${chain_id} (no upstream RPC)"
  anvil \
    --host 127.0.0.1 \
    --port "$CAPTURE_PORT" \
    --chain-id "$chain_id" \
    --timestamp "$SYNTHETIC_TIMESTAMP" \
    --dump-state "$tmp_state" >"$log_file" 2>&1 &
  pid="$!"
  ANVIL_PIDS+=("$pid")

  wait_for_anvil "$rpc_url_local" "$pid" "$log_file"
  actual_chain_id="$(cast chain-id --rpc-url "$rpc_url_local")"
  if [[ "$actual_chain_id" != "$chain_id" ]]; then
    printf 'expected synthetic %s chain id %s, got %s\n' "$chain_name" "$chain_id" "$actual_chain_id" >&2
    return 1
  fi

  while IFS=' ' read -r address code; do
    [[ -z "$address" || -z "$code" ]] && continue
    cast rpc --rpc-url "$rpc_url_local" anvil_setCode "$address" "$code" >/dev/null
  done < <(python3 scripts/generate-aave-mock-state.py <<<"$chain_config")

  warm_aave_reads "$rpc_url_local" "$chain_id" "$chain_name" "$chain_config"
  warm_gas_tracking_reads "$rpc_url_local"
  local warm_block
  for warm_block in $(seq 1 "$CAPTURE_WARM_MINED_BLOCKS"); do
    cast rpc --rpc-url "$rpc_url_local" evm_mine >/dev/null
    warm_aave_reads "$rpc_url_local" "$chain_id" "$chain_name" "$chain_config" || true
    warm_gas_tracking_reads "$rpc_url_local"
  done
  stop_anvil_and_wait_for_dump "$pid" "$tmp_state" "$log_file"
  mv "$tmp_state" "$state_file"
  update_manifest_hash "$chain_id" "$state_file"
  anvil_version="$(anvil --version | head -n 1)"
  update_manifest_anvil_version "$chain_id" "$anvil_version"
  update_manifest_aave_warmed_contracts "$chain_id" "$chain_config"
}

capture_fixture() {
  local fixture="$1"
  local chain_id chain_name fork_block state_file source_rpc_env rpc_url rpc_url_value
  local state_dir tmp_state log_file rpc_url_local pid actual_chain_id cache_archive anvil_version
  chain_id="$(jq -r '.chain_id' <<<"$fixture")"
  chain_name="$(jq -r '.chain_name' <<<"$fixture")"
  fork_block="$(jq -r '.fork_block' <<<"$fixture")"
  state_file="$(jq -r '.state_file' <<<"$fixture")"
  source_rpc_env="$(jq -r '.source_rpc_env' <<<"$fixture")"

  if ! fixture_enabled "$chain_id"; then
    printf 'skipping %s chain %s because ANVIL_CAPTURE_CHAINS=%s\n' "$chain_name" "$chain_id" "$CAPTURE_ONLY"
    return 0
  fi

  rpc_url_value="${!source_rpc_env:-}"
  if [[ -z "$rpc_url_value" ]]; then
    printf 'missing %s for %s chain %s state capture\n' "$source_rpc_env" "$chain_name" "$chain_id" >&2
    return 1
  fi

  if [[ "$ANVIL_CAPTURE_FIND_ACTIVE_BLOCK" == true ]]; then
    local _pool_addr
    _pool_addr="$(jq -r '.protocols.aave.pool // empty' <<<"$(chain_config_for "$chain_id")")"
    if [[ -n "$_pool_addr" ]]; then
      fork_block="$(find_active_block "$rpc_url_value" "$_pool_addr")" || true
      if [[ "$fork_block" =~ ^[0-9]+$ ]]; then
        printf 'found active block %s for %s (Aave events in last %s blocks)\n' \
          "$fork_block" "$chain_name" "$ANVIL_CAPTURE_ACTIVE_BLOCK_SCAN_DEPTH"
      else
        printf 'warn: no active Aave block found for %s in last %s blocks, using latest\n' \
          "$chain_name" "$ANVIL_CAPTURE_ACTIVE_BLOCK_SCAN_DEPTH" >&2
        fork_block="$(cast block-number --rpc-url "$rpc_url_value")"
      fi
    else
      fork_block="$(cast block-number --rpc-url "$rpc_url_value")"
    fi
    if [[ ! "$fork_block" =~ ^[0-9]+$ ]]; then
      printf 'expected numeric fork block for %s chain %s, got %s\n' "$chain_name" "$chain_id" "$fork_block" >&2
      return 1
    fi
    state_file="fixtures/anvil-state/${chain_name}/chain-${chain_id}-block-${fork_block}.json"
  elif [[ "$CAPTURE_USE_LATEST_BLOCK" == true ]]; then
    fork_block="$(cast block-number --rpc-url "$rpc_url_value")"
    if [[ ! "$fork_block" =~ ^[0-9]+$ ]]; then
      printf 'expected numeric latest block from %s for %s chain %s, got %s\n' "$source_rpc_env" "$chain_name" "$chain_id" "$fork_block" >&2
      return 1
    fi
    state_file="fixtures/anvil-state/${chain_name}/chain-${chain_id}-block-${fork_block}.json"
  fi
  cache_archive="$(cache_archive_for_fixture "$chain_id" "$chain_name" "$fork_block")"

  state_dir="$(dirname "$state_file")"
  mkdir -p "$state_dir"
  tmp_state="${state_file}.tmp"
  log_file="/tmp/chainsentry-capture-${chain_name}-${chain_id}.log"
  rpc_url_local="http://127.0.0.1:${CAPTURE_PORT}"
  rm -f "$tmp_state"

  log "Capture ${chain_name} chain ${chain_id} at block ${fork_block}"
  anvil \
    --host 127.0.0.1 \
    --port "$CAPTURE_PORT" \
    --chain-id "$chain_id" \
    --fork-url "$rpc_url_value" \
    --fork-block-number "$fork_block" \
    --preserve-historical-states \
    --dump-state "$tmp_state" >"$log_file" 2>&1 &
  pid="$!"
  ANVIL_PIDS+=("$pid")

  wait_for_anvil "$rpc_url_local" "$pid" "$log_file"
  actual_chain_id="$(cast chain-id --rpc-url "$rpc_url_local")"
  if [[ "$actual_chain_id" != "$chain_id" ]]; then
    printf 'expected captured %s chain id %s, got %s\n' "$chain_name" "$chain_id" "$actual_chain_id" >&2
    return 1
  fi

  warm_protocol_reads "$rpc_url_local" "$fixture"
  local warm_block
  for warm_block in $(seq 1 "$CAPTURE_WARM_MINED_BLOCKS"); do
    cast rpc --rpc-url "$rpc_url_local" evm_mine >/dev/null
    # Repeat passes cache reads at new block heights; code was validated in the
    # first pass so failures from upstream state pruning are non-fatal here.
    warm_protocol_reads "$rpc_url_local" "$fixture" || true
  done
  local logs_file="${state_file%.json}-logs.json"
  local log_addrs=()
  local _lc; _lc="$(chain_config_for "$chain_id")"
  local _pool; _pool="$(jq -r '.protocols.aave.pool // empty' <<<"$_lc")"
  [[ -n "$_pool" ]] && log_addrs+=("$_pool")
  while IFS= read -r _uni_pool; do
    [[ -z "$_uni_pool" || "$_uni_pool" == "null" ]] && continue
    log_addrs+=("$_uni_pool")
  done < <(jq -r '.protocols.uniswap.pools[]?' <<<"$_lc")
  warm_log_reads "$rpc_url_value" "$logs_file" "$fork_block" "${log_addrs[@]}" || true

  stop_anvil_and_wait_for_dump "$pid" "$tmp_state" "$log_file"
  mv "$tmp_state" "$state_file"
  archive_foundry_cache "$chain_id" "$chain_name" "$fork_block" "$cache_archive"
  if [[ "$ANVIL_CAPTURE_FIND_ACTIVE_BLOCK" == true || "$CAPTURE_USE_LATEST_BLOCK" == true ]]; then
    update_manifest_fork_block "$chain_id" "$fork_block"
    update_manifest_state_file "$chain_id" "$state_file"
  fi
  update_manifest_hash "$chain_id" "$state_file"
  update_manifest_cache_archive "$chain_id" "$cache_archive"
  update_manifest_cache_hash "$chain_id" "$cache_archive"
  anvil_version="$(anvil --version | head -n 1)"
  update_manifest_anvil_version "$chain_id" "$anvil_version"
  update_manifest_warmed_contracts "$chain_id" "$(chain_config_for "$chain_id")"
}

require_command anvil
require_command cast
require_command jq
require_command sha256sum
require_command tar
if [[ "$CAPTURE_MODE" == "synthetic" ]]; then
  require_command python3
fi

if [[ ! -f "$MANIFEST" ]]; then
  printf 'offline Anvil manifest not found: %s\n' "$MANIFEST" >&2
  exit 1
fi

if ! jq -e '.schema_version == "1.0.0" and (.fixtures | type == "array")' "$MANIFEST" >/dev/null; then
  printf 'unsupported offline Anvil manifest schema: %s\n' "$MANIFEST" >&2
  exit 1
fi

mapfile -t fixtures < <(jq -c '.fixtures[]' "$MANIFEST")
if ((${#fixtures[@]} == 0)); then
  printf 'offline Anvil manifest has no fixtures: %s\n' "$MANIFEST" >&2
  exit 1
fi

for fixture in "${fixtures[@]}"; do
  if [[ "$CAPTURE_MODE" == "synthetic" ]]; then
    capture_synthetic_fixture "$fixture"
  else
    capture_fixture "$fixture"
  fi
done

log "Offline Anvil state capture complete"
