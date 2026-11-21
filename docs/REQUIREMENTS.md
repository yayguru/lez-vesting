# RFP-017 hard requirements → tests

Every hard requirement of [RFP-017](https://github.com/logos-co/rfp/blob/master/RFPs/RFP-017-token-vesting.md)
and the test(s) that check it. Run them with:

```sh
RISC0_DEV_MODE=1 cargo test --workspace      # unit + state-machine tests (real guest ELF, dev-mode receipts)
e2e/run_e2e.sh                               # CLI against a standalone LEZ sequencer (CI runs both)
E2E_REAL_PROOFS=1 e2e/run_e2e.sh             # the same with real proofs (no RISC0_DEV_MODE)
```

Where we write:
- `core::` we mean the unit tests in `core/src/lib.rs`;
- `cli::` we mean the unit tests in `cli/src/main.rs`;
- `public_path`, `private_claim`, `concurrency`, `requirements`, `costs`, `idl` we mean
  `tests/tests/<name>.rs`. They run the compiled guest in the LEZ 0.4 state machine
  (`lee::V04State`).
- `e2e:` we mean a step of `e2e/run_e2e.sh` (real sequencer, real wallet, CLI binary).
- `ui:` we mean `logos/vesting_ui/tests/ui-tests.mjs` (the mini-app loads in the standalone host), `tests/ui-e2e.mjs` (`E2E_UI=1 e2e/run_e2e.sh`: all 10 user flows by clicking through the real app on a live local chain) and `tests/render/render.sh` (all 56 screens render with no QML warnings); originally a smoke test that the mini-app loads
  (`ui-dev` build). Views, buttons and dialogs are checked by hand (manual).
- `manual:` we mean the Basecamp e2e recorded in `e2e/RESULTS.md`.

## Functionality

| # | Requirement | Tests |
|---|---|---|
| F1a | Cliff + linear vesting | `core::cliff_then_linear`, `requirements::cliff_pays_lump_sum_then_linear`, `public_path::claim_before_cliff_fails_then_linear_claims_add_up`, e2e: linear cliff schedule |
| F1b | Fully linear vesting | `core::fully_linear_and_rounding_down`, `requirements::fully_linear_accrues_from_start`, `core::huge_totals_do_not_overflow` |
| F1c | Milestone vesting (creator signals tranches) | `core::milestones_sum`, `public_path::milestones_unlock_once_per_index`, e2e: milestone schedule (signal → claim) |
| F2 | Beneficiary set at creation; claim to public or private; creator does not learn the private account | `public_path::create_escrows_and_emits_created`, `public_path::only_beneficiary_can_claim`, `private_claim::beneficiary_claims_into_a_blinded_private_alias_and_receives_privately`, `private_claim::two_claims_use_unlinkable_aliases`, e2e: public claim and private claim + receive |
| F3 | Cancelable flag (default cancelable); one-way conversion to non-cancelable; cancel returns unvested; vested-but-unclaimed stays claimable | `requirements::non_cancelable_at_creation_rejects_cancel_and_conversion_is_irreversible`, `public_path::irrevocable_is_one_way_and_blocks_cancel`, `public_path::cancel_returns_unvested_and_keeps_vested_claimable`, `requirements::cancel_milestones_keeps_signalled_unclaimed_tranche_claimable`, `core::cancellation_caps_vesting`, `public_path::backdated_cancel_is_rejected`, e2e: cancel (+ V013 on repeat), irrevocable (+ V012 on cancel) |
| F4 | Transferability fixed at creation | `public_path::transfer_beneficiary_respects_flag`, `requirements::transferability_is_fixed_at_creation`, e2e: transfer-beneficiary, then V009 for the old beneficiary |
| F5 | Batch creation; documented maximum per tx | `public_path::batch_create_many`, `requirements::batch_is_all_or_nothing`, `costs::cost_table_and_batch_maximum` (asserts `MAX_BATCH_RECIPIENTS` = 360 is the largest batch that fits), `cli::batch_file_is_parsed_and_validated`, e2e: create-batch of 3, dry-run of 360, V024 for 361 |
| F6 | Event per state transition, schema documented | `requirements::every_state_transition_emits_its_event` (Created, Claimed, Cancelled, MilestoneSignalled, MadeIrrevocable, BeneficiaryTransferred), `core::seeds_are_namespaced`; schema in README "Events" |

## Usability

| # | Requirement | Tests |
|---|---|---|
| U1 | SDK for Logos modules, full lifecycle, public and private claim | SDK = `vesting_core` (types, PDA, curve, errors) + `vesting_module` (Logos core module: `create`, `createBatch`, `show`/`quoteClaim` (query claimable), `claim` public/private, `receivePending`, `cancel`, `signalMilestone`, `makeIrrevocable`, `transferBeneficiary`). The module drives the CLI, so the CLI tests and e2e cover its logic. manual: Basecamp runs of create, signal, public and private claim, receive, cancel (RESULTS.md). |
| U2 | Mini-app, local build, downloadable assets, loadable via git repo; recipient and creator views | ui: loads; manual: Basecamp install of the `.lgx` files and the full flow (RESULTS.md). Build steps: README "Mini-app". |
| U3 | CLI: create, claim, cancel, signal, query claimable | e2e: every command (`create`, `show`, `claim`, `claim --private`, `receive`, `signal`, `cancel`, `irrevocable`, `transfer-beneficiary`, `create-batch`, `list`, `txs`) |
| U4 | Pre-claim summary with fee; private path checks the fee payer's gas, with an actionable error | e2e: `claim --dry-run` (module `quoteClaim`) before each claim; e2e "fee payer without gas": V020 from both the summary and the claim, state unchanged; manual: claim dialog in Basecamp (RESULTS.md) |
| U5 | Privacy disclosure before each private claim | The disclosure text comes from `quoteClaim` (`claim --dry-run --private`, run by e2e) and the claim dialog shows it before every private claim: manual (RESULTS.md) |
| U6 | SPEL IDL | `idl::idl_lists_every_instruction`, `idl::idl_error_codes_match_the_program`; CI regenerates `idl/vesting.spel.json` and fails on drift |
| U7 | Clear errors, including nothing-claimable with the next unlock | `core::unlock_messages_name_the_next_event`, `requirements::cliff_pays_lump_sum_then_linear` (V011 "next unlock at …"), e2e: V011 for milestones ("when the creator signals milestone #0") |

## Reliability

| # | Requirement | Tests |
|---|---|---|
| R1 | Claim is atomic, retry without loss | `requirements::failed_claim_and_failed_cancel_leave_state_unchanged`, `public_path::claim_with_future_now_is_rejected_by_validity_window`, `private_claim::two_private_claims_proven_on_the_same_state_cannot_both_pay`, `private_claim::non_beneficiary_cannot_prove_a_private_claim` |
| R2 | Cancel is atomic | `requirements::failed_claim_and_failed_cancel_leave_state_unchanged`, `public_path::backdated_cancel_is_rejected`, `requirements::batch_is_all_or_nothing` |
| R3 | Concurrent claims on independent schedules do not corrupt state | `concurrency::independent_schedules_claimed_in_one_block_do_not_interfere`, `concurrency::racing_double_claim_on_one_schedule_pays_once` |
| R4 | Milestone signal idempotent: deterministic error, no double unlock | `public_path::milestones_unlock_once_per_index`, e2e: V015 on a repeat signal |

## Performance

| # | Requirement | Tests |
|---|---|---|
| P1 | A claim is one LEZ transaction | e2e: public and private claims each report one tx hash and block; `vesting txs` audit covers every hash in the tx log |
| P2 | CU cost per operation | `costs::cost_table_and_batch_maximum` (cycles + wire bytes per op, in the LEZ 0.4 metered state machine); e2e writes `e2e/out/costs_<mode>.json` from the live sequencer (incl. private claim). Table: README "Costs". **Gap:** RFP asks for measurements on public testnet 0.4, which is not live yet (see below). |

## Supportability

| # | Requirement | Status |
|---|---|---|
| S1 | Deployed and tested on LEZ testnet 0.4 | **Not possible yet.** The public testnet runs LEZ v0.3.2 (`testnet.lez.logos.co`); the 0.4 endpoints are listed as "TBD" on docs.logos.co. We test on a standalone 0.4.0-rc3 sequencer (CI and box), and on Windows/WSL through Basecamp. |
| S2 | e2e against a standalone sequencer, in CI, green | `.github/workflows/ci.yml` job `pinned` runs `scripts/ci.sh` (build, unit tests, `e2e/run_e2e.sh`). Checked locally in a clean `ubuntu:24.04` container. |
| S3 | Each hard requirement has a test | This file. |
| S4 | README with end-to-end usage | `README.md` |

## Privacy

| # | Requirement | Tests |
|---|---|---|
| X1 | Mini-app and SDK claim to public and private | as F2 and U1; manual: both buttons in Basecamp |
| X2 | Disclosure before each private claim | as U5 |
| X3 | SDK checks the claim target is a private account and rejects with an explicit error | `cli::private_claim_rejects_a_non_private_target` (V023), e2e: `claim --private <public id>` returns V023 |

Also covered: private payouts are told apart from fee refunds on receive
(`cli::receive_skips_fee_refunds_but_not_payouts`, manual v4 run in RESULTS.md).
