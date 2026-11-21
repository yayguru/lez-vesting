//! Shared types and pure logic of the RFP-017 vesting program for LEZ (testnet 0.4 actor model).
//!
//! Everything here is deterministic and used both by the RISC Zero guest and by host clients
//! (SDK, CLI, tests), so the claimable amount a client shows is computed by the same code the
//! program runs.

use borsh::{BorshDeserialize, BorshSerialize};
use lee_core::{
    Timestamp,
    account::{AccountId, Balance},
    program::{PdaSeed, ProgramEvent},
};

/// Maximum number of milestone tranches in one schedule (bitmask width).
pub const MAX_MILESTONES: usize = 64;
/// How far a cancellation's `now` may lag the block timestamp (ms). Bounds how much a creator can
/// claw back by back-dating a cancellation.
pub const CANCEL_SKEW_MS: Timestamp = 10 * 60 * 1000;

/// Vesting curve.
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Kind {
    /// Nothing before `cliff`; from `cliff` on, `total * (t - start) / (end - start)`, capped at
    /// `total`. `cliff == start` is fully linear vesting.
    Linear { start: Timestamp, cliff: Timestamp, end: Timestamp },
    /// Tranches unlocked by the milestone authority, one signal per index.
    Milestones { amounts: Vec<Balance> },
}

/// Parameters a creator chooses for one schedule.
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Params {
    pub beneficiary: AccountId,
    pub total: Balance,
    pub kind: Kind,
    pub cancelable: bool,
    pub transferable: bool,
}

/// One entry of a (batch) creation.
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct CreateEntry {
    /// Creator-chosen 32-byte id, unique per creator.
    pub id: [u8; 32],
    pub params: Params,
}

/// Messages of the vesting program.
///
/// `Create`..`TransferBeneficiary` are received at the caller's own actor under this program
/// (`Actor::new(caller, vesting)`) in a transaction the caller signs. The caller's actor then
/// forwards an [`Op`] to the schedule's PDA actor, granting the schedule's PDA seed.
/// Most schedules one `Create` transaction can carry within LEZ 0.4's per-transaction limits
/// for single-linear entries: bound by execution gas (MAX_GAS_EXEC = 10M cycles; one entry costs
/// ~27.7k cycles). Measured, and kept in sync, by tests/tests/costs.rs.
pub const MAX_BATCH_RECIPIENTS: usize = 360;

#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Message {
    Create { entries: Vec<CreateEntry> },
    Claim { creator: AccountId, id: [u8; 32], now: Timestamp, to: AccountId },
    Cancel { id: [u8; 32], now: Timestamp },
    SignalMilestone { id: [u8; 32], index: u8 },
    MakeIrrevocable { id: [u8; 32] },
    TransferBeneficiary { creator: AccountId, id: [u8; 32], new_beneficiary: AccountId },
    /// Internal: only accepted from another actor of this program.
    Op(Op),
}

/// Operations executed by the schedule actor. `by` is the account whose actor forwarded it.
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Op {
    Init { by: AccountId, id: [u8; 32], params: Params },
    Claim { by: AccountId, now: Timestamp, to: AccountId },
    Cancel { by: AccountId, now: Timestamp },
    Signal { by: AccountId, index: u8 },
    Irrevocable { by: AccountId },
    Transfer { by: AccountId, new_beneficiary: AccountId },
}

/// On-chain state of one schedule, stored as the schedule PDA's actor state.
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Schedule {
    pub version: u8,
    pub creator: AccountId,
    pub id: [u8; 32],
    pub beneficiary: AccountId,
    pub total: Balance,
    pub kind: Kind,
    pub cancelable: bool,
    pub transferable: bool,
    pub claimed: Balance,
    pub milestones_done: u64,
    /// Set on cancellation: the amount vested at that moment, which becomes the new ceiling.
    pub cancelled: Option<Cancelled>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub struct Cancelled {
    pub at: Timestamp,
    pub vested: Balance,
}

/// Deterministic, user-facing errors. The guest panics with `Display` of these, so a failed
/// transaction carries the code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VestingError {
    ZeroTotal,
    BadTimes,
    BadMilestones,
    NotAuthorized,
    NotOwnProgram,
    WrongScheduleAccount,
    AlreadyInitialized,
    NotInitialized,
    NotBeneficiary,
    NotCreator,
    NothingClaimable { next_unlock: Unlock },
    NotCancelable,
    AlreadyCancelled,
    MilestoneOutOfRange,
    MilestoneAlreadySignalled,
    NotMilestoneSchedule,
    NotTransferable,
    Overflow,
    EmptyBatch,
}

