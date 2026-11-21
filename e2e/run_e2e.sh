#!/usr/bin/env bash
# End-to-end test of the vesting program against a standalone LEZ sequencer (mock Bedrock).
#
#   e2e/run_e2e.sh                     # dev-mode proofs (RISC0_DEV_MODE=1), what CI runs
#   E2E_REAL_PROOFS=1 e2e/run_e2e.sh   # real RISC Zero proofs (needs ~RAM, see README)
#
# Env: LEZ_DIR (LEZ checkout; default .lez/<LEZ_TAG>, cloned if missing), E2E_PORT (3040),
# E2E_WORK (scratch dir; default mktemp), E2E_OUT (results; default e2e/out),
# E2E_UI=1 (also drive the mini-app UI against the same chain: logos/vesting_ui/tests/ui-e2e.mjs).
# Builds the pinned LEZ sequencer_service (standalone) + wallet, and our vesting CLI. Never
# prints key material: the wallet's init output goes to a 0600 file in the scratch dir.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=$(cat "$ROOT/LEZ_TAG")
LEZ_URL=https://github.com/logos-blockchain/logos-execution-zone
LEZ_DIR=${LEZ_DIR:-$ROOT/.lez/$TAG}
PORT=${E2E_PORT:-3040}
OUT=${E2E_OUT:-$ROOT/e2e/out}
WORK=${E2E_WORK:-$(mktemp -d)}
mkdir -p "$OUT" "$WORK"
FUNDING_KEY=2e03b2eff5a45478e7e79668d2a146cf2c5c7925bce927f2b1c67f2ab4fc0d26 # public local-devnet Bedrock key (LEZ README)
if [ "${E2E_REAL_PROOFS:-0}" = 1 ]; then unset RISC0_DEV_MODE; MODE=real; else export RISC0_DEV_MODE=1; MODE=dev; fi
log() { printf '\n== %s\n' "$*"; }

log "LEZ $TAG -> $LEZ_DIR"
[ -d "$LEZ_DIR/.git" ] || git clone -q --depth 1 --branch "$TAG" "$LEZ_URL" "$LEZ_DIR"
(cd "$LEZ_DIR" && cargo build --release -q -p sequencer_service --features sequencer_service/standalone -p wallet)
SEQ=$LEZ_DIR/target/release/sequencer_service
WALLET=$LEZ_DIR/target/release/wallet
log "vesting CLI"
(cd "$ROOT" && cargo build --release -q -p vesting_cli)
VESTING=$ROOT/target/release/vesting

log "standalone sequencer on 127.0.0.1:$PORT ($MODE proofs, scratch $WORK)"
if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then echo "port $PORT is busy; set E2E_PORT"; exit 1; fi
METRICS_PORT=${E2E_METRICS_PORT:-$((PORT + 1))}
python3 - "$LEZ_DIR/lez/sequencer/service/networks/local.json" "$WORK/seq_config.json" "$METRICS_PORT" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["metrics_listen_address"] = f"127.0.0.1:{sys.argv[3]}"
json.dump(c, open(sys.argv[2], "w"), indent=1)
PY
rm -rf "$WORK/seq" "$WORK/wallet"   # fresh chain and wallet on every run
"$SEQ" setup "$WORK/seq" --config "$WORK/seq_config.json" \
  --funding-public-key $FUNDING_KEY --create-channel > "$WORK/seq_setup.log" 2>&1
chmod -R go-rwx "$WORK"
RUST_LOG=info,risc0_zkvm=warn,kameo=warn "$SEQ" start "$WORK/seq" --rpc-listen-address 127.0.0.1:$PORT > "$WORK/seq.log" 2>&1 &
SEQ_PID=$!
trap 'kill $SEQ_PID 2>/dev/null || true' EXIT

export LEE_WALLET_HOME_DIR=$WORK/wallet LEE_WALLET_PASSWORD=
mkdir -p "$LEE_WALLET_HOME_DIR"; chmod 700 "$LEE_WALLET_HOME_DIR"
cat > "$LEE_WALLET_HOME_DIR/wallet_config.json" <<JSON
{"sequencer": {"sequencer_addr": "http://127.0.0.1:$PORT"}, "seq_poll_timeout": "30s",
 "seq_tx_poll_max_blocks": 15, "seq_poll_max_retries": 10, "seq_block_poll_max_amount": 100}
