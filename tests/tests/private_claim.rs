//! Private claim: the beneficiary claims vested tokens into a *blinded alias* of one of its
//! private accounts, within one privacy-preserving transaction that also binds the alias's
//! recovery note. The creator (and everyone else) sees only a fresh alias, never the private
//! account; the beneficiary recovers the payout by key and consumes it privately.
//!
//! Runs the real vesting guest and the real privacy-preserving circuit (RISC0_DEV_MODE=1 for
//! fake receipts) on the LEZ v0.4.0-rc3 state machine.

use std::{borrow::Cow, collections::{BTreeSet, HashMap}};

use lee::{
    PrivateKey, PublicKey, PublicTransaction, Simulation, V03State, execute_and_prove,
    privacy_preserving_transaction::{
        Message as PpMessage, PrivacyPreservingTransaction, WitnessSet as PpWitnessSet,
        circuit::ProgramCatalog,
    },
    program::Program,
    public_transaction::{Message as TxMessage, WitnessSet},
    test_utils::{TestPrivateKeys, init_witness, no_seal, signer_nonces},
};
use lee_core::{
    AuthorizationSecretKey, Commitment, DummyOutput, EphemeralSecretKey, MessageWitness,
    Nullifier, PrivateAccountKind, PrivateWitness, ProvingInput, Recipient, RecipientEncryption,
    RootCall, SenderPresentation,
    account::{Account, AccountId, Actor, Nonce},
    execution_state::{PublicExecutionContext, TransactionEntry},
    native_token,
    program::Publication,
};
use vesting_core::{CreateEntry, Kind, Message, Params, Schedule, schedule_account};

const PROGRAM: AccountId = AccountId::new([0x17; 32]);

fn program() -> Program {
    Program::new(Cow::Borrowed(vesting_methods::VESTING_ELF)).unwrap()
}
fn catalog() -> ProgramCatalog {
    ProgramCatalog::from([(PROGRAM, program())])
}
fn key(seed: u8) -> (PrivateKey, AccountId) {
    let k = PrivateKey::try_new([seed; 32]).unwrap();
    let id = AccountId::from(&PublicKey::new_from_private_key(&k));
    (k, id)
}
fn alice_private() -> TestPrivateKeys {
    TestPrivateKeys { ask: AuthorizationSecretKey([13; 32]), d: [31; 32], z: [32; 32] }
}
/// Alice's private account under a fresh per-claim opening.
fn alias_recipient(opening: [u8; 32]) -> Recipient {
    let k = alice_private();
    Recipient { npk: k.npk(), vpk: k.vpk(), kind: PrivateAccountKind::Regular, opening: Some(opening) }
}

fn public_send(state: &mut V03State, k: &PrivateKey, id: AccountId, nonce: u128, actors: Vec<Actor>, msg: &Message, now: u64) {
    let m = TxMessage::try_new(Actor::new(id, PROGRAM), actors, signer_nonces(&[k], vec![Nonce(nonce)]), msg).unwrap();
    let ws = WitnessSet::for_message(&m, &[k]);
    state.transition_from_public_transaction(&PublicTransaction::new(m, ws), 1, now).expect("public tx");
}

fn setup() -> (V03State, (PrivateKey, AccountId), (PrivateKey, AccountId), [u8; 32]) {
    let creator = key(1);
    let alice = key(2);
    let mut state = V03State::new()
        .with_public_accounts([(creator.1, Account::funded(1_000_000)), (alice.1, Account::funded(10))])
        .with_named_programs([(PROGRAM, program())]);
    let id = [9; 32];
    let sched = schedule_account(&PROGRAM, &creator.1, &id);
    let params = Params { beneficiary: alice.1, total: 1000, kind: Kind::Linear { start: 0, cliff: 0, end: 1000 }, cancelable: true, transferable: false };
    public_send(&mut state, &creator.0, creator.1, 0,
        vec![Actor::new(creator.1, PROGRAM), Actor::native_balance(creator.1), Actor::new(sched, PROGRAM), Actor::native_balance(sched)],
        &Message::Create { entries: vec![CreateEntry { id, params }] }, 0);
    (state, creator, alice, id)
}

