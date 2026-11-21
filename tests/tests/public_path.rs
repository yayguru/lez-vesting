//! End-to-end tests of the vesting guest ELF executed by the LEZ v0.4.0-rc3 state machine
//! (`lee::V03State`), public path. Each test runs the real RISC Zero guest.

use std::borrow::Cow;

use lee::{
    PrivateKey, PublicKey, PublicTransaction, V03State,
    error::LeeError,
    program::Program,
    public_transaction::{Message as TxMessage, WitnessSet},
    test_utils::signer_nonces,
};
use lee_core::{
    Timestamp,
    account::{Account, AccountId, Actor, Nonce},
};
use vesting_core::{CreateEntry, Event, Kind, Message, Params, Schedule, schedule_account};

const PROGRAM: AccountId = AccountId::new([0x17; 32]);

struct User {
    key: PrivateKey,
    id: AccountId,
    nonce: u128,
}

impl User {
    fn new(seed: u8) -> Self {
        let key = PrivateKey::try_new([seed; 32]).unwrap();
        let id = AccountId::from(&PublicKey::new_from_private_key(&key));
        Self { key, id, nonce: 0 }
    }
}

fn program() -> Program {
    Program::new(Cow::Borrowed(vesting_methods::VESTING_ELF)).unwrap()
}

struct Env {
    state: V03State,
    creator: User,
    alice: User,
    bob: User,
}

fn env() -> Env {
    let creator = User::new(1);
    let alice = User::new(2);
    let bob = User::new(3);
    let state = V03State::new()
        .with_public_accounts([
            (creator.id, Account::funded(1_000_000)),
            (alice.id, Account::funded(10)),
            (bob.id, Account::funded(10)),
        ])
        .with_named_programs([(PROGRAM, program())]);
    Env { state, creator, alice, bob }
}

fn me(u: &User) -> Actor {
    Actor::new(u.id, PROGRAM)
}
fn sched_actor(creator: &User, id: [u8; 32]) -> Actor {
    Actor::new(schedule_account(&PROGRAM, &creator.id, &id), PROGRAM)
}
fn bal(acct: AccountId) -> Actor {
    Actor::native_balance(acct)
}

fn send(
    state: &mut V03State,
    user: &mut User,
    actors: Vec<Actor>,
    msg: &Message,
    now: Timestamp,
) -> Result<Vec<lee_core::program::TransactionEvent>, LeeError> {
    let tx_msg = TxMessage::try_new(me(user), actors, signer_nonces(&[&user.key], vec![Nonce(user.nonce)]), msg).unwrap();
    let ws = WitnessSet::for_message(&tx_msg, &[&user.key]);
    let tx = PublicTransaction::new(tx_msg, ws);
    let out = state.transition_from_public_transaction(&tx, 1, now);
    if out.is_ok() {
        user.nonce += 1;
    }
    out
}

fn balance(state: &V03State, id: AccountId) -> u128 {
    state.get_account_by_id(id).data.native_balance().unwrap()
}

fn schedule(state: &V03State, creator: &User, id: [u8; 32]) -> Schedule {
    let acct = schedule_account(&PROGRAM, &creator.id, &id);
    borsh::from_slice(state.get_account_by_id(acct).data.actor_state(PROGRAM)).unwrap()
}

fn linear(beneficiary: AccountId, total: u128, start: u64, cliff: u64, end: u64) -> Params {
    Params { beneficiary, total, kind: Kind::Linear { start, cliff, end }, cancelable: true, transferable: false }
}

fn create(e: &mut Env, id: [u8; 32], params: Params) -> Result<Vec<lee_core::program::TransactionEvent>, LeeError> {
    let s = sched_actor(&e.creator, id);
    let actors = vec![me(&e.creator), bal(e.creator.id), s, bal(s.account_id)];
    send(&mut e.state, &mut e.creator, actors, &Message::Create { entries: vec![CreateEntry { id, params }] }, 0)
}

