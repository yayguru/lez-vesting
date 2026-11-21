//! `vesting` — CLI for the RFP-017 vesting program on LEZ 0.4 (rc3).
//!
//! Uses the LEZ wallet library (`LEE_WALLET_HOME_DIR`, `LEE_WALLET_PASSWORD`) for keys, fees and
//! proving; never prints key material. `--json` prints exactly one JSON object on stdout
//! (`{"ok":true,...}` or `{"ok":false,"error":"..."}`), which the Logos module consumes.

use std::{borrow::Cow, collections::BTreeSet, path::PathBuf, time::{SystemTime, UNIX_EPOCH}};

use anyhow::{Context as _, Result, anyhow, bail};
use clap::{Parser, Subcommand};
use lee::{AccountId, privacy_preserving_transaction::circuit::ProgramCatalog, program::Program};
use rand::RngCore as _;
use sequencer_service_rpc::SequencerClient;
use serde_json::{Map, Value, json};
use vesting_core::{CreateEntry, Kind, Message, Params, Schedule, Unlock, VestingError, schedule_account};
use wallet::{AccountIdentity, AccountMention, AsyncDelivery, ExecutionFailureKind, WalletCore, DryRunReport};

#[derive(Parser)]
#[command(name = "vesting", about = "Privacy-preserving token vesting on LEZ (RFP-017 prototype)")]
struct Cli {
    /// Program account id of the deployed vesting program (header account).
    #[arg(long, env = "VESTING_PROGRAM", global = true)]
    program: Option<AccountId>,
    /// Print one JSON object instead of text.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Write the program ELF (for `wallet program-loader deploy --elf`).
    WriteElf { path: PathBuf },
    /// Print the program image id.
    ImageId,
    /// Derive a schedule's account address (offline).
    Address { #[arg(long)] creator: AccountId, #[arg(long)] id: String },
    /// List this wallet's accounts that can act (public signers, owned private accounts).
    Accounts,
    /// Create a schedule, escrowing `total` from the creator's public balance.
    Create {
        #[arg(long)] creator: AccountId,
        #[arg(long)] beneficiary: AccountId,
        #[arg(long)] total: u128,
        /// Schedule id (64 hex chars); random if omitted.
        #[arg(long)] id: Option<String>,
        /// Linear: start,cliff,end (unix ms).
        #[arg(long, value_delimiter = ',', conflicts_with = "milestones")] linear: Option<Vec<u64>>,
        /// Milestones: tranche amounts.
        #[arg(long, value_delimiter = ',')] milestones: Option<Vec<u128>>,
        #[arg(long)] non_cancelable: bool,
        #[arg(long)] transferable: bool,
        /// Only quote the fee.
        #[arg(long)] dry_run: bool,
    },
    /// Show a schedule: vested, claimed, claimable now, next unlock.
    Show { #[arg(long)] creator: AccountId, #[arg(long)] id: String, #[arg(long)] now: Option<u64> },
    /// Remember a schedule in this wallet's list (beneficiaries add the ones they receive).
    Track { #[arg(long)] creator: AccountId, #[arg(long)] id: String },
    /// Schedules this wallet created or tracks, with live state.
    List,
    /// Transaction hashes in blocks `from..=to` (audit trail for e2e runs).
    Txs { #[arg(long)] from: u64, #[arg(long)] to: u64 },
    /// Claim everything vested so far (with --dry-run: the pre-claim summary only).
    Claim {
        #[arg(long)] beneficiary: AccountId,
        #[arg(long)] creator: AccountId,
        #[arg(long)] id: String,
        /// Public destination (default: the beneficiary).
        #[arg(long, conflicts_with = "private")] to: Option<AccountId>,
        /// Private destination: a private account this wallet owns. The payout goes to a fresh
        /// blinded alias of it, so the account itself is never published.
        #[arg(long)] private: Option<AccountId>,
        /// Private account paying the privacy-preserving claim's fee (default: --private).
        #[arg(long)] fee_payer: Option<AccountId>,
        #[arg(long)] dry_run: bool,
        /// Skip the confirmation prompt.
        #[arg(long)] yes: bool,
    },
    /// Receive pending private payouts (from private claims) into this wallet's private accounts.
    Receive,
    Cancel { #[arg(long)] creator: AccountId, #[arg(long)] id: String, #[arg(long)] dry_run: bool },
    Signal { #[arg(long)] creator: AccountId, #[arg(long)] id: String, #[arg(long)] index: u8, #[arg(long)] dry_run: bool },
    /// Make a cancelable schedule non-cancelable (one-way).
    Irrevocable { #[arg(long)] creator: AccountId, #[arg(long)] id: String, #[arg(long)] dry_run: bool },
    /// Hand the position to a new beneficiary (only if created --transferable).
    TransferBeneficiary { #[arg(long)] beneficiary: AccountId, #[arg(long)] creator: AccountId, #[arg(long)] id: String, #[arg(long)] new_beneficiary: AccountId, #[arg(long)] dry_run: bool },
    /// Create many schedules in one transaction from a JSON file:
    /// `[{"beneficiary":"..","total":"100","linear":[start,cliff,end] | "milestones":["50","50"],
    ///    "cancelable":true,"transferable":false,"id":"<64 hex, optional>"}, ...]`.
    /// See README for the documented per-tx maximum.
    CreateBatch {
        #[arg(long)] creator: AccountId,
        /// JSON file with the entries.
        #[arg(long, required_unless_present = "entries_hex")] file: Option<PathBuf>,
        /// The same JSON, hex-encoded (used by the Logos module: survives any argv quoting).
        #[arg(long, conflicts_with = "file")] entries_hex: Option<String>,
        #[arg(long)] dry_run: bool,
    },
}

/// Collects the result: text lines for humans, fields for `--json`.
struct Out { json: bool, fields: Map<String, Value> }
impl Out {
    fn put(&mut self, key: &str, label: &str, v: impl Into<Value>) {
        let v = v.into();
        if !self.json {
            let shown = match &v { Value::String(s) => s.clone(), other => other.to_string() };
            println!("{label:<14}{shown}");
        }
        self.fields.insert(key.to_string(), v);
    }
    fn note(&mut self, text: &str) {
        if !self.json { println!("{text}"); }
        self.fields.entry("notes").or_insert_with(|| json!([])).as_array_mut().unwrap().push(json!(text));
    }
}

/// Blocks read per `getBlockRange` call, and at most per `list` (the rest on the next refresh).
const SCAN_CHUNK: u64 = 100;
const MAX_SCAN_BLOCKS: u64 = 3000;

/// "local" (this computer or a private network: a test network with free test tokens),
/// "testnet" (the public Logos testnet) or "other".
fn network_kind(host: &str) -> &'static str {
    let host = host.trim_matches(['[', ']']);
    let private = host == "localhost" || host.ends_with(".local") || host.parse::<std::net::IpAddr>().is_ok_and(|ip| match ip {
        std::net::IpAddr::V4(v) => v.is_loopback() || v.is_private() || v.is_link_local(),
        std::net::IpAddr::V6(v) => v.is_loopback(),
    });
    if private { "local" } else if host.contains("testnet") { "testnet" } else { "other" }
}

/// The vestings a transaction creates for (or hands to) one of `mine`, as (creator, id).
/// Vesting messages are received at the caller's own actor under the program, so the root
/// actor's account is the creator (for `Create`) or the current recipient (for transfers).
fn vesting_hits(program: &AccountId, t: &common::transaction::LeeTransaction, mine: &BTreeSet<AccountId>) -> Vec<(AccountId, [u8; 32])> {
    let Some((actor, data)) = t.public_call() else { return vec![] };
    if actor.program_account_id != *program { return vec![] }
    match borsh::from_slice::<Message>(data) {
        Ok(Message::Create { entries }) => entries.iter()
            .filter(|e| mine.contains(&e.params.beneficiary) || mine.contains(&actor.account_id))
            .map(|e| (actor.account_id, e.id)).collect(),
        Ok(Message::TransferBeneficiary { creator, id, new_beneficiary }) if mine.contains(&new_beneficiary) => vec![(creator, id)],
        _ => vec![],
    }
}

/// Most schedules one `create-batch` transaction may carry (measured in tests/tests/costs.rs).
const MAX_BATCH: usize = vesting_core::MAX_BATCH_RECIPIENTS;

/// Parses a `create-batch` file and validates every entry (V019 empty, Params::validate, size cap).
fn parse_batch(text: &str) -> Result<Vec<CreateEntry>> {
    let v: Vec<Value> = serde_json::from_str(text).context("batch file must be a JSON array")?;
    if v.is_empty() { bail!("{}", VestingError::EmptyBatch); }
    if v.len() > MAX_BATCH { bail!("V024 batch of {} exceeds the per-transaction maximum of {MAX_BATCH} schedules; split it", v.len()); }
    let num = |x: &Value| -> Result<u128> {
        match x { Value::String(s) => s.parse().context("amount"), Value::Number(n) => n.as_u64().map(u128::from).context("amount"), _ => bail!("amount must be a number or string") }
    };
    let mut out = vec![];
    let mut seen = BTreeSet::new();
    for (i, e) in v.iter().enumerate() {
        let ctx = |m: &str| anyhow!("entry {i}: {m}");
        let beneficiary: AccountId = e["beneficiary"].as_str().ok_or_else(|| ctx("beneficiary missing"))?.parse().map_err(|_| ctx("bad beneficiary"))?;
        let total = num(&e["total"]).map_err(|_| ctx("bad total"))?;
        let kind = if let Some(l) = e["linear"].as_array() {
            let t: Vec<u64> = l.iter().filter_map(Value::as_u64).collect();
            if t.len() != 3 { return Err(ctx("linear must be [start,cliff,end]")); }
            Kind::Linear { start: t[0], cliff: t[1], end: t[2] }
        } else if let Some(m) = e["milestones"].as_array() {
            Kind::Milestones { amounts: m.iter().map(num).collect::<Result<_>>().map_err(|_| ctx("bad milestone amount"))? }
        } else { return Err(ctx("give linear or milestones")); };
        let id = match e["id"].as_str() { Some(s) => parse_id(s)?, None => { let mut b = [0; 32]; rand::thread_rng().fill_bytes(&mut b); b } };
        if !seen.insert(id) { return Err(ctx("duplicate id")); }
        let params = Params { beneficiary, total, kind, cancelable: e["cancelable"].as_bool().unwrap_or(true), transferable: e["transferable"].as_bool().unwrap_or(false) };
        params.validate().map_err(|err| ctx(&err.to_string()))?;
        out.push(CreateEntry { id, params });
    }
    Ok(out)
}

/// The private-path target must be a private (shielded) account this wallet owns; a public
/// account (or a foreign one) is rejected before anything is built or sent.
fn check_private_target(owned_private: &[AccountId], target: AccountId) -> Result<()> {
    if owned_private.contains(&target) { return Ok(()); }
    bail!("V023 claim target {target} is not a private (shielded) account of this wallet; pass one listed under \"private\" by `vesting accounts`, or claim publicly with --to")
}

fn parse_id(s: &str) -> Result<[u8; 32]> {
    let v = hex::decode(s.trim_start_matches("0x")).context("id must be hex")?;
    v.try_into().map_err(|_| anyhow!("id must be 32 bytes (64 hex chars)"))
}
fn now_ms() -> u64 {
    u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap()
}
fn program_obj() -> Result<Program> {
    Program::new(Cow::Borrowed(vesting_methods::VESTING_ELF)).map_err(|e| anyhow!("load ELF: {e}"))
}
fn unlock_json(u: Unlock) -> Value {
    match u {
        Unlock::At(t) => json!({"kind": "time", "at": t}),
        Unlock::AwaitingMilestone(i) => json!({"kind": "milestone", "index": i}),
        Unlock::Never => json!({"kind": "never"}),
    }
}
/// Guest panics surface as "... Guest panicked: V0xx ..."; keep the actionable part.
/// A pending message sent by a fee account is the surplus refund of a private fee reserve, not a
/// vesting payout. `vesting receive` leaves these alone: receiving one is itself a private tx whose
/// reserve produces a new refund, so sweeping them loops and burns the fee balance.
fn is_fee_refund(sender: &AccountId) -> bool {
    system_accounts::fee_account_ids().contains(sender)
}

fn clean_error(e: &str) -> String {
    if let Some(i) = e.find("Fee reserve of ") {
        let rest = &e[i + 15..];
        let fee = rest.split_whitespace().next().unwrap_or("?");
        let payer = rest.split("from payer ").nth(1).and_then(|r| r.split_whitespace().next()).unwrap_or("the fee payer");
        return format!("V020 {payer} cannot cover the fee reserve of {fee}; fund it first (e.g. shield some balance into it with `wallet auth-transfer send`)");
    }
    e.find(" V0").and_then(|i| e.get(i + 1..)).map_or_else(|| e.to_string(), str::to_string)
}

/// Waits for inclusion; a tx that fails settlement never lands, so give up after 2 minutes.
async fn poll(w: &WalletCore<SequencerClient>, hash: common::HashType) -> Result<lee_core::BlockId> {
    match tokio::time::timeout(std::time::Duration::from_secs(120), w.poll_transaction(hash)).await {
        Ok(r) => Ok(r?.1),
        Err(_) => bail!("V021 transaction {hash} was not included within 2 minutes; it was probably refused at settlement. Refresh and retry."),
    }
}

struct Ctx { w: WalletCore<SequencerClient>, program: AccountId, home: PathBuf }

impl Ctx {
    fn me(&self, id: AccountId) -> AccountMention { AccountIdentity::Public(id).select_program_actor_state(self.program) }
    fn other(&self, id: AccountId) -> AccountMention { AccountIdentity::PublicNoSign(id).select_program_actor_state(self.program) }
    fn bal(id: AccountId, sign: bool) -> AccountMention {
        if sign { AccountIdentity::Public(id).balance() } else { AccountIdentity::PublicNoSign(id).balance() }
    }
    async fn schedule(&self, creator: AccountId, id: [u8; 32]) -> Result<(AccountId, Option<Schedule>, u128)> {
        let at = schedule_account(&self.program, &creator, &id);
        let Some(acct) = self.w.get_account_public(at).await? else { return Ok((at, None, 0)) };
        let raw = acct.data.actor_state(self.program);
        let s = if raw.is_empty() { None } else { Some(borsh::from_slice(raw).context("decode schedule")?) };
        Ok((at, s, acct.data.native_balance().unwrap_or(0)))
    }
    /// Appends every submitted tx (and where it landed, or null if it never did) to
    /// `<wallet home>/vesting_txlog.jsonl`, so a UI-driven run leaves an audit trail.
    fn txlog(&self, tx: &str, block: Option<lee_core::BlockId>) {
        use std::io::Write as _;
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(self.home.join("vesting_txlog.jsonl")) {
            let _ = writeln!(f, "{}", json!({"t": now_ms(), "program": self.program.to_string(), "tx": tx, "block": block}));
        }
    }
    fn scan_path(&self) -> PathBuf { self.home.join(format!("vesting_{}_scan.json", self.program)) }
    /// Scans blocks the wallet hasn't looked at yet for vesting transactions that concern this
    /// wallet's public accounts: a `Create` entry whose recipient (or creator) is ours, or a
    /// `TransferBeneficiary` to one of ours. Each hit is added to the wallet's vesting list.
    /// Resumes from `vesting_<program>_scan.json`; at most `MAX_SCAN_BLOCKS` per call.
    async fn discover(&self, out: &mut Out) -> Result<()> {
        let mine: BTreeSet<AccountId> = self.w.storage().key_chain().public_account_ids().map(|(id, _)| id).collect();
        let mut next = std::fs::read_to_string(self.scan_path()).ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok()).and_then(|v| v["next"].as_u64()).unwrap_or(1).max(1);
        let tip = self.w.get_last_block_id().await.context("last block")?;
        let client = WalletCore::<SequencerClient>::client_from_config(self.w.config())?;
        let stop = next.saturating_add(MAX_SCAN_BLOCKS);
        let mut found = 0u64;
        while next <= tip && next < stop {
            let end = next.saturating_add(SCAN_CHUNK - 1).min(tip);
            let blocks = sequencer_service_rpc::RpcClient::get_block_range(&client, next, end).await.context("read blocks")?;
            for b in &blocks {
                for (i, t) in b.body.transactions.iter().enumerate() {
                    if b.body.reverted.contains(&(i as u64)) { continue; }
                    for (creator, id) in vesting_hits(&self.program, t, &mine) {
                        if !self.registry().contains(&(creator, id)) { self.remember(creator, id)?; found += 1; }
                    }
                }
            }
            next = end + 1;
            std::fs::write(self.scan_path(), json!({"next": next}).to_string())?;
        }
        out.fields.insert("scan".into(), json!({"next": next, "tip": tip, "found": found, "done": next > tip}));
        Ok(())
    }
    fn registry_path(&self) -> PathBuf { self.home.join(format!("vesting_{}.json", self.program)) }
    fn registry(&self) -> Vec<(AccountId, [u8; 32])> {
        let Ok(text) = std::fs::read_to_string(self.registry_path()) else { return vec![] };
        let v: Vec<(String, String)> = serde_json::from_str(&text).unwrap_or_default();
        v.into_iter().filter_map(|(c, i)| Some((c.parse().ok()?, parse_id(&i).ok()?))).collect()
    }
    fn remember(&self, creator: AccountId, id: [u8; 32]) -> Result<()> {
        let mut r = self.registry();
        if !r.contains(&(creator, id)) { r.push((creator, id)); }
        let v: Vec<(String, String)> = r.iter().map(|(c, i)| (c.to_string(), hex::encode(i))).collect();
        std::fs::write(self.registry_path(), serde_json::to_string_pretty(&v)?)?;
        Ok(())
    }
    /// Sends (or with `dry_run` quotes) a transaction; returns the quoted fee or the inclusion block.
    async fn send(&mut self, out: &mut Out, accounts: Vec<AccountMention>, msg: &Message, delivery: AsyncDelivery, fee_payer: Option<AccountId>, dry_run: bool) -> Result<()> {
        let data = Program::serialize_message(msg).map_err(|e| anyhow!("{e}"))?;
        let catalog = ProgramCatalog::from([(self.program, program_obj()?)]);
        self.w.set_dry_run(dry_run);
        let r = self.w.send_tx_with_pre_check(accounts, 0, data, &catalog, None, delivery, fee_payer, |_| Ok(())).await;
        self.w.set_dry_run(false);
        match r {
            Err(ExecutionFailureKind::DryRun(report)) => {
                let (fee, revert) = match report.as_ref() {
                    DryRunReport::Public { fee_at_head, revert_reason, cycles, wire_bytes, .. } => {
                        // Cost units: execution gas = guest cycles, storage gas = wire bytes.
                        out.put("cycles", "cycles", *cycles);
                        out.put("wire_bytes", "wire bytes", *wire_bytes);
                        (*fee_at_head, revert_reason.clone())
                    }
                    DryRunReport::Private { fee_at_head, cycles, .. } => {
                        // Plus the protocol's flat PRIVATE_VERIFY_GAS / PRIVATE_GAS_STOR.
                        out.put("cycles", "public cycles", *cycles);
                        (*fee_at_head, None)
                    }
                };
                out.put("fee_estimate", "fee estimate", fee.to_string());
                if let Some(r) = revert { bail!("{}", clean_error(&r)); }
                Ok(())
            }
            Err(e) => bail!("{}", clean_error(&e.to_string())),
            Ok((hash, _)) => {
                out.put("tx", "submitted tx", hash.to_string());
                let polled = poll(&self.w, hash).await;
                self.txlog(&hash.to_string(), polled.as_ref().ok().copied());
                let block = polled?;
                out.put("block", "included in", block);
                // Pick up the new private states (fee payer, outputs) before anything else spends them.
                self.w.sync_to_latest_block().await?;
                Ok(())
            }
        }
    }
}

fn describe(out: &mut Out, s: &Schedule, at: AccountId, escrow: u128, now: u64) {
    out.put("schedule", "schedule", at.to_string());
    out.put("id", "id", hex::encode(s.id));
    out.put("creator", "creator", s.creator.to_string());
    out.put("beneficiary", "beneficiary", s.beneficiary.to_string());
    match &s.kind {
        Kind::Linear { start, cliff, end } => out.put("kind", "kind", json!({"linear": {"start": start, "cliff": cliff, "end": end}})),
        Kind::Milestones { amounts } => out.put("kind", "kind", json!({"milestones": amounts.iter().map(u128::to_string).collect::<Vec<_>>(), "done_mask": s.milestones_done})),
    }
    out.put("total", "total", s.total.to_string());
    out.put("vested", "vested now", s.vested_at(now).to_string());
    out.put("locked", "locked", (s.total - s.vested_at(now)).to_string());
    out.put("claimed", "claimed", s.claimed.to_string());
    out.put("claimable", "claimable", s.claimable_at(now).to_string());
    out.put("escrow", "escrow", escrow.to_string());
    out.put("next_unlock", "next unlock", unlock_json(s.next_unlock_event(now)));
    out.put("cancelable", "cancelable", s.cancelable);
    out.put("transferable", "transferable", s.transferable);
    out.put("cancelled", "cancelled", s.cancelled.as_ref().map_or(Value::Null, |c| json!({"at": c.at, "vested": c.vested.to_string()})));
}

async fn run(cli: Cli, out: &mut Out) -> Result<()> {
    match &cli.cmd {
        Cmd::WriteElf { path } => { std::fs::write(path, vesting_methods::VESTING_ELF)?; out.put("path", "wrote", path.display().to_string()); return Ok(()) }
        Cmd::ImageId => { out.put("image_id", "image id", hex::encode(vesting_methods::VESTING_ID.iter().flat_map(|w| w.to_le_bytes()).collect::<Vec<_>>())); return Ok(()) }
        Cmd::Address { creator, id } => {
            let p = cli.program.context("--program / VESTING_PROGRAM required")?;
            out.put("schedule", "schedule", schedule_account(&p, creator, &parse_id(id)?).to_string()); return Ok(())
        }
        _ => {}
    }
    let program = match (&cli.cmd, cli.program) {
        (Cmd::Accounts, p) => p.unwrap_or(AccountId::new([0; 32])),
        (_, p) => p.context("--program / VESTING_PROGRAM required")?,
    };
    let home = wallet::utils::fetch_config_path()?.parent().map(PathBuf::from).context("wallet home")?;
    let w = WalletCore::from_env().context("open wallet (LEE_WALLET_HOME_DIR)")?;
    let mut c = Ctx { w, program, home };
    // Private account states move with every privacy-preserving tx (fees, claims, receipts);
    // spending a stale one is refused at settlement ("nullifier already seen").
    c.w.sync_to_latest_block().await.context("sync wallet with the sequencer")?;
    match cli.cmd {
        Cmd::Accounts => {
            let mut pubs = vec![]; let mut privs = vec![];
            let kc = c.w.storage().key_chain();
            let pub_ids: Vec<AccountId> = kc.public_account_ids().map(|(id, _)| id).collect();
            let priv_ids: Vec<AccountId> = kc.private_account_ids().map(|(id, _)| id).collect();
            for id in pub_ids {
                pubs.push(json!({"id": id.to_string(), "balance": c.w.get_account_balance(id).await.unwrap_or(0).to_string()}));
            }
            for id in priv_ids {
                let b = c.w.get_account(wallet::account::AccountIdWithPrivacy::Private(id)).await.ok().and_then(|a| a.data.native_balance().ok()).unwrap_or(0);
                privs.push(json!({"id": id.to_string(), "balance": b.to_string()}));
            }
            out.put("public", "public", Value::Array(pubs));
            out.put("private", "private", Value::Array(privs));
            // Which network this wallet talks to, so the app can say "free test tokens" honestly.
            let url = c.w.config().sequencer.sequencer_addr.clone();
            out.put("network", "network", json!({"url": url.to_string(), "kind": network_kind(url.host_str().unwrap_or(""))}));
        }
        Cmd::Create { creator, beneficiary, total, id, linear, milestones, non_cancelable, transferable, dry_run } => {
            let id = match id { Some(s) => parse_id(&s)?, None => { let mut b = [0; 32]; rand::thread_rng().fill_bytes(&mut b); b } };
            let kind = match (linear, milestones) {
                (Some(v), None) if v.len() == 3 => Kind::Linear { start: v[0], cliff: v[1], end: v[2] },
                (None, Some(amounts)) => Kind::Milestones { amounts },
                _ => bail!("give --linear start,cliff,end or --milestones a,b,..."),
            };
            let params = Params { beneficiary, total, kind, cancelable: !non_cancelable, transferable };
            params.validate().map_err(|e| anyhow!("{e}"))?;
            let at = schedule_account(&program, &creator, &id);
            out.put("id", "schedule id", hex::encode(id));
            out.put("schedule", "schedule", at.to_string());
            c.send(out, vec![c.me(creator), Ctx::bal(creator, true), c.other(at), Ctx::bal(at, false)],
                &Message::Create { entries: vec![CreateEntry { id, params }] }, AsyncDelivery::default(), None, dry_run).await?;
            if !dry_run { c.remember(creator, id)?; }
        }
        Cmd::Show { creator, id, now } => {
            let (at, s, escrow) = c.schedule(creator, parse_id(&id)?).await?;
            let s = s.ok_or_else(|| anyhow!("{} (schedule {at})", VestingError::NotInitialized))?;
            describe(out, &s, at, escrow, now.unwrap_or_else(now_ms));
        }
        Cmd::Track { creator, id } => {
            let id = parse_id(&id)?;
            let (at, s, _) = c.schedule(creator, id).await?;
            s.ok_or_else(|| anyhow!("{} (schedule {at})", VestingError::NotInitialized))?;
            c.remember(creator, id)?;
            out.put("schedule", "tracking", at.to_string());
        }
        Cmd::Txs { from, to } => {
            let mut rows = vec![];
            for id in from..=to {
                let Some(b) = c.w.get_block(id).await? else { continue };
                let txs: Vec<Value> = b.body.transactions.iter().map(|t| json!({"hash": t.hash().to_string(), "kind": format!("{:?}", t.kind())})).collect();
                rows.push(json!({"block": id, "txs": txs}));
            }
            out.put("blocks", "blocks", Value::Array(rows));
        }
        Cmd::List => {
            // Pick up vestings sent to (or made by) this wallet's accounts straight from the chain,
            // so a recipient never needs a code. A scan problem must not hide the known list.
            if let Err(e) = c.discover(out).await { out.note(&format!("scan for new vestings failed: {e:#}")); }
            let now = now_ms();
            let mut rows = vec![];
            for (creator, id) in c.registry() {
                let (at, s, escrow) = c.schedule(creator, id).await?;
                let Some(s) = s else { continue };
                let mut o = Out { json: true, fields: Map::new() };
                describe(&mut o, &s, at, escrow, now);
                if !cli.json { println!("{at}  {}  claimable {}  of {}", hex::encode(id), s.claimable_at(now), s.total); }
                rows.push(Value::Object(o.fields));
            }
            out.fields.insert("schedules".into(), Value::Array(rows));
            out.fields.insert("now".into(), json!(now));
        }
        Cmd::Claim { beneficiary, creator, id, to, private, fee_payer, dry_run, yes } => {
            let id = parse_id(&id)?;
            let (at, s, _) = c.schedule(creator, id).await?;
            let s = s.ok_or_else(|| anyhow!("{} (schedule {at})", VestingError::NotInitialized))?;
            if s.beneficiary != beneficiary { bail!("{}", VestingError::NotBeneficiary); }
            // Back off a little so the validity window `now..` holds at inclusion.
            let now = now_ms().saturating_sub(5_000);
            let amount = s.claimable_at(now);
            if amount == 0 { bail!("{}", VestingError::NothingClaimable { next_unlock: s.next_unlock_event(now) }); }
            out.put("amount", "claimable", amount.to_string());
            out.put("schedule", "schedule", at.to_string());
            if let Some(pid) = private {
                let owned: Vec<AccountId> = c.w.storage().key_chain().private_account_ids().map(|(id, _)| id).collect();
                check_private_target(&owned, pid)?;
            }
            let fee_payer = if private.is_some() { fee_payer.or(private) } else { None };
            let (payer_label, fee_balance) = match fee_payer {
                Some(p) => {
                    let a = c.w.get_account(wallet::account::AccountIdWithPrivacy::Private(p)).await
                        .context("fee payer must be a private account this wallet owns")?;
                    (format!("Private/{p}"), a.data.native_balance().unwrap_or(0))
                }
                None => (format!("Public/{beneficiary}"), c.w.get_account_balance(beneficiary).await.unwrap_or(0)),
            };
            out.put("fee_payer", "fee payer", payer_label.clone());
            out.put("fee_payer_balance", "payer balance", fee_balance.to_string());
            if fee_balance == 0 {
                bail!("V020 {payer_label} has no balance to pay the claim fee; fund it first (e.g. `wallet auth-transfer send --to {payer_label} ...`)");
            }
            let mut accounts = vec![c.me(beneficiary), c.other(at), Ctx::bal(at, false)];
            let private_dest = |w: &WalletCore<SequencerClient>, pid: AccountId| -> Result<(AccountId, AsyncDelivery)> {
                let mut opening = [0u8; 32];
                rand::thread_rng().fill_bytes(&mut opening);
                let mention = AccountMention { address_openings: BTreeSet::from([opening]), ..AccountIdentity::PrivateOwned(pid).balance() };
                let (_, mut d) = w.async_destination(mention).map_err(|e| anyhow!("{e}"))?;
                d.promotions.listed_only = true;
                let alias = d.recoveries.first().context("no recipient")?.recipient.address();
                Ok((alias, d))
            };
            let (dest, delivery) = if let Some(pid) = private {
                let (alias, d) = private_dest(&c.w, pid)?;
                out.put("visible", "on-chain", json!({"amount": amount.to_string(), "beneficiary": beneficiary.to_string(), "schedule": at.to_string(), "one_time_alias": alias.to_string()}));
                out.put("hidden", "not traceable", json!(["which private account the alias belongs to", "later movements of the funds"]));
                (alias, d)
            } else {
                let to = to.unwrap_or(beneficiary);
                accounts.push(Ctx::bal(to, to == beneficiary));
                out.put("destination", "destination", to.to_string());
                (to, AsyncDelivery::default())
            };
            if !dry_run {
                // Quote first: refuse before proving if the payer cannot cover the fee.
                let (qdest, qdelivery) = match private { Some(pid) => private_dest(&c.w, pid)?, None => (dest, AsyncDelivery::default()) };
                let mut q = Out { json: true, fields: Map::new() };
                c.send(&mut q, accounts.clone(), &Message::Claim { creator, id, now, to: qdest }, qdelivery, fee_payer, true).await?;
                if let Some(Value::String(f)) = q.fields.get("fee_estimate") {
                    out.put("fee_estimate", "fee estimate", f.clone());
                    if f.parse::<u128>().unwrap_or(0) > fee_balance { bail!("V020 {payer_label} balance {fee_balance} is below the estimated fee {f}; fund it first"); }
                }
            }
            if !yes && !dry_run && !cli.json {
                eprint!("proceed? [y/N] ");
                let mut line = String::new();
                std::io::stdin().read_line(&mut line)?;
                if !line.trim().eq_ignore_ascii_case("y") { bail!("aborted"); }
            }
            c.send(out, accounts, &Message::Claim { creator, id, now, to: dest }, delivery, fee_payer, dry_run).await?;
            if fee_balance > 0 && dry_run {
                if let Some(Value::String(f)) = out.fields.get("fee_estimate").cloned() {
                    if f.parse::<u128>().unwrap_or(0) > fee_balance { bail!("V020 {payer_label} balance {fee_balance} is below the estimated fee {f}; fund it first"); }
                }
            }
            if private.is_some() && !dry_run { out.note("payout pending at the alias; run `vesting receive` to move it into the private account"); }
        }
        Cmd::Receive => {
            // One payout per wallet session: within a session the wallet hides a message whose
            // receive it already sent (even if settlement refused it), and a second receive built
            // in the same session can spend a stale private state ("Nullifier already seen").
            // So each round persists, reopens and re-syncs the wallet, then receives one message;
            // a refused round is retried after one block.
            let mut got = vec![];
            let mut refused = 0;
            let mut idle = 0;
            for round in 0..8 {
                if round > 0 {
                    c.w.store_persistent_data()?;
                    c.w = WalletCore::from_env().context("reopen wallet")?;
                    c.w.sync_to_latest_block().await?;
                }
                // Only vesting payouts. A private receive pays its fee from a reserve whose
                // surplus comes back as a new pending fee-refund message; receiving that refund
                // costs another fee and yields another refund, so sweeping refunds here would
                // loop and burn the fee balance. Refunds are left for `wallet pending receive`.
                let Some(p) = c.w.owned_pending_messages().await?.into_iter()
                    .find(|m| !is_fee_refund(&m.body.from.account_id)) else {
                    // After a refused receive the message is hidden for a while; wait for it to
                    // reappear (up to ~2 minutes) before concluding there is nothing left.
                    if refused > 0 && idle < 12 { idle += 1; tokio::time::sleep(std::time::Duration::from_secs(10)).await; continue; }
                    break;
                };
                idle = 0;
                let pos = p.position;
                let (hash, _) = c.w.receive_pending_message(p).await.map_err(|e| anyhow!("{}", clean_error(&e.to_string())))?;
                let polled = poll(&c.w, hash).await;
                c.txlog(&hash.to_string(), polled.as_ref().ok().copied());
                match polled {
                    Ok(block) => {
                        got.push(json!({"position": pos, "tx": hash.to_string(), "block": block}));
                        // Let the chain move two blocks past the inclusion before building the
                        // next receive, so the private account's new state is settled.
                        for _ in 0..20 {
                            if c.w.get_block(block + 2).await?.is_some() { break; }
                            tokio::time::sleep(std::time::Duration::from_secs(4)).await;
                        }
                    }
                    Err(e) => {
                        refused += 1;
                        if refused > 2 { return Err(e); }
                        eprintln!("receive retry after: {e}");
                    }
                }
            }
            out.put("received", "received", Value::Array(got));
        }
        Cmd::Cancel { creator, id, dry_run } => {
            let id = parse_id(&id)?;
            let at = schedule_account(&program, &creator, &id);
            c.send(out, vec![c.me(creator), c.other(at), Ctx::bal(at, false), Ctx::bal(creator, true)],
                &Message::Cancel { id, now: now_ms() }, AsyncDelivery::default(), None, dry_run).await?;
        }
        Cmd::Signal { creator, id, index, dry_run } => {
            let id = parse_id(&id)?;
            let at = schedule_account(&program, &creator, &id);
            c.send(out, vec![c.me(creator), c.other(at)], &Message::SignalMilestone { id, index }, AsyncDelivery::default(), None, dry_run).await?;
        }
        Cmd::Irrevocable { creator, id, dry_run } => {
            let id = parse_id(&id)?;
            let at = schedule_account(&program, &creator, &id);
            c.send(out, vec![c.me(creator), c.other(at)], &Message::MakeIrrevocable { id }, AsyncDelivery::default(), None, dry_run).await?;
        }
        Cmd::TransferBeneficiary { beneficiary, creator, id, new_beneficiary, dry_run } => {
            let id = parse_id(&id)?;
            let at = schedule_account(&program, &creator, &id);
            c.send(out, vec![c.me(beneficiary), c.other(at)], &Message::TransferBeneficiary { creator, id, new_beneficiary }, AsyncDelivery::default(), None, dry_run).await?;
        }
        Cmd::CreateBatch { creator, file, entries_hex, dry_run } => {
            let text = match (file, entries_hex) {
                (Some(f), _) => std::fs::read_to_string(&f).with_context(|| format!("read {}", f.display()))?,
                (None, Some(h)) => String::from_utf8(hex::decode(h).context("--entries-hex must be hex")?).context("entries must be UTF-8 JSON")?,
                (None, None) => bail!("give --file or --entries-hex"),
            };
            let entries = parse_batch(&text)?;
            let mut accounts = vec![c.me(creator), Ctx::bal(creator, true)];
            let mut rows = vec![];
            for e in &entries {
                let at = schedule_account(&program, &creator, &e.id);
                accounts.push(c.other(at));
                accounts.push(Ctx::bal(at, false));
                rows.push(json!({"id": hex::encode(e.id), "schedule": at.to_string(), "beneficiary": e.params.beneficiary.to_string(), "total": e.params.total.to_string()}));
            }
            out.put("schedules", "schedules", Value::Array(rows));
            let ids: Vec<[u8; 32]> = entries.iter().map(|e| e.id).collect();
            // The wallet simulates within its configured gas_limit (default 2M cycles, ~71
            // schedules); a batch may use the protocol's per-tx cap MAX_GAS_EXEC (10M).
            let mut cfg = c.w.config().clone();
            cfg.gas_limit = cfg.gas_limit.max(10_000_000);
            c.w.set_config(cfg);
            c.send(out, accounts, &Message::Create { entries }, AsyncDelivery::default(), None, dry_run).await?;
            if !dry_run { for id in ids { c.remember(creator, id)?; } }
        }
        Cmd::WriteElf { .. } | Cmd::ImageId | Cmd::Address { .. } => unreachable!(),
    }
    c.w.store_persistent_data()?;
    Ok(())
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let json = cli.json;
    let mut out = Out { json, fields: Map::new() };
    // Library code prints progress to stdout; in --json mode keep stdout to the one result object.
    let hush = if json { gag::Redirect::stdout(std::io::stderr()).ok() } else { None };
    let r = run(cli, &mut out).await;
    drop(hush);
    if json {
        let mut f = out.fields;
        match &r { Ok(()) => { f.insert("ok".into(), json!(true)); } Err(e) => { f.insert("ok".into(), json!(false)); f.insert("error".into(), json!(format!("{e:#}"))); } }
        println!("{}", Value::Object(f));
    } else if let Err(e) = &r {
        eprintln!("Error: {e:#}");
    }
    std::process::exit(i32::from(r.is_err()));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_kind_tells_local_test_networks_apart() {
        for h in ["127.0.0.1", "localhost", "[::1]", "192.168.1.20", "10.0.0.5", "box.local"] { assert_eq!(network_kind(h), "local", "{h}"); }
        assert_eq!(network_kind("testnet.lez.logos.co"), "testnet");
        assert_eq!(network_kind("rpc.example.org"), "other");
    }

    #[test]
    fn private_claim_rejects_a_non_private_target() {
        let private: AccountId = "GMQwBNSNG4vcx3ysvn9Ts6agH6NyomcRp5fQo9bxfnFy".parse().unwrap();
        let public: AccountId = "7wHg9sbJwc6h3NP1S9bekfAzB8CHifEcxKswCKUt3YQo".parse().unwrap();
        assert!(check_private_target(&[private], private).is_ok());
        let e = check_private_target(&[private], public).unwrap_err().to_string();
        assert!(e.starts_with("V023") && e.contains("not a private"), "{e}");
        assert!(check_private_target(&[], private).is_err());
    }

    #[test]
    fn batch_file_is_parsed_and_validated() {
        let b = "7wHg9sbJwc6h3NP1S9bekfAzB8CHifEcxKswCKUt3YQo";
        let ok = format!(r#"[{{"beneficiary":"{b}","total":"100","linear":[0,10,100]}},
                             {{"beneficiary":"{b}","total":90,"milestones":["30","60"],"cancelable":false,"transferable":true}}]"#);
        let v = parse_batch(&ok).unwrap();
        assert_eq!(v.len(), 2);
        assert!(!v[1].params.cancelable && v[1].params.transferable);
        assert!(parse_batch("[]").unwrap_err().to_string().starts_with("V019"));
        let bad_sum = format!(r#"[{{"beneficiary":"{b}","total":"100","milestones":["30","60"]}}]"#);
        assert!(parse_batch(&bad_sum).unwrap_err().to_string().contains("V003"));
        let one = format!(r#"{{"beneficiary":"{b}","total":"1","linear":[0,0,1]}}"#);
        let too_many = format!("[{}]", vec![one; MAX_BATCH + 1].join(","));
        assert!(parse_batch(&too_many).unwrap_err().to_string().starts_with("V024"));
    }

    #[test]
    fn receive_skips_fee_refunds_but_not_payouts() {
        // Every fee account (the inbox `8ga8ND…` sends the refunds seen on the WSL chain).
        for fee in system_accounts::fee_account_ids() {
            assert!(is_fee_refund(&fee), "{fee} must be treated as a fee refund sender");
        }
        let inbox: AccountId = "8ga8NDaWPPnpAo2sWwj4Cjrhcb8hvNa7nrxJaAZh6jwq".parse().unwrap();
        assert!(is_fee_refund(&inbox));
        // A vesting payout comes from its schedule account and must be received.
        let program: AccountId = "GaDvygRPGyyBpGz9TZiXXYURd1GoE4KpfCPCEF1Yqs2w".parse().unwrap();
        let creator: AccountId = "6iArKUXxhUJqS7kCaPNhwMWt3ro71PDyBj7jwAyE2VQV".parse().unwrap();
        let schedule = schedule_account(&program, &creator, &[7u8; 32]);
        assert!(!is_fee_refund(&schedule));
        // Mixed pending set (run 3 on WSL: one payout + one refund) selects only the payout.
        let pending = [inbox, schedule, inbox];
        let picked: Vec<_> = pending.iter().filter(|s| !is_fee_refund(s)).collect();
        assert_eq!(picked, vec![&schedule]);
    }
}