/// Builds Alice's privacy-preserving claim transaction paying into `alias`.
fn private_claim_tx(state: &V03State, creator: AccountId, alice: &(PrivateKey, AccountId), id: [u8; 32], now: u64, opening: [u8; 32], esk: u8) -> (PrivacyPreservingTransaction, AccountId) {
    let recipient = alias_recipient(opening);
    let alias = recipient.address();
    let sched = schedule_account(&PROGRAM, &creator, &id);
    let root_actor = Actor::new(alice.1, PROGRAM);
    let public_actors = [root_actor, Actor::new(sched, PROGRAM), Actor::native_balance(sched)];
    let simulation = Simulation {
        public_actor_states: public_actors
            .iter()
            .map(|a| (*a, state.get_account_by_id(a.account_id).data.actor_state(a.program_account_id).clone()))
            .collect::<HashMap<_, _>>(),
        admitted_accounts: None,
    };
    let msg = Message::Claim { creator, id, now, to: alias };
    let input = ProvingInput {
        claims: Vec::new(),
        root: TransactionEntry::Sync(RootCall { to: root_actor, message: borsh::to_vec(&msg).unwrap() }),
        public_context: PublicExecutionContext::new(public_actors, [alice.1]),
        private_witnesses: Vec::new(),
        dummy_inputs: Vec::new(),
        ciphertext_padding: None,
        recoveries: vec![RecipientEncryption { recipient, esk: EphemeralSecretKey([esk; 32]) }],
        private_promotions: BTreeSet::new(),
        fee: None,
    };
    let (output, proof) = execute_and_prove(input, &simulation, &catalog(), |_| SenderPresentation::Canonical, |_, _| false, no_seal)
        .expect("prove private claim");
    let nonce = state.get_account_by_id(alice.1).nonce;
    let message = PpMessage::from_circuit_output(signer_nonces(&[&alice.0], vec![nonce]), output);
    let ws = PpWitnessSet::for_message(&message, proof, &[&alice.0]);
    (PrivacyPreservingTransaction::new(message, ws), alias)
}

#[test]
fn beneficiary_claims_into_a_blinded_private_alias_and_receives_privately() {
    let (mut state, creator, alice, id) = setup();
    let sched = schedule_account(&PROGRAM, &creator.1, &id);

    let (tx, alias) = private_claim_tx(&state, creator.1, &alice, id, 400, [0xA1; 32], 5);
    let real_private = alice_private().account_id();
    assert_ne!(alias, real_private, "the alias does not name Alice's private account");
    state.transition_from_privacy_preserving_transaction(&tx, 2, 400).expect("settle private claim");

    // Escrow moved, schedule updated, Alice's public balance untouched.
    assert_eq!(state.get_account_by_id(sched).data.native_balance().unwrap(), 600);
    let s: Schedule = borsh::from_slice(state.get_account_by_id(sched).data.actor_state(PROGRAM)).unwrap();
    assert_eq!(s.claimed, 400);
    assert_eq!(state.get_account_by_id(alice.1).data.native_balance().unwrap(), 10);

    // Public view: one clear credit to the *alias*, with a recovery note; no public account for it.
    let pubs: Vec<_> = state.publications_from(0).collect();
    let [(position, Publication::Clear { body, recovery })] = <[_; 1]>::try_from(pubs).expect("one publication") else {
        panic!("public escrow payout is a clear publication");
    };
    assert_eq!(body.to, Actor::native_balance(alias));
    assert_ne!(body.to.account_id, real_private);
    assert_eq!(borsh::from_slice::<native_token::Message>(&body.message).unwrap(), native_token::Message::Credit(400));
    assert!(state.get_account_by_id_ref(alias).is_none());
    assert!(state.get_account_by_id_ref(real_private).is_none());

    // Alice (only she holds d,z) recovers the recipient from the note and receives privately.
    let k = alice_private();
    let recovered = Recipient::recover(body.to.account_id, &recovery, &k.d, &k.z).expect("alice recovers");
    assert_eq!(recovered.account_id(), real_private);
    // A different key cannot.
    assert!(Recipient::recover(body.to.account_id, &recovery, &[1; 32], &[2; 32]).map(|r| r.account_id()) != Some(real_private));

    let commitment = Commitment::for_message(&body);
    let membership_proof = state.get_proof_for_position(position).unwrap();
    let (output, proof) = execute_and_prove(
        ProvingInput {
            claims: Vec::new(),
            root: TransactionEntry::Async(MessageWitness { body, rho: None, membership_proof, filler: DummyOutput::default() }),
            public_context: PublicExecutionContext::default(),
            private_witnesses: vec![PrivateWitness { address_openings: recovered.opening.into_iter().collect(), ..init_witness(&k) }],
            dummy_inputs: Vec::new(),
            ciphertext_padding: None,
            recoveries: Vec::new(),
            private_promotions: BTreeSet::new(),
            fee: None,
        },
        &Simulation::default(),
        &catalog(),
        |_| SenderPresentation::Canonical,
        |_, _| false,
        no_seal,
    )
    .expect("prove receipt");
    let message = PpMessage::from_circuit_output(Default::default(), output);
    let ws = PpWitnessSet::for_message(&message, proof, &[]);
    state.transition_from_privacy_preserving_transaction(&PrivacyPreservingTransaction::new(message, ws), 3, 500).expect("settle receipt");
    assert!(state.is_spent(&Nullifier::for_message(&k.nsk(), &commitment, position)), "payout consumed exactly once");
    let expected = Account {
        nonce: Nonce::default().private_account_nonce_increment(&k.nsk()),
        ..Account::funded(400)
    };
    assert!(state.get_proof_for_commitment(&Commitment::new(&real_private, &expected)).is_some(), "alice's private note holds 400");
}