fn claim(e: &mut Env, who: u8, id: [u8; 32], now: u64, to: AccountId) -> Result<Vec<lee_core::program::TransactionEvent>, LeeError> {
    let s = sched_actor(&e.creator, id);
    let creator = e.creator.id;
    let user = match who { 2 => &mut e.alice, 3 => &mut e.bob, _ => &mut e.creator };
    let actors = vec![Actor::new(user.id, PROGRAM), s, bal(s.account_id), bal(to)];
    send(&mut e.state, user, actors, &Message::Claim { creator, id, now, to }, now)
}

#[test]
fn create_escrows_and_emits_created() {
    let mut e = env();
    let id = [7; 32];
    let events = { let __p = linear(e.alice.id, 1000, 100, 200, 1100); create(&mut e, id, __p) }.expect("create");
    let sched = schedule_account(&PROGRAM, &e.creator.id, &id);
    assert_eq!(balance(&e.state, sched), 1000);
    assert_eq!(balance(&e.state, e.creator.id), 1_000_000 - 1000);
    let s = schedule(&e.state, &e.creator, id);
    assert_eq!((s.beneficiary, s.total, s.claimed), (e.alice.id, 1000, 0));
    let created = Event::selector_of("vesting::Created");
    assert!(events.iter().any(|ev| ev.event.selector == created), "Created event emitted");
}

#[test]
fn claim_before_cliff_fails_then_linear_claims_add_up() {
    let mut e = env();
    let id = [1; 32];
    { let __p = linear(e.alice.id, 1000, 100, 200, 1100); create(&mut e, id, __p) }.unwrap();
    let alice = e.alice.id;
    // Before the cliff nothing is claimable; the failed claim changes nothing.
    assert!(claim(&mut e, 2, id, 150, alice).is_err());
    assert_eq!(schedule(&e.state, &e.creator, id).claimed, 0);
    // At t=600, half vested.
    claim(&mut e, 2, id, 600, alice).expect("claim at 600");
    assert_eq!(balance(&e.state, alice), 10 + 500);
    // At t=2000 the rest.
    claim(&mut e, 2, id, 2000, alice).expect("claim at end");
    assert_eq!(balance(&e.state, alice), 10 + 1000);
    let sched = schedule_account(&PROGRAM, &e.creator.id, &id);
    assert_eq!(balance(&e.state, sched), 0);
    // Nothing left.
    assert!(claim(&mut e, 2, id, 3000, alice).is_err());
}

#[test]
fn claim_with_future_now_is_rejected_by_validity_window() {
    let mut e = env();
    let id = [2; 32];
    { let __p = linear(e.alice.id, 1000, 0, 0, 1000); create(&mut e, id, __p) }.unwrap();
    let alice = e.alice.id;
    let s = sched_actor(&e.creator, id);
    let creator = e.creator.id;
    // Claims "now = 900" in a block whose timestamp is 100.
    let actors = vec![me(&e.alice), s, bal(s.account_id), bal(alice)];
    let r = {
        let tx_msg = TxMessage::try_new(me(&e.alice), actors, signer_nonces(&[&e.alice.key], vec![Nonce(0)]), &Message::Claim { creator, id, now: 900, to: alice }).unwrap();
        let ws = WitnessSet::for_message(&tx_msg, &[&e.alice.key]);
        e.state.transition_from_public_transaction(&PublicTransaction::new(tx_msg, ws), 1, 100)
    };
    assert!(matches!(r, Err(LeeError::OutOfValidityWindow)), "got {r:?}");
}

#[test]
fn only_beneficiary_can_claim() {
    let mut e = env();
    let id = [3; 32];
    { let __p = linear(e.alice.id, 1000, 0, 0, 1000); create(&mut e, id, __p) }.unwrap();
    let bob = e.bob.id;
    assert!(claim(&mut e, 3, id, 500, bob).is_err());
    assert_eq!(balance(&e.state, bob), 10);
}

