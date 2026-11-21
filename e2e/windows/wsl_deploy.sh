#!/bin/bash
# Deploys vesting.bin with fresh header/segment accounts and funds a private account. Prints public ids/txids only.
set -e
V=$HOME/vest; cd $V
export LEE_WALLET_HOME_DIR=$V/wallet LEE_WALLET_PASSWORD= RISC0_DEV_MODE=1
CREATOR=6iArKUXxhUJqS7kCaPNhwMWt3ro71PDyBj7jwAyE2VQV; BEN=7wHg9sbJwc6h3NP1S9bekfAzB8CHifEcxKswCKUt3YQo
if [ ! -f deploy.txt ]; then
  ids=()
  for i in 1 2 3 4 5; do
    id=$(wallet account new public 2>&1 | grep -o 'Public/[1-9A-HJ-NP-Za-km-z]\{32,44\}' | head -1); ids+=("$id")
  done
  printf '%s\n' "${ids[@]}" > deploy.txt
  echo "header ${ids[0]}"
  wallet program-loader deploy --elf /opt/vest/cfg/vesting.bin --header ${ids[0]} --segments ${ids[1]} ${ids[2]} ${ids[3]} ${ids[4]} --payer Public/$CREATOR 2>&1 | tail -8
fi
P=$(head -1 deploy.txt | cut -d/ -f2); echo "PROGRAM $P"; echo $P > program.txt
PRIV=$(vesting --json accounts 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['private'][0]['id'])")
echo "PRIVATE $PRIV"
if [ ! -f shield.done ]; then
  wallet auth-transfer send --from Public/$BEN --to Private/$PRIV --amount 60000000 2>&1 | tail -4; touch shield.done
fi
vesting --json --program $P accounts 2>/dev/null
