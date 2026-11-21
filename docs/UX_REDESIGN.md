# Mini-app UX redesign

The first mini-app had four tabs: **Receiving**, **Created**, **New schedule** and **Settings**. They mirrored the program's API, not what a person wants to do. Problems:
- you had to "track" a schedule by typing a creator account and a 64-character id;
- times were entered as "minutes from now";
- milestones were a comma-separated list;
- batch create was a raw JSON box;
- the private claim needed a separate "Receive private payouts" step that nobody would guess.

This document gives the redesigned flows, every user-visible string, and how the RFP usability requirements are met. Reference products: Uniswap (its open-source interface, `github.com/Uniswap/interface`) for the interaction model, and Sablier for the vesting-specific parts.

## 0. Version 0.2.0: wallet first

Feedback on 0.1.0 from the first person who tried it on Windows: "I don't understand when I can claim, why I have trillions of tokens, where the tokens come from or how to deposit. I have a wallet, I want to vest." Four causes, four fixes:

| What confused | Cause | Fix in 0.2.0 |
|---|---|---|
| "Trillions of tokens" | Amounts were shown in raw native units. A local test network gives its two dev accounts 10,000,000,000,000 and 20,000,000,000,000 units, i.e. 10,000 and 20,000 LGO (1 LGO = 10^9 units, LEZ `testnet_initial_state`). | Every amount is in **LGO** with up to 9 decimals. Amount fields take LGO (`1500`, `12.5`, `0,5`). A **Test network · free test LGO** pill plus banner says these tokens have no value. |
| "Where do the tokens come from? How do I deposit?" | The app never showed the wallet itself. | A **wallet card** at the top of Home: account, full address with **Copy address**, balance in LGO, **Receive** and **Add LGO**. **Add LGO** explains, for the network you're on: local test network = free test LGO from setup, plus how to give some to another address; Logos testnet / real network = Basecamp → Logos Blockchain app → Wallet → **Channel Deposit** (Unofficial Windows build: **LEZ Bridge**) with this address as Metadata, credited after the deposit is final (about an hour on the testnet), public accounts only. There is no faucet. |
| "When can I claim?" | Next unlock was a short relative line. | Home has a summary (ready now / still locked / claimed) and **Next unlock** with the exact date and time and a live **countdown**. Every card repeats it; the detail page has a big **Next unlock** box with countdown and "Times are in this computer's time zone." |
| "Receiving / Created / schedule / milestones / codes" | API words and a code you had to paste. | One **Home**: wallet, **Coming to you**, **Created by you**. Vestings to your address are found on chain by themselves (the CLI scans blocks), so the code is only a fallback behind **Have a vesting code?**. Every term has a **?** with one line, and **How it works** lists them all. First run shows a 3-step **Welcome**. |

Version and build date are in **Settings → About** (`Vesting 0.2.0 (2026-11-21)`), and `render.sh` checks they match `metadata.json`.

## 0a. Version 0.3.0: vest like a product

The owner tried 0.2.0 on the laptop (Basecamp maximized, 1366x768, 96 DPI, so the app gets about 1260x655 px). What went wrong:
- **"No button to VEST, part of the UI is hidden."** The create form was one long page. Its only button (**Review**) sat about 600 px below the fold, and Basecamp's scroll bar is invisible until you scroll. He typed 1000 LGO for his second account and could not find a way to finish.
- **"Can't we vest on some special account for vesting?"** That is exactly what happens, but no screen said so. See §0b for how the program holds the funds.
- **"How do we have 30k LGO between 2 wallets?"** The note about test LGO was buried in **Add LGO**.
- **"Account selection is bad."** The wallet has 8 public accounts, 6 of them empty. The form showed 7 identical chips ("Account 3 (2koD…YS2y)") with no balances, and the From account changed with a **Change** link that just cycled through them.

Design pass. Sablier (create stream: a stepper of *token and amount → recipient → shape with a curve preview → review*; the stream page shows sender → stream → recipient with streamed, withdrawn and remaining amounts) and Uniswap (one primary button whose label is the validation message, pinned at the bottom of the card; a token or account picker as a list with balances). Applied:

| Problem | 0.3.0 |
|---|---|
| Hidden button | **Vest tokens** is always in the header (compact **Vest** on narrow windows) and on the Home wallet card. Create is a 4-step stepper: **1 Who · 2 How much · 3 Schedule · 4 Review**. Its **Back / Continue / Vest 1,000 LGO** bar is pinned below the scrolling area, so it is never clipped. Every page scrolls with an always-visible scroll bar. Checked at 1260x655 (laptop), 1280x720, 1024x700 and 440 px wide. |
| Where the locked LGO live | A **money-flow** diagram: **Your wallet → Locked in vesting (vesting account, short address, held by the vesting program) → Recipient**, with locked, unlocked and claimed amounts. It appears on Home (all your vestings), on every vesting's page (with that vesting's own account address and balance), in Review, and on the success screen ("Where your LGO are now"). |
| 30,000 test LGO | A one-time card on Home and a **Where did these LGO come from?** link on the wallet card that is always there: "These 30,000 LGO are free test tokens your local test network created for 2 demo accounts when it started. On the real network you bring your own LGO from your Logos wallet." |
| Account selection | Accounts have names (**Account 1**, …; rename from Home, stored on this computer). Every account picker is a list of rows: name, short address, balance. Empty accounts are collapsed under **Show N empty accounts**. Create asks **Paying from** (a list with balances) and **Sending to**: **My other account** (one click) or **Someone else**, a paste field that checks the address as you type. One line explains public vs private. |
| Seeing the recipient side | When the recipient is one of your own accounts: the success screen has **See what Account 2 sees** (opens the vesting as the recipient, with **Claim**), and the vesting page has a **View as: Sender / Recipient** switch. |

## 0b. Where vested tokens are held (checked against the program)

`methods/guest/src/bin/vesting.rs` and `core/src/lib.rs`:
- **Create:** every vesting gets its **own account**, a PDA (program-derived address) of the vesting program: `schedule_account = AccountId::for_public_pda(program, sha256("rfp017/vesting/schedule" || creator || id))`. In one transaction the program initialises that account with the schedule (its actor state) and moves `total` from the creator's public balance into the **native balance of that same account**. That balance is the escrow; the CLI and UI show it as `schedule` / `escrow`.
- No person holds a key for it. Only the vesting program can move the LGO, through `custody_transfer` signed with the PDA seed, and only:
  - (a) on **Claim** by the current beneficiary, for the amount unlocked so far, to the `to` account the beneficiary names (one of theirs, or a one-time private alias);
  - (b) on **Stop** by the creator, returning what has not vested yet to the creator. The vested part stays in the vesting account until the recipient claims it.
- Nothing is sent to the recipient's account at creation. **Give to another account** only changes who may claim, not where the LGO are.

## 1. What we took from Uniswap and Sablier

Read from the Uniswap interface source:
- the swap form: `SwapFormButton/useSwapFormButtonText.ts`;
- the review screen: `swap/review/SwapReviewScreen/*`;
- settings: `components/settings/*`;
- wording: `i18n/locales/source/en-US.json`.

