# E2E results

## Windows tested via WSL (20.11.2026, Windows 10 laptop)

Setup:
- Windows 10 22H2 (19045), Logos Basecamp 0.4.0-rc.2 (Unofficial Windows build, credit OPDE),
  `--user-dir C:\Users\USER\lgxtest\bcdata`.
- `vesting_module-0.1.0-windows.lgx` (native mingw DLL) and `vesting_ui-0.1.0-windows.lgx` (QML),
  signed `yayguru`, installed via Package Manager → Install Local Package → **Install** (not Trust).
- WSL2 Ubuntu 24.04.5, `.wslconfig` memory=2GB. Inside WSL: LEZ 0.4.0-rc3 standalone sequencer
  (mock Bedrock, RISC0_DEV_MODE=1) on 127.0.0.1:3040, LEE wallet, vesting CLI, r0vm 3.0.6
  (scripts: `e2e/windows/wsl_setup.sh`, `wsl_chain.sh`, `wsl_deploy.sh`).
- Vesting program deployed at `GaDvygRPGyyBpGz9TZiXXYURd1GoE4KpfCPCEF1Yqs2w`
  (deploy txs 6b513e36…, bf2f642d…; private account funded by shield dba25a3d…).
- Module settings (Settings tab): backend `wsl` (Windows default when no native vesting.exe),
  distro `Ubuntu-24.04`, CLI `vesting`, wallet home `/root/vest/wallet`, dev-mode proofs on.
- Creator `6iArKUXx…2VQV`, beneficiary `7wHg9sbJ…3YQo`, private account `GMQwBNSN…fnFy`.

Every step below was driven from the Vesting mini-app inside Basecamp on Windows; the module ran
`wsl.exe -d Ubuntu-24.04 -e env … vesting --json …` for each call.

| Step | Result | Block | Tx |
|---|---|---|---|
| Create milestones schedule 4,000,000 + 8,000,000 (id `b1384dced3b0db494195eb60f1adf757cafb85b8ed744425532e2904b205b5de`) | ok | 40 | `c86303ff5408589857d6f0948e3ae746c6dc7008a5b68b5be9b55dcbc7a3c410` |
| Signal milestone #0 | ok, vested 4,000,000 | 45 | `30b71495593ee39f7ea6cc0d48d85d63435b4b9f2cb786f6dca841cb98c24a96` |
| Public claim 4,000,000 (fee estimate 308,376) | ok | 53 | `70ea9a92cc43c2a837ca575fe3190cc27c7818a3210fb3b95b267b2a3b76362a` |
| Signal milestone #1 | ok, fully vested | 58 | `3b3ab0fcf6b0ead79fc92b7efef224f739d082fc153b4846adc19b8740792c65` |
| Private claim 8,000,000 (fee estimate 5,373,432, paid by the private account) | ok | 65 | `21c72cc445d6b856688aceb04af29d1c1bb18ff74989a7e5e584f7689226409f` (privacy-preserving) |
| Receive private payouts, 1st press | 1 payout received, 2nd refused at settlement ("Nullifier already seen") → UI showed V021 | 68 | `9d65e37c6ea4a5169fd32bd3a26847ee5849166a700bca9dff50b8d07c4d3bb7`; refused `bcb1455261d6150603f3a3441ebee0c67e9407f7a8011e3be983618f6566e8fe` |
| Receive private payouts, 2nd press (after Refresh) | ok, "Received 1 payout(s)" | 82 | `5a9245634625f0d7871cae94d07d9bcc079fe772a358fea4760197a867b0dff4` |

Final: schedule total 12,000,000, claimed 12,000,000, escrow 0. Private account balance:
54,929,384 before the private claim, 44,245,585 after both receives (the 8M payouts minus privacy-preserving fees).

