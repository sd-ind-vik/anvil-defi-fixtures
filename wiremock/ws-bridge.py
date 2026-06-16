#!/usr/bin/env python3
"""
ws-bridge: WebSocket ↔ WireMock HTTP bridge for Ethereum JSON-RPC.

Listens on LISTEN_PORT (default 8545) for both plain HTTP and WebSocket
connections.  All JSON-RPC methods are forwarded to WireMock (WIREMOCK_URL,
default http://127.0.0.1:8080) except:

  eth_subscribe   — handled locally; returns a subscription ID
  eth_unsubscribe — handled locally; cancels the subscription
  evm_mine / hardhat_mine / anvil_mine
                  — forwarded to WireMock (advances scenario state),
                    then pushes an eth_subscription newHeads notification
                    to every active "newHeads" WebSocket subscriber.
"""

import asyncio
import json
import logging
import os
import secrets
import sys

import aiohttp
from aiohttp import web, WSMsgType

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format="%(asctime)s ws-bridge %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)

WIREMOCK_URL = os.environ.get("WIREMOCK_URL", "http://127.0.0.1:8080")
LISTEN_HOST  = os.environ.get("WS_HOST", "0.0.0.0")
LISTEN_PORT  = int(os.environ.get("WS_PORT", "8545"))

# ── subscription state ────────────────────────────────────────────────────────
# sub_id → {"type": "newHeads"|"logs", "ws": aiohttp.WebSocketResponse,
#            "addr_filter": set[str] | None}
_subscriptions: dict = {}
# ws → set of sub_ids  (for cleanup on disconnect)
_conn_subs: dict = {}
_sub_lock = asyncio.Lock()


async def _register_sub(kind: str, ws, addr_filter=None) -> str:
    sub_id = "0x" + secrets.token_hex(16)
    async with _sub_lock:
        _subscriptions[sub_id] = {"type": kind, "ws": ws, "addr_filter": addr_filter}
        _conn_subs.setdefault(ws, set()).add(sub_id)
    return sub_id


async def _remove_sub(sub_id: str) -> bool:
    async with _sub_lock:
        sub = _subscriptions.pop(sub_id, None)
        if sub is None:
            return False
        _conn_subs.get(sub["ws"], set()).discard(sub_id)
    return True


async def _cleanup_conn(ws) -> None:
    async with _sub_lock:
        for sub_id in list(_conn_subs.pop(ws, [])):
            _subscriptions.pop(sub_id, None)


# ── WireMock proxy ────────────────────────────────────────────────────────────

_session: aiohttp.ClientSession | None = None


async def _get_session() -> aiohttp.ClientSession:
    global _session
    if _session is None or _session.closed:
        _session = aiohttp.ClientSession()
    return _session


async def _call_wiremock(payload) -> dict:
    session = await _get_session()
    try:
        async with session.post(
            WIREMOCK_URL,
            json=payload,
            headers={"Content-Type": "application/json"},
        ) as resp:
            return await resp.json(content_type=None)
    except Exception as exc:
        log.error("WireMock call failed: %s", exc)
        id_ = payload.get("id") if isinstance(payload, dict) else None
        return {
            "jsonrpc": "2.0",
            "id": id_,
            "error": {"code": -32603, "message": f"upstream error: {exc}"},
        }


# ── newHeads push ─────────────────────────────────────────────────────────────

async def _push_new_heads() -> None:
    # Fetch the current block from WireMock to build the notification payload.
    block_resp = await _call_wiremock({
        "jsonrpc": "2.0",
        "method": "eth_getBlockByNumber",
        "params": ["latest", False],
        "id": 0,
    })
    block = block_resp.get("result")

    dead_ids = []
    async with _sub_lock:
        targets = [
            (sid, sub)
            for sid, sub in _subscriptions.items()
            if sub["type"] == "newHeads"
        ]

    for sub_id, sub in targets:
        notification = json.dumps({
            "jsonrpc": "2.0",
            "method": "eth_subscription",
            "params": {"subscription": sub_id, "result": block},
        })
        try:
            await sub["ws"].send_str(notification)
        except Exception:
            dead_ids.append(sub_id)

    for sub_id in dead_ids:
        await _remove_sub(sub_id)


# ── Multicall3 aggregate3 dispatcher ─────────────────────────────────────────

MULTICALL3_ADDR   = "0xca11bde05977b3631167028862be2a173976ca11"
AGG3_SELECTOR     = bytes.fromhex("82ad56cb")   # aggregate3((address,bool,bytes)[])
_mc3_call_counter = 0


