#!/usr/bin/env python3
"""Tail Aave v3 Pool position events (Supply/Withdraw/Borrow/Repay/Liquidation).

Run in a separate terminal:  ./scripts/aave-position-monitor.py
Env: RPC (default http://localhost:8545), POOL, POLL_SECS
"""
import json
import os
import sys
import time
import urllib.request

sys.stdout.reconfigure(line_buffering=True)

RPC = os.environ.get("RPC", "http://localhost:8545")
POOL = os.environ.get("POOL", "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2")
POLL_SECS = float(os.environ.get("POLL_SECS", "2"))

# topic0 -> (name, user_topic_idx, amount_data_word, sign); precomputed via `cast keccak`
# sign: position delta direction (+supply/+borrow grows the position, withdraw/repay shrinks it)
EVENTS = {
    "0x2b627736bca15cd5381dcf80b0bf11fd197d01a037c52b927a881a10fb73ba61": ("Supply", 2, 1, +1),
    "0x3115d1449a7b732c986cba18244e897a450f61e1bb8d589cd2e69e6c8924f9f7": ("Withdraw", 2, 0, -1),
    "0xb3d084820fb1a9decffb176436bd02558d15fac9b0ddfed8c465bc7359d7dce0": ("Borrow", 2, 1, +1),
    "0xa534c8dbe71f871f9f3530e97a74601fea17b426cae02e1c5aee42c96c784051": ("Repay", 2, 0, -1),
    "0xe413a321e8681d831f4dbccbca790d2952b56f977908e45be37335533e005286": ("LiquidationCall", 3, 0, -1),
}

_id = 0
def rpc(method, params):
    global _id
    _id += 1
    req = urllib.request.Request(
        RPC,
        json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params}).encode(),
        {"Content-Type": "application/json"},
    )
    body = json.loads(urllib.request.urlopen(req, timeout=10).read())
    if "error" in body:
        raise RuntimeError(f"{method}: {body['error']}")
    return body["result"]

def topic_addr(topic):
    return "0x" + topic[-40:]

def data_word(data, i):
    return int(data[2 + 64 * i : 2 + 64 * (i + 1)], 16)

_reserves = {}
def reserve_info(addr):
    """symbol + decimals, cached; falls back to short address."""
    if addr not in _reserves:
        try:
            sym_hex = rpc("eth_call", [{"to": addr, "data": "0x95d89b41"}, "latest"])  # symbol()
            sym = bytes.fromhex(sym_hex[2:]).replace(b"\x00", b"").decode()[-20:].strip() or addr[:10]
            dec = int(rpc("eth_call", [{"to": addr, "data": "0x313ce567"}, "latest"]), 16)  # decimals()
        except Exception:
            sym, dec = addr[:10], 18
        _reserves[addr] = (sym, dec)
    return _reserves[addr]

def main():
    last = int(rpc("eth_blockNumber", []), 16)
    print(f"watching Aave Pool {POOL} on {RPC} from block {last + 1} ...")
    while True:
        head = int(rpc("eth_blockNumber", []), 16)
        if head > last:
            logs = rpc("eth_getLogs", [{
                "address": POOL,
                "fromBlock": hex(last + 1),
                "toBlock": hex(head),
                "topics": [list(EVENTS)],
            }])
            for log in logs:
                name, user_idx, amt_word, sign = EVENTS[log["topics"][0]]
                reserve = topic_addr(log["topics"][1])
                sym, dec = reserve_info(reserve)
                amount = data_word(log["data"], amt_word) / 10**dec
                user = topic_addr(log["topics"][user_idx])
                # user's wallet balance of the reserve token after this block
                bal_hex = rpc("eth_call", [{
                    "to": reserve,
                    "data": "0x70a08231" + user[2:].rjust(64, "0"),  # balanceOf(user)
                }, log["blockNumber"]])
                wallet = int(bal_hex, 16) / 10**dec
                receipt = rpc("eth_getTransactionReceipt", [log["transactionHash"]])
                gas_used = int(receipt["gasUsed"], 16)
                gas_eth = gas_used * int(receipt["effectiveGasPrice"], 16) / 1e18
                print(f"block {int(log['blockNumber'], 16)}  {name:<16} {sign * amount:>+16.6f} {sym:<6}"
                      f" wallet={wallet:.6f} {sym}  user={user}"
                      f"  gas={gas_used} ({gas_eth:.6f} ETH)  tx={log['transactionHash']}")
            last = head
        time.sleep(POLL_SECS)

if __name__ == "__main__":
    main()
