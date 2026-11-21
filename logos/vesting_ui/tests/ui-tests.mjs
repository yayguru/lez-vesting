import { resolve } from "node:path";
const root = process.env.LOGOS_QT_MCP || new URL("../result-mcp", import.meta.url).pathname;
const { test, run } = await import(resolve(root, "test-framework/framework.mjs"));

// Runs against the real vesting_module in the standalone host. With no wallet/program configured
// the app must land in a clear "Finish setup" or "Can't …" state, never a blank or broken screen.

test("vesting_ui: loads with the main navigation", async (app) => {
  await app.waitFor(async () => { await app.expectTexts(["Vesting", "How it works", "+  Vest tokens"]); },
    { timeout: 20000, interval: 500, description: "UI to load" });
});

test("vesting_ui: shows a setup or connection state, not a blank screen", async (app) => {
  await app.waitFor(async () => {
    try { await app.expectTexts(["Finish setup", "Open settings"]); }
    catch { await app.expectTexts(["Try again", "Settings"]); }
  }, { timeout: 30000, interval: 500, description: "setup or error card" });
});

test("vesting_ui: How it works explains every word", async (app) => {
  await app.click("How it works");
  await app.waitFor(async () => {
    await app.expectTexts(["How vesting works", "Words used here", "Vesting", "Unlock", "Claim", "Waiting period (cliff)", "Network cost", "Vesting code", "Vesting account", "Public / private account"]);
  }, { timeout: 5000, interval: 300, description: "help sheet" });
  await app.click("✕");
});

test("vesting_ui: Vest tokens is a 4-step stepper", async (app) => {
  await app.click("+  Vest tokens");
  await app.waitFor(async () => {
    await app.expectTexts(["Vest tokens", "Who", "How much", "Schedule", "Review", "Paying from", "Sending to", "My other account", "Someone else",
                           "How much to vest", "LGO", "How it unlocks", "1 year · first unlock after 3 months", "When I confirm milestones", "Custom", "Send to many people"]);
  }, { timeout: 5000, interval: 300, description: "vest stepper" });
});

test("vesting_ui: Settings sheet", async (app) => {
  await app.click("⚙");
  await app.waitFor(async () => { await app.expectTexts(["Settings", "Vesting program address", "Wallet folder", "Save", "About", "Vesting 0.3.0 (2026-11-21) · RFP-017 prototype for LEZ 0.4"]); },
    { timeout: 5000, interval: 300, description: "settings sheet" });
});

run();
