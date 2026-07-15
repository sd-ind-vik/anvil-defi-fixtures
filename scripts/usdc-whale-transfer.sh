#!/usr/bin/env bash
# Transfer USDC from a whale to an anvil account via impersonation. Raw JSON-RPC, no cast.
# Usage: ./usdc-whale-transfer.sh [amount_usdc] [dest_address]
set -euo pipefail
. "$(dirname "$0")/rpc-lib.sh"

USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
WHALE="${WHALE:-0x28C6c06298d514Db089934071355E5743bf21d60}"   # Binance 14
DEST="${2:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"        # anvil account 0
AMOUNT_USDC="${1:-10000}"
AMOUNT=$(( AMOUNT_USDC * 1000000 ))                            # USDC has 6 decimals

fmt_usdc() { printf '%d.%06d USDC' $(( $1 / 1000000 )) $(( $1 % 1000000 )); }

show_balances() {
  echo "--- $1"
  echo "  whale $WHALE: $(fmt_usdc "$(erc20_balance "$USDC" "$WHALE")")"
  echo "  dest  $DEST: $(fmt_usdc "$(erc20_balance "$USDC" "$DEST")")"
}

show_balances "before"

if (( $(erc20_balance "$USDC" "$WHALE") < AMOUNT )); then
  echo "error: whale holds less than ${AMOUNT_USDC} USDC at this block" >&2
  exit 1
fi

rpc anvil_impersonateAccount "[\"$WHALE\"]" > /dev/null
rpc anvil_setBalance "[\"$WHALE\",\"0xde0b6b3a7640000\"]" > /dev/null
show_balances "after impersonate + gas funding (unchanged)"

send_tx "$WHALE" "$USDC" "0xa9059cbb$(pad_addr "$DEST")$(pad_uint "$AMOUNT")" > /dev/null
show_balances "after transfer of ${AMOUNT_USDC} USDC"

rpc anvil_stopImpersonatingAccount "[\"$WHALE\"]" > /dev/null
