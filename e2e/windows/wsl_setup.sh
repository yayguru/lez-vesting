#!/bin/bash
# Run as: wsl -d Ubuntu -u root -- bash /mnt/c/Users/USER/lgxtest/wsl_setup.sh <linuxuser>
# Installs the LEZ rc3 sequencer/wallet/vesting CLI + r0vm into /opt/vest and wrappers into /usr/local/bin.
set -e
U=${1:-root}
mkdir -p /opt/vest && tar xzf /mnt/c/Users/USER/lgxtest/wslbundle.tgz -C /opt/vest
chmod +x /opt/vest/bin/*
cp /opt/vest/lib/libpcsclite.so.1 /usr/local/lib/ && ldconfig
ln -sf /opt/vest/bin/r0vm /usr/local/bin/r0vm
for b in vesting wallet sequencer_service; do ln -sf /opt/vest/bin/$b /usr/local/bin/$b; done
H=$(getent passwd $U | cut -d: -f6); mkdir -p $H/vest && chown $U: $H/vest
for b in vesting wallet sequencer_service r0vm; do ldd /usr/local/bin/$b | grep -q "not found" && echo "MISSING LIB for $b"; done
echo "installed for $U home $H"