impl core::fmt::Display for VestingError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::ZeroTotal => write!(f, "V001 total must be > 0"),
            Self::BadTimes => write!(f, "V002 require start <= cliff <= end and start < end"),
            Self::BadMilestones => write!(f, "V003 milestones: 1..=64 non-zero tranches summing to total"),
            Self::NotAuthorized => write!(f, "V004 caller did not sign"),
            Self::NotOwnProgram => write!(f, "V005 schedule ops are only accepted from this program"),
            Self::WrongScheduleAccount => write!(f, "V006 account is not the PDA of (creator, id)"),
            Self::AlreadyInitialized => write!(f, "V007 schedule already exists"),
            Self::NotInitialized => write!(f, "V008 no schedule at this account"),
            Self::NotBeneficiary => write!(f, "V009 only the beneficiary can do this"),
            Self::NotCreator => write!(f, "V010 only the creator can do this"),
            Self::NothingClaimable { next_unlock: Unlock::At(t) } => {
                write!(f, "V011 nothing claimable yet; next unlock at {t} (unix ms)")
            }
            Self::NothingClaimable { next_unlock: Unlock::AwaitingMilestone(i) } => {
                write!(f, "V011 nothing claimable yet; next unlock when the creator signals milestone #{i}")
            }
            Self::NothingClaimable { next_unlock: Unlock::Never } => {
                write!(f, "V011 nothing claimable; everything vested has been claimed and nothing else will unlock")
            }
            Self::NotCancelable => write!(f, "V012 schedule is not cancelable"),
            Self::AlreadyCancelled => write!(f, "V013 schedule already cancelled"),
            Self::MilestoneOutOfRange => write!(f, "V014 milestone index out of range"),
            Self::MilestoneAlreadySignalled => write!(f, "V015 milestone already signalled"),
            Self::NotMilestoneSchedule => write!(f, "V016 not a milestone schedule"),
            Self::NotTransferable => write!(f, "V017 position is not transferable"),
            Self::Overflow => write!(f, "V018 arithmetic overflow"),
            Self::EmptyBatch => write!(f, "V019 batch is empty"),
        }
    }
}

impl Params {
    pub fn validate(&self) -> Result<(), VestingError> {
        if self.total == 0 {
            return Err(VestingError::ZeroTotal);
        }
        match &self.kind {
            Kind::Linear { start, cliff, end } => {
                if !(start <= cliff && cliff <= end && start < end) {
                    return Err(VestingError::BadTimes);
                }
            }
            Kind::Milestones { amounts } => {
                if amounts.is_empty() || amounts.len() > MAX_MILESTONES || amounts.contains(&0) {
                    return Err(VestingError::BadMilestones);
                }
                let mut sum: Balance = 0;
                for a in amounts {
                    sum = sum.checked_add(*a).ok_or(VestingError::Overflow)?;
                }
                if sum != self.total {
                    return Err(VestingError::BadMilestones);
                }
            }
        }
        Ok(())
    }
}

/// `total * num / den` without overflow for any u128 total (den > 0, num <= den).
fn mul_div(total: Balance, num: u64, den: u64) -> Balance {
    let (num, den) = (Balance::from(num), Balance::from(den));
    let q = total / den;
    let r = total % den;
    // q*num <= total and r*num < den*num <= 2^128 only if den,num < 2^64, which holds.
    q * num + r * num / den
}

impl Schedule {
    pub fn new(creator: AccountId, id: [u8; 32], params: Params) -> Self {
        Self {
            version: 1,
            creator,
            id,
            beneficiary: params.beneficiary,
            total: params.total,
            kind: params.kind,
            cancelable: params.cancelable,
            transferable: params.transferable,
            claimed: 0,
            milestones_done: 0,
            cancelled: None,
        }
    }

    /// Amount vested at `now`, before subtracting claims.
    pub fn vested_at(&self, now: Timestamp) -> Balance {
        let curve = match &self.kind {
            Kind::Linear { start, cliff, end } => {
                if now < *cliff {
                    0
                } else if now >= *end {
                    self.total
                } else {
                    mul_div(self.total, now - start, end - start)
                }
            }
            Kind::Milestones { amounts } => amounts
                .iter()
                .enumerate()
                .filter(|(i, _)| self.milestones_done & (1 << i) != 0)
                .map(|(_, a)| *a)
                .sum(),
        };
        match self.cancelled {
            Some(c) => curve.min(c.vested),
            None => curve,
        }
    }