JSON
for i in $(seq 1 60); do
  kill -0 $SEQ_PID 2>/dev/null || { echo "sequencer exited:"; tail -5 "$WORK/seq.log"; exit 1; }
  "$WALLET" check-health > "$WORK/health.log" 2>&1 && break; sleep 2
done
"$WALLET" account list > "$WORK/wallet_init.log" 2>&1 || true; chmod 600 "$WORK/wallet_init.log"
python3 - "$LEZ_DIR" "$WALLET" <<'PY'
import re, subprocess, sys
src = open(sys.argv[1] + '/lez/testnet_initial_state/src/lib.rs').read()
for name in ('PRIVATE_KEY_PUB_ACC_A', 'PRIVATE_KEY_PUB_ACC_B'):   # public local-devnet genesis keys
    body = re.search(name + r': \[u8; 32\] = \[(.*?)\];', src, re.S).group(1)
    key = bytes(int(x) for x in re.findall(r'\d+', body)).hex()
    r = subprocess.run([sys.argv[2], 'account', 'import', 'public', '--private-key', key], capture_output=True, text=True)
    if r.returncode: sys.exit(f'import {name} failed: ' + (r.stdout + r.stderr).replace(key, '<redacted>')[-300:])
PY
"$WALLET" account new private > /dev/null 2>&1

# --- helpers --------------------------------------------------------------------------------------
P=""
v() { "$VESTING" --json ${P:+--program $P} "$@"; }
# j EXPR: evaluates a python expression over the last JSON (variable d) and prints it.
j() { python3 -c "import json,sys; d=json.load(open('$WORK/last.json')); print($1)"; }
run() { v "$@" > "$WORK/last.json" 2> "$WORK/last.err" || { echo "FAILED: vesting $*"; cat "$WORK/last.json" "$WORK/last.err" | tail -20; exit 1; }; }
expect_err() { local code=$1; shift; if v "$@" > "$WORK/last.json" 2> "$WORK/last.err"; then echo "expected $code from: vesting $*"; exit 1; fi
  grep -q "$code" "$WORK/last.json" || { echo "expected $code, got: $(cat "$WORK/last.json")"; exit 1; }; echo "  ok: $code ($(j 'd["error"][:110]'))"; }