Finding / fix (corrected after the follow-up re-check below): a private claim leaves **one** vesting
payout plus **one fee-refund message** (the unused part of the private fee reserve, sent by the fee
inbox `8ga8ND…`). Receiving a refund is itself a private tx with a fee reserve, so it produces a new
refund. The "2nd payout" above was such a refund. `vesting receive` now receives only messages not
sent by a fee account (`system_accounts::fee_account_ids()`), persists/re-syncs the wallet between
rounds, waits two blocks after each inclusion, and retries a refused receive. Every submitted tx is
appended to `<wallet home>/vesting_txlog.jsonl`; `vesting txs --from --to` lists tx hashes per block.

### Follow-up re-check: private claim → one Receive press (20.11.2026, 16:40–17:40 CET)

Pre-check: node Online/Following, height ~99,100–99,190, mining ON (Stop mining shown), one node
(one `:8080` listener, one Basecamp), WSL Ubuntu-24.04 running.

- Runs 1–2 (CLI v1/v2, schedules `b4af205f…`, `e4489faf…`): one press received the payout; the
  "second" message was refused (stale private state) and needed another press.
- Run 3 (CLI v3, schedule `a5e3be1c…`): create block 316 `fd260306…`, signal #0 327 `ed4b2352…`,
  private claim 10,000,000 block 333 `e8a9205d…`. Pending before the press: 2 (payout from the
  schedule + fee refund). **One press: "Received 9 payout(s)"**, blocks 379–395
  (`8fd05438…`, `2f2f8163…`, `56663944…`, `32f04e3f…`, `6089d346…`, `9515d338…`, `c8ab42a5…`,
  `13505006…`, `b88c4744…`), pending afterwards 0. Each receive after the payout was a fee refund
  that triggered a new refund, so v3 looped and the private fee account fell from 38,290,217 to
  452,048 TestToken (test network funds only).
- `vesting txs --from 316 --to 396` lists all 12 hashes from the txlog (12/12).
- Fix v4 (refunds skipped, max 8 rounds) built and deployed to WSL (`/opt/vest/bin/vesting`, image id
  `d14c22f4…` unchanged); smoke run `vesting receive` → `{"ok":true,"received":[]}`, no tx sent.

### v4 check from Basecamp (20.11.2026, 17:34–17:50 CET)

Pre-check: node Online/Following (99,199 → 99,214), mining ON, one node, WSL running, no v4 run yet.

- Top-up (test chain only): shield 50,000,000 from creator `6iArKU…` to `Private/GMQwBN…`, block 450,
  `1a0a67711658f5d92c3e2da0e2c17dfc11572fab23cc627ef7168cb196dad312`. Needs `RISC0_DEV_MODE=1` like the
  sequencer; a real proof OOM-kills `r0vm` at ~1.55 GB under WSL `memory=2GB`. Private balance
  452,048 → 45,381,432 (fee 5,070,616).

| Step (Basecamp, backend=wsl) | Result | Block | Tx |
|---|---|---|---|
| Create, schedule `bdde78cb…`, 10,000,000, 1 milestone | ok | 457 | `7999cb2cf63e9ff938a098b53b9cbbbec8a9d7f0ef651af12313c7927902769f` |
| Signal milestone #0 | ok | 463 | `7b73fb4128722761f83a03ba267df51b486300d77c2aabe0fbf60194b07a7157` |
| Private claim 10,000,000 | ok; pending: payout (from schedule) + fee refund (from `8ga8ND…`) | 469 | `2edc57bd5149e4c6a8d60036fcc8516543bee0ab8d8edddb65dde8eae39465eb` |
| Receive private payouts, **one press** | "Received 1 payout(s)", only one tx sent, no loop | 473 | `a631ab095284de5e384b986af51dd1739b14d2c921c0aa98bfbd4b5e67c68737` |

- Private balance: 45,381,432 → 36,652,322 after the claim (reserve 8,729,110) → 41,769,921 after the
  receive (+10,000,000 payout, minus the receive's reserve; the claim's refund was absorbed by the
  wallet as a payer credit into that reserve). Total fees for the 2 private txs ≤ 13,611,511, i.e.
  within two max reserves (~8.24M each); the receive's own refund stays pending (not looped).
