# Rewrite bash scripts in Elixir

## Goal

Replace `scripts/*.sh` with Elixir scripts (`scripts/*.exs`), same behavior,
same CLI shape, same env-var knobs, so README commands change only in
extension. No Mix project — plain `elixir` scripts (Elixir 1.20 / OTP 29,
built-in `JSON` module, `:httpc` for HTTP, `/bin/sh -c "nohup … & echo $!"`
for daemonizing servers).

## Design

- `scripts/bench.exs` — shared library (not executable): `Bench` (env/http/
  pidfile/daemon/shell helpers), `Bench.Genbody`, `Bench.Smolquery`,
  `Bench.Clickhouse`, `Bench.RunArm`, `Bench.Report`.
- Thin executable entry scripts with `#!/usr/bin/env elixir` shebangs, one per
  old bash script: `gen-bodies.exs`, `setup-smolquery.exs`,
  `setup-clickhouse.exs`, `run-arm.exs`, `sweep.exs`, `stop.exs`, `report.exs`.
- `sweep.exs` calls the setup/run/report functions in-process instead of
  shelling out to sibling scripts.
- `.formatter.exs` covering `scripts/*.exs`; `mix format` before finishing.

## Work items

1. [x] `scripts/bench.exs` with all modules.
2. [x] Seven entry scripts, chmod +x.
3. [x] Verify: `gen-bodies.exs` output byte-identical to existing body file
       (same seed); `report.exs` output matches the bash report (and prints
       `-` where jq crashed on null latency); smoke runs passed —
       clickhouse 263k rows/s @4VU/5s, smolquery 221k rows/s @16VU/5s, watch
       pattern now excludes ElixirLS.
4. [x] Delete `scripts/*.sh` (`git rm -f`), update README, `mix format`.
5. [x] Run the baseline sweeps (wait-for-quiet + both arms) on the Elixir
       scripts. Completed 13:27; results and anomalies recorded in plan _01
       item 9 and `results/2026-08-10-baseline.md`.
