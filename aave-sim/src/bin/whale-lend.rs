//! Whale USDC transfer + Aave v3 lend against a running anvil fork.
//!
//! Targets, in order: $RPC_URL if set; the dockerized fixture if ANVIL_DOCKER=1;
//! otherwise http://127.0.0.1:8545.
//!
//!   cargo run --bin whale-lend
//!   ANVIL_DOCKER=1 cargo run --bin whale-lend

use aave_sim::{fmt, scaled, start_chain, weth_usdc_ethereum, AaveClient};
use alloy::{
    network::EthereumWallet,
    primitives::{address, Address, U256},
    providers::ProviderBuilder,
    signers::local::PrivateKeySigner,
};
use eyre::Result;

const WHALE: Address = address!("28C6c06298d514Db089934071355E5743bf21d60"); // Binance 14
const ANVIL_KEY: &str = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil dev account 0

#[tokio::main]
async fn main() -> Result<()> {
    let cfg  = weth_usdc_ethereum();
    let usdc = cfg.borrow.addr;
    let dec  = cfg.borrow.decimals;

    let mut _docker = None; // keeps the container alive for the whole run
    let rpc_url = match std::env::var("RPC_URL") {
        Ok(url) => url,
        Err(_) if std::env::var("ANVIL_DOCKER").is_ok() => {
            let handle = start_chain(&cfg).await?;
            let url = handle.rpc_url.clone();
            _docker = Some(handle);
            url
        }
        Err(_) => "http://127.0.0.1:8545".into(),
    };
    println!("rpc: {rpc_url}");

    let signer: PrivateKeySigner = ANVIL_KEY.parse()?;
    let me = signer.address();
    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(signer))
        .connect_http(rpc_url.parse()?);
    let client = AaveClient::new(provider, cfg);
    // walletless provider: impersonated txs must be signed by anvil, not locally
    let node_signed = AaveClient::new(ProviderBuilder::new().connect_http(rpc_url.parse()?), cfg);

    let amount = scaled(1_000, dec);

    // ── whale USDC transfer ──────────────────────────────────────────────────
    println!("whale USDC: {}", fmt(client.token_balance(usdc, WHALE).await?, dec));
    println!("me    USDC: {}", fmt(client.token_balance(usdc, me).await?, dec));

    node_signed.impersonate(WHALE).await?;
    node_signed.fund_eth(WHALE, scaled(1, 18)).await?;
    if node_signed.token_balance(usdc, WHALE).await? < amount {
        // offline fixture state has no exchange balances — seed the whale first
        node_signed.seed_token_balance(usdc, cfg.borrow.balance_slot, WHALE, amount * U256::from(10)).await?;
    }
    node_signed.transfer_token_as(WHALE, usdc, me, amount).await?;
    node_signed.stop_impersonating(WHALE).await?;

    println!("--- after whale transfer of {} USDC", fmt(amount, dec));
    println!("whale USDC: {}", fmt(client.token_balance(usdc, WHALE).await?, dec));
    println!("me    USDC: {}", fmt(client.token_balance(usdc, me).await?, dec));

    // ── aave lend ────────────────────────────────────────────────────────────
    client.fund_eth(me, scaled(1, 18)).await?; // gas
    let before = client.get_account_data(me).await?;
    client.approve_pool(usdc).await?;
    client.supply(usdc, amount, me).await?;
    let after = client.get_account_data(me).await?;

    println!("--- after lending {} USDC", fmt(amount, dec));
    println!("me    USDC: {}", fmt(client.token_balance(usdc, me).await?, dec));
    println!(
        "collateral USD: {} -> {}",
        fmt(before.total_collateral_base, 8),
        fmt(after.total_collateral_base, 8),
    );
    assert!(after.total_collateral_base > before.total_collateral_base, "supply not reflected");
    println!("ok");
    Ok(())
}
