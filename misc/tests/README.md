# Tests

A small, offline regression net. No Docker or running environment required —
external commands (`docker`, `curl`) are stubbed on `PATH`; `jq` stays real.

## Run

```bash
bash misc/tests/run.sh
```

What it covers, by category (the authoritative list is `run.sh` itself):

- **Syntax:** `bash -n` over every tracked `.sh`, plus a Bash 3.2 portability
  guard; `py_compile` + `unittest` for the Python helpers.
- **Config model:** env precedence (shell > credentials > local > defaults),
  credentials file persistence (Vault token), vault token handling.
- **Descriptor/runtime sync:** version actualizer, discovery/service/env
  derivation, descriptor-vs-image skew halt, image freshness/refresh offer.
- **Bootstrap behavior:** gateway selection and the route-loss guard, warm
  `--actualize` recovery, ARM build queue decisions, native sidecar
  (tag/resources/build env), create-user flows, preflight checks, start/stop
  semantics and profile activation, failure-diagnostics content.
- **Presentation contracts:** output purity (helpers that return values keep
  stdout bare; presentation stays on stderr and escape-free when piped) and
  `ui_run` behavior (exit-code propagation, errexit restore, bounded failure
  output).

Behavior tests assert observable outcomes, not exact terminal bytes — the
end-to-end proof is a real `./start.sh` run finishing with its smoke check.
