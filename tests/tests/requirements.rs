//! On-chain tests for hard requirements not covered elsewhere (see docs/REQUIREMENTS.md).
//! Real guest ELF on the pinned LEZ state machine.

use vesting_core::{Event, Kind, Message, Params, schedule_account};
use vesting_tests::*;

fn has(events: &[lee_core::program::TransactionEvent], name: &str) -> bool {
    let sel = Event::selector_of(name);
    events.iter().any(|e| e.event.selector == sel)
}

#[test]
fn cliff_pays_lump_sum_then_linear() {
    // 1-year cliff, 4-year total (scaled: start 0, cliff 1000, end 4000).
    let mut e = env();
    let id = [1; 32];
    let (c, a) = (e.creator.id, e.alice.id);
    send(&mut e.state, &mut e.creator, create_actors(c, &[id]), &create_msg(vec![(id, linear(a, 4000, 0, 1000, 4000))]), 0).unwrap();
    let r = send(&mut e.state, &mut e.alice, claim_actors(a, c, id, a), &Message::Claim { creator: c, id, now: 999, to: a }, 999);
    assert!(err_text(r).contains("V011 nothing claimable yet; next unlock at 1000"), "error names the next unlock time");
    // At the cliff the whole cliff share (1/4) unlocks at once.
    send(&mut e.state, &mut e.alice, claim_actors(a, c, id, a), &Message::Claim { creator: c, id, now: 1000, to: a }, 1000).unwrap();
    assert_eq!(balance(&e.state, a), 10 + 1000);
    // Then linearly: at 2500, 2500 vested in total.
    send(&mut e.state, &mut e.alice, claim_actors(a, c, id, a), &Message::Claim { creator: c, id, now: 2500, to: a }, 2500).unwrap();
    assert_eq!(balance(&e.state, a), 10 + 2500);
}

#[test]
fn fully_linear_accrues_from_start() {
    let mut e = env();
    let id = [2; 32];
    let (c, a) = (e.creator.id, e.alice.id);
    send(&mut e.state, &mut e.creator, create_actors(c, &[id]), &create_msg(vec![(id, linear(a, 1000, 100, 100, 1100))]), 0).unwrap();
    for (t, total) in [(101, 1), (350, 250), (1100, 1000)] {
        send(&mut e.state, &mut e.alice, claim_actors(a, c, id, a), &Message::Claim { creator: c, id, now: t, to: a }, t).unwrap();
        assert_eq!(balance(&e.state, a), 10 + total, "vested at {t}");
    }
}

#[test]
fn every_state_transition_emits_its_event() {
    let mut e = env();
    let (c, a, b) = (e.creator.id, e.alice.id, e.bob.id);
    let (lin, ms) = ([3; 32], [4; 32]);
    let mut p = linear(a, 100, 0, 0, 100);
    p.transferable = true;
    let ev = send(&mut e.state, &mut e.creator, create_actors(c, &[lin]), &create_msg(vec![(lin, p)]), 0).unwrap();
    assert!(has(&ev, "vesting::Created"));
    let ev = send(&mut e.state, &mut e.alice, claim_actors(a, c, lin, a), &Message::Claim { creator: c, id: lin, now: 50, to: a }, 50).unwrap();
    assert!(has(&ev, "vesting::Claimed"));
    let ev = send(&mut e.state, &mut e.alice, admin_actors(a, c, lin), &Message::TransferBeneficiary { creator: c, id: lin, new_beneficiary: b }, 50).unwrap();
    assert!(has(&ev, "vesting::BeneficiaryTransferred"));
    let ev = send(&mut e.state, &mut e.creator, cancel_actors(c, lin), &Message::Cancel { id: lin, now: 60 }, 60).unwrap();
    assert!(has(&ev, "vesting::Cancelled"));
    let mp = Params { beneficiary: a, total: 30, kind: Kind::Milestones { amounts: vec![10, 20] }, cancelable: true, transferable: false };
    send(&mut e.state, &mut e.creator, create_actors(c, &[ms]), &create_msg(vec![(ms, mp)]), 60).unwrap();
    let ev = send(&mut e.state, &mut e.creator, admin_actors(c, c, ms), &Message::SignalMilestone { id: ms, index: 0 }, 60).unwrap();
    assert!(has(&ev, "vesting::MilestoneSignalled"));
    let ev = send(&mut e.state, &mut e.creator, admin_actors(c, c, ms), &Message::MakeIrrevocable { id: ms }, 60).unwrap();
    assert!(has(&ev, "vesting::MadeIrrevocable"));
}

#[test]
fn non_cancelable_at_creation_rejects_cancel_and_conversion_is_irreversible() {
    let mut e = env();
    let c = e.creator.id;
    let id = [5; 32];
    let mut p = linear(e.alice.id, 100, 0, 0, 100);
    p.cancelable = false;
    send(&mut e.state, &mut e.creator, create_actors(c, &[id]), &create_msg(vec![(id, p)]), 0).unwrap();
    let r = send(&mut e.state, &mut e.creator, cancel_actors(c, id), &Message::Cancel { id, now: 1 }, 1);
    assert!(err_text(r).contains("V012"), "non-cancelable cancel is rejected with V012");
    // There is no message that makes a schedule cancelable again; the stored flag stays false
    // and the escrow is untouched.
    assert!(!schedule(&e.state, c, id).cancelable);
    assert_eq!(balance(&e.state, schedule_account(&PROGRAM, &c, &id)), 100);
    // Converting an already non-cancelable schedule again is harmless (still non-cancelable).
    let _ = send(&mut e.state, &mut e.creator, admin_actors(c, c, id), &Message::MakeIrrevocable { id }, 2);
    assert!(!schedule(&e.state, c, id).cancelable);
}

