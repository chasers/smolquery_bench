# 2026-08-20: batch size is the whole game

> **SUPERSEDED.** This headline is wrong as a general claim. Later the same day,
> `WRITE_PARTITIONS` 3 -> 12 more than doubled sealed throughput *while commit
> size fell to a quarter*. Commit size matters when seal concurrency is pinned
> near 1.3, which is the regime every run below was measured in. See
> [2026-08-20-partitions-and-seal-contention.md](2026-08-20-partitions-and-seal-contention.md).


**At 3,062-row requests the pipeline accepts more than it can seal. At
40,000-row requests it keeps up.**

| request size | accepted rows/s | seal:commit | sustainable |
|---|---|---|---|
| 3,062 rows | ~158,000 | 0.33 - 0.43 | **no** - the hot tier grows |
| **40,000 rows** | **99,575** | **0.96** | **yes** |

Two knobs move the result, and only two. **`flush_idle_interval_ms`** sets
commit size: T-333's close-reason metric shows the 100 ms idle timer closes 71%
of windows and `flush_interval_ms` never fires at all. **`claim_valve_factor`**
sets seal throughput: 2 -> 1 tripled `seal:commit` at 32 VUs with every other
measure flat.

`flush_max_bytes` (48 -> 94 MB) and `write_pool_size` (4 -> 2) were both tested
and are **inert** at these loads.

Secondary results: T-335 cleared the seal wall, and the buffer tier - not
sealing - is what caps large bodies.

**Read the corrections section before trusting any claim-level number here.**

Build `f5f5deb` then `0a6ab69` (T-333). Tables `otel_logs_v11` -
`otel_logs_v19`.

## What shipped

    f5f5deb  Expose seal claim sizing, concurrency and merge timeouts (T-335)

Deployment adds two settings in `push-secrets.exs`:

    SMOLQUERY_CLAIM_VALVE_FACTOR    2
    SMOLQUERY_MAX_CONCURRENT_SEALS  4

The buffer boot line now prints `claim_max_bytes=134217728` and
`claim_max_files=128`. T-335 also added a `storage shape:` line, which prints
`max_concurrent_seals` and all three merge call budgets.

## The wedged claim released itself

    [warning] released oversized claim on {"bench", "otel_logs_v9"}:
    488 inputs return to pending and re-claim under the valves (T-294)

The valve reaches backwards into a claim frozen before it. The 3,662 entries
queued behind it drained at about 128 per minute. **Zero merge timeouts.** The
wall described in `2026-08-20-the-seal-wall.md` is gone.

## Runs

All 180 s measured, three api pods, three buffer pods, three storage pods.

| run | table | rows/s | p50 / p95 | refused | seal:commit | sealed rows/s |
|---|---|---|---|---|---|---|
| 24 VU x 3,062, contended | v11 | 159,576 | 425 / 693 ms | 0 | 0.219 | 34,947 |
| 24 VU x 3,062, clean | v11 | 158,575 | 430 / 706 ms | 0 | 0.427 | 67,712 |
| 1 VU x 40,000 | v12 | 39,896 | 939 / 1,121 ms | 0 | 0.953 | 38,021 |
| 2 VU x 40,000 | v12 | 68,518 | 1,080 / 1,477 ms | 0 | 0.973 | 66,668 |
| **3 VU x 40,000** | v12 | **99,575** | 1,037 / 1,829 ms | 0 | **0.961** | **95,691** |
| 4 VU x 40,000 | v12 | 100,553 | 1,190 / 2,007 ms | **363** | invalid | — |

Zero seal errors in every run. Zero restarts except the 4 VU run.

`seal:commit` is `retired / added` on
`smolquery_hot_manifest_index_entries_total`, summed over the three buffer
pods across the measured phase. The same query against the 2026-08-20 15:00Z
v10 run returns 0.344, which matches its published figure, so the method
agrees with the earlier write-up.

**The 4 VU ratio is not reportable.** `buffer-2` OOMKilled three times, so its
counters reset mid-phase and the sum is meaningless. The two surviving pods
read 0.91 and 0.92, so sealing was still near parity when the tier died.