| Uniswap pattern | Where it is in Uniswap | What we do |
|---|---|---|
| One card, one action. The swap card has a single primary button. | `SwapForm`, `SwapFormButton` | Each screen has exactly one filled (primary) button: **Claim**, **Review**, **Create vesting**. |
| The button label is the validation message: "Select a token", "Enter an amount", "Not enough ETH", then "Review". | `useSwapFormButtonText.ts` | The create form's button reads **Enter recipient** → **Enter an amount** → **Not enough balance** → **Review**. There are no separate red error lines for empty fields. |
| Review before signing. "You're swapping" shows big amounts, a few detail rows, one confirm button, and "Show more" for the rest. | `SwapReviewScreen`, `TransactionAmountsReview`, `SwapDetails` | **Review claim** and **Review vesting** sheets. Big amount, plain rows (To, Network cost, Paid from), and one button. Technical rows sit under **Show details**. |
| Pending in the button: "Confirm in wallet", "Submitting swap…", "Keep your wallet open…". Multi-step trades show "Step 1 of 2". | `SubmitSwapButton`, `ProgressIndicator`, `swap.review.stepXofN` | **Claiming…** with a spinner, elapsed time and one honest sentence on why it takes long. A private claim shows **Step 1 of 2 · Claiming** and **Step 2 of 2 · Moving to your private balance**. |
| Clear success: "Swap success!", "Swapped X for Y", "View on Explorer". | `swap.success`, `notification.transaction.swap.success` | **Claimed!**, **12,500 tokens are now in your account.**, then **Done**. Block and transaction details sit under **Show details**. |
| Error screen with a title, a human message, **Try again**, and **Get help**. Raw error hidden. | `SwapErrorScreen`, `getErrorContent` | Every V0xx code maps to a title, a sentence and an action (table §5). The raw text is under **Show details**. |
| Settings behind a gear. Defaults are "Auto"; experts change slippage and deadline. Each row has a one-line tooltip. | `TransactionSettingsModal`, `swap.settings.*` | A gear opens **Settings**. The basic part is connection status only. **Advanced** holds the program address, wallet folder, CLI path, WSL backend and dev proofs, each with a one-line hint. |
| Empty states that invite the next step: "No positions. Create a new position…", "No activity yet". | `positions.noPositions.*`, `home.activity.empty.*` | **Nothing to claim yet** plus a field for the code you were sent. **You haven't created any vestings** plus a **Create vesting** button. |
| Positions list → position detail with per-position actions. | `pool.positions.*` | **Created by you** list → vesting detail. Stop, make permanent, confirm milestone and copy code live in the detail view, not on every card. |
| Network cost is one row with a tooltip, and a warning when it is very high. | `transaction.networkCost.*` | One **Network cost** row. If the cost exceeds the amount: **The network cost is higher than what you'd claim. Consider waiting until more unlocks.** |

From Sablier, which solves this exact problem:
- **Named shapes instead of parameters:** Sablier offers "Linear", "Cliff-Linear", "Unlock Monthly" and more. We use presets: **1 year · first unlock after 3 months**, **4 years · first unlock after 1 year**, **6 months · starts now**, **When I confirm milestones**, **Custom**.
- **A progress visual and a simulation before creating:** we show a progress bar on every card and an unlock chart in the create form.
- **CSV for bulk:** our bulk create takes `account, amount` lines, not JSON (raw JSON stays under Advanced).
- **Permissions vocabulary:**
  - "Cancel" becomes **Stop vesting**;
  - "Renounce cancelability" becomes **Make permanent**;
  - "Transfer" becomes **Give to another account**.
- **A stream is identified by a shareable link:** ours is a **vesting code** the creator copies and sends.

Streamflow and Hedgey use the same structure: recipient, amount, a duration and cliff picker, plus "who can cancel / transfer" toggles.

What the program cannot do, and so the UI does not pretend:
- **No pause:** only stop, which is final.
- **No step-wise monthly unlock:** linear vesting is continuous, so the copy says "unlocks gradually".
- **No indexer:** the CLI finds vestings for your accounts by scanning blocks itself (`list` scans from where it stopped; first run scans the whole chain). The vesting code stays as a fallback.

## 2. Journeys

**Recipient: "I have a wallet; what do I get, and when?"**
1. Open Vesting. Home shows your account and balance in LGO. Vestings to your address appear under **Coming to you** by themselves (a line says "Looking for vestings sent to you…" until the first scan is done).
2. The summary says how much is **ready to claim now**, what is **still locked**, and the **next unlock** with the exact date and time and a countdown.
3. Press **Claim N LGO**. The **Review claim** sheet shows the amount, where it goes, the network cost and who pays it, and a **Receive privately** switch (privacy disclosure, time and memory note).
4. Press **Claim** or **Claim privately**: pending, then **Claimed!**, or an error with a fix.

**Creator: "lock LGO for someone"**
1. Press **+ Create vesting**. Pick the recipient (or one of your other accounts), an amount in LGO, and how it unlocks. A sentence and a chart say exactly what happens.
2. **Review** → **Create vesting** → **Vesting created**. Nothing to send: the recipient sees it in their app.
3. Later, under **Created by you** → **Manage**: confirm a milestone, stop the vesting, or make it permanent.

**Newcomer: "where do my LGO come from?"**
1. Home → wallet card → **Add LGO**: what this network is, where the balance came from, and how to bring LGO here (Channel Deposit / LEZ Bridge with this address in Metadata).
2. **Receive**: the full address with **Copy address**, safe to share.

