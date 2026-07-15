# rpc-lib.sh — raw JSON-RPC helpers for the anvil fork (curl + jq + python3, no cast).
# Source from other scripts:  . "$(dirname "$0")/rpc-lib.sh"

RPC="${RPC:-http://localhost:8545}"

rpc() {  # rpc <method> [params-json-array]
  local resp
  resp=$(curl -s "$RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}")
  if [[ -n $(jq -r '.error // empty' <<<"$resp") ]]; then
    echo "rpc $1 error: $(jq -c '.error' <<<"$resp")" >&2
    return 1
  fi
  jq -r '.result' <<<"$resp"
}

hex2dec() { python3 -c "print(int('$1', 16))"; }
pad_addr() { printf '%064s' "${1#0x}" | tr ' ' 0; }   # address -> 32-byte hex word
pad_uint() { printf '%064x' "$1"; }                   # decimal -> 32-byte hex word

eth_call() {  # eth_call <to> <calldata>  -> hex result
  rpc eth_call "[{\"to\":\"$1\",\"data\":\"$2\"},\"latest\"]"
}

erc20_balance() {  # erc20_balance <token> <holder>  -> decimal
  hex2dec "$(eth_call "$1" "0x70a08231$(pad_addr "$2")")"
}

send_tx() {  # send_tx <from> <to> <calldata>  — waits for receipt (fork uses interval mining)
  local hash receipt
  hash=$(rpc eth_sendTransaction "[{\"from\":\"$1\",\"to\":\"$2\",\"data\":\"$3\",\"gas\":\"0x7a120\"}]") || return 1
  while :; do
    receipt=$(rpc eth_getTransactionReceipt "[\"$hash\"]")
    [[ "$receipt" != "null" ]] && break
    sleep 1
  done
  if [[ $(jq -r '.status' <<<"$receipt") != "0x1" ]]; then
    echo "tx $hash reverted" >&2
    return 1
  fi
  echo "$hash"
}
