## TL;DR

**The merge engine's memory budget was the ceiling.**
`SMOLQUERY_STORAGE_MEMORY_LIMIT` 2048MiB -> 3584MiB tripled sealed throughput:
the same config measured `seal:commit` **0.329** then **0.988**.

**Parity sits at 96 VUs and 254,163 rows/s** — `seal:commit` 0.990, **251,621
rows/s sealed**, zero refusals, ordinary requests, no client batching. That is
**3.7x** the 2026-08-20 morning baseline.

**An evening of partition/claim sweeping was measuring which shapes fit in
2 GiB.** The ranking inverted once the budget rose.

**Small rows: 3,461,443 rows/s at 32 VUs, zero refusals, seal at parity.**
133-byte kv rows against `kv_v1`, same tuning. In wire bytes it is the same
~500 MiB/s ceiling the otel record hits — the cluster is byte-bound.

## The winning configuration

    WRITE_PARTITIONS=3 · MAX_LIVE_CLAIMS=8 · STORAGE_MEMORY_LIMIT=3584MiB
    SEAL_MAX_BYTES=24MiB · CLAIM_VALVE_FACTOR=1 · FLUSH_IDLE_INTERVAL_MS=300

| virtual users | 48 | **96** |
|---|---|---|
| accepted rows/s | 178,577 | **254,163** |
| **seal:commit** | 1.123 | **0.990** |
| sealed rows/s | ~178,000 | **251,621** |
| rows/commit | 42,013 | 42,689 |
| close reason | mostly `idle` | **`bytes` 99.3%** |
| p50 | 716 ms | 1,057 ms |
| refused | 0 | 0 |

**96 VUs is the knee.** The cost of the last 42% is latency: p50 716 ->
1,057 ms. `flush_max_bytes` binds for the first time all session.

## The memory result

| config | seal:commit @ 2048MiB | @ 3584MiB |
|---|---|---|
| 12 x 2 | 0.619 | 0.874 |
| 6 x 3 | 0.322 | 0.920 |
| 3 x 4 | 0.329 | **0.988** |
| **3 x 8** | not measured | **1.123** |

Storage connections share one DuckDB instance — one `memory_limit`, one buffer
pool. **Size it against merges in flight, not per merge.**

## The seven things we know

1. **Memory is the seal ceiling**, not partitions, claims, or commit size.
   At 3584MiB it is still not binding at 96 VUs — the cliff is unlocated.
2. **Fewer partitions with more claims per ref wins** once memory is adequate:
   best ratio, largest commits, fastest merges.
3. **Seal concurrency is a trap metric.** It reads higher when merges are
   degraded; the best run has the lowest figure. T-346.
4. **Per-segment merge cost across a window** separates healthy from starved:
   flat vs a 4-10x mid-window rise.
5. **Commit size is controllable** via `flush_idle_interval_ms` and client
   parallelism; `flush_max_bytes` only binds above ~160k rows/s per ref.
6. **The spill mechanism is unproven.** All `/spill` bytes belong to the
   compaction engine; the seal engine's directories are empty.
7. **The ingest ceiling is wire bytes, not rows.** Small (133 B) and wide
   (~2.2 KB) rows both top out near ~500 MiB/s; rows/s is that budget divided
   by row width. Past the knee, extra VUs buy latency and 429s — the buffer
   pods pin their 4,096 MB limit either way.

## Open blockers

| item | what it does | state |
|---|---|---|
| **merge serialization** | Concurrent merges queue; caps seal concurrency at ~5 | **Unfiled - belongs in T-338** |
| **T-343** | Compaction fails on a missing spill temp dir, retries forever | Filed |
| **T-344** | Claim loop spins on one partition with `:nothing_to_claim` | Filed |
| **T-338** | Simplify the write-path tuning surface | Filed, updated |
| **T-346** | A seal metric that separates big merges from starved ones — the concurrency figure inverts | Filed |
| T-331 | Feedback loop targeting `seal:commit` | Ready |
| T-334 | DuckDB engine memory metrics | Ready |

T-333 and T-335 are **done** and deployed.

## Read this before you quote a number

- **`smolquery_seal_*` counters are cluster-wide, not per table.** Older tables
  drain during later runs, so every claim-level figure in this corpus is
  contaminated. Drain the whole cluster, not the table, before trusting them.
  The bench's drain gate is per table and does not do this.
- **`byte_size` means three different things.** Wire/heap bytes
  (`flush_max_bytes`), micro-segment Parquet (`seal_max_bytes`, claim valve),
  and sealed Parquet (`target_segment_bytes`). Ratio roughly 10-20x. This
  ambiguity produced three wrong models in one day.
- **Single-run `seal:commit` ratios are approximate** - the same settings read
  0.427 and 0.326. Prefer the direction of a change over its magnitude.
- **All cluster numbers are short windows** — 60 s for the kv sweep, 3 min
  for the otel runs. Not soak results.
- **Every number in this repo used OTP 29.** OTP 27 measured 6.2% faster at
  1 VU. Do not mix the two in one table.
- **Read `memory.stat` anon, not `memory.current`** - the latter includes page
  cache and reads at the container limit while anon sits far below.