#[test]
fn unsigned_forwarding_is_rejected() {
    // Bob tries to drive Alice's actor without her signature.
    let mut e = env();
    let id = [4; 32];
    { let __p = linear(e.alice.id, 1000, 0, 0, 1000); create(&mut e, id, __p) }.unwrap();
    let s = sched_actor(&e.creator, id);
    let (alice, bob, creator) = (e.alice.id, e.bob.id, e.creator.id);
    let tx_msg = TxMessage::try_new(Actor::new(alice, PROGRAM), vec![Actor::new(alice, PROGRAM), s, bal(s.account_id), bal(bob)], signer_nonces(&[&e.bob.key], vec![Nonce(0)]), &Message::Claim { creator, id, now: 500, to: bob }).unwrap();
    let ws = WitnessSet::for_message(&tx_msg, &[&e.bob.key]);
    assert!(e.state.transition_from_public_transaction(&PublicTransaction::new(tx_msg, ws), 1, 500).is_err());
    assert_eq!(balance(&e.state, bob), 10);
}

#[test]
fn cancel_returns_unvested_and_keeps_vested_claimable() {
    let mut e = env();
    let id = [5; 32];
    { let __p = linear(e.alice.id, 1000, 0, 0, 1000); create(&mut e, id, __p) }.unwrap();
    let before = balance(&e.state, e.creator.id);
    let s = sched_actor(&e.creator, id);
    let creator_id = e.creator.id;
    let actors = vec![me(&e.creator), s, bal(s.account_id), bal(creator_id)];
    send(&mut e.state, &mut e.creator, actors.clone(), &Message::Cancel { id, now: 300 }, 300).expect("cancel");
    assert_eq!(balance(&e.state, e.creator.id), before + 700);
    // Second cancel fails.
    assert!(send(&mut e.state, &mut e.creator, actors, &Message::Cancel { id, now: 301 }, 301).is_err());
    // Alice still gets the 300 that vested, and no more later.
    let alice = e.alice.id;
    claim(&mut e, 2, id, 900, alice).expect("claim after cancel");
    assert_eq!(balance(&e.state, alice), 10 + 300);
    assert!(claim(&mut e, 2, id, 2000, alice).is_err());
}

#[test]
fn backdated_cancel_is_rejected() {
    let mut e = env();
    let id = [6; 32];
    { let __p = linear(e.alice.id, 1000, 0, 0, 1_000_000); create(&mut e, id, __p) }.unwrap();
    let s = sched_actor(&e.creator, id);
    let creator_id = e.creator.id;
    let actors = vec![me(&e.creator), s, bal(s.account_id), bal(creator_id)];
    // Claims now=0 while the block is 20 minutes later.
    let r = send(&mut e.state, &mut e.creator, actors, &Message::Cancel { id, now: 0 }, 20 * 60 * 1000);
    assert!(matches!(r, Err(LeeError::OutOfValidityWindow)), "got {r:?}");
}

#[test]
fn irrevocable_is_one_way_and_blocks_cancel() {
    let mut e = env();
    let id = [8; 32];
    { let __p = linear(e.alice.id, 1000, 0, 0, 1000); create(&mut e, id, __p) }.unwrap();
    let s = sched_actor(&e.creator, id);
    let creator_id = e.creator.id;
    { let __a = vec![me(&e.creator), s]; send(&mut e.state, &mut e.creator, __a, &Message::MakeIrrevocable { id }, 10) }.expect("irrevocable");
    assert!(!schedule(&e.state, &e.creator, id).cancelable);
    let actors = vec![me(&e.creator), s, bal(s.account_id), bal(creator_id)];
    assert!(send(&mut e.state, &mut e.creator, actors, &Message::Cancel { id, now: 20 }, 20).is_err());
}

