import { resolve } from "node:path";
const root = process.env.LOGOS_QT_MCP || new URL("../result-mcp", import.meta.url).pathname;
const { test, run } = await import(resolve(root, "test-framework/framework.mjs"));

// UI end-to-end: drives the real mini-app (real vesting_module, real CLI, live local sequencer)
// through Settings -> New vesting -> Claim, clicking the same buttons a person would.
// Started by e2e/run_e2e.sh when E2E_UI=1, which exports the values below.
const E = (k) => { const v = process.env[k]; if (!v) throw new Error(`missing env ${k}`); return v; };
const PROGRAM = E("VESTING_PROGRAM"), WALLET = E("LEE_WALLET_HOME_DIR"), CLI = E("VESTING_CLI"), BEN = E("E2E_BEN");
const OTHER = E("E2E_CREATOR");
const LONG = { timeout: 240000, interval: 1000 };

async function one(app, name) {
  const r = await app.findByProperty("objectName", name);
  if (!r.matches || !r.matches.length) throw new Error(`no ${name}`);
  if (r.matches.length > 1) for (const m of r.matches) if ((await prop(app, m.id, "visible")) === true) return m.id;
  return r.matches[0].id;
}
async function prop(app, id, p) {
  const r = await app.getProperties(id);
  const f = (r.properties || []).find((x) => x.name === p);
  return f ? f.value : undefined;
}
async function setText(app, name, text) {
  const id = await one(app, name);
  const r = await app.inspector.send("setProperty", { objectId: id, property: "text", value: text });
  if (r.error) throw new Error(r.error);
}
// Click like a person: if the item is outside the visible part of its page or sheet, scroll first.
async function sceneY(app, objectId) {
  const r = await app.inspector.send("evaluate", { objectId, expression: "mapToItem(null, width / 2, height / 2).y" });
  if (r.error) throw new Error(r.error);
  return r.result;
}
// Repeaters rebuild their delegates when the list refreshes, so look the item up again if it vanished.
async function press(app, name) {
  for (let i = 0; ; i++) {
    try { return await pressId(app, await one(app, name), name); }
    catch (e) { if (i >= 3 || !/Object not found/.test(String(e.message))) throw e; await new Promise((r) => setTimeout(r, 300)); }
  }
}
async function pressId(app, id, name = id) {
  if ((await prop(app, id, "enabled")) === false) throw new Error(`${name} disabled: ${await prop(app, id, "text")}`);
  for (let i = 0; i < 6; i++) {
    await new Promise((res) => setTimeout(res, 300));   // let layout settle (an expander may have just opened)
    const inF = await app.inspector.send("evaluate", { objectId: id, expression:
      "(function(){ var p = parent; while (p) { if (p.objectName === 'sheetFlick' || p.objectName === 'pageFlick') return p.objectName; p = p.parent } return '' })()" });
    if (!inF.result) { const r = await app.inspector.send("click", { objectId: id }); if (r.error) throw new Error(r.error); return; }
    const fl = await one(app, inF.result);
    const top = await sceneY(app, fl), fh = await prop(app, fl, "height");
    const lo = top - fh / 2 + 10, hi = top + fh / 2 - 10, y = await sceneY(app, id);
    if (y >= lo && y <= hi) {
      const r = await app.inspector.send("click", { objectId: id });
      if (r.error) throw new Error(r.error);
      return;
    }
    const cy = await prop(app, fl, "contentY");
    await app.inspector.send("setProperty", { objectId: fl, property: "contentY", value: Math.max(0, Math.min(cy + y - top, (await prop(app, fl, "contentHeight")) - fh)) });
    await new Promise((res) => setTimeout(res, 200));
  }
  throw new Error(`${name} not reachable`);
}
async function scroll(app, where) {
  const id = await one(app, "pageFlick");
  const ch = await prop(app, id, "contentHeight"), h = await prop(app, id, "height");
  await app.inspector.send("setProperty", { objectId: id, property: "contentY", value: where === "end" ? Math.max(0, ch - h) : 0 });
}
async function evalq(app, expr) {
  const r = await app.inspector.send("evaluate", { expression: expr });
  if (r.error) throw new Error(r.error);
  return r.result;
}
const SHOTS = process.env.UI_E2E_SHOTS || "";
async function shot(app, name) {
  if (!SHOTS) return;
  const r = await app.screenshot();
  if (r.image) { const fs = await import("node:fs"); fs.mkdirSync(SHOTS, { recursive: true }); fs.writeFileSync(`${SHOTS}/${name}.png`, Buffer.from(r.image, "base64")); }
}
const wait = async (app, fn, d, o = LONG) => {
  try { await app.waitFor(fn, { ...o, description: d }); }
  catch (e) { await shot(app, "fail-" + d.replace(/[^a-z0-9]+/gi, "-")); throw e; }
};