COSTS=$WORK/costs.jsonl; : > "$COSTS"
cost() { local op=$1; shift; run "$@" --dry-run; python3 -c "import json; d=json.load(open('$WORK/last.json')); print(json.dumps({'op': '$op', 'cycles': d.get('cycles'), 'wire_bytes': d.get('wire_bytes'), 'fee': d.get('fee_estimate')}))" >> "$COSTS"; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

run accounts
CREATOR=$(j 'd["public"][0]["id"]'); BEN=$(j 'd["public"][1]["id"]'); PRIV=$(j 'd["private"][0]["id"]')
log "accounts: creator $CREATOR, beneficiary $BEN, private (beneficiary's) $PRIV"

log "deploy program"
"$VESTING" write-elf "$WORK/vesting.bin" > /dev/null
IMAGE_ID=$("$VESTING" --json image-id | python3 -c 'import json,sys; print(json.load(sys.stdin)["image_id"])')
HEADER=$("$WALLET" account new public 2>&1 | grep -o 'Public/[1-9A-HJ-NP-Za-km-z]\{32,44\}' | head -1)
SEGS=()
for n in $(seq 1 16); do
  SEGS+=("$("$WALLET" account new public 2>&1 | grep -o 'Public/[1-9A-HJ-NP-Za-km-z]\{32,44\}' | head -1)")
  if "$WALLET" program-loader deploy --dry-run --elf "$WORK/vesting.bin" --header "$HEADER" --segments "${SEGS[@]}" --payer "Public/$CREATOR" > "$WORK/deploy_dry.log" 2>&1; then break; fi
done
"$WALLET" program-loader deploy --elf "$WORK/vesting.bin" --header "$HEADER" --segments "${SEGS[@]}" --payer "Public/$CREATOR" > "$WORK/deploy.log" 2>&1
P=${HEADER#Public/}
echo "  program $P (image id $IMAGE_ID, ${#SEGS[@]} segments)"

log "fund the private account (shield 60,000,000 from the beneficiary)"
"$WALLET" auth-transfer send --from "Public/$BEN" --to "Private/$PRIV" --amount 60000000 > "$WORK/shield.log" 2>&1
run accounts; PRIV0=$(j "[a['balance'] for a in d['private'] if a['id']=='$PRIV'][0]"); echo "  private balance $PRIV0"

T=$(now_ms)
log "linear cliff schedule: create, public claim, transfer beneficiary"
L=$(python3 -c 'import os; print(os.urandom(32).hex())')
cost create create --creator $CREATOR --beneficiary $BEN --total 1000000 --id $L --linear $((T-60000)),$((T-30000)),$((T+3600000)) --transferable
run create --creator $CREATOR --beneficiary $BEN --total 1000000 --id $L --linear $((T-60000)),$((T-30000)),$((T+3600000)) --transferable
run show --creator $CREATOR --id $L; echo "  claimable $(j 'd["claimable"]'), locked $(j 'd["locked"]')"
cost claim_public claim --beneficiary $BEN --creator $CREATOR --id $L
run claim --beneficiary $BEN --creator $CREATOR --id $L
run show --creator $CREATOR --id $L; [ "$(j 'int(d["claimed"])>0')" = True ] || { echo "public claim paid nothing"; exit 1; }
echo "  claimed $(j 'd["claimed"]')"
NEWBEN=$("$WALLET" account new public 2>&1 | grep -o 'Public/[1-9A-HJ-NP-Za-km-z]\{32,44\}' | head -1); NEWBEN=${NEWBEN#Public/}
cost transfer transfer-beneficiary --beneficiary $BEN --creator $CREATOR --id $L --new-beneficiary $NEWBEN
run transfer-beneficiary --beneficiary $BEN --creator $CREATOR --id $L --new-beneficiary $NEWBEN
run show --creator $CREATOR --id $L; [ "$(j 'd["beneficiary"]')" = "$NEWBEN" ] || { echo "transfer failed"; exit 1; }
expect_err V009 claim --beneficiary $BEN --creator $CREATOR --id $L

log "milestone schedule: errors, signal, private claim + receive, cancel"
M=$(python3 -c 'import os; print(os.urandom(32).hex())')
run create --creator $CREATOR --beneficiary $BEN --total 1000000 --id $M --milestones 400000,600000
expect_err V011 claim --beneficiary $BEN --creator $CREATOR --id $M
cost signal signal --creator $CREATOR --id $M --index 0
run signal --creator $CREATOR --id $M --index 0
expect_err V015 signal --creator $CREATOR --id $M --index 0
expect_err V023 claim --beneficiary $BEN --creator $CREATOR --id $M --private $BEN
cost claim_private claim --beneficiary $BEN --creator $CREATOR --id $M --private $PRIV
run accounts; PRIV1=$(j "[a['balance'] for a in d['private'] if a['id']=='$PRIV'][0]")
/usr/bin/time -v -o "$WORK/claim_private.time" "$VESTING" --json --program $P claim --beneficiary $BEN --creator $CREATOR --id $M --private $PRIV > "$WORK/last.json" 2> "$WORK/last.err" || { cat "$WORK/last.json"; exit 1; }
echo "  private claim tx $(j 'd["tx"]') in block $(j 'd["block"]')"
/usr/bin/time -v -o "$WORK/receive.time" "$VESTING" --json --program $P receive > "$WORK/last.json" 2> "$WORK/last.err" || { cat "$WORK/last.json"; exit 1; }
NREC=$(j 'len(d["received"])'); echo "  received $NREC payout(s)"
[ "$NREC" = 1 ] || { echo "expected exactly 1 payout (fee refunds must be skipped)"; exit 1; }
run accounts; PRIV2=$(j "[a['balance'] for a in d['private'] if a['id']=='$PRIV'][0]")
python3 - "$PRIV1" "$PRIV2" <<'PY'
import sys; b1, b2 = int(sys.argv[1]), int(sys.argv[2])
fees = b1 + 400000 - b2
print(f"  private balance {b1} -> {b2} (+400000 payout, fees {fees})")
assert 0 < fees < 2 * 9_000_000, "fees outside two private-fee reserves"
PY
cost cancel cancel --creator $CREATOR --id $M
run cancel --creator $CREATOR --id $M
run show --creator $CREATOR --id $M
[ "$(j 'd["cancelled"] is not None and d["escrow"]=="0"')" = True ] || { echo "cancel did not return the unvested 600000"; exit 1; }
expect_err V013 cancel --creator $CREATOR --id $M

log "non-cancelable conversion"
I=$(python3 -c 'import os; print(os.urandom(32).hex())')
run create --creator $CREATOR --beneficiary $BEN --total 1000 --id $I --linear $((T-1000)),$((T-1000)),$((T+600000))
cost make_irrevocable irrevocable --creator $CREATOR --id $I
run irrevocable --creator $CREATOR --id $I
expect_err V012 cancel --creator $CREATOR --id $I

log "fee payer without gas: actionable error, nothing sent"
POOR=$("$WALLET" account new public 2>&1 | grep -o 'Public/[1-9A-HJ-NP-Za-km-z]\{32,44\}' | head -1); POOR=${POOR#Public/}
F=$(python3 -c 'import os; print(os.urandom(32).hex())')
run create --creator $CREATOR --beneficiary $POOR --total 100 --id $F --milestones 100
run signal --creator $CREATOR --id $F --index 0
expect_err V020 claim --beneficiary $POOR --creator $CREATOR --id $F
expect_err V020 claim --dry-run --beneficiary $POOR --creator $CREATOR --id $F
run show --creator $CREATOR --id $F; [ "$(j 'd["claimed"]')" = 0 ] || { echo "failed claim changed state"; exit 1; }

log "batch creation"
python3 - "$BEN" "$NEWBEN" "$T" "$WORK" <<'PY'
import json, sys
b, nb, t, w = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
small = [{"beneficiary": x, "total": "1000", "linear": [t, t, t + 86400000]} for x in (b, nb, b)]
json.dump(small, open(w + '/batch3.json', 'w'))
PY
MAXB=$(grep -o 'MAX_BATCH_RECIPIENTS: usize = [0-9]*' "$ROOT/core/src/lib.rs" | grep -o '[0-9]*$')
python3 -c "
import json; t=$T
json.dump([{'beneficiary':'$BEN','total':'1','linear':[t,t,t+1]} for _ in range($MAXB)], open('$WORK/batchmax.json','w'))
json.dump([{'beneficiary':'$BEN','total':'1','linear':[t,t,t+1]} for _ in range($MAXB+1)], open('$WORK/batchover.json','w'))"
cost create_batch_3 create-batch --creator $CREATOR --file "$WORK/batch3.json"
run create-batch --creator $CREATOR --file "$WORK/batch3.json"; echo "  3 schedules in block $(j 'd["block"]')"
run create-batch --dry-run --creator $CREATOR --entries-hex "$(python3 -c "print(open('$WORK/batch3.json','rb').read().hex())")"
cost create_batch_max create-batch --creator $CREATOR --file "$WORK/batchmax.json"
echo "  batch of $MAXB fits: dry-run ok on the sequencer"
expect_err V024 create-batch --creator $CREATOR --file "$WORK/batchover.json"
run list; [ "$(j 'len(d["schedules"])')" -ge 6 ] || { echo "list misses schedules"; exit 1; }

log "auto-discovery: a vesting appears in the recipient's own wallet with no code"
W2=$WORK/wallet2; mkdir -p "$W2"; chmod 700 "$W2"; cp "$LEE_WALLET_HOME_DIR/wallet_config.json" "$W2/"
LEE_WALLET_HOME_DIR=$W2 "$WALLET" account list > "$WORK/wallet2_init.log" 2>&1 || true; chmod 600 "$WORK/wallet2_init.log"
R2=$(LEE_WALLET_HOME_DIR=$W2 "$WALLET" account new public 2>&1 | grep -o 'Public/[1-9A-HJ-NP-Za-km-z]\{32,44\}' | head -1); R2=${R2#Public/}
D=$(python3 -c 'import os; print(os.urandom(32).hex())')
run create --creator $CREATOR --beneficiary $R2 --total 5000 --id $D --linear $((T-1000)),$((T-1000)),$((T+600000))
LEE_WALLET_HOME_DIR=$W2 "$VESTING" --json --program $P list > "$WORK/last.json" 2> "$WORK/last.err" || { cat "$WORK/last.json"; exit 1; }
[ "$(j "[s['beneficiary'] for s in d['schedules'] if s['id']=='$D'] == ['$R2'] and d['scan']['found'] >= 1 and d['scan']['done']")" = True ] \
  || { echo "recipient wallet did not discover the vesting: $(j 'd.get("scan"), len(d["schedules"])')"; exit 1; }
echo "  recipient wallet found it by itself (scanned to block $(j 'd["scan"]["next"]-1'), $(j 'd["scan"]["found"]') new)"
LEE_WALLET_HOME_DIR=$W2 "$VESTING" --json --program $P list > "$WORK/last.json" 2> "$WORK/last.err" || { cat "$WORK/last.json"; exit 1; }
[ "$(j "d['scan']['found'] == 0 and len(d['schedules']) == 1")" = True ] || { echo "second scan not idempotent"; exit 1; }
run accounts; [ "$(j 'd["network"]["kind"]')" = local ] || { echo "network kind: $(j 'd["network"]')"; exit 1; }

log "audit: every submitted tx is on chain (vesting txs)"
LAST=$(python3 -c "import json; print(max(json.loads(l)['block'] or 0 for l in open('$LEE_WALLET_HOME_DIR/vesting_txlog.jsonl')))")
run txs --from 1 --to $LAST
python3 - "$WORK/last.json" "$LEE_WALLET_HOME_DIR/vesting_txlog.jsonl" <<'PY'
import json, sys
chain = {t['hash'] for b in json.load(open(sys.argv[1]))['blocks'] for t in b['txs']}
log = [json.loads(l) for l in open(sys.argv[2])]
missing = [l['tx'] for l in log if l['tx'] not in chain]
print(f"  {len(log)} logged txs, {len(log)-len(missing)} found on chain")
assert not missing, missing
PY

python3 - "$COSTS" "$OUT/costs_$MODE.json" "$WORK" "$IMAGE_ID" "$TAG" <<'PY'
import json, re, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
def peak(f):
    try:
        t = open(f).read()
        return {"max_rss_mb": int(re.search(r'Maximum resident set size \(kbytes\): (\d+)', t).group(1)) // 1024,
                "wall": re.search(r'Elapsed \(wall clock\) time.*: (.+)', t).group(1)}
    except Exception: return None
out = {"lez_tag": sys.argv[5], "image_id": sys.argv[4], "ops": rows,
       "claim_private": peak(sys.argv[3] + '/claim_private.time'), "receive": peak(sys.argv[3] + '/receive.time')}
json.dump(out, open(sys.argv[2], 'w'), indent=1)
print(json.dumps(out, indent=1))
PY
if [ "${E2E_UI:-0}" = 1 ]; then
  log "mini-app UI e2e (real module + CLI, clicks through every flow: settings, create, milestones, private claim + receive, give away, make permanent, stop, batch)"
  UI=$ROOT/logos/vesting_ui
  # the inspector port must be free, or the test would drive some other running app instance
  if (exec 3<>/dev/tcp/127.0.0.1/3768) 2>/dev/null; then echo "port 3768 (UI inspector) is busy: close the other logos-standalone-app"; exit 1; fi
  (cd "$UI" && [ -x result-dev/bin/run-logos-standalone-ui ] || nix build .#ui-dev -o result-dev)
  # Start the app from an empty vesting list: everything it shows must be found on chain by itself.
  rm -f "$LEE_WALLET_HOME_DIR/vesting_$P.json" "$LEE_WALLET_HOME_DIR/vesting_${P}_scan.json"
  (cd "$UI" && VESTING_PROGRAM=$P VESTING_CLI=$VESTING E2E_BEN=$BEN E2E_CREATOR=$CREATOR QT_QUICK_BACKEND=software \
     env -u DISPLAY node tests/ui-e2e.mjs --ci ./result-dev/bin/run-logos-standalone-ui)
fi
log "E2E PASSED ($MODE proofs, LEZ $TAG)"
