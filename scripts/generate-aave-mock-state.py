#!/usr/bin/env python3
"""Generate mock EVM runtime bytecode for offline synthetic Aave V3 state.

Reads one chain entry from config/chains.json on stdin (jq -c output) and
prints one line per mock account: "<address> 0x<runtime_code>". The codes are
installed on a plain (non-forked) Anvil instance via anvil_setCode so that
Aave V3 position (getUserAccountData) and reserve detail calls
(getReserveData / getReserveConfigurationData / getReserveTokensAddresses /
getReserveCaps / getAssetPrice) plus ERC20 metadata succeed without any
upstream RPC endpoint.

The bytecode is a flat selector dispatcher: compare the 4-byte selector,
optionally compare the first ABI word (the address argument), then CODECOPY a
constant ABI-encoded return blob from the code tail. Return shapes mirror the
decoders in crates/detectors/src/protocol_decoders.rs. Selectors are
precomputed with `cast sig` because the Python stdlib has no keccak256.
"""

import json
import os
import sys

SEL_GET_RESERVE_DATA = 0x35EA6A75  # getReserveData(address)
SEL_GET_USER_ACCOUNT_DATA = 0xBF92857C  # getUserAccountData(address)
SEL_GET_RESERVE_CONFIGURATION_DATA = 0x3E150141  # getReserveConfigurationData(address)
SEL_GET_RESERVE_TOKENS_ADDRESSES = 0xD2493B6C  # getReserveTokensAddresses(address)
SEL_GET_RESERVE_CAPS = 0x46FBE558  # getReserveCaps(address)
SEL_GET_ASSET_PRICE = 0xB3596F07  # getAssetPrice(address)
SEL_GET_RESERVES_LIST = 0xD1946DBC  # getReservesList()
SEL_DECIMALS = 0x313CE567  # decimals()
SEL_SYMBOL = 0x95D89B41  # symbol()
SEL_NAME = 0x06FDDE03  # name()
SEL_TOTAL_SUPPLY = 0x18160DDD  # totalSupply()
SEL_BALANCE_OF = 0x70A08231  # balanceOf(address)

RAY = 10**27
PRICE_UNIT = 10**8  # Aave oracle base currency unit (USD, 8 decimals)
GENESIS_TIMESTAMP = int(os.environ.get("ANVIL_SYNTHETIC_TIMESTAMP", "1750000000"))