// The schedule id an item belongs to (cards and buttons sit inside a delegate with `s`, detail uses `ds`).
async function ownerId(app, objectId) {
  const r = await app.inspector.send("evaluate", { objectId, expression:
    "(function(o){ while (o) { if (o.s !== undefined && o.s) return o.s.id; o = o.parent } return ds ? ds.id : '' })(parent)" });
  return r.result || "";
}
async function visibleMatches(app, name) {
  const r = await app.findByProperty("objectName", name);
  const out = [];
  for (const m of r.matches || []) if ((await prop(app, m.id, "visible")) === true) out.push(m.id);
  return out;
}
async function pressFor(app, name, sid) {
  for (const id of await visibleMatches(app, name)) if ((await ownerId(app, id)) === sid) return pressId(app, id, name);
  throw new Error(`no visible ${name} for ${sid.slice(0, 8)}`);
}
async function pressText(app, text) {
  const r = await app.findByProperty("text", text);
  for (const m of r.matches || []) if ((await prop(app, m.id, "visible")) === true) return pressId(app, m.id, text);
  throw new Error(`no visible "${text}"`);
}
const sched = (app, sid, expr) => evalq(app, `(function(){ var s = schedules.filter(function(x){ return x.id === '${sid}' })[0]; return s ? (${expr}) : 'none' })()`);
// Wait for the running operation to finish; fail with the human error text if it failed.
async function opFinished(app, d) {
  // A send can take minutes on a loaded box (proof, inclusion, wallet re-sync); the app says so and keeps going.
  await wait(app, async () => { if ((await evalq(app, "opRunning")) === true) throw new Error("still running after 10 min"); }, d, { timeout: 600000, interval: 2000 });
  const st = await evalq(app, "opError ? 'ERR ' + opError.title + ' | ' + opError.raw : opDone ? 'OK ' + opDone.title : 'NONE'");
  console.log(`    ${d}: ${st}`);
  if (!st.startsWith("OK")) { await shot(app, "fail-" + d.replace(/[^a-z0-9]+/gi, "-")); throw new Error(st); }
  await shot(app, d.replace(/[^a-z0-9]+/gi, "-"));
  await press(app, "opDone");
}
async function refreshed(app) { await evalq(app, "refresh(true)"); await wait(app, async () => { if ((await evalq(app, "refreshing")) === true) throw new Error("refreshing"); }, "refresh"); }
// Account rows (Paying from / My other account) carry the account id they stand for.
async function pressRow(app, name, acctId) {
  for (const id of await visibleMatches(app, name)) {
    const r = await app.inspector.send("evaluate", { objectId: id, expression: "acctId" });
    if (r.result === acctId) return pressId(app, id, `${name} ${acctId.slice(0, 6)}`);
  }
  throw new Error(`no visible ${name} for ${acctId.slice(0, 6)}`);
}
// Step 1 of Vest tokens: pick "Paying from" in the account list, like a person.
async function payFrom(app, id) {
  if ((await evalq(app, "acct ? acct.id : ''")) !== id) await pressRow(app, "fromRow", id);
  if ((await evalq(app, "acct ? acct.id : ''")) !== id) throw new Error("can't pick From " + id);
}
async function startVest(app) {
  await press(app, "newVesting");
  await wait(app, async () => { if ((await evalq(app, "page + ':' + createStep")) !== "create:1") throw new Error("not on step 1"); }, "Vest tokens step 1", { timeout: 5000, interval: 300 });
}
async function next(app, step) {
  await wait(app, async () => { const t = await prop(app, await one(app, "stepNext"), "text"); if (t !== "Continue") throw new Error(t); }, `step ${step} complete`, { timeout: 10000, interval: 300 });
  await press(app, "stepNext");
  await wait(app, async () => { if ((await evalq(app, "createStep")) !== step + 1) throw new Error("still on " + step); }, `step ${step + 1}`, { timeout: 5000, interval: 300 });
}
async function goHome(app) {
  if ((await evalq(app, "sheetMode")) !== "") await evalq(app, "closeSheet()");
  await press(app, "homeLink");
  await wait(app, async () => { if ((await evalq(app, "page")) !== "home") throw new Error("not home"); }, "home", { timeout: 5000, interval: 300 });
}
async function openSent(app, sid) {
  await goHome(app);
  await wait(app, () => pressFor(app, "sentCard", sid), "Sent card", { timeout: 60000, interval: 1000 });
  await wait(app, async () => { if ((await evalq(app, "page + ':' + (ds ? ds.id : '')")) !== "detail:" + sid) throw new Error("not on detail"); }, "detail", { timeout: 5000, interval: 300 });
}

