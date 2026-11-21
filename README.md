# Privacy-preserving token vesting on LEZ 0.4 (RFP-017)

A vesting program for the Logos Execution Zone (LEZ) 0.4 actor model. It supports:
- cliff + linear, fully linear and milestone schedules;
- a cancelable flag, with a one-way switch to non-cancelable;
- positions whose transferability is fixed at creation;
- batch creation;
- one event per state transition;
- claims to a **public account, or to a private (shielded) account**, where the creator never learns the private account.

What is in the repo:

| Path | What |
|---|---|
| `core/` | `vesting_core`: schedule types, vesting math, PDA derivation, messages, events, error codes (SDK for Rust callers) |
| `methods/` | the RISC Zero guest (the on-chain program) and its build |
| `cli/` | `vesting` CLI on top of the LEZ 0.4 wallet (keys and proving stay in the wallet) |
| `logos/vesting_module` | Logos core module (SDK for Logos modules), drives the CLI |
| `logos/vesting_ui` | Basecamp mini-app (QML) |
| `idl/` | SPEL IDL `vesting.spel.json` (+ generator) |
| `tests/` | state-machine tests on the real guest; cost measurements |
| `e2e/run_e2e.sh` | end-to-end run against a standalone LEZ sequencer |
| `docs/REQUIREMENTS.md` | every RFP hard requirement → its tests |