## Where the ceiling is

| VUs | accepted rows/s | refused | outcome |
|---|---|---|---|
| 3 | 99,575 | 0 | clean |
| 4 | 100,553 | **363 of 818 (44%)** | `buffer-2` OOMKilled x3, exit 137 |

Throughput gained 1% while refusals went 0 to 44%. **Three concurrent 94 MiB
bodies is the edge for a 4 GiB buffer pod.** The limit is buffer memory, not the
seal path.

## Finding 1: the valve helps, and the first measurement lied

The contended run read 0.219 and looked like a regression. It was not. The
v9 backlog had not drained, and its claims held seal slots. Resident manifest
entries at the start of each window tell the story:

| run | resident at window start | seal:commit |
|---|---|---|
| contended | 1,337 | 0.219 |
| clean | 324 | **0.427** |

Against the v10 baseline of 0.344, `claim_valve_factor=2` buys **24% more
seal throughput at unchanged ingest throughput**, with the wedging gone.

**A backlog from an earlier table contaminates the next run.** The bench's
drain gate is per table, so it does not catch this. Drain the cluster, not
the table, before a seal measurement.

## Finding 2: bigger commits seal faster

Sealed rows per second, against offered load:

    1 VU x 40k   38,021
    2 VU x 40k   66,668
    3 VU x 40k   95,691

About 32,000 sealed rows/s per VU, linear, with no falloff.

| request size | sealed rows/s | `seal:commit` | saturated? |
|---|---|---|---|
| 3,062 rows | 67,712 | 0.427 | no — see below |
| 40,000 rows | >= 95,691 | 0.961 | no |

Neither run saturated the seal path. The 3,062-row run accepted far more than
it sealed, which looks like a seal limit, but the counters below show the seal
machinery was idle while it fell behind.

## Finding 3: the seal path is idle, and claims are rare

From `smolquery_seal_segments_total`, `smolquery_seal_attempts_total` and
`smolquery_seal_microseconds_total` (`result="ok"`), summed across the three
storage pods per measured phase:

| run | claims | segments/claim | s/claim | seal concurrency |
|---|---|---|---|---|
| 24 VU x 3,062 | **7** | 58.6 | **22.9 s** | 0.89 of 12 |
| 1 VU x 40,000 | 20 | 9.1 | 2.6 s | 0.29 of 12 |
| 2 VU x 40,000 | 33 | 9.8 | 2.4 s | 0.44 of 12 |
| 3 VU x 40,000 | 48 | 9.7 | 2.4 s | 0.64 of 12 |

`max_concurrent_seals=4` x 3 pods = 12 slots. **The busiest run used 0.89.**

The 24 VU run formed **7 claims in 180 seconds**, each holding 58.6 segments and
taking 22.9 s to merge. The 40,000-row runs formed 48 claims of 9.7 segments in
2.4 s each.

Per second of actual seal work:

    24 VU x 3,062     ~76,000 rows per seal-second
    3 VU x 40,000    ~150,000 rows per seal-second

Large segments seal about **twice as many rows per second of merge work**, and
the merge machinery still sits idle most of the time.

**The constraint is claim formation, not seal capacity.** A ref was busy roughly
30% of the 24 VU window with eleven seal slots free.

## Finding 4: what actually closes a commit window (T-333)

24 VUs, 3,062-row requests, measured window, all three buffer pods, from
`smolquery_buffer_flush_trigger_total{reason}`:

| reason | windows | share |
|---|---|---|
| **idle** | 1,117 | **71.3%** |
| bytes | 450 | 28.7% |
| interval | 0 | - |

`flush_interval_ms=1000` is dead config at this load. The 100 ms
`flush_idle_interval_ms` closes most windows, and `bytes` takes the upper tail
where a window fills 48 MB inside 100 ms.

This is why two cluster experiments produced nothing:

| change | expected | measured rows/commit |
|---|---|---|
| `flush_max_bytes` 48 -> 94 MB | ~35,900 rows | 18,520 (+1.4%) |
| `write_pool_size` 4 -> 2 | ~37,000 rows | 18,347 (-0.7%) |