# symbol, decimals, USD price in 8-decimals for the key reserves configured in
# config/chains.json. Unknown assets fall back to (TKN<i>, 18, $1).
KNOWN_TOKENS = {
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": ("USDC", 6, 1 * PRICE_UNIT),
    "0x6b175474e89094c44da98b954eedeac495271d0f": ("DAI", 18, 1 * PRICE_UNIT),
    "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": ("WETH", 18, 2500 * PRICE_UNIT),
    "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": ("WBTC", 8, 60000 * PRICE_UNIT),
    "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0": ("wstETH", 18, 3000 * PRICE_UNIT),
    "0xdac17f958d2ee523a2206206994597c13d831ec7": ("USDT", 6, 1 * PRICE_UNIT),
    "0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf": ("cbBTC", 8, 60000 * PRICE_UNIT),
    "0x4200000000000000000000000000000000000006": ("WETH", 18, 2500 * PRICE_UNIT),
    "0xd9aaec86b65d86f6a7b5b1b0c42ffa531710b6ca": ("USDbC", 6, 1 * PRICE_UNIT),
    "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913": ("USDC", 6, 1 * PRICE_UNIT),
    "0x82af49447d8a07e3bd95bd0d56f35241523fbab1": ("WETH", 18, 2500 * PRICE_UNIT),
    "0xaf88d065e77c8cc2239327c5edb3a432268e5831": ("USDC", 6, 1 * PRICE_UNIT),
    "0x912ce59144191c1204e64559fe8253a0e49e6548": ("ARB", 18, 8 * PRICE_UNIT // 10),
    "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9": ("USDT", 6, 1 * PRICE_UNIT),
    "0x5979d7b546e38e414f7e9822514be443a4800529": ("wstETH", 18, 3000 * PRICE_UNIT),
    "0x7f5c764cbc14f9669b88837ca1490cca17c31607": ("USDC.e", 6, 1 * PRICE_UNIT),
    "0x4200000000000000000000000000000000000042": ("OP", 18, 18 * PRICE_UNIT // 10),
    "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58": ("USDT", 6, 1 * PRICE_UNIT),
    "0x0b2c639c533813f4aa9d7837caf62653d097ff85": ("USDC", 6, 1 * PRICE_UNIT),
}


def word(value):
    return value.to_bytes(32, "big")


def addr_word(address):
    return bytes(12) + bytes.fromhex(address[2:])


def abi_string(text):
    data = text.encode()
    padded = data + bytes((32 - len(data) % 32) % 32)
    return word(0x20) + word(len(data)) + padded


def abi_address_array(addresses):
    return word(0x20) + word(len(addresses)) + b"".join(addr_word(a) for a in addresses)


def derived_address(asset, prefix):
    """Deterministic synthetic address: replace the asset's first byte."""
    return "0x" + prefix + asset[4:].lower()


def assemble(groups):
    """Assemble a selector dispatcher.

    groups: list of (selector, cases, default) where cases is a list of
    (arg_word, return_blob) compared against calldata word 0, and default is a
    return blob (or None to STOP) used when no case matches.
    """
    code = bytearray()
    fixups = []
    labels = {}
    data_blobs = []
    data_index = {}

    def ref(label):
        code.append(0x61)  # PUSH2 placeholder
        fixups.append((len(code), label))
        code.extend(b"\x00\x00")

    def emit_return(blob):
        if blob not in data_index:
            data_index[blob] = len(data_blobs)
            data_blobs.append(blob)
        length = len(blob).to_bytes(2, "big")
        code.append(0x61)
        code.extend(length)  # PUSH2 len
        ref(f"data{data_index[blob]}")  # PUSH2 offset
        code.extend(b"\x60\x00\x39")  # PUSH1 0 CODECOPY
        code.append(0x61)
        code.extend(length)  # PUSH2 len
        code.extend(b"\x60\x00\xf3")  # PUSH1 0 RETURN

    code.extend(b"\x60\x00\x35\x60\xe0\x1c")  # PUSH1 0 CALLDATALOAD PUSH1 224 SHR

    for gi, (selector, _, _) in enumerate(groups):
        code.append(0x80)  # DUP1
        code.append(0x63)  # PUSH4
        code.extend(selector.to_bytes(4, "big"))
        code.append(0x14)  # EQ
        ref(f"grp{gi}")
        code.append(0x57)  # JUMPI
    code.append(0x00)  # STOP: unknown selector returns empty success

    for gi, (_, cases, default) in enumerate(groups):
        labels[f"grp{gi}"] = len(code)
        code.append(0x5B)  # JUMPDEST
        if cases:
            code.extend(b"\x60\x04\x35")  # PUSH1 4 CALLDATALOAD
            for ci, (arg_word_value, _) in enumerate(cases):
                code.append(0x80)  # DUP1
                code.append(0x7F)  # PUSH32
                code.extend(arg_word_value)
                code.append(0x14)  # EQ
                ref(f"grp{gi}c{ci}")
                code.append(0x57)  # JUMPI
            code.append(0x50)  # POP
        if default is not None:
            emit_return(default)
        else:
            code.append(0x00)  # STOP
        for ci, (_, blob) in enumerate(cases):
            labels[f"grp{gi}c{ci}"] = len(code)
            code.append(0x5B)  # JUMPDEST
            emit_return(blob)

    for idx, blob in enumerate(data_blobs):
        labels[f"data{idx}"] = len(code)
        code.extend(blob)

    for pos, label in fixups:
        code[pos : pos + 2] = labels[label].to_bytes(2, "big")

    return "0x" + bytes(code).hex()


def reserve_configuration_bitmap(decimals):
    """Aave V3 ReserveConfigurationMap bit layout."""
    value = 7500  # LTV, bits 0-15
    value |= 8000 << 16  # liquidation threshold
    value |= 10500 << 32  # liquidation bonus
    value |= decimals << 48
    value |= 1 << 56  # active
    value |= 1 << 58  # borrowing enabled
    value |= 1 << 63  # flashloan enabled
    value |= 1000 << 64  # reserve factor
    return value


def reserve_data_blob(index, asset, decimals):
    return b"".join(
        [
            word(reserve_configuration_bitmap(decimals)),
            word(RAY + index * 10**24),  # liquidityIndex
            word(3 * 10**25),  # currentLiquidityRate (3% APR in ray)
            word(RAY + 2 * index * 10**24),  # variableBorrowIndex
            word(45 * 10**24),  # currentVariableBorrowRate (4.5%)
            word(0),  # currentStableBorrowRate
            word(GENESIS_TIMESTAMP),  # lastUpdateTimestamp
            word(index),  # id
            addr_word(derived_address(asset, "a1")),  # aToken
            addr_word(derived_address(asset, "a2")),  # stableDebtToken
            addr_word(derived_address(asset, "a3")),  # variableDebtToken
            addr_word(derived_address(asset, "a4")),  # interestRateStrategy
            word(0),  # accruedToTreasury
            word(0),  # unbacked
            word(0),  # isolationModeTotalDebt
        ]
    )


def reserve_configuration_data_blob(decimals):
    return b"".join(
        word(v)
        for v in [decimals, 7500, 8000, 10500, 1000, 1, 1, 0, 1, 0]
    )


def user_account_data_blob():
    return b"".join(
        word(v)
        for v in [
            100_000 * PRICE_UNIT,  # totalCollateralBase
            40_000 * PRICE_UNIT,  # totalDebtBase
            35_000 * PRICE_UNIT,  # availableBorrowsBase
            8000,  # currentLiquidationThreshold
            7500,  # ltv
            2 * 10**18,  # healthFactor
        ]
    )


def erc20_code(name, symbol, decimals):
    return assemble(
        [
            (SEL_NAME, [], abi_string(name)),
            (SEL_SYMBOL, [], abi_string(symbol)),
            (SEL_DECIMALS, [], word(decimals)),
            (SEL_TOTAL_SUPPLY, [], word(10**9 * 10**decimals)),
            (SEL_BALANCE_OF, [], word(10**6 * 10**decimals)),
        ]
    )


def main():
    chain_config = json.load(sys.stdin)
    aave = chain_config.get("protocols", {}).get("aave") or {}
    pool = aave.get("pool")
    if not pool:
        return
    data_provider = aave.get("data_provider")
    oracle = aave.get("oracle")
    reserves = aave.get("key_reserves") or []

    tokens = []
    for index, asset in enumerate(reserves):
        symbol, decimals, price = KNOWN_TOKENS.get(
            asset.lower(), (f"TKN{index}", 18, PRICE_UNIT)
        )
        tokens.append((index, asset, symbol, decimals, price))

    accounts = []
    accounts.append(
        (
            pool,
            assemble(
                [
                    (
                        SEL_GET_RESERVE_DATA,
                        [
                            (addr_word(asset), reserve_data_blob(index, asset, decimals))
                            for index, asset, _, decimals, _ in tokens
                        ],
                        None,
                    ),
                    (SEL_GET_USER_ACCOUNT_DATA, [], user_account_data_blob()),
                    (SEL_GET_RESERVES_LIST, [], abi_address_array(reserves)),
                ]
            ),
        )
    )

    if data_provider:
        accounts.append(
            (
                data_provider,
                assemble(
                    [
                        (
                            SEL_GET_RESERVE_CONFIGURATION_DATA,
                            [
                                (addr_word(asset), reserve_configuration_data_blob(decimals))
                                for _, asset, _, decimals, _ in tokens
                            ],
                            None,
                        ),
                        (
                            SEL_GET_RESERVE_TOKENS_ADDRESSES,
                            [
                                (
                                    addr_word(asset),
                                    addr_word(derived_address(asset, "a1"))
                                    + addr_word(derived_address(asset, "a2"))
                                    + addr_word(derived_address(asset, "a3")),
                                )
                                for _, asset, _, _, _ in tokens
                            ],
                            None,
                        ),
                        (SEL_GET_RESERVE_CAPS, [], word(0) + word(0)),
                    ]
                ),
            )
        )

    if oracle:
        accounts.append(
            (
                oracle,
                assemble(
                    [
                        (
                            SEL_GET_ASSET_PRICE,
                            [
                                (addr_word(asset), word(price))
                                for _, asset, _, _, price in tokens
                            ],
                            word(PRICE_UNIT),
                        ),
                    ]
                ),
            )
        )

    for _, asset, symbol, decimals, _ in tokens:
        accounts.append((asset, erc20_code(f"Mock {symbol}", symbol, decimals)))
        accounts.append(
            (derived_address(asset, "a1"), erc20_code(f"Aave {symbol}", f"a{symbol}", decimals))
        )
        accounts.append(
            (
                derived_address(asset, "a2"),
                erc20_code(f"Aave Stable Debt {symbol}", f"stableDebt{symbol}", decimals),
            )
        )
        accounts.append(
            (
                derived_address(asset, "a3"),
                erc20_code(f"Aave Variable Debt {symbol}", f"variableDebt{symbol}", decimals),
            )
        )
        # interest rate strategy only needs non-empty code: a bare STOP
        accounts.append((derived_address(asset, "a4"), "0x00"))

    for address, code in accounts:
        print(f"{address} {code}")


if __name__ == "__main__":
    main()
