#!/usr/bin/env python3
"""
generate-wiremock-stubs.py

Generates WireMock mapping files for every JSON-RPC method that the capture
script warms across all four chains.

Data sources (in priority order)
---------------------------------
  *-full.json      — primary: 176 accounts with code + storage in plain hex;
                     realistic mined block headers (fork+1, fork+2) with real
                     parentHash chain so block-by-hash lookups are accurate.
  foundry-cache.tar.gz — fallback: same account data in Foundry's internal
                     format when full.json is absent.
  chain-*-logs.json — pre-captured eth_getLogs entries.

eth_call stubs
--------------
  NOT generated here — eth_call responses are EVM-computed and not stored in
  the cache files.  Run  scripts/record-eth-calls.py  against a live Anvil
  instance to add them.  A catch-all "0x" stub is written so clients don't
  error on unknown calls.

Block scenario
--------------
  WireMock scenarios progress fork_block → fork_block+10.
  "Started"  ≡ fork_block  (WireMock's reserved initial state name)
  "block-N"  ≡ fork_block + N  (N = 1 … 10)

  evm_mine stubs transition the active scenario state one step at a time.
  eth_blockNumber and eth_getBlockByNumber("latest") are scenario-gated.

Usage
-----
  python3 scripts/generate-wiremock-stubs.py [--out-dir wiremock/chains]
          [--chains 1,8453]
"""

import argparse
import hashlib
import json
import os
import pathlib
import tarfile
import uuid

ROOT          = pathlib.Path(__file__).parent.parent
MANIFEST_PATH = ROOT / "fixtures" / "anvil-state" / "manifest.json"
CHAINS_PATH   = ROOT / "config" / "chains.json"
MINE_AHEAD    = 10   # blocks to pre-generate past fork_block

# ── helpers ───────────────────────────────────────────────────────────────────

def load_json(path):
    with open(path) as f:
        return json.load(f)


def stub_id() -> str:
    return str(uuid.uuid4())


def synth_hash(n: int) -> str:
    d = hashlib.sha256(f"mockrpc-block-{n}".encode()).hexdigest()
    return "0x" + d


def hex_int(v) -> str:
    """Return v as a lowercase hex string (accepts int or hex str)."""
    if isinstance(v, int):
        return hex(v)
    return v  # already hex


def add_hex(h: str, delta: int) -> str:
    return hex(int(h, 16) + delta)


# ── block construction ────────────────────────────────────────────────────────

def _empty_block_tmpl(number: int, parent_hash: str,
                       timestamp: str, gas_limit: str,
                       basefee: str, difficulty: str,
                       miner: str, state_root: str,
                       mix_hash: str) -> dict:
    return {
        "number":           hex(number),
        "hash":             synth_hash(number),
        "parentHash":       parent_hash,
        "sha3Uncles":       "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
        "miner":            miner,
        "stateRoot":        state_root,
        "transactionsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "receiptsRoot":     "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "logsBloom":        "0x" + "0" * 512,
        "difficulty":       difficulty,
        "totalDifficulty":  difficulty,
        "extraData":        "0x",
        "gasLimit":         gas_limit,
        "gasUsed":          "0x0",
        "timestamp":        timestamp,
        "baseFeePerGas":    basefee,
        "mixHash":          mix_hash,
        "nonce":            "0x0000000000000000",
        "transactions":     [],
        "uncles":           [],
    }


def header_to_rpc_block(header: dict, block_hash: str) -> dict:
    """Convert a full.json block header to an eth_getBlockByNumber response."""
    return {
        "number":           header.get("number", "0x0"),
        "hash":             block_hash,
        "parentHash":       header.get("parentHash", "0x" + "0" * 64),
        "sha3Uncles":       header.get("sha3Uncles",
                            "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347"),
        "miner":            header.get("miner", "0x0000000000000000000000000000000000000000"),
        "stateRoot":        header.get("stateRoot", "0x" + "0" * 64),
        "transactionsRoot": header.get("transactionsRoot",
                            "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"),
        "receiptsRoot":     header.get("receiptsRoot",
                            "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"),
        "logsBloom":        header.get("logsBloom", "0x" + "0" * 512),
        "difficulty":       header.get("difficulty", "0x0"),
        "totalDifficulty":  header.get("difficulty", "0x0"),
        "extraData":        header.get("extraData", "0x"),
        "gasLimit":         header.get("gasLimit", "0x3938700"),
        "gasUsed":          header.get("gasUsed", "0x0"),
        "timestamp":        header.get("timestamp", "0x0"),
        "baseFeePerGas":    header.get("baseFeePerGas"),
        "mixHash":          header.get("mixHash", "0x" + "0" * 64),
        "nonce":            header.get("nonce", "0x0000000000000000"),
        "transactions":     [],
        "uncles":           [],
    }


