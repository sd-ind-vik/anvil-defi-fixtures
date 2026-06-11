#!/usr/bin/env python3
"""
Merge a Foundry RPC cache archive into an anvil dump-state JSON so that
anvil --load-state can serve all warmed contract reads fully offline
(no shim, no tar.gz required).

Usage:
    enrich-state-with-cache.py <state.json> <foundry-cache.tar.gz> <output.json>

The input state.json is an anvil --dump-state file (sparse: only locally
written accounts).  The tar.gz is the Foundry RPC cache captured during
the warm-up phase.  The output is a self-contained state file that
includes all warmed contract bytecode and storage slots.
"""

import json
import sys
import tarfile
from pathlib import Path


def pad32(hex_str: str) -> str:
    """Normalise a hex value to a 0x-prefixed 32-byte (64 hex char) string."""
    s = hex_str.lower()
    if s.startswith("0x"):
        s = s[2:]
    return "0x" + s.zfill(64)


def extract_bytecode(code_field) -> str:
    """Return raw hex bytecode from a Foundry cache code field."""
    if code_field is None:
        return "0x"
    if isinstance(code_field, str):
        return code_field or "0x"
    # {"LegacyAnalyzed": {"bytecode": "0x...", ...}} or similar wrapper
    for _variant, inner in code_field.items():
        if isinstance(inner, dict):
            return inner.get("bytecode", "0x") or "0x"
        if isinstance(inner, str):
            return inner or "0x"
    return "0x"


def load_cache_from_tar(tar_path: Path) -> dict:
    with tarfile.open(tar_path) as tf:
        members = [m for m in tf.getmembers() if m.name.endswith("storage.json")]
        if not members:
            raise SystemExit(f"no storage.json found inside {tar_path}")
        member = members[0]
        return json.load(tf.extractfile(member))


def main():
    if len(sys.argv) != 4:
        print("usage: enrich-state-with-cache.py <state.json> <cache.tar.gz> <output.json>",
              file=sys.stderr)
        sys.exit(1)

    state_path = Path(sys.argv[1])
    tar_path = Path(sys.argv[2])
    out_path = Path(sys.argv[3])

    dump = json.loads(state_path.read_text())
    cache = load_cache_from_tar(tar_path)

    cache_accounts: dict = cache.get("accounts", {})
    cache_storage: dict = cache.get("storage", {})

    added = updated = 0

    for addr, acc in cache_accounts.items():
        bytecode = extract_bytecode(acc.get("code"))
        # skip pure EOAs with no code and no storage — they add no value
        raw_storage = cache_storage.get(addr, {})
        if bytecode == "0x" and not raw_storage:
            continue

        storage = {pad32(slot): pad32(val) for slot, val in raw_storage.items()}

        existing = dump["accounts"].get(addr)
        if existing is None:
            added += 1
        else:
            updated += 1

        raw_nonce = acc.get("nonce", 0)
        if isinstance(raw_nonce, str):
            raw_nonce = int(raw_nonce, 16) if raw_nonce.startswith("0x") else int(raw_nonce)

        dump["accounts"][addr] = {
            "nonce": raw_nonce,
            "balance": acc.get("balance", "0x0"),
            "code": bytecode,
            "storage": storage,
        }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(dump, separators=(",", ":")))

    total = added + updated
    print(
        f"enriched {state_path.name}: +{added} new accounts, {updated} updated"
        f" → {total} cache accounts merged → {out_path}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