## 3. Screen map

```
Header: Vesting [network pill]          How it works   [+ Create vesting]   [⚙]
├─ Home
│   ├─ test-network banner (local / testnet)
│   ├─ Welcome (first run, no vestings yet): 3 steps, Got it, Words used here
│   ├─ Wallet card: Your account N of M (Switch account), address + Copy address,
│   │   balance in LGO (+ "no LGO yet" note), private balance + Check for private payments,
│   │   [Receive] [Add LGO]
│   ├─ Coming to you: summary (ready now / still locked / claimed, next unlock + countdown),
│   │   cards → [Claim N LGO] [Details]; empty: "Nothing coming to you yet" + your address
│   │   scan status ("Checked the whole network…") + Have a vesting code? (fallback field)
│   └─ Created by you: cards → Manage ›; empty: "You haven't created a vesting yet"
├─ Detail (recipient): amount ready, Next unlock box (exact time + countdown), chart, stats,
│   [Claim], Give to another account, Show details (dates, accounts, vesting code + Copy)
├─ Detail (creator): total, Next unlock, chart, stats, milestones [Confirm], Manage
│   (Stop vesting / Make permanent), Show details
├─ Create a vesting: From (Change), To (+ my other accounts), Amount in LGO (Use all),
│   How it unlocks (presets, custom, milestones), preview + chart, More options, [Review]
│   └─ Send to many people: "address, amount" lines in LGO (JSON in native units), [Review]
├─ Sheets: Review claim, Review vesting, Review vestings, confirm (stop / permanent /
│   milestone / give away), pending (1 or 2 steps), success, error, Receive, Add LGO,
│   How it works (every term), Settings (status, Advanced, About: version + network)
```

## 4. Wording

Every amount: `1,234.5 LGO` (grouping, up to 9 decimals, trailing zeros dropped). Every date: `Sat, Jul 24, 2027 at 12:25`, local time zone. Countdowns: `in 2 days 04:11:09`, `in 00:00:59` (live, every second).

**Glossary (the "?" tooltips and How it works)**
- Vesting: Tokens locked for someone that unlock bit by bit on a schedule, like a salary or a team grant.
- Unlock: The moment tokens become the recipient's to take.
- Claim: Move tokens that have unlocked out of the vesting into your account. Waiting costs nothing; they stay safe in the vesting.
- Waiting period (cliff): A waiting period at the start. Nothing unlocks before it ends; then the share for that period unlocks at once.
- Milestones: The tokens come in parts. Each part unlocks only when the sender confirms that milestone.
- Stop / Permanent / Give away; Account / address; LGO (1 LGO = 1,000,000,000 native units); Network cost; Private balance; Receive privately; Test network; Vesting code (only needed if the sender used another app).

**Home**
- Banner (local): `You're on a test network running on this computer. Its LGO are free test tokens with no value, so try anything.`
- Banner (testnet): `You're on the Logos testnet. Its LGO are test tokens with no value.`
- Welcome: `Welcome! Here's how vesting works` + 3 steps (someone locks LGO for your address → they unlock bit by bit, this screen shows the exact time of the next unlock → you claim whenever you like).
- Wallet: `Your account 2 of 2`, `Copy address`, `20,000 LGO`, `Free test LGO you can spend or lock in a vesting.`, zero: `This account has no LGO yet. You need some to create a vesting or to pay the small network cost of a claim. See "Add LGO".`
- Coming to you: `Ready to claim now` · `Still locked` · `Claimed so far` · `Next unlock` + `in 2 days 04:11:09`; cards `From 3F9a…c4e1 → your Account 1`, `328 of 1,000 LGO unlocked · 25 claimed · 672 still locked`, next-unlock lines:
  - `First unlock: about 1,199.18 LGO on Wed, May 5, 2027 at 12:25.`
  - `Unlocking every second (about 2.74 LGO a day) until Sat, Jul 24, 2027 at 12:25.`
  - `Next: 300 LGO when the sender confirms milestone 2.`
- Empty: `Nothing coming to you yet` · `When someone creates a vesting for your address, it shows up here by itself. No code needed. Give them your address:`
- Scan: `Looking for vestings sent to you… checked 1,199 of 4,200 blocks` → `Checked the whole network for vestings to your address.` · `Have a vesting code?`

