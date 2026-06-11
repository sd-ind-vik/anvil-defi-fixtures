# Anvil DeFi Fixtures

Portable offline Anvil nodes for deterministic multi-chain DeFi testing.
Four chains ship as pre-built Docker images — no live RPC required at runtime.

Each fixture includes:
- **State snapshot** — forked at a block with real Aave V3 + Uniswap V3 activity
- **Foundry cache** — warmed contract code, storage slots, and block headers
- **Event log file** — 50-block window of Aave and Uniswap events, served via `eth_getLogs`

## Chains

| Chain | `CHAIN_NAME` | Chain ID | Fork Block | Logs |
|-------|-------------|----------|------------|------|
| Ethereum mainnet | `ethereum` | 1 | 25290309 | 163 |
| Base | `base` | 8453 | 47193640 | 52 |
| Arbitrum One | `arbitrum` | 42161 | 472376266 | 27 |
| Optimism | `optimism` | 10 | 152791326 | 20 |

Fork blocks are chosen with `ANVIL_CAPTURE_FIND_ACTIVE_BLOCK` — the most recent
block in the last 500 that has a `ReserveDataUpdated` event, guaranteeing real
protocol activity rather than a quiet chain tip.

## Quick Start

```bash
# All 4 chains
docker compose up -d

# Single chain
docker compose up -d anvil-ethereum
```

RPC endpoints (host):

| Chain | URL |
|-------|-----|
| Ethereum | `http://127.0.0.1:18545` |
| Base | `http://127.0.0.1:18546` |
| Arbitrum | `http://127.0.0.1:18547` |
| Optimism | `http://127.0.0.1:18548` |

Override ports with env vars: `ANVIL_ETHEREUM_PORT`, `ANVIL_BASE_PORT`, `ANVIL_ARBITRUM_PORT`, `ANVIL_OPTIMISM_PORT`.

Verify:

```bash
cast chain-id    --rpc-url http://127.0.0.1:18545
cast block-number --rpc-url http://127.0.0.1:18545
```

## What Works Offline

**Aave V3**
```bash
# Reserve rates
cast call --rpc-url http://127.0.0.1:18545 \
  0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
  'getReserveData(address)((uint256),uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)' \
  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Oracle price
cast call --rpc-url http://127.0.0.1:18545 \
  0x54586bE62E3c3580375aE3723C145253060Ca0C2 \
  'getAssetPrice(address)(uint256)' \
  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Position health factor
cast call --rpc-url http://127.0.0.1:18545 \
  0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2 \
  'getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)' \
  0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
```

**Uniswap V3**
```bash
# Pool price + liquidity
cast call --rpc-url http://127.0.0.1:18545 \
  0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640 \
  'slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)'
```

**Event logs** (`eth_getLogs` served from the captured log file)
```bash
# Aave ReserveDataUpdated — last 50 blocks
cast rpc --rpc-url http://127.0.0.1:18545 eth_getLogs \
  '{"address":"0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2","topics":["0x804c9b842b2748a22bb64b345453a3de7ca54a6ca45ce00d415894979e22897a"],"fromBlock":"0x181e5e1","toBlock":"0x181e645"}'

# Uniswap Swap events
cast rpc --rpc-url http://127.0.0.1:18545 eth_getLogs \
  '{"address":"0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640","topics":["0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"],"fromBlock":"0x181e5e1","toBlock":"0x181e645"}'
```

**Gas tracking**, **ERC-20 metadata**, **block headers** — all cached and served offline.

## Standalone Ingestor

`scripts/ingest-offline.sh` polls all 4 chains and prints blocks, prices,
reserve APRs, and position health factors to the console — no chain-sentry binary needed.

```bash
# Start anvils first, then:
bash scripts/ingest-offline.sh --no-docker --mine-interval 5
```

Output:
```
[ethereum] BLOCK  #25290310  ts=2026-06-10 23:29:02 UTC  baseFee=0.048 gwei
[ethereum] PRICE  USDC = $1.00
[ethereum] PRICE  WETH = $1,620.19
[ethereum] RESRV  USDC  supplyAPR=8.8287%  varBorrowAPR=10.1236%
[ethereum] POSIT  0xf39fd6e5..  collateral=$0.00  debt=$0.00  HF=∞ (no debt)
```

## Smoke Test

```bash
bash scripts/test-offline-logs.sh --no-docker
```

Verifies `eth_getLogs` for Aave `ReserveDataUpdated` and Uniswap `Swap` events
across all 4 chains. All 16 checks should pass.

## Docker Run (without Compose)

```bash
docker build -t anvil-defi-fixtures:latest .

docker run --rm -p 18545:8545 \
  -e CHAIN_NAME=ethereum \
  anvil-defi-fixtures:latest
```

## Mine Blocks / Send Transactions

The node is a normal Anvil instance after startup:

```bash
# Mine a block
cast rpc --rpc-url http://127.0.0.1:18545 evm_mine

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
3. Warms contract code and storage for Aave V3 (pool, oracle, data provider, aToken / variableDebtToken / stableDebtToken per reserve) and Uniswap V3 (pools, TWAP observations)
4. Dumps state snapshot → `fixtures/anvil-state/<chain>/chain-<id>-block-<n>.json`
5. Packages Foundry RPC cache → `chain-<id>-block-<n>-foundry-cache.tar.gz`
6. Fetches 50-block event window → `chain-<id>-block-<n>-logs.json`
7. Updates `fixtures/anvil-state/manifest.json`

### After Recapture

```bash
docker compose build
docker compose up -d --force-recreate

# Verify
bash scripts/test-offline-logs.sh --no-docker
```

## Offline Scope

The fixtures cache practical DeFi reads — Aave V3 reserves, oracles, user positions,
Uniswap V3 pool state and TWAP observations, ERC-20 metadata, sequencer feeds, and
50 blocks of event logs. They are not complete archive-node snapshots.

If execution touches an uncached storage slot, the shim returns a `-32000` error
(`offline cache miss`). Extend `capture-anvil-state.sh` and recapture to add coverage.

## Publish to GHCR

```bash
docker build -t ghcr.io/<owner>/anvil-defi-fixtures:latest .
docker push ghcr.io/<owner>/anvil-defi-fixtures:latest
```

The included GitHub Actions workflow publishes on tags starting with `v`.