#[test]
fn two_claims_use_unlinkable_aliases() {
    let (mut state, creator, alice, id) = setup();
    let (tx1, a1) = private_claim_tx(&state, creator.1, &alice, id, 300, [0xB1; 32], 6);
    state.transition_from_privacy_preserving_transaction(&tx1, 2, 300).expect("claim 1");
    let (tx2, a2) = private_claim_tx(&state, creator.1, &alice, id, 700, [0xB2; 32], 7);
    state.transition_from_privacy_preserving_transaction(&tx2, 3, 700).expect("claim 2");
    assert_ne!(a1, a2);
    let s: Schedule = borsh::from_slice(state.get_account_by_id(schedule_account(&PROGRAM, &creator.1, &id)).data.actor_state(PROGRAM)).unwrap();
    assert_eq!(s.claimed, 700);
    assert_eq!(state.publications_from(0).count(), 2);
}

#[test]
fn non_beneficiary_cannot_prove_a_private_claim() {
    let (state, creator, _alice, id) = setup();
    let mallory = key(3);
    let r = std::panic::catch_unwind(|| private_claim_tx(&state, creator.1, &mallory, id, 400, [0xC1; 32], 8));
    assert!(r.is_err(), "proving fails: V009 only the beneficiary");
}

#[test]
fn two_private_claims_proven_on_the_same_state_cannot_both_pay() {
    let (mut state, creator, alice, id) = setup();
    // Two devices prove a claim for the same instant from the same snapshot.
    let (tx1, _) = private_claim_tx(&state, creator.1, &alice, id, 500, [0xD1; 32], 9);
    let (tx2, _) = private_claim_tx(&state, creator.1, &alice, id, 500, [0xD2; 32], 10);
    state.transition_from_privacy_preserving_transaction(&tx1, 2, 500).expect("first settles");
    let before = state.clone();
    assert!(state.transition_from_privacy_preserving_transaction(&tx2, 2, 500).is_err(), "stale twin is refused");
    assert!(state == before, "refusal leaves state untouched");
    let s: Schedule = borsh::from_slice(state.get_account_by_id(schedule_account(&PROGRAM, &creator.1, &id)).data.actor_state(PROGRAM)).unwrap();
    assert_eq!(s.claimed, 500);
    assert_eq!(state.publications_from(0).count(), 1);
}
