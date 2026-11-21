#!/usr/bin/env bash
# Everything CI checks, in order. Run locally the same way: scripts/ci.sh
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/set-lez-tag.sh --check
echo "== IDL is up to date"; (cd idl && python3 gen_idl.py >/dev/null) && git diff --exit-code -- idl/vesting.spel.json
echo "== build (release CLI)"; cargo build --release --locked -p vesting_cli
echo "== unit + on-chain tests"; RISC0_DEV_MODE=1 cargo test --locked --workspace -- --nocapture
echo "== e2e against a standalone sequencer"; e2e/run_e2e.sh
