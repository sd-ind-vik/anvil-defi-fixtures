#!/usr/bin/env bash
# run-fixtures-ci.sh
#
# Clones sd-ind-vik/anvil-defi-fixtures, builds the Docker image, starts the
# 4 offline Anvil nodes, runs the log-validation test, then runs the offline
# ingestor for a bounded window.
#
# Usage:
#   bash scripts/run-fixtures-ci.sh [OPTIONS]
#
# Options:
#   --ingest-secs N    Seconds to run the ingestor (default: 30)
#   --skip-build       Skip docker build (use existing image)
#   --keep             Keep containers running after script exits
#   --no-clone         Expect repo already cloned in $WORK_DIR
#   --work-dir PATH    Use this directory instead of a temp dir
#
# Requires: git, docker, cast (foundry), python3
set -euo pipefail

REMOTE_URL="https://github.com/sd-ind-vik/anvil-defi-fixtures.git"
INGEST_SECS=30
SKIP_BUILD=false
KEEP_CONTAINERS=false
NO_CLONE=false
WORK_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ingest-secs)  shift; INGEST_SECS="$1" ;;
    --skip-build)   SKIP_BUILD=true ;;
    --keep)         KEEP_CONTAINERS=true ;;
    --no-clone)     NO_CLONE=true ;;
    --work-dir)     shift; WORK_DIR="$1" ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

# ── Workspace ─────────────────────────────────────────────────────────────────

OWNS_WORK=false
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(mktemp -d)"
  OWNS_WORK=true
fi
REPO="$WORK_DIR/repo"

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

# ── 1. Clone ──────────────────────────────────────────────────────────────────

if [[ "$NO_CLONE" == false ]]; then
  log "Clone $REMOTE_URL"
  git clone --depth 1 "$REMOTE_URL" "$REPO"
else
  [[ -d "$REPO" ]] || { printf 'ERROR: --no-clone set but %s does not exist\n' "$REPO" >&2; exit 1; }
  log "Using existing repo at $REPO"
fi

cd "$REPO"

# ── 2. Build ──────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == false ]]; then
  log "Build Docker image"
  docker compose build
fi

# ── 3. Start all 4 nodes ──────────────────────────────────────────────────────

log "Start containers"
docker compose up -d

# ── 4. Wait for all 4 RPCs ────────────────────────────────────────────────────

log "Wait for RPC readiness"
declare -A CHAIN_RPCS=(
  [ethereum]="http://127.0.0.1:18545"
  [base]="http://127.0.0.1:18546"
  [arbitrum]="http://127.0.0.1:18547"
  [optimism]="http://127.0.0.1:18548"
)

for name in ethereum base arbitrum optimism; do
  rpc="${CHAIN_RPCS[$name]}"
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

# ── 5. Log validation ─────────────────────────────────────────────────────────

log "Run log/event validation (test-offline-logs.sh)"
bash scripts/test-offline-logs.sh --no-docker

# ── 6. Offline ingestor ───────────────────────────────────────────────────────

log "Run offline ingestor for ${INGEST_SECS}s (ingest-offline.sh)"
timeout "$INGEST_SECS" bash scripts/ingest-offline.sh --no-docker --mine-interval 3 || {
  code=$?
  # timeout exits 124; anything else is a real error
  [[ $code -eq 124 ]] || { printf 'ingestor exited with code %d\n' "$code" >&2; exit "$code"; }
}

log "CI run complete"
