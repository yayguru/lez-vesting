//! RFP-017 vesting program for LEZ testnet 0.4 (actor model).
//!
//! Two kinds of actors run this code:
//! - a caller's own actor `(caller, vesting)`: receives the public instructions in a transaction
//!   the caller signs and forwards an [`Op`] to the schedule actor, granting its PDA seed;
//! - a schedule actor `(schedule_pda, vesting)`: holds the [`Schedule`] as its actor state and
//!   the escrow as the native balance of the same PDA account.

use lee_core::{
    account::{AccountId, Actor},
    native_token::{self, custody_transfer},
    program::{ReceiveInput, Response, SyncMessage},
};
use vesting_core::{
    CANCEL_SKEW_MS, Cancelled, Event, Kind, Message, Op, Schedule, VestingError, schedule_account,
    schedule_seed,
};

lee_core::actor_entrypoint!(handle_message);

fn handle_message(input: &ReceiveInput, message: Message) -> Response {
    match run(input, message) {
        Ok(response) => response,
        Err(error) => panic!("{error}"),
    }
}

fn run(input: &ReceiveInput, message: Message) -> Result<Response, VestingError> {
    let program = input.receiver.program_account_id;
    let me = input.receiver.account_id;
    if let Message::Op(op) = message {
        return schedule_op(input, op);
    }
    if !input.is_authorized {
        return Err(VestingError::NotAuthorized);
    }
    let forward = |creator: &AccountId, id: &[u8; 32], op: Op| {
        let seed = schedule_seed(creator, id);
        SyncMessage::new(
            Actor::new(schedule_account(&program, creator, id), program),
            &Message::Op(op),
        )
        .with_pda_seeds(vec![seed])
    };
    let response = match message {
        Message::Create { entries } => {
            if entries.is_empty() {
                return Err(VestingError::EmptyBatch);
            }
            let mut response = Response::keep_state();
            for entry in entries {
                entry.params.validate()?;
                let schedule = schedule_account(&program, &me, &entry.id);
                let total = entry.params.total;
                // Init first: granting the PDA seed admits the (new) schedule account, so the
                // escrow transfer that follows may credit it.
                response = response
                    .send(forward(&me, &entry.id, Op::Init { by: me, id: entry.id, params: entry.params }))
                    .send_sync(
                        Actor::native_balance(me),
                        &native_token::Message::Transfer { to: schedule, amount: total },
                    );
            }
            response
        }
        Message::Claim { creator, id, now, to } => {
            Response::keep_state().send(forward(&creator, &id, Op::Claim { by: me, now, to }))
        }
        Message::Cancel { id, now } => {
            Response::keep_state().send(forward(&me, &id, Op::Cancel { by: me, now }))
        }
        Message::SignalMilestone { id, index } => {
            Response::keep_state().send(forward(&me, &id, Op::Signal { by: me, index }))
        }
        Message::MakeIrrevocable { id } => {
            Response::keep_state().send(forward(&me, &id, Op::Irrevocable { by: me }))
        }
        Message::TransferBeneficiary { creator, id, new_beneficiary } => Response::keep_state()
            .send(forward(&creator, &id, Op::Transfer { by: me, new_beneficiary })),
        Message::Op(_) => unreachable!(),
    };
    Ok(response)
}

