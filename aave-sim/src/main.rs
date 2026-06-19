use aave_sim::{
    start_chain, subscribe_blocks, run_sim_actions,
    weth_usdc_ethereum, weth_usdc_arbitrum, weth_usdc_base, weth_usdc_optimism,
    BlockEvent,
};
use tokio::{sync::mpsc, task::JoinSet};
use futures::future::try_join_all;
use eyre::Result;

#[tokio::main]
async fn main() -> Result<()> {
    let cfgs = [
        weth_usdc_ethereum(),
        weth_usdc_arbitrum(),
        weth_usdc_base(),
        weth_usdc_optimism(),
    ];

    let handles = try_join_all(cfgs.iter().map(start_chain)).await?;

    let (tx, mut rx) = mpsc::channel::<BlockEvent>(64);

    let mut subscribers: JoinSet<Result<()>> = JoinSet::new();
    let mut sims:        JoinSet<Result<()>> = JoinSet::new();

    for (cfg, handle) in cfgs.into_iter().zip(handles.iter()) {
        subscribers.spawn(subscribe_blocks(
            handle.chain.to_string(),
            handle.ws_url.clone(),
            tx.clone(),
        ));
        sims.spawn(run_sim_actions(cfg, handle.rpc_url.clone()));
    }
    drop(tx);

    let mut sims_running = true;

    loop {
        tokio::select! {
            Some(ev) = rx.recv() => {
                println!(
                    "[{}] ▶ block #{:<12}  ts={:>12}  base_fee={}",
                    ev.chain, ev.number, ev.timestamp, ev.base_fee
                );
            }

            Some(res) = sims.join_next(), if sims_running => {
                res??;
                if sims.is_empty() {
                    sims_running = false;
                    subscribers.abort_all();
                }
            }

            else => break,
        }
    }

    Ok(())
}
