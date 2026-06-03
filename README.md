# Anvil DeFi Fixtures

Portable offline Anvil fixtures for deterministic DeFi development and tests.

This image starts a local Anvil node from cached fork state, backed by a small
fail-closed JSON-RPC shim. It is intended for repeatable local testing without
depending on public RPC endpoints at runtime.

## Included Chains

- Ethereum mainnet, `CHAIN_NAME=ethereum`, chain id `1`
- Base, `CHAIN_NAME=base`, chain id `8453`
- Arbitrum One, `CHAIN_NAME=arbitrum`, chain id `42161`
- Optimism, `CHAIN_NAME=optimism`, chain id `10`

## Run

Build and start Ethereum:

```bash
docker compose up -d anvil-ethereum
```

Check the node:

```bash
cast chain-id --rpc-url http://127.0.0.1:18545
cast block-number --rpc-url http://127.0.0.1:18545
```

Start all chains:

```bash
docker compose up -d
```

RPC ports:

- Ethereum: `http://127.0.0.1:18545`
- Base: `http://127.0.0.1:18546`
- Arbitrum: `http://127.0.0.1:18547`
- Optimism: `http://127.0.0.1:18548`

## Docker Run

```bash
docker build -t anvil-defi-fixtures:latest .

docker run --rm -p 18545:8545 \
  -e CHAIN_NAME=ethereum \
  anvil-defi-fixtures:latest
```

## Send Transactions

The node is a normal Anvil instance after startup, so you can send local
transactions and mine blocks:

```bash
cast rpc --rpc-url http://127.0.0.1:18545 eth_accounts
cast rpc --rpc-url http://127.0.0.1:18545 anvil_mine 1
```

Default Anvil private key:

```text
0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Default account:

```text
0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
```

## Offline Scope

The fixtures include practical warmed DeFi reads for Aave, Uniswap, selected
tokens, and sequencer feeds. They are not complete archive-node snapshots.

If execution touches an uncached contract or storage slot, the shim fails closed
with an offline cache miss. Extend the fixture warmer and recapture if you need
additional protocol coverage.

## Publish To GHCR

```bash
docker build -t ghcr.io/<owner>/anvil-defi-fixtures:offline-defi-v1 .
docker push ghcr.io/<owner>/anvil-defi-fixtures:offline-defi-v1
```

The included GitHub Actions workflow publishes on tags that start with `v`.
