# Logos integration (RFP-017 prototype)

Two modules:

- `vesting_module/` — universal core module (Qt-free C++). It drives the `vesting` CLI
  (`../cli`, LEZ 0.4.0-rc3 wallet) as a subprocess with `--json`, so keys and proving stay in the
  wallet. Methods: `getConfig`, `setConfig(json)`, `accounts`, `listSchedules`, `show`, `track`,
  `quoteClaim` (pre-claim summary: amount, fee estimate, fee payer + balance, privacy disclosure),
  and the sending calls `create`, `claim`, `cancel`, `signalMilestone`, `receivePending`. Sending
  calls return `{"ok":true,"pending":true,"job":"N"}` at once; poll `jobResult(N)` (a bridge call
  times out after 20 s, proving and inclusion take longer). One CLI runs at a time, since every run
  rewrites the wallet storage; reads give up after 12 s with `V022 busy`.
- `vesting_ui/` — QML-only Basecamp mini-app (no compiled code, so it runs on any platform that
  has the module). Tabs: Receiving (position, locked, claimable, next unlock, public or private
  claim with a confirmation summary, receive private payouts), Created (cancel, signal
  milestones), New schedule, Settings (program id, wallet home, CLI path, dev-mode proofs).

Errors keep the program's codes (`V0xx …`); the CLI adds V020 (fee payer cannot pay),
V021 (not included: refused at settlement) and the module V022 (busy).

## Build and run (Linux, box)

```sh
cp ../target/release/vesting vesting_module/bin/            # cargo build --release -p vesting_cli
nix build path:$PWD/vesting_module                          # plugin + bundled CLI
cd vesting_ui && nix flake update vesting_module --flake path:$PWD
nix build path:$PWD#ui-dev -o result-dev && ./result-dev/bin/run-logos-standalone-ui
```

Settings are stored in the module's instance data dir (`vesting_module.json`).