test("ui-e2e: connect in Settings", async (app) => {
  await wait(app, () => app.expectTexts(["Vesting", "How it works", "+  Vest tokens"]), "UI", { timeout: 20000, interval: 500 });
  await wait(app, async () => {
    if ((await evalq(app, "sheetMode")) !== "settings") await press(app, "settingsButton");
    await one(app, "programField");
  }, "settings", { timeout: 15000, interval: 1000 });
  if ((await prop(app, await one(app, "programField"), "visible")) !== true) {
    const adv = await app.findByProperty("text", "▸  Advanced");
    await pressId(app, adv.matches[0].id, "Advanced");
  }
  await setText(app, "programField", PROGRAM);
  await setText(app, "walletField", WALLET);
  await setText(app, "cliField", CLI);
  const tg = await one(app, "devToggle");
  if ((await prop(app, tg, "checked")) !== true) await press(app, "devToggle");
  await press(app, "backendNative");
  await press(app, "saveSettings");
  await wait(app, async () => { if ((await evalq(app, "ready && loaded")) !== true) throw new Error("not ready: " + await evalq(app, "'setup=' + needsSetup + ' ready=' + ready + ' loaded=' + loaded + ' err=' + loadError + ' program=' + (cfg.program || '')")); }, "connected");
  await press(app, "sheetClose");
  // The app started with an empty list: everything must be found on chain by itself (no codes).
  await wait(app, async () => { if ((await evalq(app, "!!scan && scan.done === true")) !== true) throw new Error("scan " + await evalq(app, "JSON.stringify(scan)")); }, "on-chain search done");
  await refreshed(app);
  const n = await evalq(app, "incoming.length + ':' + outgoing.length");
  console.log(`    connected: incoming:outgoing = ${n} (found on chain, no codes)`);
  if (!(Number(n.split(":")[0]) > 0 && Number(n.split(":")[1]) > 0)) throw new Error("auto-discovery found nothing: " + n);
  // Wallet card: the balance is in LGO, not in trillions of raw units.
  const bal = await prop(app, await one(app, "balanceText"), "text");
  console.log(`    wallet card: ${bal}`);
  if (!/ LGO$/.test(bal) || /\d{13}/.test(bal.replace(/,/g, ""))) throw new Error("balance not in LGO: " + bal);
  await shot(app, "home");
});

let created = "";
test("ui-e2e: Vest tokens: 1 Who (my other account) -> 2 How much -> 3 Schedule -> 4 Review -> Vest, then see it as the recipient", async (app) => {
  const before = await evalq(app, "outgoing.length");
  await startVest(app);
  await payFrom(app, OTHER);
  await press(app, "toModeMine");
  await pressRow(app, "toMineRow", BEN);
  await shot(app, "vest-1-who");
  await next(app, 1);
  await setText(app, "amountField", "0.05");
  await shot(app, "vest-2-amount");
  await next(app, 2);
  await press(app, "preset_6m");
  await shot(app, "vest-3-schedule");
  await next(app, 3);
  await wait(app, async () => { const t = await prop(app, await one(app, "createConfirm"), "text"); if (t !== "Vest 0.05 LGO") throw new Error(t); }, "Vest button", { timeout: 10000, interval: 300 });
  await shot(app, "vest-4-review");
  await press(app, "createConfirm");
  await wait(app, () => app.expectTexts(["Vesting created", "Where your LGO are now"]), "vesting created");
  created = await evalq(app, "opDone && opDone.code ? opDone.code : ''");
  if (!/^vesting:/.test(created)) throw new Error(`no vesting code: ${created}`);
  const sch = await evalq(app, "opDone.created.schedule");
  console.log(`    created ${created} (vesting account ${sch})`);
  if (!sch) throw new Error("no vesting account in the result");
  await shot(app, "vesting-created");
  // The recipient is one of my accounts: one click to its side.
  await press(app, "viewAsRecipient");
  const id = created.split(":")[2];
  await wait(app, async () => { const v = await evalq(app, "page + ':' + detailRole + ':' + (ds ? ds.id : '')"); if (v !== "detail:recipient:" + id) throw new Error(v); }, "recipient view", { timeout: 120000, interval: 1000 });
  if ((await evalq(app, "ds.schedule")) !== sch) throw new Error("vesting account differs: " + await evalq(app, "ds.schedule"));
  if ((await evalq(app, "acct.id")) !== BEN) throw new Error("switched to the wrong account");
  await one(app, "detailClaim");
  await shot(app, "recipient-view");
  await goHome(app);
  await wait(app, async () => { if ((await evalq(app, "outgoing.length")) <= before) throw new Error("not listed"); }, "listed under Created by you");
});