def _decode_aggregate3(data_hex: str) -> list[tuple[str, bool, bytes]] | None:
    """
    Parse aggregate3 calldata.
    Returns list of (to_addr, allowFailure, callBytes) or None if unrecognised.
    """
    try:
        raw = bytes.fromhex(data_hex.removeprefix("0x"))
        if len(raw) < 4 or raw[:4] != AGG3_SELECTOR:
            return None
        body = raw[4:]   # after selector

        def u256(b: bytes, off: int) -> int:
            return int.from_bytes(b[off: off + 32], "big")

        arr_off = u256(body, 0)          # outer offset (should be 0x20)
        n       = u256(body, arr_off)
        base    = arr_off + 32           # start of offset table

        calls: list[tuple[str, bool, bytes]] = []
        for i in range(n):
            tup_off   = u256(body, base + i * 32)
            tup_start = arr_off + 32 + tup_off
            addr_raw  = body[tup_start:      tup_start + 32]
            allow_raw = body[tup_start + 32: tup_start + 64]
            data_poff = u256(body, tup_start + 64)   # offset to bytes, from start of tuple
            data_abs  = tup_start + data_poff
            data_len  = u256(body, data_abs)
            call_data = body[data_abs + 32: data_abs + 32 + data_len]
            addr = "0x" + addr_raw[12:].hex()
            allow = bool(int.from_bytes(allow_raw, "big"))
            calls.append((addr, allow, call_data))
        return calls
    except Exception:
        return None


def _encode_aggregate3_result(results: list[tuple[bool, bytes]]) -> str:
    """Encode (bool success, bytes returnData)[] as aggregate3 return value."""
    n = len(results)
    # outer offset = 0x20
    parts: list[bytes] = []

    def w(n: int) -> bytes:
        return n.to_bytes(32, "big")

    # Build each tuple body first to know offsets.
    bodies: list[bytes] = []
    for success, data in results:
        pad     = (32 - len(data) % 32) % 32 if data else 0
        # tuple: success(32) + offset_to_bytes(32) + len(32) + data_padded
        body = w(int(success)) + w(64) + w(len(data)) + data + b"\x00" * pad
        bodies.append(body)

    # Offset table: each entry = distance from start of array body (after len word).
    offsets: list[int] = []
    offset_table_size = n * 32
    current = offset_table_size
    for body in bodies:
        offsets.append(current)
        current += len(body)

    offset_table = b"".join(w(o) for o in offsets)
    arr_data     = w(n) + offset_table + b"".join(bodies)

    # Full return: outer_offset(32) + arr_data
    full = w(0x20) + arr_data
    return "0x" + full.hex()


async def _dispatch_multicall3(req: dict) -> dict | None:
    """
    If req is an eth_call to Multicall3 aggregate3, decompose sub-calls,
    run each against WireMock, re-pack and return.  Returns None if req
    is not a recognised aggregate3 call.
    """
    global _mc3_call_counter
    params = req.get("params", [])
    if not params or not isinstance(params[0], dict):
        return None
    tx    = params[0]
    to    = (tx.get("to") or "").lower()
    data  = tx.get("data") or ""
    if to != MULTICALL3_ADDR:
        return None
    calls = _decode_aggregate3(data)
    if calls is None:
        return None

    _mc3_call_counter += 1
    log.info("multicall3 aggregate3: decomposing %d sub-calls", len(calls))
    block_tag = params[1] if len(params) > 1 else "latest"

    # Fan out all sub-calls to WireMock concurrently.
    async def _sub_call(idx: int, sub_to: str, allow: bool, sub_data: bytes) -> tuple[bool, bytes]:
        sub_req = {
            "jsonrpc": "2.0",
            "id": idx + 1,       # must be an integer so WireMock templates it without quotes
            "method": "eth_call",
            "params": [{"to": sub_to.lower(), "data": "0x" + sub_data.hex()}, block_tag],
        }
        resp    = await _call_wiremock(sub_req)
        err     = resp.get("error")
        if err:
            if allow:
                return (False, b"")
            # propagate as top-level error
            raise RuntimeError(f"sub-call {idx} failed: {err}")
        result_hex = resp.get("result", "0x")
        result_bytes = bytes.fromhex(result_hex.removeprefix("0x")) if result_hex else b""
        return (True, result_bytes)

    tasks = [_sub_call(i, t, a, d) for i, (t, a, d) in enumerate(calls)]
    try:
        sub_results: list[tuple[bool, bytes]] = list(await asyncio.gather(*tasks))
    except RuntimeError as exc:
        return {
            "jsonrpc": "2.0",
            "id": req.get("id"),
            "error": {"code": -32000, "message": str(exc)},
        }

    return {
        "jsonrpc": "2.0",
        "id": req.get("id"),
        "result": _encode_aggregate3_result(sub_results),
    }


