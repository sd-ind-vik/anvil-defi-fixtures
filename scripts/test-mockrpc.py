#!/usr/bin/env python3
"""
Integration test: WebSocket newHeads + full Aave eth_calls via Multicall3.

Flow
----
1.  Connect WebSocket, subscribe eth_subscribe("newHeads")
2.  Mine 3 blocks via HTTP evm_mine; receive newHeads for each
3.  For every block, send ONE Multicall3 aggregate3 batch that covers:
      - getReserveData(asset)                 → pool
      - getReserveConfigurationData(asset)    → data_provider
      - getReserveCaps(asset)                 → data_provider
      - getReserveTokensAddresses(asset)      → data_provider
      - getAssetPrice(asset)                  → oracle
    for every key_reserve, PLUS getUserAccountData for a warm account.
4.  Parse aggregate3 results (success flag + return bytes).
5.  Also exercise individual eth_calls that match recorded stubs directly.
"""

import argparse
import asyncio
import json
import struct
import sys
import urllib.request
from typing import Any

import aiohttp

MULTICALL3    = "0xca11bde05977b3631167028862be2a173976ca11"
AAVE_POOL     = "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2"
AAVE_ORACLE   = "0x54586be62e3c3580375ae3723c145253060ca0c2"
AAVE_DATA     = "0x7b4eb56e7cd4b454ba8ff71e4518426369a138a3"
WARM_ACCOUNT  = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

