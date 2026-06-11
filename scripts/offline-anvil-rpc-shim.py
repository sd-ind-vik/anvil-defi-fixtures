#!/usr/bin/env python3
"""Fail-closed JSON-RPC shim for cache-backed offline Anvil forks."""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ANVIL_EMPTY_CODE_ADDRESSES = {
    "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
    "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
    "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
    "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
    "0x15d34aaf54267db7d7c367839aaf71a00a2c6a65",
    "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc",
    "0x976ea74026e726554db657fa54763abd0c3a0aa9",
    "0x14dc79964da2c08b23698b3d3cc7ca32193d9955",
    "0x23618e81e3f5cdf7f54c3d65f7fbc0abf5b21e8f",
    "0xa0ee7a142d267c1f36714e4a8f75612f20a79720",
}


def strip_0x(value: str) -> str:
    return value[2:] if value.startswith("0x") else value


def quantity(value: Any) -> str:
    if isinstance(value, str):
        if value.startswith("0x"):
            return value
        return hex(int(value))
    return hex(int(value))


def bytes32(value: str) -> str:
    return "0x" + strip_0x(value).rjust(64, "0")[-64:]


def compact_quantity(value: str) -> str:
    return hex(int(value, 16) if value.startswith("0x") else int(value))


def normalize_address(value: str) -> str:
    return value.lower()


def map_get_case_insensitive(mapping: dict[str, Any], key: str) -> Any:
    value = mapping.get(key) or mapping.get(key.lower())
    if value is not None:
        return value
    lower_key = key.lower()
    for candidate_key, candidate_value in mapping.items():
        if candidate_key.lower() == lower_key:
            return candidate_value
    return None


def extract_bytecode(account: dict[str, Any] | None) -> str:
    if not account:
        return "0x"
    code = account.get("code")
    if code is None:
        return "0x"
    if isinstance(code, str):
        return code
    if isinstance(code, dict):
        for variant in code.values():
            if isinstance(variant, dict) and isinstance(variant.get("bytecode"), str):
                return variant["bytecode"]
    return "0x"


def make_block(cache: dict[str, Any], include_transactions: bool) -> dict[str, Any]:
    env = cache.get("meta", {}).get("block_env", {})
    block_number = quantity(env.get("number", "0x0"))
    gas_limit = quantity(env.get("gas_limit", "0x1c9c380"))
    base_fee = quantity(env.get("basefee", "0x0"))
    timestamp = quantity(env.get("timestamp", "0x0"))
    prevrandao = env.get("prevrandao") or env.get("difficulty") or "0x0"
    zero32 = "0x" + "00" * 32
    block_hash = bytes32(strip_0x(block_number) or "0")
    return {
        "number": block_number,
        "hash": block_hash,
        "parentHash": bytes32(hex(max(int(block_number, 16) - 1, 0))),
        "nonce": "0x0000000000000000",
        "sha3Uncles": zero32,
        "logsBloom": "0x" + "00" * 256,
        "transactionsRoot": zero32,
        "stateRoot": zero32,
        "receiptsRoot": zero32,
        "miner": env.get("beneficiary", "0x" + "00" * 20),
        "difficulty": "0x0",
        "totalDifficulty": "0x0",
        "extraData": "0x",
        "size": "0x1",
        "gasLimit": gas_limit,
        "gasUsed": "0x0",
        "timestamp": timestamp,
        "transactions": [] if include_transactions else [],
        "uncles": [],
        "baseFeePerGas": base_fee,
        "mixHash": bytes32(prevrandao),
        "withdrawals": [],
        "withdrawalsRoot": zero32,
        "blobGasUsed": "0x0",
        "excessBlobGas": quantity(env.get("blob_excess_gas_and_price", {}).get("excess_blob_gas", 0)),
        "parentBeaconBlockRoot": zero32,
    }


