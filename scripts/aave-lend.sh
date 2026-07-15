#!/usr/bin/env bash
# Lend (supply) an ERC20 to Aave v3 on the anvil fork. Raw JSON-RPC, no cast.
# Sender must be an anvil-unlocked account (dev accounts or impersonated).
# Usage: ./aave-lend.sh [amount] [token_address]
# Env: RPC, FROM, POOL
set -euo pipefail
. "$(dirname "$0")/rpc-lib.sh"

POOL="${POOL:-0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2}"
TOKEN="${2:-0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48}"   # USDC
AMOUNT_HUMAN="${1:-1000}"
FROM="${FROM:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}" # anvil account 0

DECIMALS=$(hex2dec "$(eth_call "$TOKEN" 0x313ce567)")
SYMBOL=$(python3 -c "print(bytes.fromhex('$(eth_call "$TOKEN" 0x95d89b41)'[2:]).replace(b'\x00', b'').decode()[-20:].strip())")
AMOUNT=$(python3 -c "print(int($AMOUNT_HUMAN * 10**$DECIMALS))")

status() {
  local bal collateral
  bal=$(erc20_balance "$TOKEN" "$FROM")
  collateral=$(hex2dec "$(eth_call "$POOL" "0xbf92857c$(pad_addr "$FROM")" | cut -c1-66)")
  echo "--- $1"
  echo "  wallet ${SYMBOL}:      $(python3 -c "print($bal / 10**$DECIMALS)")"
  echo "  total collateral USD: $(python3 -c "print($collateral / 10**8)")"
}

status "before"

if (( $(erc20_balance "$TOKEN" "$FROM") < AMOUNT )); then
  echo "error: wallet holds less than ${AMOUNT_HUMAN} ${SYMBOL} (run usdc-whale-transfer.sh first?)" >&2
  exit 1
fi

send_tx "$FROM" "$TOKEN" "0x095ea7b3$(pad_addr "$POOL")$(pad_uint "$AMOUNT")" > /dev/null
send_tx "$FROM" "$POOL" "0x617ba037$(pad_addr "$TOKEN")$(pad_uint "$AMOUNT")$(pad_addr "$FROM")$(pad_uint 0)" > /dev/null

status "after lending ${AMOUNT_HUMAN} ${SYMBOL}"