    pub fn claimable_at(&self, now: Timestamp) -> Balance {
        self.vested_at(now).saturating_sub(self.claimed)
    }

    /// Next moment the claimable amount grows (time-based schedules only), for UIs.
    pub fn next_unlock(&self, now: Timestamp) -> Option<Timestamp> {
        match self.next_unlock_event(now) {
            Unlock::At(t) => Some(t),
            Unlock::AwaitingMilestone(_) | Unlock::Never => None,
        }
    }

    /// What unlocks next: a time, a milestone the creator must signal, or nothing.
    pub fn next_unlock_event(&self, now: Timestamp) -> Unlock {
        if self.cancelled.is_some() {
            return Unlock::Never;
        }
        match &self.kind {
            Kind::Linear { cliff, end, .. } => {
                if now < *cliff {
                    Unlock::At(*cliff)
                } else if now < *end {
                    Unlock::At(now + 1)
                } else {
                    Unlock::Never
                }
            }
            Kind::Milestones { amounts } => (0..amounts.len())
                .find(|i| self.milestones_done & (1u64 << i) == 0)
                .map_or(Unlock::Never, |i| Unlock::AwaitingMilestone(u8::try_from(i).unwrap_or(u8::MAX))),
        }
    }
}

/// The next unlock event of a schedule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unlock {
    At(Timestamp),
    AwaitingMilestone(u8),
    Never,
}

/// PDA seed of a schedule: `sha256("rfp017/vesting/schedule" || creator || id)`.
pub fn schedule_seed(creator: &AccountId, id: &[u8; 32]) -> PdaSeed {
    use risc0_zkvm::sha::{Impl, Sha256 as _};
    let mut bytes = Vec::with_capacity(23 + 64);
    bytes.extend_from_slice(b"rfp017/vesting/schedule");
    bytes.extend_from_slice(creator.value());
    bytes.extend_from_slice(id);
    let digest = Impl::hash_bytes(&bytes);
    PdaSeed::new(digest.as_bytes().try_into().expect("32-byte digest"))
}

/// Account id of a schedule (also its escrow: the native balance of this account).
pub fn schedule_account(program: &AccountId, creator: &AccountId, id: &[u8; 32]) -> AccountId {
    AccountId::for_public_pda(program, &schedule_seed(creator, id))
}

/// Event payloads (LP-0012 style: 8-byte selector + borsh data).
#[derive(Debug, Clone, PartialEq, Eq, BorshSerialize, BorshDeserialize)]
pub enum Event {
    Created { schedule: AccountId, creator: AccountId, beneficiary: AccountId, total: Balance },
    Claimed { schedule: AccountId, amount: Balance, now: Timestamp },
    Cancelled { schedule: AccountId, returned: Balance, vested: Balance, at: Timestamp },
    MilestoneSignalled { schedule: AccountId, index: u8, amount: Balance },
    MadeIrrevocable { schedule: AccountId },
    BeneficiaryTransferred { schedule: AccountId, from: AccountId, to: AccountId },
}

