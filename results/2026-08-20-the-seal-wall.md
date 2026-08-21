# 2026-08-20: the buffer is tuned, and the wall moved to the seal path

The buffer side is now at defensible settings and the tier survives 161k rows/s
with zero restarts. Sealing still retires only a third of what commits create,
and the remaining constraint has **no configuration surface at all**.

Report: `results/loadgen-20260820T150030Z-v10-sib1.html`. Table:
`bench.otel_logs_v10`, created because v9's base partition ref wedged (below).

## The run

`COMMIT_SIBLINGS=1`, `FLUSH_IDLE_INTERVAL_MS=100`, `FLUSH_MAX_BYTES=48000000`,
merge engine 2048MiB, spill cap 32GiB — all from `push-secrets.exs`, no inline
overrides, no GC loop. First measurement of the session with nothing propping it
up.

| | 2 VUs | 24 VUs |
|---|---|---|
| rows/s | 24,510 | **161,275** |
| p50 / p95 | 240 / 284 ms | 416 / 694 ms |
| rows/commit | 6,018 | **18,259** |
| commits/s per node | 1.5 | 3.4 |
| **seal:commit** | 0.62 | **0.34** |
| seal errors | 1 | 2 |
| restarts | 0 | **0** |
| buffer RSS peak | — | 3,806–4,090 MB of 4,096 |

## What the tuning bought

Commits went **12,515 → 18,259 rows**, a 46% increase, close to the ~20,400 the
48 MB cap allows. `COMMIT_SIBLINGS=1` with a 100 ms idle window stops windows
closing early — the boundary flapping that `COMMIT_SIBLINGS=2` caused is gone.
`seal:commit` improved with it, 0.19 → 0.34.

T-330 is holding: buffer RSS peaked at 4,090 MB against a 4,096 MB limit under
161k rows/s with no OOM and no GC loop.

## The cost, at the other end

| config | 2 VU rows/s | 2 VU p50 |
|---|---|---|
| `siblings=2`, `idle=5` | 45,184 | **131 ms** |
| `siblings=1`, `idle=100` | 24,510 | 240 ms |

Half the throughput and nearly double the latency at low volume. Two variables
moved at once so they cannot be fully separated, but a p50 of 240 ms matches a
100 ms idle window plus overhead rather than the 1 s full window, so the idle
interval is the likely cause.

**Every knob that helps batching at high volume costs latency at low volume.**
That has held for every setting tested today, which is the case for a feedback
loop (T-331) rather than a better constant.

## The wall: a valve-sized claim cannot be sealed

One 488-segment claim on `bench.otel_logs_v9` failed four ways, each time
against a different limit:

| config | failure |
|---|---|
| merge engine 1024MiB | `failed to pin block of size 256.0 KiB (1023.8 MiB/1.0 GiB used)` |
| merge 2048MiB, spill 8GiB | `failed to offload data block (7.9 GiB/8.0 GiB used)` |
| merge 2048MiB, spill 32GiB | `%Smolquery.Engine.CallExited{reason: :timeout}` |

Spill in use at the final failure was **625 MB of 32 GiB**, with 89 GB free.
Memory and disk are not the constraint; the merge simply cannot finish a
488-segment claim (~6.1M rows) inside its hardcoded call budgets.

**This is not a v9 artefact.** `otel_logs_v10`, created twenty minutes earlier,
produced the same timeout on `__p1` within minutes of load. The claim valve
(`@claim_valve_factor 16 × seal_max_files 64` = 1,024 segments) routinely permits
claims the sealer cannot complete.

Blast radius: one live claim per table ref, so 3,662 entries queued behind the
failing claim on v9's base ref while `__p1` and `__p2` drained normally. Losing
one ref costs a third of seal throughput on a 3-partition table, and the retry
is level-triggered, so it fails identically forever.

## Why no configuration fixes it

Everything on the claim and merge path is code-only:

    seal_max_files          64          no env override
    seal_max_bytes          67_108_864  no env override
    @claim_valve_factor     16          module attribute, table_buffer.ex:194
    max_concurrent_seals    2           no env override
    merge COPY timeout      5 min       hardcoded
    merge staging timeout   2 min       hardcoded

Their buffer-side neighbours — `flush_max_bytes`, `flush_interval_ms`,
`commit_siblings`, the engine memory limits — all have `System.get_env`
branches. The seal side never got them. **T-335** (urgent) specifies all eleven.

The loop is now visible in a single run: bigger commits produce bigger claims,
bigger claims exceed the merge budget, failed seals grow the backlog, and the
next claim is bigger still. **The batching fix feeds the claim problem.**

## Targets for when the knobs exist

    @claim_valve_factor   16 -> 2     # claim cap 1,024 -> 128 segments
    max_concurrent_seals   2 -> 4     # more, smaller merges in parallel

At ~18k rows per commit a 128-segment claim merges ~2.3M rows instead of ~6.1M.
Seal cost scales as roughly `segments^1.21`, so a smaller claim is more than
proportionally cheaper, and shorter merges shrink the window in which a ref is
blocked by its single live claim.

## Cluster state

- `bench.otel_logs_v10` is the working table.
- `bench.otel_logs_v9`'s base ref is permanently wedged — 488-segment claim,
  3,662 pending, retrying forever. Left in place as live evidence for T-335.
- All tuning is in `smolquery-deploy/push-secrets.exs`. No inline
  `kubectl set env` overrides remain.
- **ESO's refresh interval is 1h**, so a `push-secrets` does not reach the
  cluster promptly. Force it with
  `kubectl annotate externalsecret smolquery-env -n smolquery force-sync=$(date +%s) --overwrite`,
  then verify from the pod's boot log, never from the file.
- The loadgen EC2 box is still running. `mise run bench-down` terminates it.

## Next

1. **T-335** — expose the claim and merge knobs. Nothing else moves until this
   lands; the buffer side is exhausted.
2. Re-run 24 VUs with `valve_factor 2` and `max_concurrent_seals 4`, and check
   whether `seal:commit` reaches 1.
3. **T-331** — the seal:commit feedback loop, once claim size is controllable.
4. **T-334** — DuckDB engine memory metrics. Every failure above was read out of
   a log line.
