#!/usr/bin/env python3
"""Generates vesting.spel.json in the SPEL IDL schema (spel-framework-core::idl::SpelIdl).
SPEL (logos-co/spel @c6f73ce) still targets LEZ 0.2.5/0.3; this IDL describes the LEZ 0.4
actor-model program. Wire encoding: borsh of `vesting_core::Message` (variant index first)."""
import json, hashlib
P = lambda t: t
A32 = {"array": ["u8", 32]}
ACC = "account_id"
def f(n, t): return {"name": n, "type": t}
def disc(name): return list(hashlib.sha256(f"global:{name}".encode()).digest()[:8])
def acct(name, writable=False, signer=False, init=False, pda=None, vis=("public",)):
    d = {"name": name, "writable": writable, "signer": signer, "init": init, "visibility": list(vis)}
    if pda: d["pda"] = pda
    return d
sched_pda = {"seeds": [{"kind": "const", "value": "rfp017/vesting/schedule"},
                       {"kind": "account", "path": "creator"}, {"kind": "arg", "path": "id"}]}
ix = [
 ("create", "Create", [acct("creator", True, True), acct("creator_native_balance", True),
   acct("schedule", True, init=True, pda=sched_pda), acct("schedule_native_balance", True)],
   [f("entries", {"vec": {"defined": "CreateEntry"}})], {"public": True, "private_owned": False}),
 ("claim", "Claim", [acct("beneficiary", False, True), acct("schedule", True, pda=sched_pda),
   acct("schedule_native_balance", True), acct("destination", True, vis=("public", "private_alias"))],
   [f("creator", ACC), f("id", A32), f("now", "u64"), f("to", ACC)], {"public": True, "private_owned": True}),
 ("cancel", "Cancel", [acct("creator", False, True), acct("schedule", True, pda=sched_pda),
   acct("schedule_native_balance", True), acct("creator_native_balance", True)],
   [f("id", A32), f("now", "u64")], {"public": True, "private_owned": False}),
 ("signal_milestone", "SignalMilestone", [acct("creator", False, True), acct("schedule", True, pda=sched_pda)],
   [f("id", A32), f("index", "u8")], {"public": True, "private_owned": False}),
 ("make_irrevocable", "MakeIrrevocable", [acct("creator", False, True), acct("schedule", True, pda=sched_pda)],
   [f("id", A32)], {"public": True, "private_owned": False}),
 ("transfer_beneficiary", "TransferBeneficiary", [acct("beneficiary", False, True), acct("schedule", True, pda=sched_pda)],
   [f("creator", ACC), f("id", A32), f("new_beneficiary", ACC)], {"public": True, "private_owned": False}),
]
types = [
 {"name": "Kind", "kind": "enum", "variants": [
   {"name": "Linear", "fields": [f("start", "u64"), f("cliff", "u64"), f("end", "u64")]},
   {"name": "Milestones", "fields": [f("amounts", {"vec": "u128"})]}]},
 {"name": "Params", "kind": "struct", "fields": [f("beneficiary", ACC), f("total", "u128"), f("kind", {"defined": "Kind"}),
   f("cancelable", "bool"), f("transferable", "bool")]},
 {"name": "CreateEntry", "kind": "struct", "fields": [f("id", A32), f("params", {"defined": "Params"})]},
 {"name": "Cancelled", "kind": "struct", "fields": [f("at", "u64"), f("vested", "u128")]},
]
accounts = [{"name": "Schedule", "type": {"kind": "struct", "fields": [
  f("version", "u8"), f("creator", ACC), f("id", A32), f("beneficiary", ACC), f("total", "u128"),
  f("kind", {"defined": "Kind"}), f("cancelable", "bool"), f("transferable", "bool"), f("claimed", "u128"),
  f("milestones_done", "u64"), f("cancelled", {"option": {"defined": "Cancelled"}})]}}]
errors = [(1,"ZeroTotal","total must be > 0"),(2,"BadTimes","require start <= cliff <= end and start < end"),
 (3,"BadMilestones","1..=64 non-zero milestone amounts summing to total"),(4,"NotAuthorized","caller did not sign"),
 (5,"NotOwnProgram","schedule ops must come from this program"),(6,"WrongScheduleAccount","schedule PDA does not match (creator, id)"),
 (7,"AlreadyInitialized","schedule already exists"),(8,"NotInitialized","no such schedule"),
 (9,"NotBeneficiary","only the beneficiary can do this"),(10,"NotCreator","only the creator can do this"),
 (11,"NothingClaimable","nothing claimable yet; carries next unlock time"),(12,"NotCancelable","schedule is not cancelable"),
 (13,"AlreadyCancelled","schedule already cancelled"),(14,"MilestoneOutOfRange","milestone index out of range"),
 (15,"MilestoneAlreadySignalled","milestone already signalled"),(16,"NotMilestoneSchedule","not a milestone schedule"),
 (17,"NotTransferable","beneficiary is not transferable"),(18,"Overflow","arithmetic overflow"),(19,"EmptyBatch","empty create batch")]
idl = {"version": "0.1.0", "name": "rfp017_vesting",
  "spec": "spel-idl/0.1 on LEZ 0.4.0-rc3 actor model (borsh-encoded vesting_core::Message)",
  "metadata": {"name": "rfp017_vesting", "version": "0.1.0"},
  "instruction_type": "vesting_core::Message",
  "instructions": [{"name": n, "variant": v, "accounts": a, "args": g, "discriminator": disc(n), "execution": e} for n, v, a, g, e in ix],
  "accounts": accounts, "types": types,
  "errors": [{"code": c, "name": n, "msg": f"V{c:03} {m}"} for c, n, m in errors]}
open("vesting.spel.json", "w").write(json.dumps(idl, indent=2) + "\n")
print("instructions", len(ix), "errors", len(errors))
