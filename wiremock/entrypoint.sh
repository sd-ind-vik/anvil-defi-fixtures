#!/usr/bin/env bash
set -euo pipefail

CHAIN_DIR="/app/chains/${CHAIN_NAME}"
if [[ ! -d "${CHAIN_DIR}/mappings" ]]; then
  printf 'ERROR: no mappings at %s/mappings\n' "${CHAIN_DIR}" >&2
  exit 1
fi

printf '[entrypoint] chain=%s rpc_port=%s wiremock_port=%s\n' \
  "${CHAIN_NAME}" "${RPC_PORT}" "${WIREMOCK_PORT}"

# Start WireMock with root-dir pointing at the chain directory (which contains mappings/).
java -cp "/var/wiremock/lib/*:/var/wiremock/extensions/*" wiremock.Run \
  --port "${WIREMOCK_PORT}" \
  --root-dir "${CHAIN_DIR}" \
  --global-response-templating \
  &
WM_PID=$!

# Wait up to 30 s for WireMock to accept requests.
for i in $(seq 1 30); do
  if python3 -c "
import urllib.request, sys
try:
    urllib.request.urlopen('http://127.0.0.1:${WIREMOCK_PORT}/__admin/health', timeout=2)
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    printf '[entrypoint] WireMock ready\n'
    break
  fi
  if ! kill -0 "${WM_PID}" 2>/dev/null; then
    printf '[entrypoint] WireMock exited unexpectedly\n' >&2
    exit 1
  fi
  sleep 1
done

# Start ws-bridge in foreground; if it exits the container exits.
printf '[entrypoint] starting ws-bridge on :%s\n' "${RPC_PORT}"
exec python3 /opt/ws-bridge.py
