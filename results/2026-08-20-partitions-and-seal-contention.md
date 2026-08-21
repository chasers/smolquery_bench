# 2026-08-20 (evening): partitions beat every buffer knob

> **SUPERSEDED.** This grid was measured at `STORAGE_MEMORY_LIMIT=2048MiB` and
> is really a map of which shapes fit that budget. Raising it to 3584MiB
> inverted the ranking: 3 refs x 8 claims reaches `seal:commit` 1.123 with
> 42,013-row commits, while 12 x 2 becomes the weakest. See
> [2026-08-21-memory-is-the-seal-ceiling.md](2026-08-21-memory-is-the-seal-ceiling.md).


**`WRITE_PARTITIONS` 3 -> 12 more than doubled sealed throughput**, from 46,308
to **101,709 rows/s**, while commit size fell to a quarter. It also beat the
best client-batching result on both axes.

**Commit size is not the driver.** An earlier write-up today concluded "batch
size is the whole game". That is wrong, and this run disproves it directly.

**The new ceiling is contention inside the merge path.** Concurrent merges
queue on a serialized connection, so seal concurrency saturates near 5 against
12 configured slots. That is a code problem, not a knob.

Image `sha256:0a6ab69`. Tables `otel_logs_v22` - `otel_logs_v24`.

## The partition sweep

48 VUs, 3,062-row requests, 180 s measured, fresh table each run. Settings held
constant: `seal_max_bytes=24MiB`, `claim_valve_factor=1`,
`flush_idle_interval_ms=300`, `flush_max_bytes=94000000`.

| | 3 refs | 6 refs | **12 refs** |
|---|---|---|---|
| accepted rows/s | 172,790 | 184,085 | **207,570** |
| **seal:commit** | 0.268 | 0.429 | **0.490** |
| **sealed rows/s** | 46,308 | 78,972 | **101,709** |
| seal concurrency | 1.29 | 4.63 | **5.08** |
| claims completed | 15 | 39 | 74 |
| segments/claim | 14.0 | 17.9 | 24.4 |
| seconds/merge | 15.5 | 21.4 | 12.4 |
| rows/commit | 41,413 | 21,449 | **10,873** |
| p50 | 741 ms | 749 ms | **657 ms** |
| refused | 0 | 0 | 0 |
| buffer anon peak | - | - | 1,949 MB of 4,096 |

## Finding 1: commit size is not what governs sealing

Commits fell **41,413 -> 10,873 rows** while sealed throughput went
**46,308 -> 101,709**. A quarter the commit size, 2.2x the sealed rate.

This directly contradicts `2026-08-20-seal-parity-with-large-batches.md`, which
concluded larger commits seal faster. That conclusion held *within* the runs it
was drawn from - all at 3 refs - and does not generalise. **Read it as
"commit size matters when seal concurrency is pinned at 1.3".**

## Finding 2: seal concurrency saturates near 5

| refs | concurrency | gain |
|---|---|---|
| 3 -> 6 | 1.29 -> 4.63 | 3.6x |
| 6 -> 12 | 4.63 -> 5.08 | **1.1x** |

`max_concurrent_seals=4` x 3 storage pods = 12 slots. Measured ceiling is
about 5. Doubling refs past 6 buys nearly nothing in parallelism.

Sealed throughput still rose 29% from 6 to 12 refs, but because *individual*
merges got faster (21.4 s -> 12.4 s), not because more ran at once.

## Finding 3: concurrent merges contend, and it is measurable

Per-scrape deltas on one storage pod, 6-ref run. Claim size is nearly constant;
per-segment cost varies **4.3x**:

| time | segs/claim | s/claim | s/segment |
|---|---|---|---|
| 22:45:13 | 21.0 | 5.3 | **0.25** |
| 22:44:30 | 20.0 | 11.4 | 0.57 |
| 22:43:32 | 14.0 | 14.0 | 1.00 |
| 22:45:55 | 18.3 | 19.7 | **1.08** |

Grouped by how many claims finished in the same tick:

| claims in tick | mean s/claim |
|---|---|
| 1 | 10.7 s |
| 2 | 12.1 s |
| 3 | 19.7 s |

**Merges slow down as more run concurrently.** `Smolquery.StorageService.Merge`
documents the reason: a call's budget "is spent on a serialized connection,
where every other merge's staging call is this call's queue time."

The same run showed 2x variation *between* pods at equal claim size
(storage-1 13.2 s/claim; storage-0 26.6; storage-2 26.4). The two slow pods
were also servicing T-343's compaction retries.

Scrape ticks are ~14 s, so a merge spanning two ticks smears across both. The
4.3x spread is far larger than that error; the individual figures are coarse.

## Finding 4: the claim-size knob works, and does not help much

`seal_max_bytes` 64 -> 24 MiB at 48 VUs and 3 refs, single variable:

| | 64 MiB | 24 MiB |
|---|---|---|
| segments/claim | 37.5 | **14.0** |
| seconds/merge | 67.2 | **15.5** |
| rows per merge-second | 23,289 | 37,405 |
| seal:commit | 0.239 | **0.268** |

Claims capped as intended and merges ran 4.3x faster, but `seal:commit` moved
only 12% - because seal concurrency *fell* (1.49 -> 1.29). Faster merges just
added idle time to a cadence-bound cycle. The knob is real; it was not the
constraint.

## Best configuration measured

Ordinary 6.87 MiB requests. No client batching.

    SMOLQUERY_WRITE_PARTITIONS        12
    SMOLQUERY_SEAL_MAX_BYTES          25165824
    SMOLQUERY_CLAIM_VALVE_FACTOR      1
    SMOLQUERY_FLUSH_IDLE_INTERVAL_MS  300
    SMOLQUERY_FLUSH_MAX_BYTES         94000000
    48 VUs

    207,570 rows/s accepted · 101,709 sealed · seal:commit 0.49 · 0 refused
    p50 657 ms · buffer anon 1,949 MB of 4,096

Against the best client-batching result (3 VUs x 40,000 rows: 99,575 accepted,
95,691 sealed, `seal:commit` 0.96) this seals **6% more** while accepting
**108% more**, at lower latency.

Still not parity. `seal:commit` 0.49 means the hot tier grows under this load.

## Caveats

- **Claim-level counters are cluster-wide, not per table.** T-343's compaction
  retries and T-344's claim loop on older tables ran throughout. `seal:commit`
  and `rows/commit` come from buffer counters against one table's offered load
  and are unaffected.
- **Single runs.** `seal:commit` read 0.427 and 0.326 on identical settings
  earlier today. Prefer directions over magnitudes.
- All numbers are 3-minute windows on OTP 29.

## Next

1. **The merge path's serialized connection** is the ceiling. Partitioning
   past 12 cannot move it. This belongs in T-338 as a structural limit, and
   probably wants its own ticket.
2. **Find parity.** `seal:commit` 0.49 at 48 VUs; the sustainable VU count at
   12 refs is untested and is lower.
3. **T-343 and T-344** block clean measurement - the cluster cannot be drained
   while they retry.

## References

- Supersedes the headline of `2026-08-20-seal-parity-with-large-batches.md`
- T-338 (tuning surface), T-343 (compaction spill), T-344 (claim loop)