# ── account / storage extraction ──────────────────────────────────────────────

def accounts_from_full_json(full: dict) -> dict[str, dict]:
    """Return {lower_addr: {"code": "0x...", "storage": {slot: value}}}."""
    result = {}
    for addr, acct in full.get("accounts", {}).items():
        code = acct.get("code", "0x")
        if not isinstance(code, str):
            code = "0x"
        storage = {k: v for k, v in acct.get("storage", {}).items()}
        result[addr.lower()] = {"code": code, "storage": storage}
    return result


def _extract_bytecode_foundry(code_field) -> str:
    if isinstance(code_field, str):
        return code_field
    if isinstance(code_field, dict):
        if "LegacyAnalyzed" in code_field:
            return code_field["LegacyAnalyzed"].get("bytecode", "0x")
        if "Eof" in code_field:
            return code_field["Eof"].get("raw", "0x")
    return "0x"


def accounts_from_foundry_cache(cache: dict) -> dict[str, dict]:
    result = {}
    for addr, acct in cache.get("accounts", {}).items():
        code = _extract_bytecode_foundry(acct.get("code"))
        storage = {k: hex_int(v) if isinstance(v, int) else v
                   for k, v in cache.get("storage", {}).get(addr, {}).items()}
        result[addr.lower()] = {"code": code, "storage": storage}
    return result


def load_foundry_cache(archive: pathlib.Path) -> dict:
    with tarfile.open(archive, "r:gz") as tf:
        for name in tf.getnames():
            if name.endswith("storage.json"):
                return json.load(tf.extractfile(name))
    raise FileNotFoundError(f"storage.json not found in {archive}")


# ── WireMock stub builders ────────────────────────────────────────────────────

def _tmpl(result_json: str) -> str:
    """Response body using WireMock response-template to echo $.id."""
    return (
        '{"jsonrpc":"2.0",'
        '"id":{{jsonPath request.body \'$.id\'}},'
        f'"result":{result_json}}}'
    )


def _method_stub(method: str, result, priority: int = 5) -> dict:
    return {
        "id": stub_id(), "priority": priority,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method", "equalTo": method}}
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(result)),
            "transformers": ["response-template"],
        },
    }


def _method_stub_scen(method: str, result, scenario: str,
                       req_state: str, new_state: str = None,
                       priority: int = 4) -> dict:
    s = _method_stub(method, result, priority=priority)
    s["scenarioName"]          = scenario
    s["requiredScenarioState"] = req_state
    if new_state:
        s["newScenarioState"] = new_state
    return s


def _get_code_stub(addr: str, bytecode: str) -> dict:
    return {
        "id": stub_id(), "priority": 3,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method", "equalTo": "eth_getCode"}},
                {"matchesJsonPath": {"expression": "$.params[0]", "equalTo": addr}},
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(bytecode)),
            "transformers": ["response-template"],
        },
    }


def _get_storage_stub(addr: str, slot: str, value: str) -> dict:
    # Normalise slot to 64-char hex so it matches either form clients send.
    s = slot.lstrip("0x") if slot.startswith("0x") else slot
    slot_norm = "0x" + s.zfill(64)
    # Normalise value to 64-char hex.
    if isinstance(value, int):
        value = "0x" + format(value, "064x")
    elif isinstance(value, str) and value.startswith("0x"):
        value = "0x" + value[2:].zfill(64)
    return {
        "id": stub_id(), "priority": 3,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method",     "equalTo": "eth_getStorageAt"}},
                {"matchesJsonPath": {"expression": "$.params[0]",  "equalTo": addr}},
                {"matchesJsonPath": {"expression": "$.params[1]",  "equalTo": slot_norm}},
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(value)),
            "transformers": ["response-template"],
        },
    }


def _eth_call_stub(to: str, data: str, result: str) -> dict:
    return {
        "id": stub_id(), "priority": 2,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method",         "equalTo": "eth_call"}},
                {"matchesJsonPath": {"expression": "$.params[0].to",   "equalTo": to}},
                {"matchesJsonPath": {"expression": "$.params[0].data", "equalTo": data}},
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(result)),
            "transformers": ["response-template"],
        },
    }