#[test]
fn milestones_unlock_once_per_index() {
    let mut e = env();
    let id = [9; 32];
    let params = Params { beneficiary: e.alice.id, total: 60, kind: Kind::Milestones { amounts: vec![10, 20, 30] }, cancelable: true, transferable: false };
    { let __p = params; create(&mut e, id, __p) }.unwrap();
    let alice = e.alice.id;
    assert!(claim(&mut e, 2, id, 0, alice).is_err());
    let s = sched_actor(&e.creator, id);
    { let __a = vec![me(&e.creator), s]; send(&mut e.state, &mut e.creator, __a, &Message::SignalMilestone { id, index: 1 }, 0) }.expect("signal 1");
    assert!({ let __a = vec![me(&e.creator), s]; send(&mut e.state, &mut e.creator, __a, &Message::SignalMilestone { id, index: 1 }, 0) }.is_err(), "double signal rejected");
    assert!({ let __a = vec![me(&e.creator), s]; send(&mut e.state, &mut e.creator, __a, &Message::SignalMilestone { id, index: 3 }, 0) }.is_err(), "out of range");
    claim(&mut e, 2, id, 0, alice).expect("claim tranche 1");
    assert_eq!(balance(&e.state, alice), 10 + 20);
    // Only the creator signals.
    assert!({ let __a = vec![me(&e.alice), s]; send(&mut e.state, &mut e.alice, __a, &Message::SignalMilestone { id, index: 0 }, 0) }.is_err());
}

#[test]
fn transfer_beneficiary_respects_flag() {
    let mut e = env();
    let (id_a, id_b) = ([10; 32], [11; 32]);
    { let __p = linear(e.alice.id, 100, 0, 0, 100); create(&mut e, id_a, __p) }.unwrap();
    let mut p = linear(e.alice.id, 100, 0, 0, 100);
    p.transferable = true;
    { let __p = p; create(&mut e, id_b, __p) }.unwrap();
    let creator = e.creator.id;
    let bob = e.bob.id;
    let sa = sched_actor(&e.creator, id_a);
    let sb = sched_actor(&e.creator, id_b);
    assert!({ let __a = vec![me(&e.alice), sa]; send(&mut e.state, &mut e.alice, __a, &Message::TransferBeneficiary { creator, id: id_a, new_beneficiary: bob }, 0) }.is_err());
    { let __a = vec![me(&e.alice), sb]; send(&mut e.state, &mut e.alice, __a, &Message::TransferBeneficiary { creator, id: id_b, new_beneficiary: bob }, 0) }.expect("transfer");
    assert_eq!(schedule(&e.state, &e.creator, id_b).beneficiary, bob);
    let alice = e.alice.id;
    assert!(claim(&mut e, 2, id_b, 100, alice).is_err(), "old beneficiary can no longer claim");
    claim(&mut e, 3, id_b, 100, bob).expect("new beneficiary claims");
    assert_eq!(balance(&e.state, bob), 110);
}

#[test]
fn duplicate_id_is_rejected() {
    let mut e = env();
    let id = [12; 32];
    { let __p = linear(e.alice.id, 100, 0, 0, 100); create(&mut e, id, __p) }.unwrap();
    assert!({ let __p = linear(e.alice.id, 100, 0, 0, 100); create(&mut e, id, __p) }.is_err());
}

#[test]
fn batch_create_many() {
    let mut e = env();
    let n = 20_u8;
    let mut actors = vec![me(&e.creator), bal(e.creator.id)];
    let mut entries = vec![];
    for i in 0..n {
        let id = [100 + i; 32];
        let s = sched_actor(&e.creator, id);
        actors.push(s);
        actors.push(bal(s.account_id));
        entries.push(CreateEntry { id, params: linear(e.alice.id, 10, 0, 0, 10) });
    }
    send(&mut e.state, &mut e.creator, actors, &Message::Create { entries }, 0).expect("batch");
    for i in 0..n {
        assert_eq!(schedule(&e.state, &e.creator, [100 + i; 32]).total, 10);
    }
}