Target: **LEZ `v0.4.0-rc3`** (file `LEZ_TAG`; see [Updating LEZ](#updating-lez)).

## Downloads

Prebuilt Basecamp packages are on the [v0.3.0 release](https://github.com/yayguru/lez-vesting/releases/tag/v0.3.0):
`vesting_module` (Linux), `vesting_ui` (Linux) and `vesting_ui` (Windows; signed, install with **Install/Upgrade**, no need to trust the signer). Each asset has its sha256 in the release notes.

## Platforms

| Platform | Status |
|---|---|
| Linux x86_64 (Ubuntu 24.04, Debian 13) | Native. Build, tests, e2e and real proofs all tested; CI runs here. |
| Windows 10/11 | Through WSL2 (Ubuntu 24.04). The sequencer, wallet and CLI run inside WSL. Basecamp on Windows installs the module and mini-app `.lgx`, and the module calls the CLI through `wsl.exe` (Settings → backend `wsl`). Tested end to end (`e2e/RESULTS.md`). Basecamp on Windows is an unofficial build (credit: OPDE). |
| macOS | **Untested.** The Rust parts should build (RISC Zero supports macOS), but no run has been done. |

## Requirements

| | |
|---|---|
| OS | Linux x86_64 with glibc ≥ 2.39 for binaries built on Ubuntu 24.04 (build from source on older systems) |
| Rust | 1.98.1 (pinned in `rust-toolchain.toml`, picked up by rustup) |
| RISC Zero | `rzup`, guest toolchain (`rzup install rust`), `cargo-risczero` and `r0vm` **3.0.x** (tested 3.0.6; the crate is risc0-zkvm 3.0.5) |
| System packages | `build-essential clang libclang-dev pkg-config libssl-dev libpcsclite-dev git curl unzip python3 time` |
| Disk | ~30 GB for the LEZ + RISC Zero build |
| RAM | Builds: 8 GB. Real private proofs: **~9.5 GB peak** (r0vm), so 12 GB+ recommended; see [Proving cost](#proving-cost-real-proofs). With less RAM (e.g. a 2 GB WSL VM), use dev-mode proofs. |
| Mini-app | Nix ≥ 2.26 (flakes) and Logos Basecamp 0.4 |

On Debian/Ubuntu, one script installs everything:

```sh
scripts/install-deps.sh
export PATH=$HOME/.cargo/bin:$HOME/.risc0/bin:$PATH
```

## Build and test

```sh
cargo build --release -p vesting_cli            # target/release/vesting (embeds the guest ELF)
RISC0_DEV_MODE=1 cargo test --workspace         # unit + state-machine tests (dev profile only:
                                                # LEZ test-utils refuses release builds)
e2e/run_e2e.sh                                  # e2e on a standalone sequencer (dev-mode proofs)
E2E_REAL_PROOFS=1 e2e/run_e2e.sh                # the same with real proofs
scripts/ci.sh                                   # all of the above, as CI runs it
```

`e2e/run_e2e.sh` does the following:
1. Clones LEZ at the pinned tag into `.lez/`.
2. Builds the standalone sequencer (mock Bedrock) and the wallet.
3. Starts the sequencer on `127.0.0.1:$E2E_PORT` (default 3040; metrics on port+1).
4. Imports the public local-devnet genesis keys, deploys the program, then exercises every operation and the error paths.
5. Writes `e2e/out/costs_<dev|real>.json`.

No key material is printed.

## Deploy to a standalone sequencer (manual)

```sh
# 1. LEZ sequencer + wallet at the pinned tag
git clone --depth 1 --branch "$(cat LEZ_TAG)" https://github.com/logos-blockchain/logos-execution-zone .lez/lez
(cd .lez/lez && cargo build --release -p sequencer_service --features sequencer_service/standalone -p wallet)
export PATH=$PWD/.lez/lez/target/release:$PATH
sequencer_service setup ./seq --config .lez/lez/lez/sequencer/service/networks/local.json \
  --funding-public-key 2e03b2eff5a45478e7e79668d2a146cf2c5c7925bce927f2b1c67f2ab4fc0d26 --create-channel
RISC0_DEV_MODE=1 sequencer_service start ./seq --rpc-listen-address 127.0.0.1:3040 &   # drop RISC0_DEV_MODE for real proofs

# 2. Wallet (LEE_WALLET_HOME_DIR holds the keys; keep it private)
export LEE_WALLET_HOME_DIR=$PWD/wallet
mkdir -p "$LEE_WALLET_HOME_DIR"
echo '{"sequencer":{"sequencer_addr":"http://127.0.0.1:3040"}}' > "$LEE_WALLET_HOME_DIR/wallet_config.json"
#    fund a public account; on a local devnet, import the genesis keys as e2e/run_e2e.sh does

# 3. Deploy: the ELF is ~350 KB, so the program loader splits it over 4 segment accounts (96 KiB each)
vesting write-elf vesting.bin
wallet account new public      # header account = the program address; repeat 4x for segments
wallet program-loader deploy --elf vesting.bin --header Public/<HEADER> \
  --segments Public/<S1> Public/<S2> Public/<S3> Public/<S4> --payer Public/<FUNDED>
export VESTING_PROGRAM=<HEADER>
```

**Program address.**
- On LEZ the program address is the header account you deploy to, so every deployment gets its own. Pass it with `--program` or `VESTING_PROGRAM`, or set it in the mini-app's Settings.
- The program code is identified by its image id (`vesting image-id`). The guest is built locally, so the id depends on the build environment: the box build gives `fd0135f0…c28f`, and a clean `ubuntu:24.04` container gives `1fdab914…496d`. Build with `RISC0_USE_DOCKER=1` for a reproducible id. A deployment is checked against the ELF you deployed, so a different local id is harmless.
- Known deployments (all local test chains): Windows/WSL test chain `GaDvygRPGyyBpGz9TZiXXYURd1GoE4KpfCPCEF1Yqs2w` (see `e2e/RESULTS.md`). The e2e script prints the address of each run.

**Public testnet.**
- LEZ testnet 0.4 is not live yet: the public testnet (`https://testnet.lez.logos.co`) runs v0.3.2, and docs.logos.co lists the 0.4 endpoints as "TBD".
- Once it is live, deploying there takes the same step 3 with the following:
  - `sequencer_addr` set to the testnet RPC;
  - a public account funded from the testnet faucet as payer;
  - the resulting header id published here.

## CLI

All commands take `--json` for one machine-readable object. Times are unix ms. Amounts are integers in the token's base unit (native LGO units: 1 LGO = 10^9; the mini-app shows LGO). Ids are 64 hex chars; one is generated at random if `--id` is omitted.

```sh
vesting accounts                                            # public signers + owned private accounts + network {url, kind: local|testnet|other}
# create (escrows `total` from the creator's public balance); cancelable by default
vesting create --creator <PUB> --beneficiary <PUB> --total 1000000 --linear <start>,<cliff>,<end> [--transferable] [--non-cancelable]
vesting create --creator <PUB> --beneficiary <PUB> --total 1000000 --milestones 400000,600000
vesting create-batch --creator <PUB> --file batch.json      # many schedules, one tx (format below)
vesting show --creator <PUB> --id <ID>                      # vested, claimed, claimable now, locked, next unlock
vesting list                                                # finds vestings to/from your accounts on chain by itself (scans new blocks; `scan` in the JSON)
vesting track --creator <PUB> --id <ID>                     # fallback: add one by its code
vesting claim --beneficiary <PUB> --creator <PUB> --id <ID> --dry-run     # pre-claim summary + fee
vesting claim --beneficiary <PUB> --creator <PUB> --id <ID>               # to the beneficiary's public account
vesting claim --beneficiary <PUB> --creator <PUB> --id <ID> --private <PRIV>   # to a private account
vesting receive                                             # pull private payouts into the private account
vesting signal --creator <PUB> --id <ID> --index 0          # milestone authority = creator
vesting cancel --creator <PUB> --id <ID>                    # unvested back to the creator
vesting irrevocable --creator <PUB> --id <ID>               # one-way: no longer cancelable
vesting transfer-beneficiary --beneficiary <PUB> --creator <PUB> --id <ID> --new-beneficiary <PUB>
vesting txs --from 1 --to 50                                # tx hashes per block (audit)
```

How each claim path works:
- **Public claim:** the beneficiary signs and pays the fee.
- **Private claim:**
  - The beneficiary signs inside a privacy-preserving transaction. The payout goes to a fresh blinded alias that only the beneficiary's private key can receive.
  - `vesting receive` moves the payout into the private account.
  - The private account pays the private fee reserve, and the unused part is refunded. `receive` skips fee-refund messages.
  - `--private` must be a private account of this wallet, otherwise **V023**.

Batch file (`create-batch --file`, or the same JSON hex-encoded with `--entries-hex`):

```json
[{"beneficiary": "<PUB>", "total": "1000", "linear": [start, cliff, end]},
 {"beneficiary": "<PUB>", "total": "30", "milestones": ["10", "20"], "cancelable": false, "transferable": true, "id": "<64 hex>"}]
```

The batch is all-or-nothing. **Maximum: 360 single-linear entries per transaction.**
- The limit comes from execution gas (`MAX_GAS_EXEC` = 10M cycles), at ~27.7k cycles per entry. The tx size (85 KB at 360 entries) is far below the limit.
- Milestone entries cost more, so mixed batches fit fewer.
- 361 or more entries are refused with **V024** before sending; split them.
- `create-batch` raises the wallet's simulation budget to 10M. Plain wallet calls would stop at ~71 entries (default `gas_limit` 2M).

## Mini-app (Basecamp)

The module bundles the CLI and calls it. The mini-app is QML only, designed the Uniswap way: one obvious action per screen, plain words, sensible defaults, technical detail behind *Show details* and *Settings → Advanced*, and a review before anything is signed. Design notes: [docs/UX_REDESIGN.md](docs/UX_REDESIGN.md).

Version 0.3.0 is built like a product: every amount is in **LGO** (1 LGO = 10^9 native units). A local test network gives its two dev accounts 10,000 and 20,000 test LGO, which 0.1.0 showed as "10,000,000,000,000". The version is in Settings → About.

Where vested LGO are: every vesting has **its own account**, a PDA of the vesting program (`sha256("rfp017/vesting/schedule" || creator || id)`). Create moves the total from the creator into that account's balance. Nobody holds a key to it. Only the program moves the LGO: unlocked parts to the recipient on **Claim**, the not-yet-vested rest back to the creator on **Stop**. The app shows this as **Your wallet → Vesting account (held by the vesting program) → Recipient**. Details: [docs/UX_REDESIGN.md §0b](docs/UX_REDESIGN.md).

Screens. Header: **Vesting**, network pill, **How it works**, **+ Vest tokens** (always visible; **Vest** on narrow windows), gear ⚙.
- **Home**:
  - on a local test network, once: **Where did these LGO come from?** ("These 30,000 LGO are free test tokens your local test network created for 2 demo accounts…"). It stays reachable from the wallet card and the network pill;
  - **Your wallet**: every funded account as a row (number, name, short address, balance, in-use radio). Empty accounts sit under **Show N empty accounts**. The account in use has **Rename** (kept on this computer), the full address with **Copy address**, its balance, the private balance with **Check for private payments**, and **Vest tokens** / **Receive** / **Add LGO**;
  - **Where your LGO are**: money-flow diagrams *Your wallet → Locked in vestings (vesting accounts held by the vesting program) → Recipients* and *From → Locked for you → Your wallet*, with locked / unlocked / claimed amounts;
  - **Coming to you**: summary (ready now, still locked, claimed, **next unlock with exact date and a live countdown**) and one card per vesting (*From … → vesting account … → your Account N*) with **Claim N LGO** / **Details**. Vestings are **found on chain automatically**; **Have a vesting code?** is a fallback;
  - **Created by you**: one card per vesting with status pills and **Manage ›**.
- **Vest tokens**: a 4-step stepper with a pinned action bar (**Back** / **Continue** / **Vest N LGO**) that never scrolls away:
  - **1 Who**: *Paying from* (account rows with balances) and *Sending to*: **My other account** (one click) or **Someone else** (paste field checked as you type), plus one line on public vs private accounts;
  - **2 How much**: amount in LGO, *Available*, **25% / 50% / Max**, and what stays in the account;
  - **3 Schedule**: presets (*1 year · first unlock after 3 months*, *4 years · first unlock after 1 year*, *6 months · starts now*, *When I confirm milestones*, *Custom*), a plain sentence and a chart, and *More options*;
  - **4 Review**: the amount, the money flow *From → New vesting account → To*, the sentence and the chart.
  The button always says what is missing ("Pick the account that receives it", "Enter an amount", "Not enough LGO in Account 1"…). After **Vest**: *Where your LGO are now* (flow with the new vesting account's address), *What the recipient sees*, and, when the recipient is your own account, **See what Account N sees** (opens the vesting as the recipient with **Claim**).
- **Vesting page**: the money flow with this vesting's own account and balance, **Claim** right under the amount (recipient), a **Next unlock** box (exact date and time, countdown), the unlock chart, and Unlocked / Claimed / Still locked. When both ends are your accounts, a **View as: Sender / Recipient** switch. The sender gets milestone **Confirm**, **Stop vesting** and **Make permanent**; the recipient of a transferable vesting gets **Give to another account**. *Show details* has the raw ids, including the vesting account.
- Every term (vesting, vesting account, unlock, claim, cliff, milestones, stop, permanent, public/private account, network cost…) has a **?** with one line; **How it works** lists them all.
- **Claim** sheet: amount, To, network cost and who pays it, and **Receive privately** (with "What others can see"). A private claim runs as *Step 1 of 2 Claim · Step 2 of 2 Move to private balance*.
- **Send to many people** (batch): `address, amount-in-LGO` lines (or JSON), one schedule for everyone, up to 360 per transaction, then review.
- **Settings** (gear): connection status; *Advanced*: program address, wallet folder, CLI path, this computer or WSL, fast test proofs, private account; **About**.
- Every V0xx error becomes a plain title and a next step, with the raw text under *Show details* and **Try again**.

Checks (in `logos/vesting_ui`):
- `tests/render/render.sh <outdir>`: renders all 56 screens/states (loading, setup, errors, first run, home, every Vest tokens step, success, claim states, vesting pages for sender / recipient / both, sheets, bulk, settings + About, code entry), many of them at the laptop's real Basecamp size (1260x655) and at 1024x700, 1280x720 and 440 px wide, headlessly with a mock module (LGO-scale balances), fails on any QML warning, and checks that the version in Main.qml matches metadata.json. Needs Qt 6 `qml` (`QML_BIN`, with `QML_IMPORT_PATH`).
- `node tests/ui-tests.mjs --ci ./result-dev/bin/run-logos-standalone-ui`: the real module + UI load in the standalone host.
- `E2E_UI=1 e2e/run_e2e.sh` (repo root): after the CLI e2e, `tests/ui-e2e.mjs` clicks through the real app (real module, real CLI) on the same live chain, 10 flows: Settings → Save (the app starts from an empty list and must find every vesting on chain by itself; balance must read in LGO); Vest tokens: 1 Who (Paying from row, My other account) → 2 How much (LGO) → 3 Schedule → 4 Review → **Vest**, then **See what Account N sees** opens the recipient side with Claim; Claim; Milestones vesting (recipient pasted under Someone else) → Confirm milestone 1 (Created by you → Manage); Receive privately (claim + move to private balance, with the privacy disclosure); Check for private payments; Give to another account; Make permanent; Stop vesting; Send to many people (batch). `UI_E2E_SHOTS=<dir>` saves a screenshot of each step.

Build (Linux, from inside this git checkout; Nix fetches logos-module-builder):

```sh
cargo build --release -p vesting_cli && cp target/release/vesting logos/vesting_module/bin/
cd logos/vesting_module && nix build .#lgx -o result-lgx && cd -    # logos-vesting_module-module-lib.lgx
cd logos/vesting_ui     && nix build .#lgx -o result-lgx && cd -    # logos-vesting_ui-module.lgx
```

Run `nix build` inside the git checkout, as `.#lgx`. Don't use `path:$PWD`: the UI flake refers to `../vesting_module` and needs the whole repo. Straight from the repo:

```sh
nix build "git+https://github.com/<owner>/<repo>?dir=logos/vesting_ui#lgx"
```

Install in Basecamp:
1. Open Package Manager → **Install Local Package**.
2. Pick the module `.lgx`, then the UI `.lgx`, and choose **Install**.
3. Open *Vesting*. Press ⚙ → *Advanced*, set the program address and the wallet folder (the `LEE_WALLET_HOME_DIR` above), then **Save**.

For a quick look without Basecamp, run `nix build .#ui-dev -o result-dev && ./result-dev/bin/run-logos-standalone-ui` in `logos/vesting_ui`.

Windows:
- Run the sequencer, wallet and CLI in WSL (`e2e/windows/wsl_setup.sh`, `wsl_chain.sh`, `wsl_deploy.sh`).
- Memory: with dev-mode proofs, the default WSL limit is fine. For **real proofs**, set `memory=10GB` or more under `[wsl2]` in `%UserProfile%\.wslconfig`, or add swap. With `memory=2GB`, r0vm is OOM-killed.
- Install the Windows `.lgx` builds of the two modules in Basecamp. The module defaults to backend `wsl` when it has no native `vesting.exe`.
- The bundled Linux CLI needs glibc ≥ the build machine's, so build it on Ubuntu 24.04 (glibc 2.39) or older for portability.

### Module API (SDK for Logos modules)

| Method | What it does |
|---|---|
| `getConfig`, `setConfig(json)` | Read or change the module settings. |
| `accounts` | Lists the wallet's accounts. |
| `listSchedules` | Lists the schedules this wallet created or tracks. |
| `show(creator,id)`, `track(creator,id)` | Read one schedule; remember it in this wallet's list. |
| `quoteClaim(beneficiary,creator,id,privateAccount)` | Pre-claim summary. Sends nothing. |
| `create(creator,beneficiary,total,kind,values,cancelable,transferable)` | Sending call: one new schedule. |
| `createBatch(creator,entriesJson)` | Sending call: many schedules in one tx. |
| `claim(beneficiary,creator,id,privateAccount)` | Sending call. An empty `privateAccount` means a public claim. |
| `receivePending()` | Sending call: pulls private payouts in. |
| `cancel(creator,id)` | Sending call. |
| `signalMilestone(creator,id,index)` | Sending call. |
| `makeIrrevocable(creator,id)` | Sending call: one-way switch to non-cancelable. |
| `transferBeneficiary(beneficiary,creator,id,newBeneficiary)` | Sending call. |
| `jobResult(job)` | Poll for a sending call's result. |

Sending calls return `{"ok":true,"pending":true,"job":"N"}` at once; poll `jobResult(N)`. Details: `logos/README.md`.

## Events (LP-0012 style)

Each event is a `ProgramEvent { selector, data }`:
- `selector` = the first 8 bytes of `sha256(name)`;
- `data` = the borsh encoding of `vesting_core::Event`.

| Name | Fields |
|---|---|
| `vesting::Created` | `schedule, creator, beneficiary: AccountId, total: u128` (one per batch entry) |
| `vesting::Claimed` | `schedule: AccountId, amount: u128, now: u64` |
| `vesting::Cancelled` | `schedule: AccountId, returned: u128, vested: u128, at: u64` |
| `vesting::MilestoneSignalled` | `schedule: AccountId, index: u8, amount: u128` |
| `vesting::MadeIrrevocable` | `schedule: AccountId` |
| `vesting::BeneficiaryTransferred` | `schedule, from, to: AccountId` |

A private claim's `Claimed` event names the schedule and the amount, not the private account.

## Costs

The program charges no fee of its own; only LEZ gas is paid:
- execution gas = guest cycles;
- storage gas = tx wire bytes.

Who pays:
- The creator pays for create, cancel, signal and make-irrevocable.
- The beneficiary pays for a public claim and for a transfer.
- On a private claim, the private account pays (flat private verify gas plus a refundable reserve).

The table below was measured by `tests/tests/costs.rs` in the LEZ 0.4 metered state machine, with the real guest:

| Operation | Cycles | Wire bytes |
|---|---:|---:|
| create (cliff+linear) | 36,003 | 637 |
| create (2 milestones) | 36,419 | 649 |
| claim, public | 38,767 | 630 |
| cancel | 36,633 | 566 |
| signal milestone | 33,325 | 431 |
| transfer beneficiary | 35,221 | 494 |
| make non-cancelable | 33,204 | 430 |
| create batch ×10 | 285,004 | 2,752 |
| create batch ×360 (max) | 9,997,678 | 85,002 |

Notes on the table:
- **Batch:** each extra entry costs +27,666 cycles and +235 bytes.
- **Private claim:** the same program cycles as a public claim, plus LEZ's flat `PRIVATE_VERIFY_GAS` (409,764) and private storage gas.
- **Live sequencer:** `e2e/run_e2e.sh` repeats the measurements and writes the cycles, bytes and fee estimates to `e2e/out/costs_*.json`.
- **Not measured on testnet 0.4:** that testnet is not live yet.

### Proving cost (real proofs)

Measured on the box (8 vCPU, 16 GB RAM, Debian 13; r0vm 3.0.6, CPU prover, no GPU) with
`E2E_REAL_PROOFS=1 e2e/run_e2e.sh`. Details are in `e2e/RESULTS.md`.

| Client step (private tx) | Wall time | Peak RAM |
|---|---:|---:|
| shield (fund a private account) | ~24 min | ~9.6 GB |
| private claim | 42 min | 9.4 GB |
| receive payout | 34 min | 9.4 GB |

- Public transactions (create, public claim, cancel, signal, transfer, irrevocable, batch) need
  no client-side proof. They take seconds.
- Plan for **about 10 GB of free RAM or swap** (12 GB+ machine recommended) for real private proofs. On smaller machines (e.g.
  a WSL VM with 2 GB), r0vm is OOM-killed: use dev-mode proofs (`RISC0_DEV_MODE=1` on both the
  sequencer and the client) for local testing.
- A GPU prover (CUDA) should be far faster but is untested.

## Error codes

| Code | Meaning |
|---|---|
| V001 | total must be > 0 |
| V002 | times must satisfy start ≤ cliff ≤ end and start < end |
| V003 | milestones must be 1–64 non-zero tranches summing to total |
| V004 | the caller did not sign |
| V005 | internal op not from this program |
| V006 | wrong schedule PDA |
| V007 | the schedule already exists |
| V008 | no schedule at this account |
| V009 | only the beneficiary can do this |
| V010 | only the creator can do this |
| V011 | nothing claimable yet, with the **next unlock** (time, or "when the creator signals milestone #i") |
| V012 | not cancelable |
| V013 | already cancelled |
| V014 | milestone index out of range |
| V015 | milestone already signalled |
| V016 | not a milestone schedule |
| V017 | not transferable |
| V018 | arithmetic overflow |
| V019 | empty batch |
| V020 | the fee payer cannot cover the fee (fund it first) |
| V021 | not included in time (refused at settlement; refresh and retry) |
| V022 | module busy |
| V023 | the private claim target is not a private account of this wallet |
| V024 | the batch exceeds the per-tx maximum |

V001–V019 come from the program (and the IDL). V020–V024 come from the CLI and the module, before or after sending.

## Updating LEZ

The LEZ version is set in one place: the file `LEZ_TAG`. `Cargo.toml` pins the same tag between the `LEZ pin` markers, and the script keeps the two in sync:

```sh
scripts/set-lez-tag.sh v0.4.0        # writes LEZ_TAG, rewrites the Cargo.toml pin, updates Cargo.lock
RISC0_DEV_MODE=1 cargo test --workspace && e2e/run_e2e.sh
scripts/set-lez-tag.sh --check       # CI: fails if LEZ_TAG and Cargo.toml disagree
```

CI (`.github/workflows/ci.yml`) has two jobs:
- `pinned`: build, tests and e2e at `LEZ_TAG`. It must be green.
- `lez-latest`: a non-blocking canary. Daily and on every push, it runs the same steps against the newest `v0.4.x` tag of logos-blockchain/logos-execution-zone, so a new release such as the final 0.4.0 shows up at once.

Only LEZ 0.4 is supported: the program uses the 0.4 actor model, and 0.3 is not supported.

## License

MIT or Apache-2.0.

Maintainer: OPDE.
