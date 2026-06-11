#!/usr/bin/env bash
# run-fixtures-ci.sh
#
# Clones sd-ind-vik/anvil-defi-fixtures, builds the Docker image, starts the
# 4 offline Anvil nodes, runs the log-validation test, then runs the offline
# ingestor for a bounded window.
#
# Usage:
#   # From a fresh clone (most common):
#   git clone https://github.com/sd-ind-vik/anvil-defi-fixtures.git
#   bash anvil-defi-fixtures/scripts/run-fixtures-ci.sh --in-place
#
#   # From anywhere (auto-clones):
#   bash scripts/run-fixtures-ci.sh [OPTIONS]
#
# Options:
#   --in-place         Use the repo this script lives in (no clone needed)
#   --ingest-secs N    Seconds to run the ingestor (default: 30)
#   --skip-build       Skip docker build (use existing image)
#   --keep             Keep containers running after script exits
#
# Requires: git, docker, cast (foundry), python3
set -euo pipefail

REMOTE_URL="https://github.com/sd-ind-vik/anvil-defi-fixtures.git"
INGEST_SECS=30
SKIP_BUILD=false
KEEP_CONTAINERS=false
IN_PLACE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in-place)     IN_PLACE=true ;;
    --ingest-secs)  shift; INGEST_SECS="$1" ;;
    --skip-build)   SKIP_BUILD=true ;;
    --keep)         KEEP_CONTAINERS=true ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

# ── Workspace ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$IN_PLACE" == true ]]; then
  REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
  OWNS_WORK=false
  WORK_DIR="$REPO"
else
  WORK_DIR="$(mktemp -d)"
  REPO="$WORK_DIR/repo"
  OWNS_WORK=true
fi

cleanup() {
  if [[ "$KEEP_CONTAINERS" == false ]] && [[ -d "$REPO" ]]; then
    printf '\n==> Stopping containers\n'
    docker compose -f "$REPO/docker-compose.yml" down --remove-orphans 2>/dev/null || true
  fi
  if [[ "$OWNS_WORK" == true ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

log() { printf '\n==> %s\n' "$1"; }

# macOS: no 'timeout'; use gtimeout (brew install coreutils) or python3 fallback.
# The python3 path uses start_new_session + killpg so the entire process tree
# (including background miner_loop children) is killed on timeout.
run_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"; return $?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"; return $?
  fi
  python3 - "$secs" "$@" <<'PY'
import sys, subprocess, os, signal
secs = int(sys.argv[1])
cmd  = sys.argv[2:]
try:
    p = subprocess.Popen(cmd, start_new_session=True)
    p.wait(timeout=secs)
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    os.killpg(os.getpgid(p.pid), signal.SIGTERM)
    try:
        p.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    sys.exit(124)
PY
}

# macOS bash 3.2 has no associative arrays — use a function instead
chain_rpc() {
  case "$1" in
    ethereum) echo "http://127.0.0.1:8545" ;;
    base)     echo "http://127.0.0.1:8546" ;;
    arbitrum) echo "http://127.0.0.1:8547" ;;
    optimism) echo "http://127.0.0.1:8548" ;;
  esac
}

# ── 1. Clone ──────────────────────────────────────────────────────────────────

if [[ "$IN_PLACE" == true ]]; then
  log "Using repo at $REPO"
else
  log "Clone $REMOTE_URL"
  git clone --depth 1 "$REMOTE_URL" "$REPO"
fi

cd "$REPO"

# ── 2. Build ──────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == false ]]; then
  log "Build Docker image"
  docker compose build
fi

# ── 3. Protocol test suite (load-state) ───────────────────────────────────────

log "Run protocol test suite (test-load-state.sh)"
bash scripts/test-load-state.sh --skip-build

# ── 4. Offline ingestor ───────────────────────────────────────────────────────

log "Start containers for ingestor run"
docker compose up -d

log "Wait for RPC readiness"
for name in ethereum base arbitrum optimism; do
  rpc="$(chain_rpc "$name")"
  printf '  waiting for %s (%s)...' "$name" "$rpc"
  ready=false
  for i in $(seq 1 90); do
    if cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" == true ]]; then
    block="$(cast block-number --rpc-url "$rpc" 2>/dev/null || echo '?')"
    printf ' ready  block=%s\n' "$block"
  else
    printf ' TIMEOUT\n'
    docker compose logs --tail 30 "anvil-$name" || true
    exit 1
  fi
done

log "Run offline ingestor for ${INGEST_SECS}s (ingest-offline.sh)"
run_timeout "$INGEST_SECS" bash scripts/ingest-offline.sh --no-docker --mine-interval 3 || {
  code=$?
  # timeout exits 124; gtimeout also 124; manual fallback exits 143 (SIGTERM)
  [[ $code -eq 124 || $code -eq 143 ]] || { printf 'ingestor exited with code %d\n' "$code" >&2; exit "$code"; }
}

log "CI run complete"