- `vesting txs --from 450 --to 473` lists all 4 txlog hashes with matching blocks (Public, Public,
  PrivacyPreserving, PrivacyPreserving).
- Regression test: `cargo test -p vesting_cli` → `tests::receive_skips_fee_refunds_but_not_payouts`
  (fee accounts incl. `8ga8ND…` skipped, schedule-account sender received) passes.

Not done natively: a Windows `vesting.exe` (RISC0 r0vm has no Windows build) — M3 scope; WSL is
the documented fallback.

## Box e2e, standalone sequencer, dev-mode proofs (20.11.2026, 20:30–20:50 CET)

`e2e/run_e2e.sh` (Debian 13, LEZ v0.4.0-rc3, image id `fd0135f0…c28f`): **E2E PASSED**. Every
CLI command ran: create, show, public claim, transfer-beneficiary, signal, private claim and receive,
cancel, irrevocable, create-batch (3 entries, plus `--entries-hex`), list, txs. Expected errors came
back: V009, V011, V015, V023, V013, V012, V020 (fee payer without gas, state unchanged) and V024.
The private claim gave exactly 1 payout, fee refunds were skipped, fees were 13,613,183, and
13/13 logged txs were found on chain.

Sequencer dry-run measurements (`e2e/out/costs_dev.json`; fee = wallet estimate incl. margin):

| Op | Cycles | Wire bytes | Fee estimate |
|---|---:|---:|---:|
| create | 36,003 | 702 | 293,640 |
| claim public | 39,068 | 695 | 318,104 |
| claim private | 37,852 (public part) | – | 5,373,432 (reserve) |
| transfer | 35,221 | 559 | 286,240 |
| signal | 33,325 | 496 | 270,568 |
| cancel | 36,417 | 631 | 296,384 |
| make irrevocable | 33,126 | 495 | 268,968 |
| create batch ×3 | 91,236 | 1,172 | 739,264 |
| create batch ×360 | 9,997,678 | 85,067 | 80,661,960 |

The 360-entry batch passes the sequencer dry-run (under MAX_GAS_EXEC 10M). 361 entries are refused with V024.
The wire bytes are 65 B higher than in `tests/tests/costs.rs` because they include the wallet's signature/witness.

## Public testnet 0.4 (checked 20.11.2026, 20:55 CET)

Not live:
- docs.logos.co/get-started/testnet-endpoints lists every 0.4 (actor model) endpoint as "TBD";
- the current public testnet is v0.3.2 (`https://testnet.lez.logos.co`);
- the newest LEZ tag is `v0.4.0-rc3`.

So nothing was deployed to a public testnet. Once 0.4 is live, the steps are:
1. Point `wallet_config.json` `sequencer_addr` at the 0.4 RPC.
2. Fund a public account from the faucet.
3. Run the README deploy (step 3).
4. Publish the header id.

This will not be done without the owner's go-ahead.

## Box e2e with REAL proofs (no RISC0_DEV_MODE), 20.11.2026, 21:08–23:00 CET

`E2E_REAL_PROOFS=1 e2e/run_e2e.sh` ran against a standalone LEZ v0.4.0-rc3 sequencer, also without dev mode, and ended with **E2E PASSED (real proofs)**.

Machine:
- the box: 8 vCPU, 16 GB RAM, plus a 16 GB swap file added for this run;
- another heavy process was using about 4.5 cores at the same time, so the wall times below are pessimistic.

| Step | Result | Wall time | Peak RSS (CLI + r0vm) |
|---|---|---:|---:|
| shield 60M → private account (wallet) | ok | ~24 min | ~9.6 GB r0vm |
| private claim 400,000 → blinded alias (tx `eade34c5…060b`, block 212) | ok | 41:55 | 9,370 MB |
| receive | 1 payout (fee refunds skipped) | 33:43 | 9,370 MB |

The private balance went 54,929,384 → 41,716,201: the 400,000 payout came in and fees were 13,613,183, the same as in dev mode.