#[test]
fn cancel_milestones_keeps_signalled_unclaimed_tranche_claimable() {
    let mut e = env();
    let (c, a) = (e.creator.id, e.alice.id);
    let id = [6; 32];
    let p = Params { beneficiary: a, total: 60, kind: Kind::Milestones { amounts: vec![10, 20, 30] }, cancelable: true, transferable: false };
    send(&mut e.state, &mut e.creator, create_actors(c, &[id]), &create_msg(vec![(id, p)]), 0).unwrap();
    send(&mut e.state, &mut e.creator, admin_actors(c, c, id), &Message::SignalMilestone { id, index: 1 }, 0).unwrap();
    let before = balance(&e.state, c);
    send(&mut e.state, &mut e.creator, cancel_actors(c, id), &Message::Cancel { id, now: 5 }, 5).unwrap();
    assert_eq!(balance(&e.state, c), before + 40, "unvested (10+30) returns to the creator");
    send(&mut e.state, &mut e.alice, claim_actors(a, c, id, a), &Message::Claim { creator: c, id, now: 6, to: a }, 6).unwrap();
    assert_eq!(balance(&e.state, a), 10 + 20, "vested-but-unclaimed stays claimable after cancel");
    // Signalling after cancel cannot unlock more.
    assert!(send(&mut e.state, &mut e.creator, admin_actors(c, c, id), &Message::SignalMilestone { id, index: 0 }, 7).is_err());
}

#[test]
fn failed_claim_and_failed_cancel_leave_state_unchanged() {
    let mut e = env();
    let (c, a, b) = (e.creator.id, e.alice.id, e.bob.id);
    let id = [7; 32];
    send(&mut e.state, &mut e.creator, create_actors(c, &[id]), &create_msg(vec![(id, linear(a, 1000, 0, 500, 1000))]), 0).unwrap();
    let sa = schedule_account(&PROGRAM, &c, &id);
    let snap = |e: &Env| (schedule(&e.state, c, id), balance(&e.state, sa), balance(&e.state, a), balance(&e.state, c));
    let s0 = snap(&e);
    // Claim before the cliff, claim by a stranger, cancel by a non-creator: all rejected, no effect.
    assert!(send(&mut e.state, &mut e.alice, claim_actors(a, c, id, a), &Message::Claim { creator: c, id, now: 100, to: a }, 100).is_err());
    assert!(send(&mut e.state, &mut e.bob, claim_actors(b, c, id, b), &Message::Claim { creator: c, id, now: 700, to: b }, 700).is_err());
    let bob_cancel = vec![e.bob.me(), sched(c, id), bal(sa), bal(b)];
    assert!(send(&mut e.state, &mut e.bob, bob_cancel, &Message::Cancel { id, now: 700 }, 700).is_err());
    assert_eq!(snap(&e), s0);
    // And the beneficiary can still claim in full afterwards (retry without loss).
    send(&mut e.state, &mut e.alice, claim_actors(a, c, id, a), &Message::Claim { creator: c, id, now: 1000, to: a }, 1000).unwrap();
    assert_eq!(balance(&e.state, a), 10 + 1000);
}

#[test]
fn transferability_is_fixed_at_creation() {
    let mut e = env();
    let (c, a, b) = (e.creator.id, e.alice.id, e.bob.id);
    let id = [8; 32];
    send(&mut e.state, &mut e.creator, create_actors(c, &[id]), &create_msg(vec![(id, linear(a, 100, 0, 0, 100))]), 0).unwrap();
    // Neither the creator nor the beneficiary can transfer a non-transferable position...
    assert!(err_text(send(&mut e.state, &mut e.alice, admin_actors(a, c, id), &Message::TransferBeneficiary { creator: c, id, new_beneficiary: b }, 1)).contains("V017"));
    assert!(send(&mut e.state, &mut e.creator, admin_actors(c, c, id), &Message::TransferBeneficiary { creator: c, id, new_beneficiary: b }, 1).is_err());
    // ...and re-creating the same schedule with another flag is rejected (V007), so the flag is frozen.
    let mut p = linear(a, 100, 0, 0, 100);
    p.transferable = true;
    assert!(send(&mut e.state, &mut e.creator, create_actors(c, &[id]), &create_msg(vec![(id, p)]), 1).is_err());
    assert!(!schedule(&e.state, c, id).transferable);
}

#[test]
fn batch_is_all_or_nothing() {
    let mut e = env();
    let c = e.creator.id;
    let a = e.alice.id;
    let ids = [[20; 32], [21; 32], [22; 32]];
    let mut entries: Vec<_> = ids.iter().map(|id| (*id, linear(a, 10, 0, 0, 10))).collect();
    entries[2].1.total = 0; // invalid entry (V001)
    let before = balance(&e.state, c);
    assert!(send(&mut e.state, &mut e.creator, create_actors(c, &ids), &create_msg(entries), 0).is_err());
    assert_eq!(balance(&e.state, c), before);
    assert!(e.state.get_account_by_id(schedule_account(&PROGRAM, &c, &ids[0])).data.actor_state(PROGRAM).is_empty());
}