fn schedule_op(input: &ReceiveInput, op: Op) -> Result<Response, VestingError> {
    let program = input.receiver.program_account_id;
    let here = input.receiver.account_id;
    let sender = match input.from {
        Some(from) if from.program_account_id == program => from.account_id,
        _ => return Err(VestingError::NotOwnProgram),
    };
    // The forwarding actor only ever names itself as `by`.
    let by = match &op {
        Op::Init { by, .. }
        | Op::Claim { by, .. }
        | Op::Cancel { by, .. }
        | Op::Signal { by, .. }
        | Op::Irrevocable { by }
        | Op::Transfer { by, .. } => *by,
    };
    if by != sender || !input.is_authorized {
        return Err(VestingError::NotAuthorized);
    }

    if let Op::Init { by, id, params } = op {
        if !input.pre_state.is_empty() {
            return Err(VestingError::AlreadyInitialized);
        }
        if schedule_account(&program, &by, &id) != here {
            return Err(VestingError::WrongScheduleAccount);
        }
        params.validate()?;
        let event = Event::Created {
            schedule: here,
            creator: by,
            beneficiary: params.beneficiary,
            total: params.total,
        };
        let schedule = Schedule::new(by, id, params);
        return Ok(Response::set_state(borsh::to_vec(&schedule).expect("serializes"))
            .event(event.to_program_event()));
    }

    if input.pre_state.is_empty() {
        return Err(VestingError::NotInitialized);
    }
    let mut s: Schedule =
        borsh::from_slice(&input.pre_state).map_err(|_| VestingError::NotInitialized)?;
    if schedule_account(&program, &s.creator, &s.id) != here {
        return Err(VestingError::WrongScheduleAccount);
    }
    let seed = schedule_seed(&s.creator, &s.id);
    let save = |s: &Schedule| Response::set_state(borsh::to_vec(s).expect("serializes"));

    let response = match op {
        Op::Init { .. } => unreachable!(),
        Op::Claim { by, now, to } => {
            if by != s.beneficiary {
                return Err(VestingError::NotBeneficiary);
            }
            let amount = s.claimable_at(now);
            if amount == 0 {
                return Err(VestingError::NothingClaimable { next_unlock: s.next_unlock_event(now) });
            }
            s.claimed = s.claimed.checked_add(amount).ok_or(VestingError::Overflow)?;
            save(&s)
                .timestamp_window(now..)
                .send(custody_transfer(here, seed, to, amount))
                .event(Event::Claimed { schedule: here, amount, now }.to_program_event())
        }
        Op::Cancel { by, now } => {
            if by != s.creator {
                return Err(VestingError::NotCreator);
            }
            if s.cancelled.is_some() {
                return Err(VestingError::AlreadyCancelled);
            }
            if !s.cancelable {
                return Err(VestingError::NotCancelable);
            }
            let vested = s.vested_at(now);
            let returned = s.total - vested;
            s.cancelled = Some(Cancelled { at: now, vested });
            let mut response = save(&s)
                .try_timestamp_window(now..now.saturating_add(CANCEL_SKEW_MS).max(now + 1))
                .expect("non-empty window")
                .event(Event::Cancelled { schedule: here, returned, vested, at: now }.to_program_event());
            if returned > 0 {
                response = response.send(custody_transfer(here, seed, s.creator, returned));
            }
            response
        }
        Op::Signal { by, index } => {
            if by != s.creator {
                return Err(VestingError::NotCreator);
            }
            if s.cancelled.is_some() {
                return Err(VestingError::AlreadyCancelled);
            }
            let Kind::Milestones { amounts } = &s.kind else {
                return Err(VestingError::NotMilestoneSchedule);
            };
            if usize::from(index) >= amounts.len() {
                return Err(VestingError::MilestoneOutOfRange);
            }
            let amount = amounts[usize::from(index)];
            let bit = 1_u64 << index;
            if s.milestones_done & bit != 0 {
                return Err(VestingError::MilestoneAlreadySignalled);
            }
            s.milestones_done |= bit;
            save(&s).event(Event::MilestoneSignalled { schedule: here, index, amount }.to_program_event())
        }
        Op::Irrevocable { by } => {
            if by != s.creator {
                return Err(VestingError::NotCreator);
            }
            if !s.cancelable {
                return Err(VestingError::NotCancelable);
            }
            s.cancelable = false;
            save(&s).event(Event::MadeIrrevocable { schedule: here }.to_program_event())
        }
        Op::Transfer { by, new_beneficiary } => {
            if by != s.beneficiary {
                return Err(VestingError::NotBeneficiary);
            }
            if !s.transferable {
                return Err(VestingError::NotTransferable);
            }
            let from = s.beneficiary;
            s.beneficiary = new_beneficiary;
            save(&s).event(
                Event::BeneficiaryTransferred { schedule: here, from, to: new_beneficiary }
                    .to_program_event(),
            )
        }
    };
    Ok(response)
}
