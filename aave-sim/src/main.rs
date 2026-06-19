use alloy::{
    hex,
    primitives::{address, keccak256, utils::format_units, Address, Bytes, B256, U256},
    providers::{ext::AnvilApi, Provider, ProviderBuilder},
    rpc::types::Log,
    transports::ws::WsConnect,
    network::{Ethereum, EthereumWallet},
    signers::local::PrivateKeySigner,
    sol,
};
use testcontainers::{
    core::{IntoContainerPort, WaitFor},
    runners::AsyncRunner,
    GenericImage, ImageExt,
};
use futures::StreamExt;
use eyre::Result;

// ── contract interfaces ──────────────────────────────────────────────────────

sol! {
    #[sol(rpc)]
    interface IERC20 {
        function approve(address spender, uint256 amount) external returns (bool);
        function balanceOf(address owner) external view returns (uint256);
    }

    #[sol(rpc)]
    interface IAaveOracle {
        function getAssetPrice(address asset) external view returns (uint256);
    }

    #[sol(rpc)]
    interface IAaveV3Pool {
        function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
        function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
        function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
        function withdraw(address asset, uint256 amount, address to) external returns (uint256);
        function getUserAccountData(address user) external view returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    }
}

// Minimal Chainlink-compatible mock feed:
//   latestAnswer() 0x50d25bcd → SLOAD(0) → return int256
//   decimals()     0x313ce567 → return 8
const MOCK_FEED_BYTECODE: &str =
    "60003560e01c806350d25bcd14601f578063313ce56714602b5760006000fd5b60005460005260206000f35b600860005260206000f3";

// ── config types ─────────────────────────────────────────────────────────────

#[derive(Copy, Clone)]
struct TokenConfig {
    addr:         Address,
    atoken:       Address,
    var_debt:     Address,
    symbol:       &'static str,
    decimals:     u8,
    balance_slot: u64,   // storage slot of balanceOf mapping in the token contract
    price_8dec:   u64,   // mock oracle price (8 decimals, Chainlink format)
    mock_feed:    Address,
}

#[derive(Copy, Clone)]
struct SimConfig {
    chain:         &'static str,  // fixture CHAIN_NAME: "ethereum" | "arbitrum" | "base" | "optimism"
    pool:          Address,       // Aave V3 Pool
    oracle:        Address,       // Aave V3 PriceOracle
    collateral:    TokenConfig,
    borrow:        TokenConfig,
    supply_amount: U256,
    borrow_amount: U256,
}

// ── per-chain pair configs ────────────────────────────────────────────────────

fn weth_usdc_ethereum() -> SimConfig {
    SimConfig {
        chain:  "ethereum",
        pool:   address!("87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2"),
        oracle: address!("54586bE62E3c3580375aE3723C145253060Ca0C2"),
        collateral: TokenConfig {
            addr:         address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
            atoken:       address!("4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8"),
            var_debt:     address!("eA51d7853EeFE3813aa3338B2b25259a0C5F2a01"),
            symbol:       "WETH", decimals: 18, balance_slot: 3, // WETH9: slot 3
            price_8dec:   250_000_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000001"),
        },
        borrow: TokenConfig {
            addr:         address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
            atoken:       address!("98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c"),
            var_debt:     address!("72E95b8931767C79bA4EeE721354d6E99a61D004"),
            symbol:       "USDC", decimals: 6, balance_slot: 9,  // FiatToken: slot 9
            price_8dec:   100_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000002"),
        },
        supply_amount: scaled(1, 18),
        borrow_amount: scaled(500, 6),
    }
}

fn weth_usdc_arbitrum() -> SimConfig {
    SimConfig {
        chain:  "arbitrum",
        pool:   address!("794a61358D6845594F94dc1DB02A252b5b4814aD"),
        oracle: address!("b56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7"),
        collateral: TokenConfig {
            addr:         address!("82aF49447D8a07e3bd95BD0d56f35241523fBab1"),
            atoken:       address!("e50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8"),
            var_debt:     address!("0c84331e39d6658Cd6e6b9ba04736cC4c4734351"),
            symbol:       "WETH", decimals: 18, balance_slot: 51, // OZ ERC20Upgradeable: slot 51
            price_8dec:   250_000_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000003"),
        },
        borrow: TokenConfig {
            addr:         address!("af88d065e77c8cC2239327C5EDb3A432268e5831"),
            atoken:       address!("724dc807b04555b71ed48a6896b6F41593b8C637"),
            var_debt:     address!("f611aEb5013fD2c0511c9CD55c7dc5C1140741A0"),
            symbol:       "USDC", decimals: 6, balance_slot: 9,
            price_8dec:   100_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000004"),
        },
        supply_amount: scaled(1, 18),
        borrow_amount: scaled(500, 6),
    }
}

