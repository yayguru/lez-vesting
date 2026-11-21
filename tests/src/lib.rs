//! Shared harness for the on-chain tests: the real vesting guest ELF executed by the pinned LEZ
//! state machine (`lee::V03State`), public transactions signed by test keys.

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
    program::TransactionEvent,
};
use vesting_core::{CreateEntry, Kind, Message, Params, Schedule, schedule_account};

pub const PROGRAM: AccountId = AccountId::new([0x17; 32]);

pub struct User { pub key: PrivateKey, pub id: AccountId, pub nonce: u128 }
impl User {
    pub fn new(seed: u8) -> Self {
        let key = PrivateKey::try_new([seed; 32]).unwrap();
        let id = AccountId::from(&PublicKey::new_from_private_key(&key));
        Self { key, id, nonce: 0 }
    }
    pub fn me(&self) -> Actor { Actor::new(self.id, PROGRAM) }
}

pub fn program() -> Program { Program::new(Cow::Borrowed(vesting_methods::VESTING_ELF)).unwrap() }

pub struct Env { pub state: V03State, pub creator: User, pub alice: User, pub bob: User }

pub fn env() -> Env {
    let (creator, alice, bob) = (User::new(1), User::new(2), User::new(3));
    let state = V03State::new()
        .with_public_accounts([
            (creator.id, Account::funded(1_000_000_000)),
            (alice.id, Account::funded(10)),
            (bob.id, Account::funded(10)),
        ])
        .with_named_programs([(PROGRAM, program())]);
    Env { state, creator, alice, bob }
}

pub fn sched(creator: AccountId, id: [u8; 32]) -> Actor { Actor::new(schedule_account(&PROGRAM, &creator, &id), PROGRAM) }
pub fn bal(a: AccountId) -> Actor { Actor::native_balance(a) }

/// Builds a signed public transaction from `user`'s vesting actor (does not bump the nonce).
pub fn tx(user: &User, actors: Vec<Actor>, msg: &Message) -> PublicTransaction {
    let m = TxMessage::try_new(user.me(), actors, signer_nonces(&[&user.key], vec![Nonce(user.nonce)]), msg).unwrap();
    let ws = WitnessSet::for_message(&m, &[&user.key]);
    PublicTransaction::new(m, ws)
}

pub fn send(state: &mut V03State, user: &mut User, actors: Vec<Actor>, msg: &Message, now: Timestamp) -> Result<Vec<TransactionEvent>, LeeError> {
    let t = tx(user, actors, msg);
    let out = state.transition_from_public_transaction(&t, 1, now);
    if out.is_ok() { user.nonce += 1; }
    out
}

pub fn balance(state: &V03State, id: AccountId) -> u128 { state.get_account_by_id(id).data.native_balance().unwrap() }

pub fn schedule(state: &V03State, creator: AccountId, id: [u8; 32]) -> Schedule {
    let acct = schedule_account(&PROGRAM, &creator, &id);
    borsh::from_slice(state.get_account_by_id(acct).data.actor_state(PROGRAM)).unwrap()
}

pub fn linear(beneficiary: AccountId, total: u128, start: u64, cliff: u64, end: u64) -> Params {
    Params { beneficiary, total, kind: Kind::Linear { start, cliff, end }, cancelable: true, transferable: false }
}

// Actor lists per operation (what the CLI sends).
pub fn create_actors(creator: AccountId, ids: &[[u8; 32]]) -> Vec<Actor> {
    let mut a = vec![Actor::new(creator, PROGRAM), bal(creator)];
    for id in ids { let s = sched(creator, *id); a.push(s); a.push(bal(s.account_id)); }
    a
}
pub fn claim_actors(by: AccountId, creator: AccountId, id: [u8; 32], to: AccountId) -> Vec<Actor> {
    let s = sched(creator, id);
    vec![Actor::new(by, PROGRAM), s, bal(s.account_id), bal(to)]
}
pub fn cancel_actors(creator: AccountId, id: [u8; 32]) -> Vec<Actor> {
    let s = sched(creator, id);
    vec![Actor::new(creator, PROGRAM), s, bal(s.account_id), bal(creator)]
}
pub fn admin_actors(by: AccountId, creator: AccountId, id: [u8; 32]) -> Vec<Actor> { vec![Actor::new(by, PROGRAM), sched(creator, id)] }

pub fn create_msg(entries: Vec<(([u8; 32]), Params)>) -> Message {
    Message::Create { entries: entries.into_iter().map(|(id, params)| CreateEntry { id, params }).collect() }
}

/// The error text of a failed transition (the guest's `V0xx ...` panic message is inside).
pub fn err_text(r: Result<Vec<TransactionEvent>, LeeError>) -> String {
    match r { Ok(_) => panic!("expected failure"), Err(e) => format!("{e:#} {e:?}") }
}