The rest of the run passed too:
- public claim, transfer, cancel, irrevocable and the batch of 3;
- V009, V011, V015, V023, V013, V012, V020 and V024 came back as expected;
- the 360-entry batch dry-run passed;
- 13/13 txs were on chain.

Findings:
- Real private-tx proving needs **~9.5 GB RAM** for r0vm.
- Two earlier attempts were OOM-killed at 7.6 and 8.6 GB.
- The earlier WSL figure (~1.6 GB) was only the point where the 2 GB VM killed r0vm.
- Public transactions need no client proof.

## Clean clone (fresh `git clone`, clean `ubuntu:24.04` container), 20–21.11.2026 CET

Setup:
- `git clone` of this repo at `04bb9f5`, mounted into a fresh `ubuntu:24.04` Docker container (5–9 GB memory limit);
- only the README commands were run (`/src/readme_steps.sh`):
  1. `scripts/install-deps.sh`
  2. `scripts/set-lez-tag.sh --check`
  3. `cargo build --release -p vesting_cli`
  4. `vesting image-id`
  5. `RISC0_DEV_MODE=1 cargo test --workspace`
  6. `e2e/run_e2e.sh`

Result: **CLEAN_CLONE_OK**, finished at 00:11 CET. The last full pass ran 23:01–00:11 CET, reusing the first attempt's partial build.

Tests and e2e:
- install-deps completed: apt packages, rustup 1.98.1, rzup with guest rust 1.97.0, cargo-risczero and r0vm 3.0.6.
- Tests: 40 passed, 0 failed (14 suites), including `costs::cost_table_and_batch_maximum`.
- e2e (dev proofs) at LEZ v0.4.0-rc3 cloned from GitHub: **E2E PASSED**.
  - V009, V011, V015, V023, V013, V012, V020 and V024 came back as expected.
  - The private claim gave exactly 1 payout, fee refunds were skipped, fees were 13,613,183.
  - The 360-entry batch dry-run passed.
  - 13/13 txs were found on chain.

What the run surfaced, and the fixes:
1. `unzip` was missing: the rapidsnark build script needs it. It is now in `install-deps.sh` and the README.
2. The guest image id depends on the build environment: the container build gives `1fdab914…496d`, the box `fd0135f0…c28f`. README documents this and `RISC0_USE_DOCKER=1` for reproducible ids.
3. `vesting_ui/flake.lock` held an absolute `/workspace` path for `vesting_module`. It now uses the relative `path:../vesting_module`.

Not run in the container: the Nix mini-app build (`nix build .#lgx`). It was built on the box, and installed and run on Windows (see above).

## Full e2e + mini-app UI e2e, fresh chain (21.11.2026, 05:43–06:02 CET)

`E2E_UI=1 E2E_PORT=3080 e2e/run_e2e.sh`, dev-mode proofs, LEZ v0.4.0-rc3, fresh standalone sequencer and wallet.
- CLI e2e: all steps passed. That covers deploy, shield, linear claim/transfer, milestones with errors, signal, private claim + receive, cancel, non-cancelable, the fee-payer error, the batch (3 entries, 360 fit, 361 → V024) and the on-chain audit.
- Mini-app UI e2e (`logos/vesting_ui/tests/ui-e2e.mjs`, real module + CLI, real clicks): **10 passed, 0 failed**:
  - Settings → Save;
  - New vesting → Review → Create vesting;
  - Claim;
  - milestone vesting → Confirm milestone 1;
  - Receive privately (claim + move to private balance);
  - Check for private payments;
  - Give to another account;
  - Make permanent;
  - Stop vesting;
  - Send to many people.
- Result: `E2E PASSED`, exit 0.
- Fixes made while running it:
  - a stale standalone app held the inspector port 3768, so the test drove the wrong window. `run_e2e.sh` now refuses to start if the port is busy.
  - a click right after an expander opened could land on the wrong button. Clicks now wait for the layout to settle.
  - one send took over 4 minutes on the loaded box. Ops now get up to 10 minutes.

