# ARM image builder

Internal worker invoked automatically by `./start.sh` on ARM hosts (Apple
Silicon) — not an operator entrypoint. The published `folioci/*` images are
amd64-only and would run under emulation (~8s startups become ~800s), so every
FOLIO-buildable image in the run (managers, gateway, modules, sidecar) is
rebuilt natively for arm64 instead.

- Builds an arm64 base JRE image from `folio-tools`, then each module from its
  descriptor-derived tag (snapshot versions build from `master` — the built
  behavior may drift from the descriptor's stated version).
- Idempotent: images already present as arm64 are skipped, so warm re-runs
  build nothing; the refresh offer in `./start.sh` forces a rebuild.
- Per-module failures propagate: the build exits non-zero and lists failed
  modules.
- All clones and logs happen in a disposable temp directory.