class OfflineRpcHandler(BaseHTTPRequestHandler):
    cache: dict[str, Any]
    chain_id: int
    logs: list[Any] | None = None  # None = no file loaded; [] = file loaded but empty

    def do_POST(self) -> None:
        length = int(self.headers.get("content-length", "0"))
        payload = json.loads(self.rfile.read(length) or b"{}")
        if isinstance(payload, list):
            response = [self.handle_call(item) for item in payload]
        else:
            response = self.handle_call(payload)
        body = json.dumps(response, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_call(self, request: dict[str, Any]) -> dict[str, Any]:
        request_id = request.get("id")
        method = request.get("method")
        params = request.get("params") or []
        try:
            result = self.dispatch(method, params)
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except Exception as exc:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32000,
                    "message": f"offline cache miss or unsupported method {method}: {exc}",
                },
            }

    def dispatch(self, method: str, params: list[Any]) -> Any:
        accounts = self.cache.get("accounts", {})
        if method == "eth_chainId":
            return hex(self.chain_id)
        if method == "net_version":
            return str(self.chain_id)
        if method == "eth_blockNumber":
            return quantity(self.cache.get("meta", {}).get("block_env", {}).get("number", "0x0"))
        if method == "eth_getBlockByNumber":
            include_transactions = bool(params[1]) if len(params) > 1 else False
            return make_block(self.cache, include_transactions)
        if method == "eth_getBlockByHash":
            include_transactions = bool(params[1]) if len(params) > 1 else False
            return make_block(self.cache, include_transactions)
        if method == "eth_getCode":
            address = normalize_address(params[0])
            code = extract_bytecode(accounts.get(address))
            if code == "0x" and address in ANVIL_EMPTY_CODE_ADDRESSES:
                return code
            if code == "0x":
                raise ValueError(f"code for {address} is not cached")
            return code
        if method == "eth_getBalance":
            address = normalize_address(params[0])
            account = accounts.get(address)
            if not account:
                return "0x0"
            return quantity(account.get("balance", "0x0"))
        if method == "eth_getTransactionCount":
            address = normalize_address(params[0])
            account = accounts.get(address)
            if not account:
                return "0x0"
            return quantity(account.get("nonce", 0))
        if method == "eth_getStorageAt":
            address = normalize_address(params[0])
            slot = bytes32(str(params[1]))
            compact_slot = compact_quantity(str(params[1]))
            account = map_get_case_insensitive(accounts, address)
            account_storage = account.get("storage", {}) if account else {}
            cache_storage = map_get_case_insensitive(self.cache.get("storage", {}), address) or {}
            value = (
                map_get_case_insensitive(account_storage, slot)
                or map_get_case_insensitive(account_storage, compact_slot)
                or map_get_case_insensitive(cache_storage, slot)
                or map_get_case_insensitive(cache_storage, compact_slot)
            )
            if value is None:
                raise ValueError(f"storage for {address} slot {slot} is not cached")
            return bytes32(str(value))
        if method == "eth_getLogs":
            if self.logs is None:
                raise ValueError("no logs file loaded; recapture fixtures to enable eth_getLogs")
            return self._filter_logs(params[0] if params else {})
        raise ValueError("method not implemented by offline shim")

    def _filter_logs(self, filter_obj: dict[str, Any]) -> list[Any]:
        def parse_block(val: Any) -> int:
            if val is None or val in ("latest", "pending", "safe", "finalized"):
                return 2**64
            if val == "earliest":
                return 0
            if isinstance(val, str) and val.startswith("0x"):
                return int(val, 16)
            return int(val)

        from_block = parse_block(filter_obj.get("fromBlock", "0x0"))
        to_block = parse_block(filter_obj.get("toBlock"))

        address_filter = filter_obj.get("address")
        if isinstance(address_filter, str):
            addr_set: set[str] | None = {address_filter.lower()}
        elif isinstance(address_filter, list):
            addr_set = {a.lower() for a in address_filter if a}
        else:
            addr_set = None

        topic_filters: list[Any] = filter_obj.get("topics") or []

        result = []
        for log in self.logs:
            block_val = log.get("blockNumber", "0x0")
            block_num = int(block_val, 16) if isinstance(block_val, str) and block_val.startswith("0x") else int(block_val or 0)
            if block_num < from_block or block_num > to_block:
                continue
            if addr_set and log.get("address", "").lower() not in addr_set:
                continue
            log_topics: list[str] = log.get("topics") or []
            match = True
            for i, tf in enumerate(topic_filters):
                if tf is None:
                    continue
                if i >= len(log_topics):
                    match = False
                    break
                if isinstance(tf, str):
                    if log_topics[i].lower() != tf.lower():
                        match = False
                        break
                elif isinstance(tf, list):
                    if not any(t and log_topics[i].lower() == t.lower() for t in tf):
                        match = False
                        break
            if match:
                result.append(log)
        return result

    def log_message(self, _format: str, *args: Any) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve a fail-closed RPC view of a Foundry cache file")
    parser.add_argument("--cache-file", required=True)
    parser.add_argument("--chain-id", required=True, type=int)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--logs-file", default=None)
    args = parser.parse_args()

    cache = json.loads(Path(args.cache_file).read_text())
    OfflineRpcHandler.cache = cache
    OfflineRpcHandler.chain_id = args.chain_id
    if args.logs_file and Path(args.logs_file).exists():
        try:
            OfflineRpcHandler.logs = json.loads(Path(args.logs_file).read_text())
        except Exception:
            OfflineRpcHandler.logs = []  # file present but unreadable → treat as empty
    server = ThreadingHTTPServer((args.host, args.port), OfflineRpcHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
