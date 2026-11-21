//! Reliability: independent schedules claimed within one block do not interfere, a racing
//! double claim on one schedule pays once, and a failed claim leaves the escrow intact.

use std::borrow::Cow;

use lee::{PrivateKey, PublicKey, PublicTransaction, V03State, program::Program,
    public_transaction::{Message as TxMessage, WitnessSet}, test_utils::signer_nonces};
use lee_core::account::{Account, AccountId, Actor, Nonce};
use vesting_core::{CreateEntry, Kind, Message, Params, Schedule, schedule_account};

const PROGRAM: AccountId = AccountId::new([0x17; 32]);

fn key(seed: u8) -> (PrivateKey, AccountId) {
    let k = PrivateKey::try_new([seed; 32]).unwrap();
    let id = AccountId::from(&PublicKey::new_from_private_key(&k));
    (k, id)
}
fn tx(k: &PrivateKey, id: AccountId, nonce: u128, actors: Vec<Actor>, msg: &Message) -> PublicTransaction {
    let m = TxMessage::try_new(Actor::new(id, PROGRAM), actors, signer_nonces(&[k], vec![Nonce(nonce)]), msg).unwrap();
    let ws = WitnessSet::for_message(&m, &[k]);
    PublicTransaction::new(m, ws)
}
fn bal(state: &V03State, id: AccountId) -> u128 {
    state.get_account_by_id(id).data.native_balance().unwrap_or(0)
}

const N: u8 = 8;

fn setup() -> (V03State, (PrivateKey, AccountId), Vec<(PrivateKey, AccountId)>) {
    let creator = key(1);
    let users: Vec<_> = (0..N).map(|i| key(10 + i)).collect();
    let mut accts = vec![(creator.1, Account::funded(10_000_000))];
    accts.extend(users.iter().map(|u| (u.1, Account::funded(1))));
    let mut state = V03State::new().with_public_accounts(accts)
        .with_named_programs([(PROGRAM, Program::new(Cow::Borrowed(vesting_methods::VESTING_ELF)).unwrap())]);
    // One batch creates N schedules (one per user), all with ids derived from the index.
    let entries: Vec<_> = users.iter().enumerate().map(|(i, u)| CreateEntry {
        id: [i as u8; 32],
        params: Params { beneficiary: u.1, total: 1000 * (i as u128 + 1), kind: Kind::Linear { start: 0, cliff: 0, end: 1000 }, cancelable: true, transferable: false },
    }).collect();
    let mut actors = vec![Actor::new(creator.1, PROGRAM), Actor::native_balance(creator.1)];
    for i in 0..N {
        let s = schedule_account(&PROGRAM, &creator.1, &[i; 32]);
        actors.extend([Actor::new(s, PROGRAM), Actor::native_balance(s)]);
    }
    state.transition_from_public_transaction(&tx(&creator.0, creator.1, 0, actors, &Message::Create { entries }), 1, 0).expect("batch create");
    (state, creator, users)
}

fn claim_tx(creator: AccountId, u: &(PrivateKey, AccountId), i: u8, nonce: u128, now: u64) -> PublicTransaction {
    let s = schedule_account(&PROGRAM, &creator, &[i; 32]);
    tx(&u.0, u.1, nonce, vec![Actor::new(u.1, PROGRAM), Actor::new(s, PROGRAM), Actor::native_balance(s), Actor::native_balance(u.1)],
        &Message::Claim { creator, id: [i; 32], now, to: u.1 })
}

#[test]
fn independent_schedules_claimed_in_one_block_do_not_interfere() {
    let (mut state, creator, users) = setup();
    // All N claims land in block 2, in reverse order, interleaved with a second round in block 3.
    for i in (0..N).rev() {
        state.transition_from_public_transaction(&claim_tx(creator.1, &users[i as usize], i, 0, 500), 2, 500).expect("claim r1");
    }
    for i in 0..N {
        if i % 2 == 0 {
            state.transition_from_public_transaction(&claim_tx(creator.1, &users[i as usize], i, 1, 1000), 3, 1000).expect("claim r2");
        }
    }
    for i in 0..N {
        let total = 1000 * (u128::from(i) + 1);
        let s = schedule_account(&PROGRAM, &creator.1, &[i; 32]);
        let sch: Schedule = borsh::from_slice(state.get_account_by_id(s).data.actor_state(PROGRAM)).unwrap();
        let expect_claimed = if i % 2 == 0 { total } else { total / 2 };
        assert_eq!(sch.claimed, expect_claimed, "schedule {i}");
        assert_eq!(bal(&state, s), total - expect_claimed, "escrow {i}");
        assert_eq!(bal(&state, users[i as usize].1), 1 + expect_claimed, "user {i}");
        assert_eq!(sch.beneficiary, users[i as usize].1);
    }
}

#[test]
fn racing_double_claim_on_one_schedule_pays_once() {
    let (mut state, creator, users) = setup();
    let u = &users[3];
    // Two claims for the same moment in the same block (distinct nonces, as two devices would).
    state.transition_from_public_transaction(&claim_tx(creator.1, u, 3, 0, 400), 2, 400).expect("first");
    let before = state.clone();
    let second = state.transition_from_public_transaction(&claim_tx(creator.1, u, 3, 1, 400), 2, 400);
    assert!(second.is_err(), "nothing more vested at the same instant");
    assert!(state == before, "a failed claim changes nothing (atomic)");
    assert_eq!(bal(&state, u.1), 1 + 1600);
    // Retrying later works without loss.
    state.transition_from_public_transaction(&claim_tx(creator.1, u, 3, 1, 1000), 3, 1000).expect("retry");
    assert_eq!(bal(&state, u.1), 1 + 4000);
}
