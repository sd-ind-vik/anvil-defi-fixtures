use alloy::{
    hex,
    primitives::{address, keccak256, utils::format_units, Address, Bytes, B256, U256},
    providers::{ext::AnvilApi, Provider, ProviderBuilder},
    rpc::types::{Log, TransactionRequest},
    transports::ws::WsConnect,
    network::{Ethereum, EthereumWallet, TransactionBuilder},
    signers::local::PrivateKeySigner,
    sol,
    sol_types::SolCall,
};
use testcontainers::{
    core::{IntoContainerPort, WaitFor},
    runners::AsyncRunner,
    ContainerAsync, GenericImage, ImageExt,
};
use futures::StreamExt;
use tokio::sync::mpsc;
use eyre::Result;

// ── contract interfaces ──────────────────────────────────────────────────────

sol! {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    #[sol(rpc)]
    interface IERC20 {
        function approve(address spender, uint256 amount) external returns (bool);
        function transfer(address to, uint256 amount) external returns (bool);
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
        function liquidationCall(
            address collateralAsset,
            address debtAsset,
            address user,
            uint256 debtToCover,
            bool receiveAToken
        ) external;
        function getReserveData(address asset) external view returns (
            ReserveConfigurationMap configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );
        function getReservesList() external view returns (address[]);
    }
}

pub const MOCK_FEED_BYTECODE: &str =
    "60003560e01c806350d25bcd14601f578063313ce56714602b5760006000fd5b60005460005260206000f35b600860005260206000f3";

// ── config types ─────────────────────────────────────────────────────────────

#[derive(Copy, Clone)]
pub struct TokenConfig {
    pub addr:         Address,
    pub atoken:       Address,
    pub var_debt:     Address,
    pub symbol:       &'static str,
    pub decimals:     u8,
    pub balance_slot: u64,
    pub price_8dec:   u64,
    pub mock_feed:    Address,
}

#[derive(Copy, Clone)]
pub struct SimConfig {
    pub chain:         &'static str,
    pub pool:          Address,
    pub oracle:        Address,
    pub collateral:    TokenConfig,
    pub borrow:        TokenConfig,
    pub supply_amount: U256,
    pub borrow_amount: U256,
}

// ── per-chain pair configs ────────────────────────────────────────────────────

pub fn weth_usdc_ethereum() -> SimConfig {
    SimConfig {
        chain:  "ethereum",
        pool:   address!("87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2"),
        oracle: address!("54586bE62E3c3580375aE3723C145253060Ca0C2"),
        collateral: TokenConfig {
            addr:         address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
            atoken:       address!("4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8"),
            var_debt:     address!("eA51d7853EeFE3813aa3338B2b25259a0C5F2a01"),
            symbol:       "WETH", decimals: 18, balance_slot: 3,
            price_8dec:   250_000_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000001"),
        },
        borrow: TokenConfig {
            addr:         address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
            atoken:       address!("98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c"),
            var_debt:     address!("72E95b8931767C79bA4EeE721354d6E99a61D004"),
            symbol:       "USDC", decimals: 6, balance_slot: 9,
            price_8dec:   100_000_000,
            mock_feed:    address!("DEAD000000000000000000000000000000000002"),
        },
        supply_amount: scaled(1, 18),
        borrow_amount: scaled(500, 6),
    }
}