def _logs_stub(addr: str, logs: list) -> dict:
    return {
        "id": stub_id(), "priority": 3,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method", "equalTo": "eth_getLogs"}},
                {"matchesJsonPath": {"expression": "$.params[0].address",
                                     "equalTo": addr}},
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(logs)),
            "transformers": ["response-template"],
        },
    }


def _block_by_tag_stub(tag: str, block: dict, scenario: str, req_state: str) -> dict:
    return {
        "id": stub_id(), "priority": 3,
        "scenarioName":          scenario,
        "requiredScenarioState": req_state,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method",     "equalTo": "eth_getBlockByNumber"}},
                {"matchesJsonPath": {"expression": "$.params[0]",  "equalTo": tag}},
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(block)),
            "transformers": ["response-template"],
        },
    }


def _block_by_exact_num_stub(block: dict) -> dict:
    return {
        "id": stub_id(), "priority": 3,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method",    "equalTo": "eth_getBlockByNumber"}},
                {"matchesJsonPath": {"expression": "$.params[0]", "equalTo": block["number"]}},
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(block)),
            "transformers": ["response-template"],
        },
    }


def _block_by_hash_stub(block: dict) -> dict:
    return {
        "id": stub_id(), "priority": 3,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method",    "equalTo": "eth_getBlockByHash"}},
                {"matchesJsonPath": {"expression": "$.params[0]", "equalTo": block["hash"]}},
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(block)),
            "transformers": ["response-template"],
        },
    }


def _evm_mine_stub(new_hash: str, scenario: str, req_state: str, new_state: str) -> dict:
    return {
        "id": stub_id(), "priority": 3,
        "scenarioName":          scenario,
        "requiredScenarioState": req_state,
        "newScenarioState":      new_state,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {
                    "expression": "$.method",
                    "matches": "evm_mine|hardhat_mine|anvil_mine",
                }},
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl(json.dumps(new_hash)),
            "transformers": ["response-template"],
        },
    }


def _catchall_stub(method: str, result, priority: int = 10) -> dict:
    s = _method_stub(method, result, priority=priority)
    return s


def _write(path: pathlib.Path, stubs: list) -> None:
    path.write_text(json.dumps({"mappings": stubs}, indent=2))


def _scen_state(i: int) -> str:
    return "Started" if i == 0 else f"block-{i}"


# ── per-chain generation ──────────────────────────────────────────────────────

