#!/usr/bin/env bash
# Pin the LEZ (logos-execution-zone) version used by the whole build.
#   scripts/set-lez-tag.sh            # re-apply LEZ_TAG to Cargo.toml (no-op if in sync)
#   scripts/set-lez-tag.sh v0.4.0     # bump: writes LEZ_TAG, rewrites the pin, updates Cargo.lock
#   scripts/set-lez-tag.sh --check    # exit 1 if Cargo.toml and LEZ_TAG disagree (CI)
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--check" ]; then
  want=$(cat LEZ_TAG)
  bad=$(grep 'logos-execution-zone' Cargo.toml | grep -v "tag = \"$want\"" || true)
  [ -z "$bad" ] || { echo "Cargo.toml LEZ pin differs from LEZ_TAG ($want):"; echo "$bad"; exit 1; }
  echo "LEZ pin consistent: $want"; exit 0
fi
[ -n "${1:-}" ] && echo "$1" > LEZ_TAG
tag=$(cat LEZ_TAG)
if ! grep 'logos-execution-zone' Cargo.toml | grep -qv "tag = \"$tag\""; then
  echo "LEZ already pinned to $tag (Cargo.toml and Cargo.lock unchanged)"; exit 0
fi
sed -i -E "s#(logos-execution-zone\", tag = \")[^\"]+#\1$tag#" Cargo.toml
cargo update -p lee -p lee_core -p wallet -p common -p sequencer_service_rpc -p system_accounts -p test_guest_core >/dev/null 2>&1 || cargo generate-lockfile
echo "LEZ pinned to $tag"