pub fn weth_usdc_arbitrum() -> SimConfig {
    SimConfig {
        chain:  "arbitrum",
        pool:   address!("794a61358D6845594F94dc1DB02A252b5b4814aD"),
        oracle: address!("b56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7"),
        collateral: TokenConfig {
            addr:         address!("82aF49447D8a07e3bd95BD0d56f35241523fBab1"),
            atoken:       address!("e50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8"),
            var_debt:     address!("0c84331e39d6658Cd6e6b9ba04736cC4c4734351"),
            symbol:       "WETH", decimals: 18, balance_slot: 51,
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

pub fn weth_usdc_base() -> SimConfig {
    SimConfig {
        chain:  "base",
        pool:   address!("A238Dd80C259a72e81d7e4664a9801593F98d1c5"),
        oracle: address!("2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156"),
        collateral: TokenConfig {
            addr:         address!("4200000000000000000000000000000000000006"),
            atoken:       address!("D4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7"),
            var_debt:     address!("24e6e0795b3c7c71D965fCc4f371803d1c1DcA1e"),
            symbol:       "WETH", decimals: 18, balance_slot: 3,
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

pub fn weth_usdc_optimism() -> SimConfig {
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

pub fn scaled(n: u64, decimals: u8) -> U256 {
    U256::from(n) * U256::from(10u64).pow(U256::from(decimals as u64))
}

pub fn fmt(amount: U256, decimals: u8) -> String {
    format_units(amount, decimals).unwrap_or_else(|_| amount.to_string())
}

pub fn fmt_hf(hf: U256) -> String {
    if hf == U256::MAX { return "∞".into(); }
    format!("{:.4}", fmt(hf, 18).parse::<f64>().unwrap_or(0.0))
}

pub fn mapping_slot(addr: Address, slot: u64) -> U256 {
    let mut buf = [0u8; 64];
    buf[12..32].copy_from_slice(addr.as_slice());
    buf[56..64].copy_from_slice(&slot.to_be_bytes());
    U256::from_be_bytes(keccak256(buf).0)
}

pub(crate) fn to_b256(v: U256) -> B256 { B256::from(v.to_be_bytes::<32>()) }

pub(crate) fn addr_to_b256(a: Address) -> B256 {
    let mut b = [0u8; 32];
    b[12..32].copy_from_slice(a.as_slice());
    B256::from(b)
}

pub(crate) fn short(a: Address) -> String {
    if a.is_zero() { return "0x0".into(); }
    let h = hex::encode(a.as_slice());
    format!("0x{}…{}", &h[..4], &h[36..])
}

pub(crate) fn token_info(cfg: &SimConfig, addr: Address) -> (String, u8) {
    for tok in [cfg.collateral, cfg.borrow] {
        if addr == tok.addr     { return (tok.symbol.into(),              tok.decimals); }
        if addr == tok.atoken   { return (format!("a{}",     tok.symbol), tok.decimals); }
        if addr == tok.var_debt { return (format!("vDebt{}", tok.symbol), tok.decimals); }
    }
    ("?token".into(), 18)
}

pub(crate) fn log_transfers(logs: &[Log], cfg: &SimConfig, ch: &str) {
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

pub(crate) fn oracle_source_slot(asset: Address) -> U256 { mapping_slot(asset, 0) }

pub(crate) fn reserve_list_slot(idx: u64) -> U256 {
    let mut buf = [0u8; 64];
    buf[24..32].copy_from_slice(&idx.to_be_bytes());
    buf[56..64].copy_from_slice(&54u64.to_be_bytes());
    U256::from_be_bytes(keccak256(buf).0)
}

// ── ChainHandle + start_chain ─────────────────────────────────────────────────

pub struct ChainHandle {
    pub chain:   &'static str,
    pub rpc_url: String,
    pub ws_url:  String,
    pub(crate) _container: ContainerAsync<GenericImage>,
}

pub async fn start_chain(cfg: &SimConfig) -> Result<ChainHandle> {
    let ch = cfg.chain;
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
    Ok(ChainHandle { chain: ch, rpc_url, ws_url, _container: container })
}

// ── BlockEvent + subscribe_blocks ─────────────────────────────────────────────

#[derive(Debug)]
pub struct BlockEvent {
    pub chain:     String,
    pub number:    u64,
    pub timestamp: u64,
    pub base_fee:  u64,
}

pub async fn subscribe_blocks(
    chain:  String,
    ws_url: String,
    tx:     mpsc::Sender<BlockEvent>,
) -> Result<()> {
    let ws = ProviderBuilder::new().connect_ws(WsConnect::new(&ws_url)).await?;
    let mut stream = ws.subscribe_blocks().await?.into_stream();
    while let Some(hdr) = stream.next().await {
        let ev = BlockEvent {
            chain:     chain.clone(),
            number:    hdr.number,
            timestamp: hdr.timestamp,
            base_fee:  hdr.base_fee_per_gas.unwrap_or_default(),
        };
        if tx.send(ev).await.is_err() { break; }
    }
    Ok(())
}

// ── AccountData ───────────────────────────────────────────────────────────────

/// Rates are in Ray (1e27 = 100%). Divide by 1e25 to get a percentage.
#[derive(Debug, Clone)]
pub struct ReserveData {
    pub liquidity_index:              u128,
    pub current_liquidity_rate:       u128,
    pub variable_borrow_index:        u128,
    pub current_variable_borrow_rate: u128,
    pub last_update_timestamp:        u64,
    pub id:                           u16,
    pub atoken:                       Address,
    pub variable_debt_token:          Address,
    pub accrued_to_treasury:          u128,
}

/// Risk parameters for a reserve. Values in basis points (10000 = 100%).
#[derive(Debug, Clone)]
pub struct ReserveConfig {
    pub ltv:                   u64,
    pub liquidation_threshold: u64,
    pub liquidation_bonus:     u64,
    pub decimals:              u8,
    pub active:                bool,
    pub frozen:                bool,
    pub borrowing_enabled:     bool,
    pub paused:                bool,
    pub reserve_factor:        u64,
}

#[derive(Debug, Clone)]
pub struct AccountData {
    pub total_collateral_base:         U256,
    pub total_debt_base:               U256,
    pub available_borrows_base:        U256,
    pub current_liquidation_threshold: U256,
    pub ltv:                           U256,
    pub health_factor:                 U256,
}

// ── AaveClient ────────────────────────────────────────────────────────────────

pub struct AaveClient<P> {
    provider: P,
    cfg:      SimConfig,
}

impl<P: Provider + Clone> AaveClient<P> {
    pub fn new(provider: P, cfg: SimConfig) -> Self {
        Self { provider, cfg }
    }

    /// Deploy mock Chainlink feeds, point oracle to them, seed aToken liquidity.
    pub async fn setup_mock_oracle(&self) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        let ch  = self.cfg.chain;
        let code = Bytes::from(hex::decode(MOCK_FEED_BYTECODE)?);
        for tok in [self.cfg.collateral, self.cfg.borrow] {
            self.provider.anvil_set_code(tok.mock_feed, code.clone()).await?;
            self.provider.anvil_set_storage_at(
                self.cfg.oracle,
                oracle_source_slot(tok.addr),
                addr_to_b256(tok.mock_feed),
            ).await?;
            self.provider.anvil_set_storage_at(
                tok.mock_feed,
                U256::ZERO,
                to_b256(U256::from(tok.price_8dec)),
            ).await?;
            println!("[{ch}]   oracle {}  ${:.2}", tok.symbol, tok.price_8dec as f64 / 1e8);
        }
        self.provider.anvil_set_storage_at(
            self.cfg.pool, reserve_list_slot(0), addr_to_b256(self.cfg.collateral.addr),
        ).await?;
        self.provider.anvil_set_storage_at(
            self.cfg.pool, reserve_list_slot(1), addr_to_b256(self.cfg.borrow.addr),
        ).await?;
        self.provider.anvil_set_storage_at(
            self.cfg.pool, U256::from(58u64), to_b256(U256::from(2u64) << 192),
        ).await?;
        println!("[{ch}]   reserves [0]={} [1]={}",
            self.cfg.collateral.symbol, self.cfg.borrow.symbol);
        let col_liq = self.cfg.supply_amount * U256::from(100);
        self.provider.anvil_set_storage_at(
            self.cfg.collateral.addr,
            mapping_slot(self.cfg.collateral.atoken, self.cfg.collateral.balance_slot),
            to_b256(col_liq),
        ).await?;
        let bor_liq = scaled(5_000_000, self.cfg.borrow.decimals);
        self.provider.anvil_set_storage_at(
            self.cfg.borrow.addr,
            mapping_slot(self.cfg.borrow.atoken, self.cfg.borrow.balance_slot),
            to_b256(bor_liq),
        ).await?;
        println!("[{ch}]   a{} liq {}  a{} liq {}",
            self.cfg.collateral.symbol, fmt(col_liq, self.cfg.collateral.decimals),
            self.cfg.borrow.symbol,     fmt(bor_liq, self.cfg.borrow.decimals));
        Ok(())
    }

    pub async fn approve_pool(&self, asset: Address) -> Result<()> {
        let erc20 = IERC20::new(asset, &self.provider);
        erc20.approve(self.cfg.pool, U256::MAX).send().await?.watch().await?;
        Ok(())
    }

    /// Set an account's native ETH balance (Anvil only).
    pub async fn fund_eth(&self, owner: Address, amount: U256) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        self.provider.anvil_set_balance(owner, amount).await?;
        Ok(())
    }

    /// Write directly to an ERC-20 balance mapping slot (Anvil only).
    /// `balance_slot` is the storage slot index of the token's `_balances` mapping.
    pub async fn seed_token_balance(
        &self, token: Address, balance_slot: u64, owner: Address, amount: U256,
    ) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        self.provider.anvil_set_storage_at(
            token,
            mapping_slot(owner, balance_slot),
            to_b256(amount),
        ).await?;
        Ok(())
    }

    /// Seed the collateral token (e.g. WETH) balance for `owner`.
    pub async fn seed_collateral(&self, owner: Address, amount: U256) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        self.seed_token_balance(
            self.cfg.collateral.addr,
            self.cfg.collateral.balance_slot,
            owner, amount,
        ).await
    }

    /// Seed the borrow token (e.g. USDC) balance for `owner`.
    pub async fn seed_borrow(&self, owner: Address, amount: U256) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        self.seed_token_balance(
            self.cfg.borrow.addr,
            self.cfg.borrow.balance_slot,
            owner, amount,
        ).await
    }

    /// Mine one block at the current timestamp to flush pending state changes to subscribers.
    /// Use this after storage overrides (set_asset_price, seed_*) so the ingress wakes up.
    /// For time-based scenarios (interest accrual, liquidation thresholds) use mine_blocks.
    pub async fn checkpoint(&self) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        self.provider.anvil_mine(Some(1u64), Some(0u64)).await?;
        Ok(())
    }

    /// Mine `count` blocks, advancing `seconds_per_block` of chain time each.
    pub async fn mine_blocks(&self, count: u64, seconds_per_block: u64) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        self.provider.anvil_mine(Some(count), Some(seconds_per_block)).await?;
        Ok(())
    }

    /// Read an ERC-20 token balance (any token, any holder).
    pub async fn token_balance(&self, token: Address, owner: Address) -> Result<U256> {
        let erc20 = IERC20::new(token, &self.provider);
        Ok(erc20.balanceOf(owner).call().await?)
    }

    /// Send a real ERC-20 transfer — emits Transfer(from, to, value) log, mines 1 block.
    /// Use this instead of seed_token_balance when the ingress must observe the movement.
    pub async fn transfer_token(
        &self, token: Address, to: Address, amount: U256,
    ) -> Result<Vec<Log>> {
        let erc20    = IERC20::new(token, &self.provider);
        let receipt  = erc20.transfer(to, amount).send().await?.get_receipt().await?;
        Ok(receipt.inner.logs().to_vec())
    }

    /// Send native ETH — visible in the block's tx list via tx.value, mines 1 block.
    /// Returns the transaction hash. No Transfer log is emitted for native ETH.
    pub async fn send_eth(&self, to: Address, amount: U256) -> Result<B256> {
        let tx      = TransactionRequest::default().with_to(to).with_value(amount);
        let receipt = self.provider.send_transaction(tx).await?.get_receipt().await?;
        Ok(receipt.transaction_hash)
    }

    /// Allow Anvil to accept transactions from `account` without its private key.
    pub async fn impersonate(&self, account: Address) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        self.provider.anvil_impersonate_account(account).await?;
        Ok(())
    }

    /// Revoke impersonation for `account`.
    pub async fn stop_impersonating(&self, account: Address) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        self.provider.anvil_stop_impersonating_account(account).await?;
        Ok(())
    }

    /// Send native ETH as an impersonated address — mines 1 block, no Transfer log.
    pub async fn send_eth_as(
        &self, from: Address, to: Address, amount: U256,
    ) -> Result<B256> {
        let tx = TransactionRequest::default()
            .with_from(from)
            .with_to(to)
            .with_value(amount);
        let receipt = self.provider.send_transaction(tx).await?.get_receipt().await?;
        Ok(receipt.transaction_hash)
    }

    /// Send an ERC-20 transfer as an impersonated address — emits Transfer log, mines 1 block.
    pub async fn transfer_token_as(
        &self, from: Address, token: Address, to: Address, amount: U256,
    ) -> Result<Vec<Log>> {
        let calldata = IERC20::transferCall { to, amount }.abi_encode();
        let tx = TransactionRequest::default()
            .with_from(from)
            .with_to(token)
            .with_input(Bytes::from(calldata));
        let receipt = self.provider.send_transaction(tx).await?.get_receipt().await?;
        Ok(receipt.inner.logs().to_vec())
    }

    pub async fn supply(
        &self, asset: Address, amount: U256, on_behalf_of: Address,
    ) -> Result<Vec<Log>> {
        let pool    = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let receipt = pool.supply(asset, amount, on_behalf_of, 0)
            .send().await?.get_receipt().await?;
        Ok(receipt.inner.logs().to_vec())
    }

    pub async fn borrow(
        &self, asset: Address, amount: U256, on_behalf_of: Address,
    ) -> Result<Vec<Log>> {
        let pool    = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let receipt = pool.borrow(asset, amount, U256::from(2u64), 0, on_behalf_of)
            .send().await?.get_receipt().await?;
        Ok(receipt.inner.logs().to_vec())
    }

    pub async fn repay(
        &self, asset: Address, amount: U256, on_behalf_of: Address,
    ) -> Result<Vec<Log>> {
        let pool    = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let receipt = pool.repay(asset, amount, U256::from(2u64), on_behalf_of)
            .send().await?.get_receipt().await?;
        Ok(receipt.inner.logs().to_vec())
    }

    pub async fn withdraw(
        &self, asset: Address, amount: U256, to: Address,
    ) -> Result<Vec<Log>> {
        let pool    = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let receipt = pool.withdraw(asset, amount, to)
            .send().await?.get_receipt().await?;
        Ok(receipt.inner.logs().to_vec())
    }

    pub async fn get_account_data(&self, user: Address) -> Result<AccountData> {
        let pool = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let d    = pool.getUserAccountData(user).call().await?;
        Ok(AccountData {
            total_collateral_base:         d.totalCollateralBase,
            total_debt_base:               d.totalDebtBase,
            available_borrows_base:        d.availableBorrowsBase,
            current_liquidation_threshold: d.currentLiquidationThreshold,
            ltv:                           d.ltv,
            health_factor:                 d.healthFactor,
        })
    }

    pub async fn get_asset_price(&self, asset: Address) -> Result<U256> {
        let oracle = IAaveOracle::new(self.cfg.oracle, &self.provider);
        Ok(oracle.getAssetPrice(asset).call().await?)
    }

    /// Supply APR, borrow APR, liquidity index, last update timestamp, token addresses.
    pub async fn get_reserve_data(&self, asset: Address) -> Result<ReserveData> {
        let pool = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let d    = pool.getReserveData(asset).call().await?;
        Ok(ReserveData {
            liquidity_index:              d.liquidityIndex,
            current_liquidity_rate:       d.currentLiquidityRate,
            variable_borrow_index:        d.variableBorrowIndex,
            current_variable_borrow_rate: d.currentVariableBorrowRate,
            last_update_timestamp:        d.lastUpdateTimestamp.to::<u64>(),
            id:                           d.id,
            atoken:                       d.aTokenAddress,
            variable_debt_token:          d.variableDebtTokenAddress,
            accrued_to_treasury:          d.accruedToTreasury,
        })
    }

    /// LTV, liquidation threshold, liquidation bonus, and flags — unpacked from the
    /// configuration bitmap stored in the reserve's storage slot.
    pub async fn get_reserve_config(&self, asset: Address) -> Result<ReserveConfig> {
        let pool = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let d    = pool.getReserveData(asset).call().await?;
        let data = d.configuration.data;
        let f    = |shift: u32, mask: u64| -> u64 {
            ((data >> U256::from(shift)) & U256::from(mask)).as_limbs()[0]
        };
        Ok(ReserveConfig {
            ltv:                   f(0,  0xFFFF),
            liquidation_threshold: f(16, 0xFFFF),
            liquidation_bonus:     f(32, 0xFFFF),
            decimals:              f(48, 0xFF) as u8,
            active:                f(56, 1) != 0,
            frozen:                f(57, 1) != 0,
            borrowing_enabled:     f(58, 1) != 0,
            paused:                f(60, 1) != 0,
            reserve_factor:        f(64, 0xFFFF),
        })
    }

    /// All active reserve addresses in the pool.
    pub async fn get_reserves_list(&self) -> Result<Vec<Address>> {
        let pool = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        Ok(pool.getReservesList().call().await?)
    }

    /// Overwrite LTV, liquidation threshold, and liquidation bonus for a reserve.
    /// Values in basis points (e.g. ltv=8000, threshold=8250, bonus=10500).
    /// Reads the existing bitmap and preserves all other config bits (flags, decimals, etc.).
    /// Silent — call checkpoint() after if the ingress needs to observe the change.
    pub async fn set_reserve_config(
        &self, asset: Address, ltv: u64, threshold: u64, bonus: u64,
    ) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        let pool = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let d    = pool.getReserveData(asset).call().await?;
        let mut data = d.configuration.data;

        // clear bits 0-47 (ltv | liquidation_threshold | liquidation_bonus)
        data &= !U256::from((1u128 << 48) - 1);
        data |= U256::from(ltv       & 0xFFFF);
        data |= U256::from(threshold & 0xFFFF) << U256::from(16u64);
        data |= U256::from(bonus     & 0xFFFF) << U256::from(32u64);

        // _reserves[asset].configuration.data is at mapping_slot(asset, 52)
        // slot 52 = _reserves in PoolStorage (slot 54 = _reservesList, offset 2 later)
        self.provider.anvil_set_storage_at(
            self.cfg.pool,
            mapping_slot(asset, 52),
            to_b256(data),
        ).await?;
        Ok(())
    }

    /// Override the mock Chainlink feed price for an asset (8-decimal USD value).
    /// Only works for assets whose mock_feed was deployed by `setup_mock_oracle`.
    pub async fn set_asset_price(&self, asset: Address, price_8dec: u64) -> Result<()>
    where
        P: AnvilApi<Ethereum> + Sync,
    {
        let mock_feed = if asset == self.cfg.collateral.addr {
            self.cfg.collateral.mock_feed
        } else if asset == self.cfg.borrow.addr {
            self.cfg.borrow.mock_feed
        } else {
            return Err(eyre::eyre!("set_asset_price: unknown asset {asset}"));
        };
        self.provider.anvil_set_storage_at(
            mock_feed, U256::ZERO, to_b256(U256::from(price_8dec)),
        ).await?;
        Ok(())
    }

    /// Liquidate an underwater position (healthFactor < 1).
    /// The caller must hold enough `debt_asset` to cover `debt_to_cover` and have
    /// approved the pool. Pass `U256::MAX` to let Aave cap at the 50% close factor.
    pub async fn liquidate(
        &self,
        collateral_asset: Address,
        debt_asset:       Address,
        borrower:         Address,
        debt_to_cover:    U256,
        receive_atoken:   bool,
    ) -> Result<Vec<Log>> {
        let pool    = IAaveV3Pool::new(self.cfg.pool, &self.provider);
        let receipt = pool
            .liquidationCall(collateral_asset, debt_asset, borrower, debt_to_cover, receive_atoken)
            .send().await?.get_receipt().await?;
        Ok(receipt.inner.logs().to_vec())
    }
}