impl Event {
    pub const fn name(&self) -> &'static str {
        match self {
            Self::Created { .. } => "vesting::Created",
            Self::Claimed { .. } => "vesting::Claimed",
            Self::Cancelled { .. } => "vesting::Cancelled",
            Self::MilestoneSignalled { .. } => "vesting::MilestoneSignalled",
            Self::MadeIrrevocable { .. } => "vesting::MadeIrrevocable",
            Self::BeneficiaryTransferred { .. } => "vesting::BeneficiaryTransferred",
        }
    }

    pub fn selector_of(name: &str) -> [u8; 8] {
        use risc0_zkvm::sha::{Impl, Sha256 as _};
        Impl::hash_bytes(name.as_bytes()).as_bytes()[..8].try_into().expect("8 bytes")
    }

    pub fn to_program_event(&self) -> ProgramEvent {
        ProgramEvent {
            selector: Self::selector_of(self.name()),
            data: borsh::to_vec(self).expect("event serializes"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acct(b: u8) -> AccountId {
        AccountId::new([b; 32])
    }

    fn linear(start: u64, cliff: u64, end: u64, total: u128) -> Schedule {
        Schedule::new(
            acct(1),
            [0; 32],
            Params {
                beneficiary: acct(2),
                total,
                kind: Kind::Linear { start, cliff, end },
                cancelable: true,
                transferable: false,
            },
        )
    }

    #[test]
    fn cliff_then_linear() {
        let s = linear(1000, 1250, 2000, 1000);
        assert_eq!(s.vested_at(0), 0);
        assert_eq!(s.vested_at(1249), 0);
        assert_eq!(s.vested_at(1250), 250);
        assert_eq!(s.vested_at(1500), 500);
        assert_eq!(s.vested_at(2000), 1000);
        assert_eq!(s.vested_at(u64::MAX), 1000);
        assert_eq!(s.next_unlock(10), Some(1250));
    }

    #[test]
    fn fully_linear_and_rounding_down() {
        let s = linear(0, 0, 3, 10);
        assert_eq!(s.vested_at(1), 3);
        assert_eq!(s.vested_at(2), 6);
        assert_eq!(s.vested_at(3), 10);
    }

    #[test]
    fn huge_totals_do_not_overflow() {
        let s = linear(0, 0, u64::MAX, u128::MAX);
        assert!(s.vested_at(u64::MAX / 2) <= u128::MAX / 2 + 1);
        assert_eq!(s.vested_at(u64::MAX), u128::MAX);
    }

    #[test]
    fn cancellation_caps_vesting() {
        let mut s = linear(0, 0, 100, 100);
        s.cancelled = Some(Cancelled { at: 40, vested: 40 });
        assert_eq!(s.vested_at(90), 40);
        assert_eq!(s.next_unlock(50), None);
    }

    #[test]
    fn milestones_sum() {
        let mut s = Schedule::new(
            acct(1),
            [0; 32],
            Params {
                beneficiary: acct(2),
                total: 60,
                kind: Kind::Milestones { amounts: vec![10, 20, 30] },
                cancelable: true,
                transferable: true,
            },
        );
        assert_eq!(s.vested_at(0), 0);
        s.milestones_done = 0b101;
        assert_eq!(s.vested_at(0), 40);
    }

    #[test]
    fn validation() {
        let p = |kind, total| Params { beneficiary: acct(2), total, kind, cancelable: true, transferable: true };
        assert_eq!(p(Kind::Linear { start: 0, cliff: 0, end: 1 }, 0).validate(), Err(VestingError::ZeroTotal));
        assert_eq!(p(Kind::Linear { start: 5, cliff: 4, end: 9 }, 1).validate(), Err(VestingError::BadTimes));
        assert_eq!(p(Kind::Linear { start: 5, cliff: 5, end: 5 }, 1).validate(), Err(VestingError::BadTimes));
        assert_eq!(p(Kind::Milestones { amounts: vec![1, 2] }, 4).validate(), Err(VestingError::BadMilestones));
        assert_eq!(p(Kind::Milestones { amounts: vec![1, 0, 3] }, 4).validate(), Err(VestingError::BadMilestones));
        assert!(p(Kind::Milestones { amounts: vec![1, 3] }, 4).validate().is_ok());
    }

    #[test]
    fn seeds_are_namespaced() {
        let prog = acct(9);
        assert_ne!(schedule_account(&prog, &acct(1), &[0; 32]), schedule_account(&prog, &acct(2), &[0; 32]));
        assert_ne!(schedule_account(&prog, &acct(1), &[0; 32]), schedule_account(&prog, &acct(1), &[1; 32]));
        assert_ne!(Event::selector_of("vesting::Created"), Event::selector_of("vesting::Claimed"));
    }

    #[test]
    fn unlock_messages_name_the_next_event() {
        let mut m = Schedule::new(acct(1), [0; 32], Params {
            beneficiary: acct(2), total: 30, kind: Kind::Milestones { amounts: vec![10, 20] },
            cancelable: true, transferable: false,
        });
        assert_eq!(m.next_unlock_event(0), Unlock::AwaitingMilestone(0));
        m.milestones_done = 0b01;
        assert_eq!(m.next_unlock_event(0), Unlock::AwaitingMilestone(1));
        m.milestones_done = 0b11;
        assert_eq!(m.next_unlock_event(0), Unlock::Never);
        let e = VestingError::NothingClaimable { next_unlock: Unlock::AwaitingMilestone(1) }.to_string();
        assert!(e.starts_with("V011") && e.contains("signals milestone #1"), "{e}");
        let l = linear(0, 100, 200, 10);
        assert_eq!(l.next_unlock_event(50), Unlock::At(100));
        assert!(VestingError::NothingClaimable { next_unlock: Unlock::At(100) }.to_string().contains("next unlock at 100"));
    }
}