fn weth_usdc_base() -> SimConfig {
    SimConfig {
        chain:  "base",
        pool:   address!("A238Dd80C259a72e81d7e4664a9801593F98d1c5"),
        oracle: address!("2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156"),
        collateral: TokenConfig {
            addr:         address!("4200000000000000000000000000000000000006"),
            atoken:       address!("D4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7"),
            var_debt:     address!("24e6e0795b3c7c71D965fCc4f371803d1c1DcA1e"),
            symbol:       "WETH", decimals: 18, balance_slot: 3, // WETH9 predeploy: slot 3
            price_8dec:   250_000_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000005"),
        },
        borrow: TokenConfig {
            addr:         address!("833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
            atoken:       address!("4e65fE4DbA92790696d040ac24Aa414708F5c0AB"),
            var_debt:     address!("59dca05b6c26dbd64b5381374aAaC5CD05644C28"),
            symbol:       "USDC", decimals: 6, balance_slot: 9,
            price_8dec:   100_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000006"),
        },
        supply_amount: scaled(1, 18),
        borrow_amount: scaled(500, 6),
    }
}

fn weth_usdc_optimism() -> SimConfig {
    SimConfig {
        chain:  "optimism",
        pool:   address!("794a61358D6845594F94dc1DB02A252b5b4814aD"),
        oracle: address!("D81eb3728a631871a7eBBaD631b5f424909f0c77"),
        collateral: TokenConfig {
            addr:         address!("4200000000000000000000000000000000000006"),
            atoken:       address!("e50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8"),
            var_debt:     address!("0c84331e39d6658Cd6e6b9ba04736cC4c4734351"),
            symbol:       "WETH", decimals: 18, balance_slot: 3,
            price_8dec:   250_000_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000007"),
        },
        borrow: TokenConfig {
            addr:         address!("0b2C639c533813f4Aa9D7837CAf62653d097Ff85"),
            atoken:       address!("38d693cE1dF5AaDF7bC62595A37D667aD57922e5"),
            var_debt:     address!("5D557B07776D12967914379C71a1310e917C7555"),
            symbol:       "USDC", decimals: 6, balance_slot: 9,
            price_8dec:   100_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000008"),
        },
        supply_amount: scaled(1, 18),
        borrow_amount: scaled(500, 6),
    }
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn scaled(n: u64, decimals: u8) -> U256 {
    U256::from(n) * U256::from(10u64).pow(U256::from(decimals as u64))
}

fn mapping_slot(addr: Address, slot: u64) -> U256 {
    let mut buf = [0u8; 64];
    buf[12..32].copy_from_slice(addr.as_slice());
    buf[56..64].copy_from_slice(&slot.to_be_bytes());
    U256::from_be_bytes(keccak256(buf).0)
}

fn to_b256(v: U256) -> B256 { B256::from(v.to_be_bytes::<32>()) }

fn addr_to_b256(a: Address) -> B256 {
    let mut b = [0u8; 32];
    b[12..32].copy_from_slice(a.as_slice());
    B256::from(b)
}

fn fmt(amount: U256, decimals: u8) -> String {
    format_units(amount, decimals).unwrap_or_else(|_| amount.to_string())
}

fn fmt_hf(hf: U256) -> String {
    if hf == U256::MAX { return "∞".into(); }
    format!("{:.4}", fmt(hf, 18).parse::<f64>().unwrap_or(0.0))
}

fn short(a: Address) -> String {
    if a.is_zero() { return "0x0".into(); }
    let h = hex::encode(a.as_slice());
    format!("0x{}…{}", &h[..4], &h[36..])
}

fn token_info(cfg: &SimConfig, addr: Address) -> (String, u8) {
    for tok in [cfg.collateral, cfg.borrow] {
        if addr == tok.addr     { return (tok.symbol.into(),              tok.decimals); }
        if addr == tok.atoken   { return (format!("a{}",     tok.symbol), tok.decimals); }
        if addr == tok.var_debt { return (format!("vDebt{}", tok.symbol), tok.decimals); }
    }
    ("?token".into(), 18)
}

fn log_transfers(logs: &[Log], cfg: &SimConfig, ch: &str) {
    let xfer_sig: B256 = keccak256(b"Transfer(address,address,uint256)");
    for log in logs {
        let topics = log.topics();
        if topics.first() != Some(&xfer_sig) || topics.len() < 3 { continue; }
        let from  = Address::from_slice(&topics[1][12..]);
        let to    = Address::from_slice(&topics[2][12..]);
        let value = U256::from_be_slice(log.data().data.as_ref());
        let (sym, dec) = token_info(cfg, log.address());
        let from_s = if from.is_zero() { "0x0(mint)".into() } else { short(from) };
        let to_s   = if to.is_zero()   { "0x0(burn)".into() } else { short(to) };
        println!("[{ch}]   ↔ {sym:<14}  {from_s} → {to_s}  {}", fmt(value, dec));
    }
}

// ── pool state injection ─────────────────────────────────────────────────────

fn oracle_source_slot(asset: Address) -> U256 { mapping_slot(asset, 0) }

// Pool layout: VersionedInitializable has uint256[50] __gap (slots 2-51)
//   slot 54: _reservesList   slot 58: packed …|reservesCount(u16 at bits 192-207)
fn reserve_list_slot(idx: u64) -> U256 {
    let mut buf = [0u8; 64];
    buf[24..32].copy_from_slice(&idx.to_be_bytes());
    buf[56..64].copy_from_slice(&54u64.to_be_bytes());
    U256::from_be_bytes(keccak256(buf).0)
}

async fn setup<P>(provider: &P, cfg: &SimConfig) -> Result<()>
where
    P: AnvilApi<Ethereum> + Sync,
{
    let ch   = cfg.chain;
    let code = Bytes::from(hex::decode(MOCK_FEED_BYTECODE)?);

    for tok in [cfg.collateral, cfg.borrow] {
        provider.anvil_set_code(tok.mock_feed, code.clone()).await?;
        provider.anvil_set_storage_at(cfg.oracle, oracle_source_slot(tok.addr), addr_to_b256(tok.mock_feed)).await?;
        provider.anvil_set_storage_at(tok.mock_feed, U256::ZERO, to_b256(U256::from(tok.price_8dec))).await?;
        println!("[{ch}]   oracle {}  ${:.2}", tok.symbol, tok.price_8dec as f64 / 1e8);
    }

    provider.anvil_set_storage_at(cfg.pool, reserve_list_slot(0), addr_to_b256(cfg.collateral.addr)).await?;
    provider.anvil_set_storage_at(cfg.pool, reserve_list_slot(1), addr_to_b256(cfg.borrow.addr)).await?;
    provider.anvil_set_storage_at(cfg.pool, U256::from(58u64), to_b256(U256::from(2u64) << 192)).await?;
    println!("[{ch}]   reserves [0]={} [1]={}", cfg.collateral.symbol, cfg.borrow.symbol);

    let col_liq = cfg.supply_amount * U256::from(100);
    provider.anvil_set_storage_at(cfg.collateral.addr, mapping_slot(cfg.collateral.atoken, cfg.collateral.balance_slot), to_b256(col_liq)).await?;
    let bor_liq = scaled(5_000_000, cfg.borrow.decimals);
    provider.anvil_set_storage_at(cfg.borrow.addr, mapping_slot(cfg.borrow.atoken, cfg.borrow.balance_slot), to_b256(bor_liq)).await?;
    println!("[{ch}]   a{} liq {}  a{} liq {}",
        cfg.collateral.symbol, fmt(col_liq, cfg.collateral.decimals),
        cfg.borrow.symbol,     fmt(bor_liq, cfg.borrow.decimals));

    Ok(())
}

// ── simulation ────────────────────────────────────────────────────────────────

async fn run_sim(cfg: SimConfig) -> Result<()> {
    let ch = cfg.chain;

    // 1. container
    println!("\n[{ch}] starting anvil-defi-fixtures...");
    let container = GenericImage::new("anvil-defi-fixtures", "latest")
        .with_exposed_port(8545.tcp())
        .with_wait_for(WaitFor::message_on_stdout("offline Anvil ready"))
        .with_env_var("CHAIN_NAME", ch)
        .with_env_var("RPC_PORT", "8545")
        .start()
        .await?;

    let port    = container.get_host_port_ipv4(8545).await?;
    let rpc_url = format!("http://127.0.0.1:{port}");
    let ws_url  = format!("ws://127.0.0.1:{port}");
    println!("[{ch}] anvil → {rpc_url}");

    // 2. wallet
    let signer: PrivateKeySigner = PrivateKeySigner::random();
    let me     = signer.address();
    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer))
        .connect_http(rpc_url.parse()?);
    println!("[{ch}] wallet {me}");

    // 3. fund + setup
    provider.anvil_set_balance(me, scaled(1, 18)).await?;
    provider.anvil_set_storage_at(cfg.collateral.addr, mapping_slot(me, cfg.collateral.balance_slot), to_b256(cfg.supply_amount * U256::from(2))).await?;
    provider.anvil_set_storage_at(cfg.borrow.addr,     mapping_slot(me, cfg.borrow.balance_slot),     to_b256(cfg.borrow_amount / U256::from(10))).await?;
    setup(&provider, &cfg).await?;

    let oracle    = IAaveOracle::new(cfg.oracle, &provider);
    let col_price = oracle.getAssetPrice(cfg.collateral.addr).call().await?;
    let bor_price = oracle.getAssetPrice(cfg.borrow.addr).call().await?;
    println!("[{ch}]   verify {}={} {}={}", cfg.collateral.symbol, fmt(col_price, 8), cfg.borrow.symbol, fmt(bor_price, 8));

    // 4. approve
    let col_erc20 = IERC20::new(cfg.collateral.addr, &provider);
    let bor_erc20 = IERC20::new(cfg.borrow.addr,     &provider);
    col_erc20.approve(cfg.pool, U256::MAX).send().await?.watch().await?;
    bor_erc20.approve(cfg.pool, U256::MAX).send().await?.watch().await?;

    // 5. supply
    println!("[{ch}] supply {} {}", fmt(cfg.supply_amount, cfg.collateral.decimals), cfg.collateral.symbol);
    let pool = IAaveV3Pool::new(cfg.pool, &provider);
    let r = pool.supply(cfg.collateral.addr, cfg.supply_amount, me, 0).send().await?.get_receipt().await?;
    log_transfers(r.inner.logs(), &cfg, ch);

    let d = pool.getUserAccountData(me).call().await?;
    println!("[{ch}]   collateral {} USD  avail {} USD  HF {}", fmt(d.totalCollateralBase, 8), fmt(d.availableBorrowsBase, 8), fmt_hf(d.healthFactor));

    // 6. borrow
    println!("[{ch}] borrow {} {}", fmt(cfg.borrow_amount, cfg.borrow.decimals), cfg.borrow.symbol);
    let r = pool.borrow(cfg.borrow.addr, cfg.borrow_amount, U256::from(2u64), 0, me).send().await?.get_receipt().await?;
    log_transfers(r.inner.logs(), &cfg, ch);

    let d = pool.getUserAccountData(me).call().await?;
    println!("[{ch}]   debt {} USD  HF {}", fmt(d.totalDebtBase, 8), fmt_hf(d.healthFactor));

    // 7. subscribe blocks + mine 5 days
    println!("[{ch}] mining 5 blocks (5 days)...");
    let ws         = ProviderBuilder::new().connect_ws(WsConnect::new(&ws_url)).await?;
    let pool_ws    = IAaveV3Pool::new(cfg.pool,           ws.clone());
    let col_tok_ws = IERC20::new(cfg.collateral.atoken,   ws.clone());
    let bor_tok_ws = IERC20::new(cfg.borrow.var_debt,     ws.clone());
    let mut stream = ws.subscribe_blocks().await?.into_stream();
    let col_sym = cfg.collateral.symbol;
    let col_dec = cfg.collateral.decimals;
    let bor_sym = cfg.borrow.symbol;
    let bor_dec = cfg.borrow.decimals;

    let watcher = tokio::spawn(async move {
        while let Some(header) = stream.next().await {
            let base_fee = header.base_fee_per_gas.unwrap_or_default();
            println!("[{ch}]   block #{} ts={}  base_fee={base_fee}", header.number, header.timestamp);
            let account = pool_ws.getUserAccountData(me).call().await;
            let col_bal = col_tok_ws.balanceOf(me).call().await;
            let bor_bal = bor_tok_ws.balanceOf(me).call().await;
            if let (Ok(d), Ok(ca), Ok(ba)) = (account, col_bal, bor_bal) {
                println!("[{ch}]     col {} USD  debt {} USD  HF {}  |  a{col_sym} {}  vDebt{bor_sym} {}",
                    fmt(d.totalCollateralBase, 8), fmt(d.totalDebtBase, 8), fmt_hf(d.healthFactor),
                    fmt(ca, col_dec), fmt(ba, bor_dec));
            }
        }
    });

    provider.anvil_mine(Some(5u64), Some(86_400u64)).await?;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    watcher.abort();
    let _ = watcher.await;

    // 8. repay
    println!("[{ch}] repay {} debt", cfg.borrow.symbol);
    let r = pool.repay(cfg.borrow.addr, U256::MAX, U256::from(2u64), me).send().await?.get_receipt().await?;
    log_transfers(r.inner.logs(), &cfg, ch);

    // 9. withdraw
    println!("[{ch}] withdraw {}", cfg.collateral.symbol);
    let r = pool.withdraw(cfg.collateral.addr, U256::MAX, me).send().await?.get_receipt().await?;
    log_transfers(r.inner.logs(), &cfg, ch);

    let final_col = col_erc20.balanceOf(me).call().await?;
    println!("[{ch}] final {} : {} {}", cfg.collateral.symbol, fmt(final_col, cfg.collateral.decimals), cfg.collateral.symbol);
    Ok(())
}

// ── main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tokio::try_join!(
        run_sim(weth_usdc_ethereum()),
        run_sim(weth_usdc_arbitrum()),
        run_sim(weth_usdc_base()),
        run_sim(weth_usdc_optimism()),
    )?;
    Ok(())
}
