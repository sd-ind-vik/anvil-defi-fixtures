# Anvil DeFi Fixtures

Portable offline Anvil nodes for deterministic multi-chain DeFi testing.
Four chains ship as pre-built Docker images — no live RPC required at runtime.

Each fixture is a **self-contained state JSON** (`-full.json`) with all Aave V3
and Uniswap V3 contract code and storage slots embedded. Anvil loads it directly
via `--load-state` — no HTTP shim, no Foundry cache, no network calls.

Each fixture includes:
- **Full state snapshot** — enriched with all warmed contract code and storage
- **Event log file** — 50-block window of Aave and Uniswap events
- **Foundry cache archive** — kept for recapture reference

## Chains

| Chain | `CHAIN_NAME` | Chain ID | Fork Block | Logs |
|-------|-------------|----------|------------|------|
| Ethereum mainnet | `ethereum` | 1 | 25295215 | 100 |
| Base | `base` | 8453 | 47201521 | 17 |
| Arbitrum One | `arbitrum` | 42161 | 472420198 | 3 |
| Optimism | `optimism` | 10 | 152810000 | 18 |

## Quick Start

```bash
# All 4 chains
docker compose up -d

# Single chain
docker compose up -d anvil-ethereum
```

RPC endpoints (HTTP and WebSocket on the same port):

| Chain | HTTP | WebSocket |
|-------|------|-----------|
| Ethereum | `http://127.0.0.1:8545` | `ws://127.0.0.1:8545` |
| Base | `http://127.0.0.1:8546` | `ws://127.0.0.1:8546` |
| Arbitrum | `http://127.0.0.1:8547` | `ws://127.0.0.1:8547` |
| Optimism | `http://127.0.0.1:8548` | `ws://127.0.0.1:8548` |

Override ports with env vars: `ANVIL_ETHEREUM_PORT`, `ANVIL_BASE_PORT`, `ANVIL_ARBITRUM_PORT`, `ANVIL_OPTIMISM_PORT`.

Verify:

```bash
cast chain-id     --rpc-url http://127.0.0.1:8545
cast block-number --rpc-url http://127.0.0.1:8545
```

## What Works Offline

**Aave V3**
```bash
# Reserve rates
cast call --rpc-url http://127.0.0.1:8545 \
  0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
  'getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)' \
  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Oracle price
cast call --rpc-url http://127.0.0.1:8545 \
  0x54586bE62E3c3580375aE3723C145253060Ca0C2 \
  'getAssetPrice(address)(uint256)' \
  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# DataProvider reserve config
cast call --rpc-url http://127.0.0.1:8545 \
  0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3 \
  'getReserveConfigurationData(address)(uint256,uint256,uint256,uint256,uint256,bool,bool,bool,bool,bool)' \
  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Position health factor
cast call --rpc-url http://127.0.0.1:8545 \
  0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
  'getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)' \
  0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
```

**Uniswap V3**
```bash
# Pool price + liquidity
cast call --rpc-url http://127.0.0.1:8545 \
  0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640 \
  'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)'

# TWAP observation
cast call --rpc-url http://127.0.0.1:8545 \
  0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640 \
  'observe(uint32[])(int56[],uint160[])' '[300,0]'
```

**Multicall3** (`0xcA11bde05977b3631167028862bE2a173976CA11`) is deployed on all 4 chains.

**Event logs** (`eth_getLogs` served from the captured log file)
```bash
cast rpc --rpc-url http://127.0.0.1:8545 eth_getLogs \
  '{"address":"0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2","topics":["0x804c9b842b2748a22bb64b345453a3de7ca54a6ca45ce00d415894979e22897a"],"fromBlock":"0x181e5e1","toBlock":"0x181e645"}'
```

**Gas tracking**, **ERC-20 metadata**, **block headers** — all served from embedded state.

## Protocol Test Suite

Runs 137 checks across all 4 chains — Aave Oracle, Pool, DataProvider, aToken,
Uniswap V3, Multicall3, ERC20 metadata, and block mining:

```bash
# Build image + run full suite (starts and stops containers automatically)
bash scripts/test-load-state.sh

# Skip rebuild if image is current
bash scripts/test-load-state.sh --skip-build

# Keep containers running after suite
bash scripts/test-load-state.sh --skip-build --keep
```

Expected output:
```
=== load-state protocol test suite ===

[ethereum / chain 1]
  [PASS] ethereum: eth_chainId = 1
  [PASS] ethereum: Oracle.getAssetPrice(0xA0b86991..) = 99972165
  ...

=== Summary ===
  PASS: 137  FAIL: 0  SKIP: 0
```

## Standalone Ingestor

`scripts/ingest-offline.sh` polls all 4 chains and prints blocks, prices,
reserve APRs, and position health factors to the console:

```bash
# Start anvils first, then:
bash scripts/ingest-offline.sh --no-docker --mine-interval 5
```

