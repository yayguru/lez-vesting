//! Measured cost (CU) of every operation, and the per-transaction batch maximum.
//!
//! LEZ 0.4 prices a public transaction in two gas dimensions (lez/programs/fee/core):
//! execution gas = RISC Zero cycles of the action, storage gas = the transaction's borsh wire
//! bytes. Per transaction: cycles <= MAX_GAS_EXEC (10,000,000), bytes <= MAX_GAS_STOR
//! (1,000,000), and RPC caps size at max_block_size - 2,048. Run with
//! `cargo test -p vesting_tests --test costs -- --nocapture` to print the table.

use lee::{PublicTransaction, ValidatedStateDiff, V03State};
use vesting_core::{Kind, MAX_BATCH_RECIPIENTS, Message, Params};
use vesting_tests::*;

const MAX_GAS_EXEC: u64 = 10_000_000; // fee_core::market::MAX_GAS_EXEC
const MAX_GAS_STOR: u64 = 1_000_000; // fee_core::market::MAX_GAS_STOR

/// (cycles, wire bytes) of `tx` against `state`, without applying it. Panics if it reverts.
fn measure(state: &V03State, tx: &PublicTransaction, now: u64) -> (u64, u64) {
    let (charge, diff) = ValidatedStateDiff::from_public_transaction_metered(tx, state, 1, now, u64::MAX);
    assert!(charge.revert.is_none() && diff.is_ok(), "reverted: {:?}", charge.revert);
    (charge.cycles, borsh::to_vec(tx).unwrap().len() as u64)
}

fn batch_tx(e: &Env, n: usize) -> PublicTransaction {
    let ids: Vec<[u8; 32]> = (0..n).map(|i| { let mut id = [0xB0; 32]; id[..8].copy_from_slice(&(i as u64).to_le_bytes()); id }).collect();
    let entries = ids.iter().map(|id| (*id, linear(e.alice.id, 10, 0, 0, 10))).collect();
    tx(&e.creator, create_actors(e.creator.id, &ids), &create_msg(entries))
}

fn fits(e: &Env, n: usize) -> bool {
    let t = batch_tx(e, n);
    let (charge, _) = ValidatedStateDiff::from_public_transaction_metered(&t, &e.state, 1, 0, u64::MAX);
    let bytes = borsh::to_vec(&t).unwrap().len() as u64;
    charge.revert.is_none() && charge.cycles <= MAX_GAS_EXEC && bytes <= MAX_GAS_STOR
}

#[test]
fn cost_table_and_batch_maximum() {
    let mut e = env();
    let (c, a, b) = (e.creator.id, e.alice.id, e.bob.id);
    let mut rows: Vec<(&str, u64, u64)> = vec![];
    let run = |e: &mut Env, who: u8, name: &'static str, actors, msg: Message, now: u64, rows: &mut Vec<(&str, u64, u64)>| {
        let user = match who { 1 => &mut e.creator, 2 => &mut e.alice, _ => &mut e.bob };
        let t = tx(user, actors, &msg);
        let (cy, by) = measure(&e.state, &t, now);
        e.state.transition_from_public_transaction(&t, 1, now).expect(name);
        user.nonce += 1;
        rows.push((name, cy, by));
    };
    let (lin, ms, cx) = ([1; 32], [2; 32], [3; 32]);
    let mut p = linear(a, 1_000_000, 0, 100, 1000);
    p.transferable = true;
    run(&mut e, 1, "create (1 linear schedule)", create_actors(c, &[lin]), create_msg(vec![(lin, p)]), 0, &mut rows);
    let mp = Params { beneficiary: a, total: 30, kind: Kind::Milestones { amounts: vec![10, 20] }, cancelable: true, transferable: false };
    run(&mut e, 1, "create (1 milestone schedule)", create_actors(c, &[ms]), create_msg(vec![(ms, mp)]), 0, &mut rows);
    run(&mut e, 1, "signal milestone", admin_actors(c, c, ms), Message::SignalMilestone { id: ms, index: 0 }, 1, &mut rows);
    run(&mut e, 2, "claim (public)", claim_actors(a, c, lin, a), Message::Claim { creator: c, id: lin, now: 500, to: a }, 500, &mut rows);
    run(&mut e, 2, "transfer beneficiary", admin_actors(a, c, lin), Message::TransferBeneficiary { creator: c, id: lin, new_beneficiary: b }, 500, &mut rows);
    run(&mut e, 1, "make irrevocable", admin_actors(c, c, ms), Message::MakeIrrevocable { id: ms }, 500, &mut rows);
    run(&mut e, 1, "create (for cancel)", create_actors(c, &[cx]), create_msg(vec![(cx, linear(a, 1000, 0, 0, 1000))]), 500, &mut rows);
    run(&mut e, 1, "cancel", cancel_actors(c, cx), Message::Cancel { id: cx, now: 600 }, 600, &mut rows);

    // Batch: per-recipient marginal cost and the largest batch inside the per-tx limits.
    let one = measure(&e.state, &batch_tx(&e, 1), 0);
    let ten = measure(&e.state, &batch_tx(&e, 10), 0);
    // Largest n that fits (binary search; fits() is monotone in n).
    let (mut lo, mut hi) = (1usize, 1024usize);
    assert!(fits(&e, lo) && !fits(&e, hi));
    while hi - lo > 1 { let mid = (lo + hi) / 2; if fits(&e, mid) { lo = mid } else { hi = mid } }
    let max = lo;
    let over = { let t = batch_tx(&e, max + 1); ValidatedStateDiff::from_public_transaction_metered(&t, &e.state, 1, 0, u64::MAX).0.cycles };
    println!("largest batch: {max} (x{} needs {over} cycles > {MAX_GAS_EXEC} or > {MAX_GAS_STOR} bytes)", max + 1);
    assert_eq!(max, MAX_BATCH_RECIPIENTS, "update vesting_core::MAX_BATCH_RECIPIENTS and the README to the measured maximum");
    let at_max = measure(&e.state, &batch_tx(&e, max), 0);

    println!("| operation | cycles (execution gas) | wire bytes (storage gas) |");
    println!("|---|---:|---:|");
    for (n, cy, by) in &rows { println!("| {n} | {cy} | {by} |"); }
    println!("| create batch x1 | {} | {} |", one.0, one.1);
    println!("| create batch x10 | {} | {} |", ten.0, ten.1);
    println!("| create batch x{max} (max) | {} | {} |", at_max.0, at_max.1);
    println!("marginal per recipient: {} cycles, {} bytes", (ten.0 - one.0) / 9, (ten.1 - one.1) / 9);
    for (_, cy, by) in &rows { assert!(*cy < MAX_GAS_EXEC && *by < MAX_GAS_STOR); }
}