## 0.2.0 wallet-first mini-app (21.11.2026, 13:04–13:16 CET)

`E2E_UI=1 E2E_PORT=3091 e2e/run_e2e.sh`, dev-mode proofs, LEZ v0.4.0-rc3, fresh standalone sequencer and wallet.
- Render harness: 35/35 screens, no QML warnings (`tests/render/render.sh`, also checks appVersion = metadata.json).
- `ui-tests.mjs` (standalone host, real module): 5/5.
- CLI e2e: all steps passed, now including auto-discovery: the recipient's own wallet found the vesting with no code (scanned to block 44, 1 new).
- Mini-app UI e2e: **10 passed, 0 failed**. Connect found 7 incoming and 8 outgoing vestings on chain with no codes. The wallet card shows the balance in LGO (`19,999.939419061 LGO`). Amounts are entered in LGO (0.05, 0.003, 0.001/0.002). A private claim lowers the private balance by the network cost; the payout arrives on `receive`.
- Result: `E2E PASSED`.
- Fixes made while running it:
  - one poll timer was shared by concurrent jobs, so a stale job's "Connection refused" reached the current refresh. Polling is now per job, and the app auto-retries after a connection error.
  - the default "From" account was the recipient. The test now picks the creator via **Change**.
- Laptop (Windows 10 laptop): signed Windows vesting_ui 0.2.0 installed via Package Manager → Install Local Package → **Reinstall/Upgrade** (never Trust). Installed Main.qml is byte-identical to the repo. Settings → About: `Vesting 0.2.0 (2026-11-21) · RFP-017 prototype for LEZ 0.4`.

## 0.3.0 stepper + money-flow mini-app (21.11.2026, 14:30–15:40 CET)

Dev-mode proofs, LEZ v0.4.0-rc3, fresh standalone sequencer and wallet.
- Render harness: **56/56** screens, no QML warnings. Includes the laptop size (1260x655 app area of a maximized 1366x768 Basecamp), 1024x700, 1280x720 and 440 wide. On every Create step the "Vest tokens" header button and the pinned action bar (Back · Step N of 4 · Continue/Vest) stay on screen.
- `ui-tests.mjs`: 5/5, including "Vest tokens is a 4-step stepper" and About = `Vesting 0.3.0 (2026-11-21)`.
- Full `E2E_UI=1` run #5 (port 3092): CLI e2e passed, mini-app UI e2e **10 passed, 0 failed**, `E2E PASSED`. The UI flow is Vest tokens → 1 Who ("My other account") → 2 How much (0.05 LGO) → 3 Schedule (6 months preset) → 4 Review → "Vest 0.05 LGO" → "Vesting created / Where your LGO are now". It then opens "Switch to <recipient>'s view", which shows the recipient detail of the same vesting account (`3NmprqBg…RA1`) with Claim.
- Run #6 (port 3093, post-review fixes): see below.
- Packages:
  - `vesting_ui-0.3.0-linux.lgx` (sha256 c1831accaddfc16f…), built with nix.
  - `vesting_ui-0.3.0-windows.lgx` (sha256 2e7ae69dd44974a3…): the same files as variant windows-x86_64, signed "yayguru", `lgx verify` OK. Its layout matches 0.2.0, and the packaged Main.qml is byte-identical to the repo.
  - The module is unchanged for Windows; Linux `vesting_module-0.3.0-linux.lgx` uses the same CLI.
- Laptop (Windows 10 laptop, 1366x768 @96 DPI): installed via Package Manager → Install Local Package → **Upgrade** (never Trust). Settings → About shows `Vesting 0.3.0 (2026-11-21) · RFP-017 prototype for LEZ 0.4`. A walk through Home and Create steps 1–4 (1,000 LGO from Account 2 to Account 1, 1-year preset) at the real window size showed the action bar on every step. The vest was not submitted. Node pid on :8080 and Basecamp pid are unchanged.