**Create a vesting**
- Buttons, in order: `Enter the recipient's address`, `That's this account: pick another`, `Enter an amount`, `Not enough LGO in this account`, `Milestones must add up to the amount`, `Review`.
- Presets: `1 year · first unlock after 3 months`, `4 years · first unlock after 1 year`, `6 months · starts now`, `When I confirm milestones`, `Custom` (`Lasts`, `Waiting period: nothing unlocks before it ends (0 = none)`, `Starts`).
- Success: `Vesting created` · `1,000 LGO are locked for 7Bc1…9e0a. They see it in their Vesting app by themselves; there is nothing to send.` (code under `Vesting code (only for other apps)`).

**Claim, pending, success, error, Settings**: as in 0.1.0 (§1 table) with LGO amounts; Settings adds **About**: `Vesting 0.2.0 (2026-11-21) · RFP-017 prototype for LEZ 0.4` and `Network: Test network on this computer (http://127.0.0.1:3040)`.

## 5. Errors in plain words

| Code | Title | Message / action |
|---|---|---|
| V001 | Amount is zero | Enter an amount above 0. |
| V002 | Dates don't fit | The cliff must be between the start and the end, and the end after the start. |
| V003 | Milestones don't add up | Milestones (1 to 64) must each be above 0 and add up to the amount. |
| V004 | Not signed | The wallet didn't sign. Unlock the wallet and try again. |
| V005/V006/V018 | Something went wrong | Internal error. Show details and report it. |
| V007 | Already exists | A vesting with this id already exists. Try again; a new id is picked. |
| V008 | Vesting not found | No vesting at this code. Check it with the sender. |
| V009 | Not yours | Only the recipient of this vesting can do this. |
| V010 | Not yours | Only the creator of this vesting can do this. |
| V011 | Nothing to claim yet | Shows the next unlock: "Next unlock: Mar 1, 2027 14:00 (in 12 days)", "…when the sender confirms milestone 2", or "Everything unlocked has been claimed." |
| V012 | Can't be stopped | This vesting was made permanent. |
| V013 | Already stopped | This vesting was stopped earlier. |
| V014/V016 | Not a milestone | This vesting has no such milestone. |
| V015 | Already confirmed | This milestone was confirmed earlier. |
| V017 | Can't be given away | The creator didn't allow giving this vesting to another account. |
| V019 | No recipients | Add at least one person. |
| V020 | Not enough to pay the network cost | Add funds to the paying account (for a private claim, your private balance) and try again. Shows the needed amount when known. |
| V021 | The network didn't accept it | It wasn't included within 2 minutes. Refresh and try again. |
| V022 | Busy | Another action is still running. Wait for it to finish. |
| V023 | Not a private account | Pick a private account from this wallet under Show details. |
| V024 | Too many people | Up to 360 per transaction. Split the list. |
| bridge / wallet | Can't reach the wallet | Open Settings and check the wallet folder and program address. |

## 6. What lives under Advanced / Show details

