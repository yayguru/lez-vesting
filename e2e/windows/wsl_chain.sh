#!/bin/bash
# Run as the WSL user: sets up + starts a standalone rc3 sequencer, wallet, deploys vesting. Never prints keys.
set -e
V=$HOME/vest; cd $V
FK=2e03b2eff5a45478e7e79668d2a146cf2c5c7925bce927f2b1c67f2ab4fc0d26   # public dev funding key (rc3 Justfile)
[ -f seqhome/sequencer_config.json ] || sequencer_service setup $V/seqhome --config /opt/vest/cfg/local.json --funding-public-key $FK --create-channel > setup.log 2>&1
if ! pgrep -f "sequencer_service start" >/dev/null; then
  RISC0_DEV_MODE=1 RUST_LOG=info,risc0_zkvm=warn,kameo=warn setsid nohup sequencer_service start $V/seqhome --rpc-listen-address 127.0.0.1:3040 > seq.log 2>&1 < /dev/null &
  sleep 8
fi
pgrep -f "sequencer_service start" >/dev/null && echo "sequencer up"
export LEE_WALLET_HOME_DIR=$V/wallet LEE_WALLET_PASSWORD= RISC0_DEV_MODE=1
mkdir -p $LEE_WALLET_HOME_DIR; chmod 700 $LEE_WALLET_HOME_DIR
[ -f $LEE_WALLET_HOME_DIR/wallet_config.json ] || echo '{"sequencer": {"sequencer_addr": "http://127.0.0.1:3040"}, "seq_poll_timeout": "30s", "seq_tx_poll_max_blocks": 15, "seq_poll_max_retries": 10, "seq_block_poll_max_amount": 100}' > $LEE_WALLET_HOME_DIR/wallet_config.json
if [ ! -f $V/accounts.done ]; then
  wallet account list > init.log 2>&1 || true; chmod 600 init.log
  python3 - <<'PY'
import re, subprocess
src = open('/opt/vest/cfg/initial_state_lib.rs').read()
for name in ('PRIVATE_KEY_PUB_ACC_A', 'PRIVATE_KEY_PUB_ACC_B'):
    body = re.search(name + r': \[u8; 32\] = \[(.*?)\];', src, re.S).group(1)
    key = bytes(int(x) for x in re.findall(r'\d+', body)).hex()
    r = subprocess.run(['wallet', 'account', 'import', 'public', '--private-key', key], capture_output=True, text=True)
    print(name, 'rc', r.returncode, (r.stdout + r.stderr).replace(key, '<redacted>').strip()[-160:])
PY
  touch $V/accounts.done
fi
echo "--- accounts (public ids only)"; vesting --json accounts 2>/dev/null | head -c 2000; echo
