#!/usr/bin/env python3
"""
record-eth-calls.py

Fires every eth_call that the capture script warms against a running Anvil
instance and writes the responses as WireMock stub files.

Each call is matched by the exact (to, data) pair — the same matching the
mock server uses at runtime — so stubs are byte-for-byte reproducible.

Prerequisites
-------------
  1. A running Anvil fork at --rpc-url (the existing fixture Docker images work).
  2. The `cast` CLI on PATH (ships with Foundry).
  3. generate-wiremock-stubs.py must have run first to create the mappings dir.

Usage
-----
  # Start Anvil fixture:
  docker compose up anvil-ethereum

  # Record eth_call stubs:
  python3 scripts/record-eth-calls.py \\
      --rpc-url http://localhost:8545 \\
      --chain 1 \\
      [--out-dir wiremock/chains]

The script appends a new mapping file  07-eth-call-recorded.json  (and
removes the catch-all placeholder file if present) inside
  <out-dir>/<chain_name>/mappings/

Re-running is idempotent: existing stubs for the same (to, data) key are
overwritten.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import uuid
from typing import Optional

ROOT          = pathlib.Path(__file__).parent.parent
MANIFEST_PATH = ROOT / "fixtures" / "anvil-state" / "manifest.json"
CHAINS_PATH   = ROOT / "config" / "chains.json"

# ── ABI encoding helpers ──────────────────────────────────────────────────────
# We encode only the argument types used by the capture script.
# keccak256 is computed via cast (avoids pycryptodome dependency).

_SELECTOR_CACHE: dict[str, str] = {}


def selector(sig: str) -> str:
    """Return the 4-byte function selector for a Solidity signature."""
    if sig in _SELECTOR_CACHE:
        return _SELECTOR_CACHE[sig]
    out = subprocess.run(
        ["cast", "sig", sig],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    _SELECTOR_CACHE[sig] = out
    return out


def _pad32(hex_val: str) -> str:
    v = hex_val.lstrip("0x") if hex_val.startswith("0x") else hex_val
    return v.zfill(64)


def encode_addr(addr: str) -> str:
    return _pad32(addr.lower().lstrip("0x"))


def encode_uint256(n: int) -> str:
    return format(n, "064x")


def encode_uint32(n: int) -> str:
    return format(n, "064x")


def encode_bytes32(b: str) -> str:
    v = b.lstrip("0x")
    return v.ljust(64, "0")[:64]


def encode_int128(n: int) -> str:
    # signed 256-bit two's complement
    if n < 0:
        n = n + (1 << 256)
    return format(n, "064x")


def encode_uint32_array(values: list[int]) -> str:
    """Encode uint32[] as ABI dynamic array (offset + length + elements)."""
    # Dynamic type: offset (always 0x20 for single arg), length, elements
    offset = encode_uint256(0x20)
    length = encode_uint256(len(values))
    elems  = "".join(encode_uint256(v) for v in values)
    return offset + length + elems


def calldata(sig: str, *encoded_args: str) -> str:
    sel = selector(sig)
    return sel + "".join(encoded_args)


ONE_ETH = encode_uint256(10 ** 18)
ZERO    = encode_uint256(0)
ZERO_ADDR = "0x0000000000000000000000000000000000000000"

# ── eth_call via cast ─────────────────────────────────────────────────────────

def eth_call_raw(rpc_url: str, to: str, data: str) -> Optional[str]:
    """
    Call eth_call via cast and return the raw hex result string,
    or None if the call reverted / errored.
    """
    result = subprocess.run(
        ["cast", "rpc", "--rpc-url", rpc_url,
         "eth_call",
         json.dumps({"to": to, "data": data}),
         "latest"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    raw = result.stdout.strip()
    # cast rpc outputs JSON-encoded string (with quotes) or raw hex
    try:
        decoded = json.loads(raw)
        return decoded if isinstance(decoded, str) else None
    except json.JSONDecodeError:
        return raw if raw.startswith("0x") else None


# ── WireMock stub builder ─────────────────────────────────────────────────────

def _tmpl(result_json: str) -> str:
    return (
        '{"jsonrpc":"2.0",'
        '"id":{{jsonPath request.body \'$.id\'}},'
        f'"result":{result_json}}}'
    )


def eth_call_stub(to: str, data: str, result: str) -> dict:
    return {
        "id":       str(uuid.uuid4()),
        "priority": 2,
        "request": {
            "method": "POST",
            "bodyPatterns": [
                {"matchesJsonPath": {"expression": "$.method",         "equalTo": "eth_call"}},
                {"matchesJsonPath": {"expression": "$.params[0].to",   "equalTo": to.lower()}},
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


# ── call enumerators (mirror the capture script's warm_* functions) ───────────

AAVE_WARM_ACCOUNT = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
UNISWAP_TWAP_SECS = 300
PENDLE_TWAP_SECS  = 900
MULTICALL3        = "0xcA11bde05977b3631167028862bE2a173976CA11"
SPECTRA_ROUTER    = "0x2E95189f0a0B79fbd38A39feBD5AFDE10B94Cbc9"
SPECTRA_FACTORY   = "0x4fC8225B6D5DE92B2E44d7Ef36ae17C6bf68Af4D"


def erc20_calls(addr: str) -> list[tuple[str, str]]:
    return [
        (addr, calldata("decimals()")),
        (addr, calldata("symbol()")),
        (addr, calldata("name()")),
        (addr, calldata("totalSupply()")),
        (addr, calldata("balanceOf(address)", encode_addr(AAVE_WARM_ACCOUNT))),
    ]


def aave_reserve_token_calls(addr: str, underlying: str) -> list[tuple[str, str]]:
    calls = erc20_calls(addr) + [
        (addr, calldata("scaledTotalSupply()")),
        (addr, calldata("POOL()")),
        (addr, calldata("UNDERLYING_ASSET_ADDRESS()")),
        (addr, calldata("getIncentivesController()")),
        (addr, calldata("getInterestRateData(address)",  encode_addr(underlying))),
        (addr, calldata("getInterestRateDataBps(address)", encode_addr(underlying))),
    ]
    return calls


def aave_calls(cfg: dict) -> list[tuple[str, str]]:
    pool          = cfg.get("protocols", {}).get("aave", {}).get("pool", "")
    data_provider = cfg.get("protocols", {}).get("aave", {}).get("data_provider", "")
    oracle        = cfg.get("protocols", {}).get("aave", {}).get("oracle", "")
    reserves      = cfg.get("protocols", {}).get("aave", {}).get("key_reserves", [])
    account       = AAVE_WARM_ACCOUNT
    calls = []
    for asset in reserves:
        calls += erc20_calls(asset)
        if pool:
            calls.append((pool, calldata("getReserveData(address)", encode_addr(asset))))
        if data_provider:
            calls += [
                (data_provider, calldata("getReserveConfigurationData(address)", encode_addr(asset))),
                (data_provider, calldata("getReserveCaps(address)",              encode_addr(asset))),
                (data_provider, calldata("getReserveTokensAddresses(address)",   encode_addr(asset))),
            ]
        if oracle:
            calls.append((oracle, calldata("getAssetPrice(address)", encode_addr(asset))))
    if pool and account:
        calls.append((pool, calldata("getUserAccountData(address)", encode_addr(account))))
    return calls


def uniswap_calls(cfg: dict) -> list[tuple[str, str]]:
    pools  = cfg.get("protocols", {}).get("uniswap", {}).get("pools", [])
    calls  = []
    twap_data = encode_uint32_array([UNISWAP_TWAP_SECS, 0])
    for pool in pools:
        calls += [
            (pool, calldata("slot0()")),
            (pool, calldata("liquidity()")),
            (pool, calldata("token0()")),
            (pool, calldata("token1()")),
            (pool, calldata("observe(uint32[])", twap_data)),
            # observations at index 0 and 1
            (pool, calldata("observations(uint256)", encode_uint256(0))),
            (pool, calldata("observations(uint256)", encode_uint256(1))),
        ]
    return calls


def compound_calls(cfg: dict) -> list[tuple[str, str]]:
    comets = cfg.get("protocols", {}).get("compound", {}).get("comets", [])
    calls  = []
    for comet in comets:
        calls += [
            (comet, calldata("getSupplyRate()")),
            (comet, calldata("getBorrowRate()")),
            (comet, calldata("getUtilization()")),
            (comet, calldata("totalSupply()")),
            (comet, calldata("totalBorrow()")),
        ]
    return calls


def sky_calls(cfg: dict) -> list[tuple[str, str]]:
    sky     = cfg.get("protocols", {}).get("sky", {})
    susds   = sky.get("susds", "")
    usds    = sky.get("usds", "")
    lite_psm = sky.get("lite_psm", "")
    if not susds:
        return []
    calls = [
        (susds, calldata("ssr()")),
        (susds, calldata("totalAssets()")),
        (susds, calldata("convertToAssets(uint256)", ONE_ETH)),
    ]
    if lite_psm:
        calls += [
            (lite_psm, calldata("buf()")),
            (lite_psm, calldata("tin()")),
            (lite_psm, calldata("tout()")),
        ]
    return calls


def morpho_calls(cfg: dict) -> list[tuple[str, str]]:
    morpho  = cfg.get("protocols", {}).get("morpho", {})
    blue    = morpho.get("blue", "")
    irm     = morpho.get("irm", "")
    markets = morpho.get("markets", [])
    if not blue:
        return []
    calls = []
    for mid in markets:
        mid_b32 = encode_bytes32(mid)
        calls.append((blue, calldata("market(bytes32)", mid_b32)))
        if irm:
            calls.append((irm, calldata("rateAtTarget(bytes32)", mid_b32)))
    return calls


def pendle_calls(cfg: dict) -> list[tuple[str, str]]:
    pendle  = cfg.get("protocols", {}).get("pendle", {})
    oracle  = pendle.get("oracle", "")
    markets = pendle.get("markets", [])
    usde    = pendle.get("entry_tokens", {}).get("usde", "")
    if not oracle:
        return []
    calls = []
    if usde:
        calls += [(usde, calldata("totalSupply()")),
                  (usde, calldata("decimals()"))]
    tw = encode_uint32(PENDLE_TWAP_SECS)
    for mkt in markets:
        calls += [
            (mkt,    calldata("expiry()")),
            (mkt,    calldata("readTokens()")),
            (oracle, calldata("getOracleState(address,uint32)", encode_addr(mkt), tw)),
            (oracle, calldata("getPtToAssetRate(address,uint32)", encode_addr(mkt), tw)),
        ]
    return calls


def lido_calls(cfg: dict) -> list[tuple[str, str]]:
    lido       = cfg.get("protocols", {}).get("lido", {})
    steth      = lido.get("steth", "")
    wsteth     = lido.get("wsteth", "")
    oracle_l   = lido.get("oracle", "")
    curve_pool = lido.get("curve_pool", "")
    calls = []
    if wsteth:
        calls += [
            (wsteth, calldata("totalSupply()")),
            (wsteth, calldata("stEthPerToken()")),
            (wsteth, calldata("getWstETHByStETH(uint256)", ONE_ETH)),
            (wsteth, calldata("getStETHByWstETH(uint256)", ONE_ETH)),
        ]
    if steth:
        calls += [
            (steth, calldata("getTotalPooledEther()")),
            (steth, calldata("totalSupply()")),
            (steth, calldata("getBeaconStat()")),
        ]
    if oracle_l:
        calls += [
            (oracle_l, calldata("getBeaconStat()")),
            (oracle_l, calldata("getTotalPooledEther()")),
        ]
    if curve_pool:
        calls += [
            (curve_pool, calldata("get_dy(int128,int128,uint256)",
                                  encode_int128(0), encode_int128(1), ONE_ETH)),
            (curve_pool, calldata("get_dy(int128,int128,uint256)",
                                  encode_int128(1), encode_int128(0), ONE_ETH)),
            (curve_pool, calldata("get_virtual_price()")),
        ]
    return calls


def rocketpool_calls(cfg: dict) -> list[tuple[str, str]]:
    rp           = cfg.get("protocols", {}).get("rocketpool", {})
    reth         = rp.get("reth", "")
    deposit_pool = rp.get("deposit_pool", "")
    calls = []
    if reth:
        calls += [
            (reth, calldata("totalSupply()")),
            (reth, calldata("getExchangeRate()")),
            (reth, calldata("totalCollateral()")),
            (reth, calldata("getEthValue(uint256)", ONE_ETH)),
            (reth, calldata("getRethValue(uint256)", ONE_ETH)),
        ]
    if deposit_pool:
        calls += [
            (deposit_pool, calldata("getBalance()")),
            (deposit_pool, calldata("getMaximumDepositAmount()")),
            (deposit_pool, calldata("getMaximumDepositPoolSize()")),
        ]
    return calls


def eigenlayer_calls(cfg: dict) -> list[tuple[str, str]]:
    el           = cfg.get("protocols", {}).get("eigenlayer", {})
    strat_mgr    = el.get("strategy_manager", "")
    wsteth_strat = el.get("wsteth_strategy", "")
    reth_strat   = el.get("reth_strategy", "")
    if not strat_mgr:
        return []
    calls = [
        (strat_mgr, calldata("strategyWhitelister()")),
        (strat_mgr, calldata("delegation()")),
    ]
    for strat in [wsteth_strat, reth_strat]:
        if strat:
            calls += [
                (strat, calldata("underlyingToken()")),
                (strat, calldata("totalShares()")),
                (strat, calldata("sharesToUnderlying(uint256)", ONE_ETH)),
                (strat, calldata("underlyingToShares(uint256)", ONE_ETH)),
                (strat, calldata("explanation()")),
            ]
    return calls


def chainlink_calls(cfg: dict) -> list[tuple[str, str]]:
    feeds = cfg.get("chainlink_feeds", [])
    calls = []
    for feed in feeds:
        calls += [
            (feed, calldata("latestRoundData()")),
            (feed, calldata("latestAnswer()")),
            (feed, calldata("decimals()")),
            (feed, calldata("description()")),
            (feed, calldata("aggregator()")),
        ]
    return calls


def sequencer_calls(cfg: dict) -> list[tuple[str, str]]:
    feed = cfg.get("sequencer_status_feed", "")
    if not feed:
        return []
    return [
        (feed, calldata("latestRoundData()")),
        (feed, calldata("decimals()")),
        (feed, calldata("description()")),
    ]


def spectra_calls(chain_name: str) -> list[tuple[str, str]]:
    if chain_name != "ethereum":
        return []
    return [
        (SPECTRA_FACTORY, calldata("allPrincipalTokensLength()")),
        (SPECTRA_ROUTER,  calldata("paused()")),
    ]


def multicall3_calls() -> list[tuple[str, str]]:
    return [
        (MULTICALL3, calldata("getEthBalance(address)", encode_addr(ZERO_ADDR))),
    ]


def all_calls_for_chain(chain_cfg: dict) -> list[tuple[str, str]]:
    return (
        aave_calls(chain_cfg)
        + uniswap_calls(chain_cfg)
        + compound_calls(chain_cfg)
        + sky_calls(chain_cfg)
        + morpho_calls(chain_cfg)
        + pendle_calls(chain_cfg)
        + lido_calls(chain_cfg)
        + rocketpool_calls(chain_cfg)
        + eigenlayer_calls(chain_cfg)
        + chainlink_calls(chain_cfg)
        + sequencer_calls(chain_cfg)
        + spectra_calls(chain_cfg.get("name", ""))
        + multicall3_calls()
    )


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rpc-url",  required=True,
                   help="JSON-RPC endpoint of the running Anvil fixture")
    p.add_argument("--chain",    required=True, type=int,
                   help="Chain ID to record (1, 8453, 42161, or 10)")
    p.add_argument("--out-dir",  default=str(ROOT / "wiremock" / "chains"),
                   help="WireMock chains root (default: wiremock/chains)")
    args = p.parse_args()

    manifest  = json.loads((ROOT / "fixtures" / "anvil-state" / "manifest.json").read_text())
    chains_by_id = {c["chain_id"]: c
                    for c in json.loads(CHAINS_PATH.read_text())["chains"]}

    fixture = next((f for f in manifest["fixtures"]
                    if f["chain_id"] == args.chain), None)
    if not fixture:
        print(f"ERROR: chain {args.chain} not found in manifest", file=sys.stderr)
        sys.exit(1)

    chain_name = fixture["chain_name"]
    chain_cfg  = chains_by_id.get(args.chain, {})
    out_file   = pathlib.Path(args.out_dir) / chain_name / "mappings" / "07-eth-call-recorded.json"
    out_file.parent.mkdir(parents=True, exist_ok=True)

    # Load existing stubs to avoid duplicates.
    existing: dict[str, dict] = {}  # "to:data" → stub
    if out_file.exists():
        raw = json.loads(out_file.read_text())
        stub_list = raw.get("mappings", raw) if isinstance(raw, dict) else raw
        for s in stub_list:
            pats = {p.get("matchesJsonPath", {}).get("expression"): p["matchesJsonPath"]
                    for p in s.get("request", {}).get("bodyPatterns", [])}
            to   = pats.get("$.params[0].to",   {}).get("equalTo", "")
            data = pats.get("$.params[0].data",  {}).get("equalTo", "")
            if to and data:
                existing[f"{to.lower()}:{data.lower()}"] = s

    calls = all_calls_for_chain(chain_cfg)
    # Deduplicate while preserving order.
    seen:  set[tuple[str, str]] = set()
    unique = []
    for to, data in calls:
        k = (to.lower(), data.lower())
        if k not in seen:
            seen.add(k)
            unique.append((to, data))

    print(f"Recording {len(unique)} eth_call stubs for {chain_name} "
          f"(chain {args.chain}) from {args.rpc_url}")

    stubs = list(existing.values())
    added = skipped = failed = 0

    for to, data in unique:
        key = f"{to.lower()}:{data.lower()}"
        result = eth_call_raw(args.rpc_url, to, data)
        if result is None:
            failed += 1
            continue
        stub = eth_call_stub(to, data, result)
        if key in existing:
            # Replace existing stub (keep the same UUID).
            for i, s in enumerate(stubs):
                pats = {pat.get("matchesJsonPath", {}).get("expression"): pat["matchesJsonPath"]
                        for pat in s.get("request", {}).get("bodyPatterns", [])}
                if (pats.get("$.params[0].to",   {}).get("equalTo", "").lower() == to.lower()
                        and pats.get("$.params[0].data", {}).get("equalTo", "").lower() == data.lower()):
                    stubs[i] = stub
                    break
            skipped += 1
        else:
            stubs.append(stub)
            existing[key] = stub
            added += 1

        if (added + skipped + failed) % 50 == 0:
            print(f"  … {added + skipped + failed}/{len(unique)}: "
                  f"+{added} new, {skipped} updated, {failed} failed")

    out_file.write_text(json.dumps({"mappings": stubs}, indent=2))
    print(f"\nDone: {added} new, {skipped} updated, {failed} failed/reverted")
    print(f"Output: {out_file}")

    # Remove the catch-all placeholder now that we have exact stubs.
    catchall = out_file.parent / "06-eth-call-catchall.json"
    if catchall.exists() and added > 0:
        # Keep catch-all with lower priority (it stays as the fallback).
        print(f"Keeping catch-all stub {catchall} as priority-10 fallback")


if __name__ == "__main__":
    main()