// ── run_sim_actions ───────────────────────────────────────────────────────────

pub async fn run_sim_actions(cfg: SimConfig, rpc_url: String) -> Result<()> {
    let ch = cfg.chain;

    let signer: PrivateKeySigner = PrivateKeySigner::random();
    let me = signer.address();
    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer))
        .connect_http(rpc_url.parse()?);
    println!("[{ch}] wallet {me}");

    let client = AaveClient::new(provider.clone(), cfg);
    client.fund_eth(me, scaled(1, 18)).await?;
    client.seed_collateral(me, cfg.supply_amount * U256::from(2)).await?;
    client.seed_borrow(me, cfg.borrow_amount / U256::from(10)).await?;
    client.setup_mock_oracle().await?;

    let col_price = client.get_asset_price(cfg.collateral.addr).await?;
    let bor_price = client.get_asset_price(cfg.borrow.addr).await?;
    println!("[{ch}]   verify {}={} {}={}",
        cfg.collateral.symbol, fmt(col_price, 8),
        cfg.borrow.symbol,     fmt(bor_price, 8));

    client.approve_pool(cfg.collateral.addr).await?;
    client.approve_pool(cfg.borrow.addr).await?;

    println!("[{ch}] supply {} {}", fmt(cfg.supply_amount, cfg.collateral.decimals), cfg.collateral.symbol);
    let logs = client.supply(cfg.collateral.addr, cfg.supply_amount, me).await?;
    log_transfers(&logs, &cfg, ch);
    let d = client.get_account_data(me).await?;
    println!("[{ch}]   collateral {} USD  avail {} USD  HF {}",
        fmt(d.total_collateral_base, 8), fmt(d.available_borrows_base, 8), fmt_hf(d.health_factor));

    println!("[{ch}] borrow {} {}", fmt(cfg.borrow_amount, cfg.borrow.decimals), cfg.borrow.symbol);
    let logs = client.borrow(cfg.borrow.addr, cfg.borrow_amount, me).await?;
    log_transfers(&logs, &cfg, ch);
    let d = client.get_account_data(me).await?;
    println!("[{ch}]   debt {} USD  HF {}", fmt(d.total_debt_base, 8), fmt_hf(d.health_factor));

    println!("[{ch}] mining 5 blocks (5 days)...");
    client.mine_blocks(5, 86_400).await?;
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;

    println!("[{ch}] repay {} debt", cfg.borrow.symbol);
    let logs = client.repay(cfg.borrow.addr, U256::MAX, me).await?;
    log_transfers(&logs, &cfg, ch);

    println!("[{ch}] withdraw {}", cfg.collateral.symbol);
    let logs = client.withdraw(cfg.collateral.addr, U256::MAX, me).await?;
    log_transfers(&logs, &cfg, ch);

    let col_erc20 = IERC20::new(cfg.collateral.addr, &provider);
    let final_col = col_erc20.balanceOf(me).call().await?;
    println!("[{ch}] final {} : {} {}",
        cfg.collateral.symbol,
        fmt(final_col, cfg.collateral.decimals),
        cfg.collateral.symbol);
    Ok(())
}