Both tuned knobs that were not binding.

**Commit size distribution**, from `smolquery_buffer_commit_rows_bucket`:

| <= rows | cumulative | in band |
|---|---|---|
| 1,000 | 0 | - |
| 4,000 | 2 | 2 |
| 16,000 | 310 | 308 |
| 64,000 | 1,570 | **1,260** |

80% of commits fall between 16,000 and 64,000 rows. The 18,220 mean hides a
wide spread.

`smolquery_buffer_commit_bytes_total / rows_committed` measures **2,351 bytes
per row** - the NDJSON wire rate exactly. That settles by counter what two
earlier derivations got wrong.

## Finding 5: the claim valve triples seal throughput

32 VUs, `flush_idle_interval_ms=300`, `flush_max_bytes=94000000`, fresh table
each run. `claim_valve_factor` is the only variable.

| | valve 2 | **valve 1** | |
|---|---|---|---|
| **seal:commit** | 0.171 | **0.540** | **3.2x** |
| sealed rows/s | 22,148 | **69,487** | 3.1x |
| claims completed | 3 | 11 | see caveat |
| rows/commit | 30,675 | 30,014 | flat |
| accepted rows/s | 129,520 | 128,679 | flat |
| p50 | 725 ms | 723 ms | flat |

Commit size, throughput and latency all held, so the valve is isolated.

**The mechanism is unknown.** The prediction was that halving `claim_max_bytes`
would halve segments per claim and shorten merges as `segments^1.21`. Measured
segments per claim barely moved (44.7 -> 39.5) and merge time went *up*
(61.3 -> 72.8 s). The cost model does not explain the result. What improved is
claim completion rate, and nothing here says why.

`claim_valve_factor` is a positive integer, so 1 is its floor. Going smaller
means lowering `seal_max_bytes` (64 MiB). Untested.

## Corrections to this document and its predecessors

Six mechanisms were proposed during this session. Five were wrong. They are
listed so the next reader does not inherit them.

**C1 - "An entry's `byte_size` is `:erlang.external_size(rows)`."** Wrong, and
it was itself a "correction" of a right answer. `Entry.from_segment` copies
`Segment.byte_size`, which is `File.stat` of the written Parquet file
(`segments/store/local.ex:92`, `hot_manifest/entry.ex:64`). **There are three
byte currencies sharing one word:**

| currency | measured as | read by |
|---|---|---|
| wire/heap | `:erlang.external_size(rows)`, or body size for NDJSON | `flush_max_bytes`, `max_buffered_bytes`, `INSERT_MAX_*`, `commit_bytes_total` |
| micro-segment Parquet | `File.stat` of the flushed file | `seal_max_bytes`, the claim valve, hot-manifest accounting |
| sealed Parquet | `File.stat` after merge | `target_segment_bytes`, `compact_*`, `seal_row_group_size` |

The wire-to-Parquet ratio is roughly 10-20x for these rows. The measured
2,351 B/row figure is **wire bytes**, from `commit_bytes_total / rows_committed`
- it does not describe manifest entries.

**C2 - "The 25.7 s claim cadence is `seal_retry_ms`."** Numerically close,
mechanically wrong. `seal_retry_ms` gates only the re-signal of an outstanding
claim (`due?`, `table_buffer.ex:928`). The cycle length is the merge itself.

**C3 - Every claim-level number in this document is contaminated.**
`smolquery_seal_segments_total`, `_attempts_total` and `_microseconds_total`
are **cluster-wide, not per table**. Older tables drain during later runs. The
valve-1 run shows it directly: 11 claims x 72.8 s = 800 s of merge work in a
180 s window, or 4.4 concurrent, against a ceiling of 3 refs x one live claim.
More than one table was sealing.

**Only drain the whole cluster - not the table - before trusting these.** The
bench's drain gate is per table and does not do this.

`seal:commit` is not affected: it comes from the buffer manifest counters
against a single table's offered load.