# ── per-request dispatch ──────────────────────────────────────────────────────

async def _dispatch(req: dict, ws=None) -> dict:
    method = req.get("method", "")
    req_id = req.get("id")

    # WebSocket-only methods
    if method == "eth_subscribe":
        if ws is None:
            return {
                "jsonrpc": "2.0", "id": req_id,
                "error": {"code": -32601,
                          "message": "eth_subscribe requires a WebSocket connection"},
            }
        params = req.get("params", [])
        if not params:
            return {"jsonrpc": "2.0", "id": req_id,
                    "error": {"code": -32602, "message": "missing subscription type"}}
        kind = params[0]
        if kind not in ("newHeads", "logs"):
            return {"jsonrpc": "2.0", "id": req_id,
                    "error": {"code": -32602,
                              "message": f"unsupported subscription: {kind}"}}
        addr_filter = None
        if kind == "logs" and len(params) > 1:
            raw_addr = params[1].get("address")
            if isinstance(raw_addr, str):
                addr_filter = {raw_addr.lower()}
            elif isinstance(raw_addr, list):
                addr_filter = {a.lower() for a in raw_addr}
        sub_id = await _register_sub(kind, ws, addr_filter)
        return {"jsonrpc": "2.0", "id": req_id, "result": sub_id}

    if method == "eth_unsubscribe":
        params = req.get("params", [])
        found = await _remove_sub(params[0]) if params else False
        return {"jsonrpc": "2.0", "id": req_id, "result": found}

    # Mining: forward to WireMock (scenario advance) then push newHeads
    if method in ("evm_mine", "hardhat_mine", "anvil_mine"):
        result = await _call_wiremock(req)
        await _push_new_heads()
        return result

    # Multicall3 aggregate3: decompose and fan out sub-calls
    if method == "eth_call":
        mc3_resp = await _dispatch_multicall3(req)
        if mc3_resp is not None:
            return mc3_resp

    # Everything else goes straight to WireMock
    return await _call_wiremock(req)


async def _handle_one(payload: dict, ws=None) -> dict:
    """Handle a single JSON-RPC object. ws is set for WebSocket callers."""
    return await _dispatch(payload, ws)


async def _handle_batch(batch: list, ws=None) -> list:
    return list(await asyncio.gather(*[_handle_one(r, ws) for r in batch]))


# ── HTTP handler ──────────────────────────────────────────────────────────────

async def http_handler(request: web.Request) -> web.Response:
    try:
        raw = await request.json()
    except Exception:
        return web.Response(
            status=400,
            content_type="application/json",
            text=json.dumps({"jsonrpc": "2.0", "id": None,
                             "error": {"code": -32700, "message": "parse error"}}),
        )

    if isinstance(raw, list):
        result = await _handle_batch(raw)
    else:
        result = await _handle_one(raw)

    return web.Response(
        content_type="application/json",
        text=json.dumps(result),
    )


# ── WebSocket handler ─────────────────────────────────────────────────────────

async def ws_handler(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse(heartbeat=30)
    await ws.prepare(request)
    log.info("ws connect %s", request.remote)
    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                try:
                    raw = json.loads(msg.data)
                except json.JSONDecodeError:
                    await ws.send_str(json.dumps({
                        "jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "parse error"},
                    }))
                    continue

                if isinstance(raw, list):
                    result = await _handle_batch(raw, ws)
                else:
                    result = await _handle_one(raw, ws)

                await ws.send_str(json.dumps(result))

            elif msg.type in (WSMsgType.ERROR, WSMsgType.CLOSE):
                break
    finally:
        await _cleanup_conn(ws)
        log.info("ws disconnect %s", request.remote)
    return ws


# ── health check ──────────────────────────────────────────────────────────────

async def health_handler(request: web.Request) -> web.Response:
    return web.Response(text="ok")


# ── startup / shutdown ────────────────────────────────────────────────────────

async def on_shutdown(app: web.Application) -> None:
    global _session
    if _session and not _session.closed:
        await _session.close()


def main() -> None:
    app = web.Application()
    app.router.add_post("/", http_handler)
    app.router.add_get("/", ws_handler)        # WebSocket upgrade comes in as GET
    app.router.add_get("/health", health_handler)
    app.on_shutdown.append(on_shutdown)

    log.info("ws-bridge starting on %s:%d → WireMock %s",
             LISTEN_HOST, LISTEN_PORT, WIREMOCK_URL)
    web.run_app(app, host=LISTEN_HOST, port=LISTEN_PORT, access_log=None)


if __name__ == "__main__":
    main()
