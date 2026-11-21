#!/usr/bin/env bash
# Build/runtime prerequisites on Debian/Ubuntu (tested: Ubuntu 24.04, Debian 13).
#   scripts/install-deps.sh
# - system packages for the LEZ wallet/sequencer crates (clang for rocksdb, OpenSSL, PC/SC)
# - Rust via rustup (the channel in rust-toolchain.toml is picked up automatically)
# - RISC Zero: rzup + the guest Rust toolchain, cargo-risczero and r0vm 3.0.x
set -euo pipefail
R0_VERSION=${R0_VERSION:-3.0.6}
SUDO=$([ "$(id -u)" = 0 ] && echo "" || echo sudo)
if command -v apt-get >/dev/null; then
  $SUDO apt-get update -q
  $SUDO apt-get install -y -q build-essential clang libclang-dev pkg-config libssl-dev \
    libpcsclite-dev git curl unzip python3 time
fi
command -v rustup >/dev/null || { curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none; }
export PATH=$HOME/.cargo/bin:$HOME/.risc0/bin:$PATH
command -v rzup >/dev/null || { curl -sSfL https://risczero.com/install | bash; }
rzup install rust
rzup install cargo-risczero "$R0_VERSION"
rzup install r0vm "$R0_VERSION"
rzup show
echo "Add to your shell: export PATH=\$HOME/.cargo/bin:\$HOME/.risc0/bin:\$PATH"
