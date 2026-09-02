# Tests

A small, offline regression net. No Docker or running environment required.

## Run

```bash
bash misc/tests/run.sh
```

This runs:

- **Bash syntax checks** (`bash -n`) over **every tracked `.sh`** in the repo
  (discovered via `git ls-files '*.sh'`), so coverage does not drift as scripts
  are added or moved.
- **Python compile + unit tests** for the descriptor-driven helpers
  (`misc/docker-module-updater/run.py`, `misc/module-version-actualizer.py`) via
  `test_phase4_descriptor_driven_helpers.py`, including cleanup of superseded
  generated module env metadata and descriptor-derived `--module-env` output.
- **Hermetic shell functional tests** (no Docker, no network — externals are
  stubbed on `PATH`):
  - `test-sidecar-image-selection.sh` — sidecar image is selected via the shell
    env without mutating `.env.local`.
  - `test-build-images-effective-sidecar.sh` — ARM image preparation uses the
    effective sidecar image ref, not a hardcoded `latest`.
  - `test-native-sidecar-effective-tag.sh` — the native sidecar builder tags the
    image Compose will run.
  - `test-build-images-failure.sh` — the ARM image builder exits non-zero and
    lists failed modules.
  - `test-vault-token.sh` — empty Vault token is refused; a real token persists.
  - `test-config-precedence.sh` — shell env > `.env.local.credentials` >
    `.env.local` > `.env`.

## Scope

These checks protect the bootstrap *logic* (descriptor → services/discovery,
version actualization), the config precedence/in-memory env contract, and the
fragile early bootstrap primitives, and they catch shell syntax regressions in
every tracked script during refactors.

They intentionally do **not** assert exact terminal output. The end-to-end proof
that the environment actually works is a real run:

```bash
./start.sh
```

which finishes with a built-in smoke check (api-gateway reachable, tenant token,
`diku` exists, capabilities reachable).