test("ui-e2e: Claim from Home", async (app) => {
  const id = created.split(":")[2];
  await goHome(app);
  await wait(app, async () => {
    const c = await evalq(app, `(function(){ var s = incoming.filter(function(x){ return x.id === '${id}' })[0]; return s ? s.claimable : 'none' })()`);
    if (c === "none" || c === "0") throw new Error(`claimable ${c}`);
  }, "new vesting claimable");
  const before = await evalq(app, `incoming.filter(function(x){ return x.id === '${id}' })[0].claimed`);
  await wait(app, () => pressFor(app, "cardClaim", id), "claim card", { timeout: 60000, interval: 1000 });
  if ((await evalq(app, "claimTarget ? claimTarget.id : ''")) !== id) throw new Error("wrong vesting opened");
  await wait(app, async () => { const t = await prop(app, await one(app, "claimConfirm"), "text"); if (t !== "Claim") throw new Error(t); }, "quote", { timeout: 120000, interval: 1000 });
  await shot(app, "claim-review");
  await press(app, "claimConfirm");
  await wait(app, () => app.expectTexts(["Claimed!"]), "claimed");
  await shot(app, "claimed");
  await press(app, "opDone");
  await wait(app, async () => {
    const now = await evalq(app, `incoming.filter(function(x){ return x.id === '${id}' })[0].claimed`);
    if (now === before) throw new Error("claimed unchanged");
  }, "claimed amount refresh");
});

let ms = "";
test("ui-e2e: milestone vesting (transferable) -> confirm milestone 1 from Created by you", async (app) => {
  await startVest(app);
  await payFrom(app, OTHER);
  await press(app, "toModeOther");      // paste an address, like for someone else
  await setText(app, "toField", BEN);
  await next(app, 1);
  await setText(app, "amountField", "0.003");
  await next(app, 2);
  await press(app, "preset_milestones");
  await wait(app, async () => { if ((await visibleMatches(app, "msField")).length !== 2) throw new Error("fields"); }, "milestone fields", { timeout: 5000, interval: 300 });
  const f = await visibleMatches(app, "msField");
  await app.inspector.send("setProperty", { objectId: f[0], property: "text", value: "0.001" });
  await app.inspector.send("setProperty", { objectId: f[1], property: "text", value: "0.002" });
  const t = await one(app, "transferableToggle");
  if ((await prop(app, t, "visible")) !== true) await pressText(app, "▸  More options");
  await wait(app, async () => {
    if ((await evalq(app, "form.transferable")) === true) return;
    if ((await evalq(app, "sheetMode")) !== "") await evalq(app, "closeSheet()");   // a click that missed must not leave a sheet open
    await press(app, "transferableToggle");
    throw new Error("transferable still off");
  }, "transferable on", { timeout: 10000, interval: 700 });
  await next(app, 3);
  await wait(app, async () => { const x = await prop(app, await one(app, "createConfirm"), "text"); if (x !== "Vest 0.003 LGO") throw new Error(x); }, "Vest button", { timeout: 10000, interval: 300 });
  await press(app, "createConfirm");
  await wait(app, async () => { if ((await evalq(app, "opRunning")) === true) throw new Error("running"); }, "milestone create");
  ms = (await evalq(app, "opDone && opDone.code ? opDone.code : ''")).split(":")[2] || "";
  if (!ms) throw new Error("no code: " + await evalq(app, "opError ? opError.title + ' ' + opError.raw : ''"));
  console.log(`    milestone vesting ${ms.slice(0, 8)}…`);
  await refreshed(app);
  if ((await sched(app, ms, "s.transferable")) !== true) throw new Error("created without transferable");
  await press(app, "opDone");
  await openSent(app, ms);
  await shot(app, "sent-detail-milestones");
  const btns = await visibleMatches(app, "msConfirm");
  await pressId(app, btns[0], "msConfirm");
  await wait(app, () => one(app, "confirmAction"), "confirm sheet", { timeout: 5000, interval: 300 });
  await shot(app, "confirm-milestone");
  await press(app, "confirmAction");
  await opFinished(app, "milestone confirmed");
  await refreshed(app);
  if ((await sched(app, ms, "s.claimable")) !== "1000000") throw new Error("claimable " + await sched(app, ms, "s.claimable"));
});

