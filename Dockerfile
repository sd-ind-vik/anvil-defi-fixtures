FROM ghcr.io/foundry-rs/foundry:v1.5.1 AS foundry

FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=foundry /usr/local/bin/anvil /usr/local/bin/anvil
COPY --from=foundry /usr/local/bin/cast /usr/local/bin/cast

WORKDIR /app
COPY fixtures/anvil-state /app/fixtures/anvil-state
COPY scripts/offline-anvil-rpc-shim.py /usr/local/bin/offline-anvil-rpc-shim.py
COPY scripts/start-offline-anvil.sh /usr/local/bin/start-offline-anvil.sh

RUN chmod +x /usr/local/bin/offline-anvil-rpc-shim.py /usr/local/bin/start-offline-anvil.sh

ENV ANVIL_OFFLINE_STATE_MANIFEST=/app/fixtures/anvil-state/manifest.json \
    CHAIN_NAME=ethereum \
    RPC_HOST=0.0.0.0 \
    RPC_PORT=8545 \
    SHIM_HOST=127.0.0.1 \
    SHIM_PORT=18549 \
    CACHE_ROOT=/tmp/chainsentry-foundry-cache \
    ANVIL_OFFLINE_MODE=cache-fork \
    ANVIL_FORK_TIMEOUT_MS=5000 \
    ANVIL_FORK_RETRIES=2

EXPOSE 8545

HEALTHCHECK --interval=5s --timeout=5s --start-period=10s --retries=6 \
  CMD cast chain-id --rpc-url "http://127.0.0.1:${RPC_PORT}" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/start-offline-anvil.sh"]