KEY_RESERVES = [
    ("USDC",   "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
    ("DAI",    "0x6b175474e89094c44da98b954eedeac495271d0f"),
    ("WETH",   "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"),
    ("WBTC",   "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599"),
    ("wstETH", "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0"),
    ("USDT",   "0xdac17f958d2ee523a2206206994597c13d831ec7"),
    ("cbBTC",  "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf"),
    ("LINK",   "0x514910771af9ca656af840dff83e8264ecf986ca"),
    ("AAVE",   "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9"),
    ("USDe",   "0x4c9edd5852cd905f086c759e8383e09bff1e68b3"),
    ("sUSDe",  "0x9d39a5de30e57443bff2a8307a4256c8797a3497"),
    ("sDAI",   "0x83f20f44975d03b1b09e64809b757c47f942beea"),
]

# 4-byte selectors
SEL = {
    "getReserveData":               bytes.fromhex("35ea6a75"),
    "getReserveConfigurationData":  bytes.fromhex("3e150141"),
    "getReserveCaps":               bytes.fromhex("f4112916"),
    "getReserveTokensAddresses":    bytes.fromhex("d2493b6c"),
    "getAssetPrice":                bytes.fromhex("b3596f07"),
    "getUserAccountData":           bytes.fromhex("bf92857c"),
    "aggregate3":                   bytes.fromhex("82ad56cb"),
    "decimals":                     bytes.fromhex("313ce567"),
    "symbol":                       bytes.fromhex("95d89b41"),
    "totalSupply":                  bytes.fromhex("18160ddd"),
}


# ── ABI helpers ────────────────────────────────────────────────────────────────

def _w(n: int) -> bytes:
    return n.to_bytes(32, "big")


def _addr_word(addr: str) -> bytes:
    return bytes.fromhex(addr.removeprefix("0x").zfill(64))


def _calldata(sel_name: str, *args: bytes) -> bytes:
    return SEL[sel_name] + b"".join(args)


def _abi_encode_aggregate3(calls: list[tuple[str, bool, bytes]]) -> bytes:
    """
    Encode aggregate3((address,bool,bytes)[]) calldata.
    Layout: selector | offset(0x20) | n | [n×tuple_offset] | [n×tuple_body]
    Each tuple_body: addr(32) + bool(32) + bytes_offset(3*32=96) + len(32) + data_padded
    """
    n = len(calls)
    tuple_bodies: list[bytes] = []
    offsets: list[int] = []
    current = n * 32          # start of first tuple body, measured from after offset table

    for addr, allow_fail, data in calls:
        addr_w   = _addr_word(addr)
        bool_w   = _w(int(allow_fail))
        data_off = _w(3 * 32)            # bytes field offset within this tuple
        data_len = _w(len(data))
        pad      = (32 - len(data) % 32) % 32
        body = addr_w + bool_w + data_off + data_len + data + b"\x00" * pad
        offsets.append(current)
        tuple_bodies.append(body)
        current += len(body)

    offset_table = b"".join(_w(o) for o in offsets)
    array_data   = _w(n) + offset_table + b"".join(tuple_bodies)
    return SEL["aggregate3"] + _w(0x20) + array_data


def build_aave_batch() -> tuple[bytes, list[str]]:
    """Return (calldata, label_list) for the Multicall3 Aave batch."""
    calls: list[tuple[str, bool, bytes]] = []
    labels: list[str] = []

    for sym, addr in KEY_RESERVES:
        calls.append((AAVE_POOL,   True, _calldata("getReserveData",              _addr_word(addr))))
        labels.append(f"getReserveData({sym})")

        calls.append((AAVE_DATA,   True, _calldata("getReserveConfigurationData", _addr_word(addr))))
        labels.append(f"getReserveConfigurationData({sym})")

        calls.append((AAVE_DATA,   True, _calldata("getReserveCaps",              _addr_word(addr))))
        labels.append(f"getReserveCaps({sym})")

        calls.append((AAVE_DATA,   True, _calldata("getReserveTokensAddresses",   _addr_word(addr))))
        labels.append(f"getReserveTokensAddresses({sym})")

        calls.append((AAVE_ORACLE, True, _calldata("getAssetPrice",               _addr_word(addr))))
        labels.append(f"getAssetPrice({sym})")

    calls.append((AAVE_POOL, True, _calldata("getUserAccountData", _addr_word(WARM_ACCOUNT))))
    labels.append("getUserAccountData(warm)")

    return _abi_encode_aggregate3(calls), labels


def parse_aggregate3_result(hex_result: str) -> list[tuple[bool, bytes]]:
    """Decode aggregate3 return value: (bool success, bytes returnData)[]."""
    if not hex_result or hex_result == "0x":
        return []
    raw = bytes.fromhex(hex_result.removeprefix("0x"))
    if len(raw) < 64:
        return []
    # outer offset = raw[0:32], array len = raw[32:64]
    arr_offset = int.from_bytes(raw[0:32], "big")
    n          = int.from_bytes(raw[arr_offset: arr_offset + 32], "big")
    base       = arr_offset + 32   # start of offset table

    results: list[tuple[bool, bytes]] = []
    for i in range(n):
        if base + i * 32 + 32 > len(raw):
            break
        elem_off = int.from_bytes(raw[base + i*32: base + i*32 + 32], "big")
        elem_abs = arr_offset + 32 + elem_off
        if elem_abs + 64 > len(raw):
            results.append((False, b""))
            continue
        success  = bool(int.from_bytes(raw[elem_abs:      elem_abs + 32], "big"))
        data_off = int.from_bytes(raw[elem_abs + 32: elem_abs + 64], "big")
        data_abs = elem_abs + data_off
        if data_abs + 32 > len(raw):
            results.append((success, b""))
            continue
        data_len = int.from_bytes(raw[data_abs: data_abs + 32], "big")
        data     = raw[data_abs + 32: data_abs + 32 + data_len]
        results.append((success, data))
    return results


def fmt_price(data: bytes) -> str:
    if len(data) >= 32:
        raw = int.from_bytes(data[:32], "big")
        return f"${raw / 1e8:,.2f}"
    return "(no data)"


def fmt_uint(data: bytes, decimals: int = 0, label: str = "") -> str:
    if len(data) >= 32:
        v = int.from_bytes(data[:32], "big")
        if decimals:
            return f"{v / 10**decimals:,.6f}{label}"
        return str(v)
    return "(no data)"


# ── RPC helpers ────────────────────────────────────────────────────────────────

_id_counter = 0

def _next_id() -> int:
    global _id_counter
    _id_counter += 1
    return _id_counter


def rpc_http(url: str, method: str, params: list) -> Any:
    body = json.dumps({"jsonrpc": "2.0", "id": _next_id(),
                        "method": method, "params": params}).encode()
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


async def rpc_ws(ws, method: str, params: list) -> Any:
    msg = json.dumps({"jsonrpc": "2.0", "id": _next_id(),
                       "method": method, "params": params})
    await ws.send_str(msg)
    raw = await asyncio.wait_for(ws.receive(), timeout=10)
    return json.loads(raw.data)


# ── main test ──────────────────────────────────────────────────────────────────

async def run_test(host: str, port: int) -> None:
    ws_url   = f"ws://{host}:{port}"
    http_url = f"http://{host}:{port}"

    # ── HTTP smoke checks ────────────────────────────────────────────────
    chain_id  = int(rpc_http(http_url, "eth_chainId",    []         )["result"], 16)
    block_num = int(rpc_http(http_url, "eth_blockNumber", []        )["result"], 16)
    gas_price = int(rpc_http(http_url, "eth_gasPrice",   []         )["result"], 16)
    print(f"[http] chainId={chain_id}  blockNumber={block_num}  gasPrice={gas_price/1e9:.2f} gwei")

    # Quick individual call to verify a recorded stub
    price_data = "0x" + (SEL["getAssetPrice"] + _addr_word(KEY_RESERVES[0][1])).hex()
    resp = rpc_http(http_url, "eth_call",
                    [{"to": AAVE_ORACLE, "data": price_data}, "latest"])
    raw_price = resp.get("result", "0x")
    usdc_price = int(raw_price, 16) if raw_price and raw_price != "0x" else 0
    print(f"[http] USDC oracle price (individual stub) = {usdc_price/1e8:.4f} USD  "
          f"{'✓ LIVE DATA' if usdc_price > 0 else '✗ catch-all (stub not matched)'}")

    # ── WebSocket flow ───────────────────────────────────────────────────
    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(ws_url) as ws:
            print(f"\n[ws] connected")

            sub_resp = await rpc_ws(ws, "eth_subscribe", ["newHeads"])
            sub_id   = sub_resp["result"]
            print(f"[ws] subscribed newHeads → {sub_id}")

            blocks_received: list[dict] = []

            async def mine_and_collect(n: int) -> None:
                for i in range(n):
                    await asyncio.sleep(0.15)
                    rpc_http(http_url, "evm_mine", [])

                while len(blocks_received) < n:
                    msg  = await asyncio.wait_for(ws.receive(), timeout=10)
                    data = json.loads(msg.data)
                    if data.get("method") == "eth_subscription":
                        blk = data["params"]["result"]
                        blocks_received.append(blk)
                        blk_num = int(blk["number"], 16) if blk else None
                        print(f"[ws] newHeads #{len(blocks_received)}  "
                              f"blockNumber={blk_num}  "
                              f"hash={blk['hash'][:18] if blk else 'none'}…")

            await mine_and_collect(3)

            # ── Multicall3 Aave batch for each received block ─────────────
            calldata, labels = build_aave_batch()
            calldata_hex = "0x" + calldata.hex()

            print(f"\n[multicall3] batch size: {len(labels)} calls")

            for blk in blocks_received:
                blk_tag = blk["number"]
                resp    = await rpc_ws(ws, "eth_call",
                                       [{"to": MULTICALL3, "data": calldata_hex}, blk_tag])
                result  = resp.get("result", "0x")
                decoded = parse_aggregate3_result(result)

                hit_count = sum(1 for ok, d in decoded if ok and len(d) > 0)
                print(f"\n  block {int(blk_tag,16)}  →  "
                      f"{hit_count}/{len(decoded)} non-empty results "
                      f"({'LIVE' if hit_count > 0 else 'catch-all'})")

                if hit_count > 0:
                    # Print highlights per reserve
                    idx = 0
                    for sym, _ in KEY_RESERVES:
                        # getReserveData
                        ok, data = decoded[idx] if idx < len(decoded) else (False, b"")
                        idx += 3  # skip cfg, caps
                        # getReserveTokensAddresses
                        idx += 1
                        # getAssetPrice
                        ok_p, price_bytes = decoded[idx] if idx < len(decoded) else (False, b"")
                        idx += 1
                        if ok_p and price_bytes:
                            price_usd = int.from_bytes(price_bytes[:32], "big") / 1e8
                            print(f"    {sym:8s}  price=${price_usd:>12,.4f}")

                    # getUserAccountData
                    ok_u, ud = decoded[-1] if decoded else (False, b"")
                    if ok_u and len(ud) >= 192:
                        total_collateral = int.from_bytes(ud[0:32],   "big") / 1e8
                        total_debt       = int.from_bytes(ud[32:64],  "big") / 1e8
                        available_borrow = int.from_bytes(ud[64:96],  "big") / 1e8
                        health_factor    = int.from_bytes(ud[160:192],"big") / 1e18
                        print(f"    warm acct: collateral=${total_collateral:,.2f}  "
                              f"debt=${total_debt:,.2f}  "
                              f"availBorrow=${available_borrow:,.2f}  "
                              f"HF={health_factor:.4f}")

            # ── Clean up ─────────────────────────────────────────────────
            await rpc_ws(ws, "eth_unsubscribe", [sub_id])
            print("\n[ws] unsubscribed")

    print("\nTest PASSED.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9545)
    args = parser.parse_args()
    asyncio.run(run_test(args.host, args.port))


if __name__ == "__main__":
    main()
