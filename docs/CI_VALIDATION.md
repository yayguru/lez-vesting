# CI validation (local, 20.11.2026, CET)

The workflow `.github/workflows/ci.yml` was checked without pushing:

- **Syntax:** `actionlint` 1.7.7 reports no findings.
- **`pinned` job:** it runs `scripts/install-deps.sh`, then `scripts/ci.sh`:
  1. `set-lez-tag.sh --check`
  2. the IDL drift check
  3. `cargo build --locked`
  4. `RISC0_DEV_MODE=1 cargo test --workspace`
  5. `e2e/run_e2e.sh`

  The same steps ran on the box, where e2e passed at 20:50 (`e2e/RESULTS.md`). They also ran in a clean
  `ubuntu:24.04` container from a fresh `git clone` (see "Clean clone" in `e2e/RESULTS.md`). That
  run found the missing `unzip` dependency, which is now fixed in `install-deps.sh`.
- **`lez-latest` canary:** the newest v0.4.x tag today is `v0.4.0-rc3`, the same as the pin, so the
  canary currently builds the pinned version. `scripts/set-lez-tag.sh <tag>` was tried with `v0.4.0-rc2` in a
  scratch clone:
  - `LEZ_TAG` and all 7 Cargo.toml pins were rewritten and `--check` passed;
  - dependency resolution then failed, because rc2 pins risc0 2.2.x. That is exactly the kind of incompatibility the
    non-blocking canary is meant to surface.
- **Not done:** a run on GitHub-hosted runners, because nothing is pushed. Two things to watch on the first push:
  - job time (cold build ~1 h);
  - disk: the job frees ~20 GB before building.
