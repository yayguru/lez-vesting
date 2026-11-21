//! The SPEL IDL (idl/vesting.spel.json) describes every instruction and every program error.
use vesting_core::{Unlock, VestingError};

fn idl() -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../idl/vesting.spel.json")).unwrap()).unwrap()
}

#[test]
fn idl_lists_every_instruction() {
    let v = idl();
    let names: Vec<&str> = v["instructions"].as_array().unwrap().iter().map(|i| i["variant"].as_str().unwrap()).collect();
    for want in ["Create", "Claim", "Cancel", "SignalMilestone", "MakeIrrevocable", "TransferBeneficiary"] {
        assert!(names.contains(&want), "IDL misses {want}");
    }
}

#[test]
fn idl_error_codes_match_the_program() {
    let v = idl();
    let codes: Vec<String> = v["errors"].as_array().unwrap().iter().map(|e| e["msg"].as_str().unwrap()[..4].to_string()).collect();
    let all = [
        VestingError::ZeroTotal, VestingError::BadTimes, VestingError::BadMilestones, VestingError::NotAuthorized,
        VestingError::NotOwnProgram, VestingError::WrongScheduleAccount, VestingError::AlreadyInitialized,
        VestingError::NotInitialized, VestingError::NotBeneficiary, VestingError::NotCreator,
        VestingError::NothingClaimable { next_unlock: Unlock::Never }, VestingError::NotCancelable,
        VestingError::AlreadyCancelled, VestingError::MilestoneOutOfRange, VestingError::MilestoneAlreadySignalled,
        VestingError::NotMilestoneSchedule, VestingError::NotTransferable, VestingError::Overflow, VestingError::EmptyBatch,
    ];
    for e in all {
        let code = e.to_string()[..4].to_string();
        assert!(codes.contains(&code), "IDL misses {code} ({e})");
    }
}