def generate(fixture: dict, out_dir: pathlib.Path) -> None:
    chain_id   = fixture["chain_id"]
    chain_name = fixture["chain_name"]
    fork_block = fixture["fork_block"]

    full_file  = ROOT / fixture.get("full_state_file",
                        fixture.get("state_file", "").replace(".json", "-full.json"))
    cache_arch = ROOT / fixture.get("cache_archive", "")
    logs_file  = ROOT / fixture.get("state_file", "").replace(".json", "-logs.json")

    print(f"\n==> {chain_name} (chain {chain_id}, fork {fork_block})")

    # ── load accounts and storage ─────────────────────────────────────────────
    accounts: dict[str, dict] = {}
    fork_block_data: dict = {}

    if full_file.exists():
        full = load_json(full_file)
        accounts = accounts_from_full_json(full)
        # Build fork block from full.json data.
        # The `blocks` list contains fork+1 … fork+N (mined by capture script).
        # blocks[0].header.parentHash == hash of the fork block itself.
        mined_blocks = full.get("blocks", [])
        env = full.get("block", {})  # Anvil's internal current block env

        fork_hash = (mined_blocks[0]["header"]["parentHash"]
                     if mined_blocks else synth_hash(fork_block))

        fork_block_data = _empty_block_tmpl(
            number      = fork_block,
            parent_hash = synth_hash(fork_block - 1),
            timestamp   = hex_int(env.get("timestamp", "0x0")),
            gas_limit   = hex_int(env.get("gas_limit", 0x3938700)),
            basefee     = hex_int(env.get("basefee", 0x3b9aca00)),
            difficulty  = env.get("difficulty", "0x0"),
            miner       = env.get("beneficiary",
                          "0x0000000000000000000000000000000000000000"),
            state_root  = env.get("prevrandao", "0x" + "0" * 64),
            mix_hash    = env.get("prevrandao", "0x" + "0" * 64),
        )
        # Overwrite with the real fork block hash we derived from mined blocks.
        fork_block_data["hash"]       = fork_hash
        fork_block_data["parentHash"] = mined_blocks[0]["header"].get(
            "parentHash", synth_hash(fork_block - 1)) if not mined_blocks else fork_block_data["parentHash"]

        # Build hash→block map for mined blocks from full.json.
        # blocks[i].hash == blocks[i+1].header.parentHash
        mined_rpc: list[dict] = []
        for i, blk in enumerate(mined_blocks):
            hdr = blk["header"]
            blk_hash = (mined_blocks[i + 1]["header"]["parentHash"]
                        if i + 1 < len(mined_blocks) else synth_hash(int(hdr["number"], 16)))
            mined_rpc.append(header_to_rpc_block(hdr, blk_hash))

        print(f"  Loaded full.json: {len(accounts)} accounts, "
              f"{len(mined_blocks)} mined blocks")

    elif cache_arch.exists():
        cache    = load_foundry_cache(cache_arch)
        accounts = accounts_from_foundry_cache(cache)
        meta     = cache.get("meta", {})
        env      = meta.get("block_env", {})
        fork_block_data = _empty_block_tmpl(
            number      = fork_block,
            parent_hash = synth_hash(fork_block - 1),
            timestamp   = hex_int(env.get("timestamp", "0x0")),
            gas_limit   = hex_int(env.get("gas_limit", 0x3938700)),
            basefee     = hex_int(env.get("basefee", 0x3b9aca00)),
            difficulty  = "0x0",
            miner       = "0x0000000000000000000000000000000000000000",
            state_root  = "0x" + "0" * 64,
            mix_hash    = "0x" + "0" * 64,
        )
        mined_rpc = []
        print(f"  Loaded Foundry cache: {len(accounts)} accounts")
    else:
        print(f"  WARN: no data source found, generating minimal stubs only")
        mined_rpc = []

    # ── build blocks map: abs_number → rpc block dict ─────────────────────────
    blocks: dict[int, dict] = {fork_block: fork_block_data}

    # Insert realistic mined blocks from full.json (fork+1, fork+2)
    for blk in mined_rpc:
        n = int(blk["number"], 16)
        blocks[n] = blk

    # Synthesise the remaining blocks up to fork+MINE_AHEAD
    for i in range(1, MINE_AHEAD + 1):
        n = fork_block + i
        if n not in blocks:
            prev = blocks.get(n - 1, fork_block_data)
            blocks[n] = _empty_block_tmpl(
                number      = n,
                parent_hash = prev["hash"],
                timestamp   = add_hex(prev["timestamp"], 12),
                gas_limit   = prev["gasLimit"],
                basefee     = prev.get("baseFeePerGas", "0x3b9aca00"),
                difficulty  = prev["difficulty"],
                miner       = prev["miner"],
                state_root  = prev["stateRoot"],
                mix_hash    = synth_hash(n),
            )

    basefee       = fork_block_data.get("baseFeePerGas", "0x3b9aca00")
    gas_price_hex = hex(int(int(basefee, 16) * 1.1))

    # ── load logs ─────────────────────────────────────────────────────────────
    logs_by_addr: dict[str, list] = {}
    if logs_file.exists():
        raw = json.loads(logs_file.read_text()) or []
        for log in raw:
            a = log.get("address", "").lower()
            if a:
                logs_by_addr.setdefault(a, []).append(log)
        print(f"  Logs: {sum(len(v) for v in logs_by_addr.values())} entries "
              f"across {len(logs_by_addr)} addresses")

    scenario     = f"block-state-{chain_id}"
    mappings_dir = out_dir / chain_name / "mappings"
    mappings_dir.mkdir(parents=True, exist_ok=True)
    total = 0

    # ── 01: chain identity ────────────────────────────────────────────────────
    stubs = [
        _method_stub("eth_chainId",               hex(chain_id)),
        _method_stub("net_version",               str(chain_id)),
        _method_stub("net_listening",             True),
        _method_stub("eth_syncing",               False),
        _method_stub("eth_gasPrice",              gas_price_hex),
        _method_stub("eth_maxPriorityFeePerGas",  "0x3b9aca00"),
        _method_stub("eth_estimateGas",           "0x5208"),
        _method_stub("eth_getBalance",            "0x0"),
        _method_stub("eth_getTransactionCount",   "0x0"),
        _method_stub("eth_getTransactionReceipt", None),
        _method_stub("eth_getTransactionByHash",  None),
        _method_stub("evm_snapshot",              "0x1"),
        _method_stub("evm_revert",                True),
        _method_stub("evm_setNextBlockTimestamp",  None),
        _method_stub("eth_feeHistory", {
            "oldestBlock":   hex(fork_block),
            "baseFeePerGas": [basefee, basefee],
            "gasUsedRatio":  [0.0],
            "reward":        [["0x0"]],
        }),
    ]
    _write(mappings_dir / "01-chain-identity.json", stubs)
    total += len(stubs)

    # ── 02: block scenario ────────────────────────────────────────────────────
    block_stubs = []
    for i in range(MINE_AHEAD + 1):
        n         = fork_block + i
        blk       = blocks[n]
        req_state = _scen_state(i)
        new_state = _scen_state(i + 1) if i < MINE_AHEAD else None

        # eth_blockNumber
        block_stubs.append(
            _method_stub_scen("eth_blockNumber", hex(n), scenario, req_state, priority=4)
        )
        # eth_getBlockByNumber("latest" / fuzzy tags)
        for tag in ("latest", "pending", "safe", "finalized"):
            block_stubs.append(_block_by_tag_stub(tag, blk, scenario, req_state))
        # eth_getBlockByNumber(exact hex) — scenario-independent
        block_stubs.append(_block_by_exact_num_stub(blk))
        # eth_getBlockByHash
        block_stubs.append(_block_by_hash_stub(blk))
        # evm_mine → transition to next state
        if i < MINE_AHEAD and new_state:
            next_blk = blocks[n + 1]
            block_stubs.append(
                _evm_mine_stub(next_blk["hash"], scenario, req_state, new_state)
            )

    _write(mappings_dir / "02-block-scenario.json", block_stubs)
    total += len(block_stubs)

    # ── 03: eth_getCode ───────────────────────────────────────────────────────
    code_stubs = []
    for addr, acct in accounts.items():
        code = acct.get("code", "0x")
        if code and code != "0x":
            code_stubs.append(_get_code_stub(addr, code))
    code_stubs.append(_catchall_stub("eth_getCode", "0x"))
    _write(mappings_dir / "03-eth-get-code.json", code_stubs)
    total += len(code_stubs)
    print(f"  eth_getCode stubs: {len(code_stubs) - 1} addresses")

    # ── 04: eth_getStorageAt ──────────────────────────────────────────────────
    storage_stubs = []
    for addr, acct in accounts.items():
        for slot, value in acct.get("storage", {}).items():
            storage_stubs.append(_get_storage_stub(addr, slot, value))
    storage_stubs.append({
        "id": stub_id(), "priority": 10,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method", "equalTo": "eth_getStorageAt"}}
            ],
        },
        "response": {
            "status": 200,
            "headers": {"Content-Type": "application/json"},
            "body": _tmpl('"0x' + '0' * 64 + '"'),
            "transformers": ["response-template"],
        },
    })
    _write(mappings_dir / "04-eth-get-storage.json", storage_stubs)
    total += len(storage_stubs)
    slot_total = sum(len(a.get("storage", {})) for a in accounts.values())
    print(f"  eth_getStorageAt stubs: {slot_total} slots")

    # ── 05: eth_getLogs ───────────────────────────────────────────────────────
    log_stubs = [_logs_stub(a, ls) for a, ls in logs_by_addr.items()]
    log_stubs.append(_catchall_stub("eth_getLogs", []))
    _write(mappings_dir / "05-eth-get-logs.json", log_stubs)
    total += len(log_stubs)

    # ── 06: eth_call (catch-all placeholder) ─────────────────────────────────
    _write(mappings_dir / "06-eth-call-catchall.json",
           [_catchall_stub("eth_call", "0x")])
    total += 1

    print(f"  Total stubs: {total}  →  {mappings_dir}")
    print(f"  Next step: scripts/record-eth-calls.py --rpc-url <anvil-url> "
          f"--chain {chain_id}")


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out-dir", default=str(ROOT / "wiremock" / "chains"),
                   help="Output root for WireMock chains (default: wiremock/chains)")
    p.add_argument("--chains", default="",
                   help="Comma-separated chain IDs to generate (default: all)")
    args = p.parse_args()

    out_dir  = pathlib.Path(args.out_dir)
    selected = set(args.chains.split(",")) if args.chains else set()

    manifest = load_json(MANIFEST_PATH)

    for fixture in manifest["fixtures"]:
        if selected and str(fixture["chain_id"]) not in selected:
            continue
        generate(fixture, out_dir)

    print("\n==> Done.")


if __name__ == "__main__":
    main()
