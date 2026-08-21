# 2026-08-21: the merge engine's memory budget was the ceiling

**`SMOLQUERY_STORAGE_MEMORY_LIMIT` 2048MiB -> 3584MiB tripled sealed
throughput.** The same configuration measured `seal:commit` **0.329** at
2048MiB and **0.988** at 3584MiB, with every other setting held constant.

**Parity sits at 96 virtual users and 254,163 rows/s** — `seal:commit` 0.990,
251,621 rows/s sealed, zero refusals, from ordinary 6.87 MiB requests with no
client-side batching. That is **3.7x** the morning baseline's sealed
throughput, and the difference between falling behind and keeping up.

**An evening of partition and claim sweeping was measuring which shapes fit in
2 GiB.** Once the budget rose, the ranking inverted completely.

Image `sha256:cf6f3786` (T-339). Tables `otel_logs_v22` - `otel_logs_v32`.
48 virtual users, 3,062-row requests, 180 s measured, fresh table each run.

## The winning configuration

    SMOLQUERY_WRITE_PARTITIONS        3
    SMOLQUERY_MAX_LIVE_CLAIMS         8
    SMOLQUERY_STORAGE_MEMORY_LIMIT    3584MiB   (container limit 6Gi)
    SMOLQUERY_SEAL_MAX_BYTES          25165824
    SMOLQUERY_CLAIM_VALVE_FACTOR      1
    SMOLQUERY_FLUSH_IDLE_INTERVAL_MS  300
    SMOLQUERY_FLUSH_MAX_BYTES         94000000
    SMOLQUERY_MAX_CONCURRENT_SEALS    4

| virtual users | 48 | **96** |
|---|---|---|
| accepted rows/s | 178,577 | **254,163** |
| **seal:commit** | 1.123 | **0.990** |
| sealed rows/s | ~178,000 | **251,621** |
| rows/commit | 42,013 | 42,689 |
| window close reason | mostly `idle` | **`bytes` 1,136 / `idle` 7** |
| seconds per merge | 6.3 | 7.5 |
| p50 | 716 ms | 1,057 ms |
| refused | 0 | **0** |

**96 VUs is the knee.** At 48 the ratio sits above 1.0, so sealing drains
backlog faster than commits arrive and the load does not saturate it. At 96 it
lands on 0.990 — sealing exactly keeping pace.

The cost of the extra 42% throughput is latency: p50 716 -> 1,057 ms.

Against the 2026-08-20 morning baseline — 67,712 sealed rows/s at `seal:commit`
0.43 — that is **3.7x the sealed throughput, at parity instead of falling
behind**.

### `flush_max_bytes` finally binds

At 96 VUs the byte cap closed **1,136 of 1,144 windows (99.3%)**, against
`idle` dominating at every lower load all session. `flush_max_bytes=94000000`
is now the active constraint on commit size, holding it at ~42,689 rows
(~100 MB of wire bytes).

This is the first run of the whole investigation where that knob does anything.
Its inertness threshold — per-ref arrival above roughly
`flush_max_bytes / (idle_interval + settle)` — is finally crossed.

### Memory is still comfortable at this load

Per-segment merge cost across the 96 VU window:

    0.56 0.41 0.51 0.54 0.54 0.52 0.57 0.59 0.53 0.56 0.55 0.52 0.51 0.51 0.58

Flat at 0.41-0.59, the steadiest series of the session, at 42% more load than
the 48 VU run. **3584MiB is not binding at 96 VUs**, so the new memory cliff is
still unlocated.

## The memory result

Same config, same load, memory the only variable:

| config | | 2048MiB | 3584MiB | |
|---|---|---|---|---|
| 3 refs x 4 claims | seal:commit | 0.329 | **0.988** | 3.0x |
| | sealed rows/s | 55,268 | **172,273** | 3.1x |
| | seconds per merge | 55.5 | **6.5** | 8.5x faster |
| 6 refs x 3 claims | seal:commit | 0.322 | **0.920** | 2.9x |
| | sealed rows/s | 56,759 | **162,984** | 2.9x |
| | seconds per merge | 72.1 | **11.5** | 6.3x faster |
| 12 refs x 2 claims | seal:commit | 0.619 | **0.874** | 1.4x |
| | sealed rows/s | 125,918 | **173,670** | 1.4x |

`engine.ex:124-129`: the storage engine's connections "share one DuckDB
instance: one `memory_limit`, one buffer pool, one temp directory". Each seal
slot gets its own connection (`sealer.ex:322`), so merges do not queue on each
other's statements — but they all draw on one budget.