**C4 - "Seal throughput caps near 67k rows/s."** Two coincident points read as
capacity. Killed by a 95,691 measurement.

**C5 - "A 40,000-row claim holds one segment."** Measured 9.7. Built on C1.

**C6 - "Windows close when a write-pool slot frees."** Halving
`write_pool_size` changed nothing.

T-338 tracks the design problem this pattern points at.

## Three models that were wrong

**The 67k seal ceiling.** After the 2 VU run, two different workloads both
landed at ~67k sealed rows/s and this looked like capacity. The 3 VU run reached
95,691, and the concurrency counters then showed the seal path was never near
its limit in either run.

**The claim byte valve, and `byte_size`.** An entry's `byte_size` is
`:erlang.external_size(rows)`, not the on-disk Parquet size. An earlier note
treated it as compressed bytes and derived ~40 segments per claim.

**One segment per claim at 40,000 rows.** A follow-up derivation put a 40,000-row
segment at 89.7 MiB, so only one would fit a 128 MiB claim. Measured value is
**9.7**. The byte arithmetic does not reconcile with the counters, so stop
deriving segment bytes from claim composition and read the counters instead.

## The old seal curve is obsolete

`2026-08-20-group-commit-sizing.md` records a seal-throughput peak at 21,346
rows per segment, with 32,659 rows measured 60% worse. **40,000 rows per
segment now seals at parity up to at least 95k rows/s.** Either T-335 changed
the curve, or the original was confounded by the wedged claims we now know
were present. Do not plan against the old peak until someone re-measures it.

## Memory

Read `memory.stat` anon, not `memory.current` — the latter includes page cache
and reads at the container limit while anon sits far below.

| run | buffer-0 anon | file |
|---|---|---|
| 1 VU x 40k | 2,539 MB | 1,036 MB |
| 2 VU x 40k | **3,496 MB** | 167 MB |
| 3 VU x 40k | 3,111 MB | 339 MB |

Limit is 4,096 MB. The 2 VU run was the tightest, not the 3 VU run, so anon
does not grow monotonically with VUs. A 40,000-row body is 94,098,065 bytes,
which leaves 5.9% headroom under `SMOLQUERY_INSERT_MAX_NDJSON_BYTES=100000000`.
About 42,500 rows would be a 413.

## A new bug: compaction hits the wall seal escaped

    compaction of {"bench", "otel_logs_v11"} failed:
    {:merge_failed, %Smolquery.Engine.CallExited{reason: :timeout}}

Compaction shares the merge code but runs on the 512 MiB compaction engine, and
T-335 gave it no claim valve. It retries, so it competes with sealing for the
merge engine on any table that carries a failure. **This needs its own ticket.**

Practical effect on benching: `otel_logs_v11` is no longer a clean table.

## Cluster state

- `bench.otel_logs_v12` is the working table.
- `bench.otel_logs_v11` carries a retrying compaction failure.
- `bench.otel_logs_v9` is drained and no longer wedged.
- The loadgen EC2 box is running. `mise run bench-down` terminates it.

## Next

**Test `flush_idle_interval_ms`.** It is the only knob the measurements point
at, and it is untested. Raise it to 300 ms with `flush_max_bytes` at 94 MB so
the byte cap has headroom, run 24 VUs, and read
`flush_trigger_total{reason}` to confirm the close reason actually moves.

If commits reach ~40,000 rows from ordinary 6.87 MiB requests, that reproduces
the segment size that sealed at 0.96 with no giant bodies and no buffer memory
risk.

Also outstanding:

- **T-338** - simplify the write-path tuning surface. Four models were wrong
  this session and two cluster runs were spent on knobs that were not binding.
- **File the compaction timeout** on `otel_logs_v11`.
- **Re-measure the seal curve against segment size.** The 21,346-row peak in
  `2026-08-20-group-commit-sizing.md` is obsolete.

## A caveat on every ratio here

`seal:commit` read **0.427 and 0.326 on identical settings** with different
tables (v11, v16). No explanation. Treat single-run ratios as approximate and
prefer the direction of a change over its magnitude.