- **Program and wallet:** program address, wallet folder, CLI path, WSL backend and distribution, dev-mode proofs. All of these are in Settings → Advanced.
- **Ids and accounts:** schedule account, vesting id, creator and beneficiary ids, escrow balance and raw timestamps. These are in the vesting detail under Show details.
- **Claim internals:** the private account used for a private claim (picker; the default is the wallet's first private account), the fee payer label, the one-time alias, the block number and the raw error text. These are in the Review and Result sheets under Show details.
- **Raw JSON batch input:** in Bulk → Paste JSON instead.

## 7. RFP usability requirements

| # | Requirement | How it is met |
|---|---|---|
| U1 | SDK: full lifecycle, public and private claims | Unchanged: `vesting_module` (module API table in README) and `vesting_core`. The UI uses only that API. |
| U2 | Mini-app. Recipient view: position, total locked, claimable now, next unlock, claim. Creator view: create with all parameters, list, cancel, signal milestone. | Home → **Coming to you**: ready to claim, still locked, claimed, next unlock with exact time and countdown, **Claim**. **Create a vesting**: every program parameter (recipient, amount, linear start/cliff/end or milestones, cancelable, transferable) via presets and Custom; bulk via **Send to many people**. **Created by you** list and detail: **Stop vesting**, **Confirm milestone N**, **Make permanent**. |
| U3 | CLI | Unchanged (`vesting` CLI). |
| U4 | Pre-claim summary: amount and fee; private path checks gas with an actionable error | **Review claim** always shows the amount, network cost and paying balance (from `quoteClaim`). If the balance is short, the button reads **Not enough to pay the network cost** and the V020 message says what to fund. |
| U5 | Privacy disclosure before each private claim | **What others can see** box in **Review claim** whenever **Receive privately** is on, filled from the quote's `visible`/`hidden` fields. |
| U6 | IDL (SPEL) | Unchanged (`idl/`). |
| U7 | Failed claims: clear, actionable errors, including nothing-claimable with the next unlock time | §5 mapping. V011 shows the next unlock as a date and a relative time. The Claim button is already disabled as **Nothing to claim yet** with the next unlock under it, so the error path is rarely reached. |

## 8. Verification

- `logos/vesting_ui/tests/render/` holds the render harness:
  - `Harness.qml` loads `Main.qml` with a mock `logos` bridge, puts the app into each state and saves a PNG;
  - `render.sh` runs it offscreen and fails on any QML warning or error.
- `tests/ui-tests.mjs` (logos-qt-mcp) checks that the real module plus UI load in the standalone host and that the main labels are present.
- `tests/ui-e2e.mjs` drives the real app against a live local chain (`E2E_UI=1 e2e/run_e2e.sh`), 10 flows: Settings → Save; New vesting → Review → Create vesting (shows the vesting code); Claim; milestone vesting → Confirm milestone; Receive privately (2 steps); Check for private payments; Give to another account; Make permanent; Stop vesting; Send to many people. Real mouse clicks via the inspector (it scrolls an item into view first, like a person), real module, real CLI, dev-mode proofs. Last run: 10/10 (21.11.2026, 0.2.0, 13:16 CET).
- Bulk: the schedule chips are the three presets, plus `Custom` when the New vesting form is on a custom schedule.
- `e2e/run_e2e.sh` exercises the same module calls the UI makes.

## 9. Progress notes (0.2.0 work, 21.11.2026)

- 12:50 CET: wallet-first Main.qml done; render.sh 35/35 clean; ui-tests 5/5; CLI e2e (with auto-discovery) passed. Fixed: job polling race (one pollTimer shared by concurrent jobs → a stale job's error reached the current refresh), auto-retry after a connection error, bulk "address,amount" parsing. Full `E2E_UI=1` run #3 in progress (/tmp/e2e_ui3/run.log).
- Laptop (Windows 10 laptop): vesting_ui 0.2.0 installed via Package Manager → Upgrade (no Trust) at 12:08; Settings → About shows "Vesting 0.2.0 (2026-11-21)". New CLI in WSL /opt/vest/bin/vesting (old one kept as vesting.v4). .wslconfig memory=6GB swap=12GB (backup .wslconfig.bak-20261121); WSL sequencer restarted (replay of ~4,700 blocks took ~25 min).
- 13:30 CET: full `E2E_UI=1` run #4 passed (CLI e2e with discovery, UI e2e 10/10, /tmp/e2e_ui4/run.log); ui-tests 5/5; render 35/35. Rebuilt signed Windows lgx reinstalled on the laptop (Reinstall, no Trust); its installed Main.qml matches the repo, and About still shows 0.2.0. The WIP commits can be squashed later.

## 9b. Progress notes (0.3.0 work, 21.11.2026)

- 14:24 CET: owner feedback on 0.2.0: lost after vesting, no visible VEST button, unclear 30k LGO, poor account picking. Verified the escrow model in the program code (§0b), designed the 0.3.0 fixes (§0a).
- Built the 4-step stepper with a pinned action bar, the header "Vest tokens" button, the money-flow cards (Home, detail, review, success), named and renamable accounts with balances, the "My other account" quick pick, live address check, the test-LGO intro and sheet, and "Switch to recipient view".
- Render 56/56 clean; ui-tests 5/5; full `E2E_UI=1` run #5 passed (10/10).
- 15:07 CET: signed Windows vesting_ui 0.3.0 installed on the laptop via Upgrade (no Trust); About shows 0.3.0.