test("ui-e2e: private claim (Receive privately) runs claim + move to private balance", async (app) => {
  const before = await evalq(app, "privAccounts.length ? privAccounts[privIndex].balance : '0'");
  await goHome(app);
  await wait(app, () => pressFor(app, "cardClaim", ms), "claim card", { timeout: 60000, interval: 1000 });
  await wait(app, async () => { const t = await prop(app, await one(app, "claimConfirm"), "text"); if (t !== "Claim") throw new Error(t); }, "public quote", { timeout: 120000, interval: 1000 });
  await press(app, "privateToggle");
  await wait(app, async () => { const t = await prop(app, await one(app, "claimConfirm"), "text"); if (t !== "Claim privately") throw new Error(t); }, "private quote", { timeout: 120000, interval: 1000 });
  await wait(app, async () => { if ((await prop(app, await one(app, "privacyDisclosure"), "visible")) !== true) throw new Error("no disclosure"); }, "privacy disclosure", { timeout: 5000, interval: 300 });
  await shot(app, "claim-review-private");
  await press(app, "claimConfirm");
  await opFinished(app, "private claim");
  await refreshed(app);
  if ((await sched(app, ms, "s.claimed")) !== "1000000") throw new Error("claimed " + await sched(app, ms, "s.claimed"));
  const after = await evalq(app, "privAccounts.length ? privAccounts[privIndex].balance : '0'");
  console.log(`    private balance ${before} -> ${after}`);
  if (after === before) throw new Error("private balance unchanged");
});

test("ui-e2e: Check for private payments (receive)", async (app) => {
  await goHome(app);
  await press(app, "receiveLink");
  await opFinished(app, "receive");
});

test("ui-e2e: Give to another account (recipient detail)", async (app) => {
  await goHome(app);
  await wait(app, () => pressFor(app, "cardDetails", ms), "details", { timeout: 30000, interval: 1000 });
  await setText(app, "giveField", OTHER);
  await press(app, "giveButton");
  await wait(app, () => one(app, "confirmAction"), "confirm sheet", { timeout: 5000, interval: 300 });
  await shot(app, "confirm-give");
  await press(app, "confirmAction");
  await opFinished(app, "given away");
  await refreshed(app);
  if ((await sched(app, ms, "s.beneficiary")) !== OTHER) throw new Error("beneficiary " + await sched(app, ms, "s.beneficiary"));
});

test("ui-e2e: Make permanent (Created by you → Manage)", async (app) => {
  const lin = created.split(":")[2];
  await openSent(app, lin);
  await press(app, "makePermanent");
  await wait(app, () => one(app, "confirmAction"), "confirm sheet", { timeout: 5000, interval: 300 });
  await press(app, "confirmAction");
  await opFinished(app, "made permanent");
  await refreshed(app);
  if ((await sched(app, lin, "s.cancelable")) !== false) throw new Error("still cancelable");
});

test("ui-e2e: Stop vesting (Created by you → Manage)", async (app) => {
  await openSent(app, ms);
  await press(app, "stopVesting");
  await wait(app, () => one(app, "confirmAction"), "confirm sheet", { timeout: 5000, interval: 300 });
  await shot(app, "confirm-stop");
  await press(app, "confirmAction");
  await opFinished(app, "stopped");
  await refreshed(app);
  if ((await sched(app, ms, "!!s.cancelled")) !== true) throw new Error("not stopped");
});

test("ui-e2e: Send to many people (batch)", async (app) => {
  const before = await evalq(app, "outgoing.length");
  await startVest(app);
  await payFrom(app, OTHER);
  await press(app, "bulkLink");
  await setText(app, "bulkArea", `${BEN}, 0.001\n${OTHER},0.002`);
  await wait(app, async () => { const x = await prop(app, await one(app, "bulkReview"), "text"); if (x !== "Review") throw new Error(x); }, "bulk Review enabled", { timeout: 10000, interval: 300 });
  await shot(app, "bulk");
  await press(app, "bulkReview");
  await wait(app, () => one(app, "bulkConfirm"), "bulk review", { timeout: 5000, interval: 300 });
  await press(app, "bulkConfirm");
  await opFinished(app, "batch created");
  await refreshed(app);
  const after = await evalq(app, "outgoing.length");
  if (after !== before + 2) throw new Error(`outgoing ${before} -> ${after}`);
});

run();