- **`bench.otel_logs_v11` carries a retrying compaction failure.** Use a
  later table — `otel_logs_v33` is current.
- **Check for a running loadgen EC2 box** with `mise run bench-status`; stop
  it with `mise run bench-down`. `TaskStop` does not kill k6 on the box - use
  `/tmp/killk6.sh`. Terminated after the 2026-08-21 kv sweep.

## Next step

**Locate the memory cliff.** 3584MiB is not binding at 96 VUs, so the sizing
rule T-346 needs either more load or a lower budget. A downward sweep of
`STORAGE_MEMORY_LIMIT` at a fixed 96 VUs brackets it in three runs.

Also open:

- `flush_max_bytes` binds now. Test it together with the memory budget —
  bigger segments are what starved the 2048MiB engine.
- Every commit-size conclusion from 2026-08-20 was measured under a starved
  budget. Re-check the seal curve before trusting any of them.

---

## The write-ups, newest first

### 2026-08-21

- [kv-small-rows-ceiling](2026-08-21-kv-small-rows-ceiling.md) — 133-byte
  rows ingest at **3.46M rows/s** (32 VUs, zero refusals, seal at parity).
  In wire bytes, small and wide rows share one ~500 MiB/s ceiling.
- [memory-is-the-seal-ceiling](2026-08-21-memory-is-the-seal-ceiling.md)
  — **current state.** The merge engine's memory budget was the ceiling.
  Parity at 96 VUs: 251,621 sealed rows/s, 3.7x the morning baseline.

### 2026-08-20

- [partitions-and-seal-contention](2026-08-20-partitions-and-seal-contention.md)
  — **superseded.** Partitions beat every buffer knob; 101,709 sealed rows/s.
  Merge contention is the new ceiling.
- [seal-parity-with-large-batches](2026-08-20-seal-parity-with-large-batches.md)
  — **headline superseded.** Still the record of T-335, T-333, and five
  corrected mechanisms.
- [the-seal-wall](2026-08-20-the-seal-wall.md) — the wall, before T-335. Its
  claim-size arithmetic is superseded.
- [group-commit-sizing](2026-08-20-group-commit-sizing.md) — the Postgres
  group-commit model does not transfer to smolquery.
- [batch-size-and-heap-garbage](2026-08-20-batch-size-and-heap-garbage.md) —
  20,000-row inserts reach seal parity. The OOM cause is heap garbage.

### 2026-08-19

- [post-t316-soak](2026-08-19-post-t316-soak.md) — 209k rows/s peak, and the
  buffer tier still OOMKills at ~2.4 minutes.
- [v8-soak-collapse](2026-08-19-v8-soak-collapse.md) — 16 VUs for 30 minutes
  kills all three buffer pods in about 3 minutes.
- [v8-0-13-0-rebench](2026-08-19-v8-0-13-0-rebench.md) — the first clean v8 run.
  200,253 rows/s, even seal skew, zero restarts.

### 2026-08-18

- [v8-seal-compaction](2026-08-18-v8-seal-compaction.md) — corrupt v6 and v7
  segments poison the compaction loop.
- [v8-post-t304-rebench](2026-08-18-v8-post-t304-rebench.md) — T-304 verified.

### 2026-08-17

- [local-rebench-0-11-0](2026-08-17-local-rebench-0-11-0.md) — local re-baseline.
- [mid-range-flush-dead-band](2026-08-17-mid-range-flush-dead-band.md) — the
  timer-bound dead band between 4 and 8 VUs.
- [otp-27-vs-29](2026-08-17-otp-27-vs-29.md) — OTP 27 is 6.2% faster at 1 VU.
- [sigbus-evidence](2026-08-17-sigbus-evidence.md) — the DuckDB SIGBUS crash.

### 2026-08-16

- [v3-first-sweep](2026-08-16-v3-first-sweep.md) — the `otel_logs_v3` schema.
- [post245-sweep](2026-08-16-post245-sweep.md) — the sweep after T-245.
- [loadgen-t245-oomkill](2026-08-16-loadgen-t245-oomkill.md) — the first
  in-region loadgen, and its OOMKill.

### 2026-08-15 and earlier

- [cost-model-1m-rows-per-second](2026-08-15-cost-model-1m-rows-per-second.md) —
  1M rows/s costs ~$139,000/month. Compute is 3% of it. Network is 92%.
- [remote-v2-baseline](2026-08-15-remote-v2-baseline.md) — 127,111 rows/s on the
  deployed cluster.
- [remote-sandbox](2026-08-14-remote-sandbox.md) — the remote arm and the
  sandbox cluster.
- [pr124-adaptive-group-commit](2026-08-11-pr124-adaptive-group-commit.md) —
  adaptive group commit.
- [baseline](2026-08-10-baseline.md) — the first harness run. Local M1 Max.
  smolquery 480,569 rows/s against ClickHouse 457,472 rows/s at 64 VUs.

## Files

- `*.html` — one self-contained charted report per run. Open in a browser.
- `raw-loadgen/` — the metrics SQLite database and the k6 summary per run.
- `raw*/` — the raw output of the older local sweeps.
- `crashes-2026-08-17/` — the SIGBUS crash dumps.