Output:
```
[ethereum] BLOCK  #25295216  ts=2025-01-15 12:00:00 UTC  baseFee=0.048 gwei
[ethereum] PRICE  USDC = $1.00
[ethereum] PRICE  WETH = $1,648.32
[ethereum] RESRV  USDC  supplyAPR=3.2130%  varBorrowAPR=4.1200%
[ethereum] POSIT  0xf39fd6e5..  collateral=$0.00  debt=$0.00  HF=∞ (no debt)
```

## Docker Run (without Compose)

```bash
docker build -t anvil-defi-fixtures:latest .

docker run --rm -p 8545:8545 \
  -e CHAIN_NAME=ethereum \
  anvil-defi-fixtures:latest
```

## Mine Blocks / Send Transactions

The node is a normal Anvil instance after startup:

```bash
# Mine a block
cast rpc --rpc-url http://127.0.0.1:8545 evm_mine

# Default Anvil account (has ETH)
# Address: 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
# Key:     0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

## Recapturing Fixtures

Recapture when you need a fresher fork block or updated protocol coverage.

### Prerequisites

| Tool | Install |
|------|---------|
| `anvil` + `cast` | `curl -L https://foundry.paradigm.xyz \| bash` |
| `jq` | `brew install jq` / `apt install jq` |
| `python3` | system |
| `sha256sum` | macOS: `brew install coreutils` |
| `tar` | system |

### RPC URLs

The script defaults to public endpoints (may rate-limit on heavy capture). Set your own for reliability:

```bash
export ETH_MAINNET_RPC_URL=https://mainnet.infura.io/v3/<key>
export BASE_RPC_URL=https://base-mainnet.infura.io/v3/<key>
export ARBITRUM_RPC_URL=https://arbitrum-mainnet.infura.io/v3/<key>
export OPTIMISM_RPC_URL=https://optimism-mainnet.infura.io/v3/<key>
```

Public fallbacks (no key needed):
`https://ethereum-rpc.publicnode.com`, `https://base-rpc.publicnode.com`,
`https://arbitrum-one-rpc.publicnode.com`, `https://optimism-rpc.publicnode.com`

### Run

```bash
# All 4 chains — active-block mode (finds most recent block with Aave activity)
ANVIL_CAPTURE_FIND_ACTIVE_BLOCK=true bash scripts/capture-anvil-state.sh

# Single chain by chain ID
ANVIL_CAPTURE_CHAINS=42161 \
ANVIL_CAPTURE_FIND_ACTIVE_BLOCK=true \
bash scripts/capture-anvil-state.sh

# Latest block (no activity scan)
ANVIL_CAPTURE_USE_LATEST_BLOCK=true bash scripts/capture-anvil-state.sh

# Wider event log window (default: 50 blocks)
ANVIL_CAPTURE_LOG_SCAN_DEPTH=100 \
ANVIL_CAPTURE_FIND_ACTIVE_BLOCK=true \
bash scripts/capture-anvil-state.sh
```

### What It Does

For each chain the script:
1. Starts a temporary Anvil fork against the live RPC
2. Selects the most recent block with a `ReserveDataUpdated` event (last 500 blocks)
3. Warms contract code and storage for Aave V3 (pool, oracle, data provider, aToken / variableDebtToken per reserve) and Uniswap V3 (pools, TWAP observations), plus Multicall3
4. Dumps state snapshot → `fixtures/anvil-state/<chain>/chain-<id>-block-<n>.json`
5. Packages Foundry RPC cache → `chain-<id>-block-<n>-foundry-cache.tar.gz`
6. Fetches 50-block event window → `chain-<id>-block-<n>-logs.json`
7. Runs `enrich-state-with-cache.py` to merge the Foundry cache into the state JSON, producing a self-contained `chain-<id>-block-<n>-full.json`
8. Updates `fixtures/anvil-state/manifest.json`

### After Recapture

```bash
docker compose build
docker compose up -d --force-recreate

# Verify all 137 protocol checks pass
bash scripts/test-load-state.sh --skip-build
```

## Offline Scope

The fixtures embed practical DeFi reads — Aave V3 reserves, oracles, data
provider, user positions, Uniswap V3 pool state and TWAP observations, Multicall3,
ERC-20 metadata, and 50 blocks of event logs.

Because the state is fully self-contained, there are no "cache miss" errors — any
storage slot that was warmed during capture is permanently embedded. Slots not
touched during capture return zero (standard EVM default). To add coverage,
extend `capture-anvil-state.sh` and recapture.

## Publish to GHCR

```bash
docker build -t ghcr.io/<owner>/anvil-defi-fixtures:latest .
docker push ghcr.io/<owner>/anvil-defi-fixtures:latest
```

The included GitHub Actions workflow publishes on tags starting with `v`.