**Size `STORAGE_MEMORY_LIMIT` against merges in flight, not per merge.**

## The ranking inverted

At 2048MiB, small commits and many partitions won. At 3584MiB the opposite
wins:

| config | rows/commit | seal:commit @ 2048 | seal:commit @ 3584 |
|---|---|---|---|
| 12 x 2 | 10,878 | **0.619** (best) | 0.874 (worst) |
| 6 x 3 | 21,869 | 0.322 | 0.920 |
| 3 x 4 | 41,753 | 0.329 | 0.988 |
| **3 x 8** | **42,013** | not measured | **1.123** (best) |

Fewer partitions with more claims per ref now wins on **every** axis: best
ratio, largest commits, fastest merges, lowest concurrency. Large commits mean
fewer, larger sealed segments, which is also better for query scans.

## Concurrency is a trap metric

Seal concurrency computed as `sum(seal_microseconds) / wall_seconds` reads
**higher** when merges are degraded, because slow merges overlap:

| config | concurrency | sealed rows/s |
|---|---|---|
| 6 x 3 @ 2048MiB | **8.81** | 56,759 |
| 6 x 3 @ 3584MiB | 4.58 | **162,984** |
| 3 x 8 @ 3584MiB | **2.17** | best of session |

Concurrency halved while throughput tripled. The best run has the *lowest*
figure. A dashboard reading this as utilisation reports the broken state as the
healthy one. **T-346.**

## The degradation signature

Per-segment merge cost across a measured window distinguishes a healthy run
from a starved one at a glance:

| config | s/segment across the window |
|---|---|
| 3 x 4 @ 2048MiB | 0.95 -> 7.27 (ramp) |
| 3 x 3 @ 2048MiB | 1.4 -> 7.5 (step at ~100 s) |
| 6 x 3 @ 2048MiB | 0.82 -> 8.6 (erratic) |
| **3 x 8 @ 3584MiB** | **0.35 - 0.48, flat** |

Starved runs rise 4-10x mid-window. Healthy runs are flat. Nothing reports this
directly; it is computed from per-scrape deltas of
`smolquery_seal_microseconds_total` against `smolquery_seal_segments_total`.

## What is measured and what is not

**Measured:** the throughput difference, twice, single-variable, on fresh
tables.

**Not established:** that seal merges spill to disk. `/spill` holds 14.7 GB
across two storage pods, and **all of it belongs to the compaction engine** —
the seal engine's per-connection directories are empty. Alternatives not ruled
out: DuckDB throttling under budget pressure without spilling, different query
plans at different budgets, or contention with the compaction engine, which is
failing continuously (T-343) and writing gigabytes of temp data on the same
pod and disk.

The effect is real. The mechanism is not identified. T-346 asks for the metric
that would settle it.

## Caveats

- Claim-level counters are cluster-wide, not per table; T-343 and T-344 were
  retrying on old tables throughout. `seal:commit` and `rows/commit` come from
  buffer counters against one table's offered load and are unaffected.
- Single runs. Earlier in the session identical settings read 0.427 and 0.326.
  Prefer directions over magnitudes.
- 3-minute windows on OTP 29. Not soak results.
- The storage container limit was raised by `kubectl patch` because
  `mise run sq-deploy` was unavailable. `overlay/sandbox/patch-resources.yaml`
  carries the same 6Gi, so a later deploy reconciles rather than reverts.

## Next

1. **Locate the memory cliff.** 3584MiB handles 96 VUs flat, so the sizing rule
   T-346 wants needs either more load or a lower budget to find. A downward
   sweep of `STORAGE_MEMORY_LIMIT` at fixed 96 VUs would bracket it in three
   runs.
2. **`flush_max_bytes` is live now.** Raising it past 94 MB grows commits
   further, but it interacts with the memory budget — bigger segments are
   exactly what starved the merge engine at 2048MiB. Test the two together, not
   separately.
3. **T-346** — a metric distinguishing "merges are big" from "merges are
   starved", and a concurrency figure that does not invert.
4. **T-343 and T-344** still block draining the cluster between runs.
5. **Re-check the seal curve.** Every conclusion about commit size from
   2026-08-20 was measured under a starved budget.

## References

- Supersedes the conclusions of
  [2026-08-20-partitions-and-seal-contention.md](2026-08-20-partitions-and-seal-contention.md)
- `engine.ex:124-129`, `sealer.ex:322`
- T-339 (concurrent claims per ref), T-343, T-344, T-346, T-338
