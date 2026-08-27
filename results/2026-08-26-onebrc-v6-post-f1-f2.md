# 2026-08-26: a billion rows on `main@1a6a543` — the F-1 and F-2 fixes cost nothing on the upload

**The cluster took 1,000,000,000 rows in 103.1 s — 9,703,402 rows/s — at 48
workers, `count(*)` exact, zero restarts, and answered the 1BRC aggregate in
11.30 s median.** The upload matches yesterday's 103.6 s on `main@18117bb` to
half a second. The build rolled today carries the TLA+ findings F-1 and F-2
fixed — the replication gate (T-385), a durable reconciler for a released
claim's orphan (T-386) and a compensated flush's drop re-shipped until the
replicas ack (T-390) — 736 lines across the buffer's `hot_manifest.ex`,
`table_buffer.ex`, the sealer and the handoff, and none of it shows in the
numbers. Sealed rows equal committed rows equal accepted rows:
1,000,000,000 each, from the counters.

**The aggregate is 0.5 s slower than yesterday, and it is not the build.**
11.30 s median against 10.80 s, every one of ten runs slower, with one 18.9 s
outlier. The deployed diff touches no query code. The sealed layout differs
— 78 Parquet objects of 16.4 MB against 82 of 15.8 MB — and that is the
only server-side variable. One run each; read it as day-to-day noise until a
third run says otherwise.

**One explain call lost its response to a ten-minute network drop on the
bench machine, not to the server.** The harness's `explain: analyze` for the
distributed aggregate returned `:timeout` after 630 s. The pod sampler on
the same machine lost DNS for the EKS endpoint from 20:28:35Z to 20:38:31Z —
the exact window. Re-run by hand afterwards, the same explain answered in
25.9 s. The metrics database has a 596 s hole in the query phase; the
before/after scrapes below are whole and are the numbers to trust.

## Setup

Same harness, data and shape as [2026-08-25-onebrc-v5-and-s3-timings.md](2026-08-25-onebrc-v5-and-s3-timings.md).

- Cluster: smolquery `main@1a6a543` (image `sha256:f09fa89a`, deploy
  `d06db16`), rolled 19:24–19:26Z today. Zero restarts before, during, after.
  Tuning unchanged since 2026-08-21. The 429 conn-scope bug in
  `insert_controller.ex:68-83` is still in main. The three commits after
  `1a6a543` on main (MAP, VARIANT, docs) are not deployed.
- Table: `bench.onebrc_v6`, fresh, `onebrc_v1` schema, clustering `[station]`.
- Data: `measurements.1000000000.txt`, seed 42, regenerated on a fresh
  c7i.2xlarge (`i-0acb82d1a691e7a3f`) in 23 s. Same bytes as before.
- Upload: 48 workers, ~200,000 rows (8.9 MB) per request, 600 s deadline,
  launched 20:22Z through `mise exec` with `TABLE=onebrc_v6`,
  `LABEL_SUFFIX=-v6-w48`.

## The upload

| build | wall | rows/s | sent MiB/s | requests | 429 | resets | p50 | p95 | p99 | max | client cores | drain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `1a6a543` (today) | 103.1 s | 9,703,402 | 424.2 | 5,405 | 239 | 238 | 824 ms | 1,423 | 1,618 | 1,861 | 0.92 | 27 s |
| `18117bb` (2026-08-25) | 103.6 s | 9,649,356 | 431.1 | 5,523 | 299 | 296 | 733 ms | 1,462 | 1,699 | 2,115 | 0.87 | 28 s |

`count(*)` = 1,000,000,000 = `rows_accepted`. 4,928 bodies accepted both
days; the rest are refusals and their resets. Admission refused
48,508,118 rows today (`smolquery_buffer_admission_refused_rows_total`,
buffer pods), 20% fewer than yesterday. p50 is 90 ms higher, p99 80 ms
lower. Noise.

Pod CPU over the upload window: api 0.79–0.98 cores, buffer 1.44–1.63,
storage 1.10–1.20. Peak `memory.current`: api 918–1,011 MB, buffer
1,610–1,748 MB, storage 1,862–2,050 MB. Yesterday: buffer 1,893–2,044 MB,
storage 1,779–2,154 MB. Nothing moved.

Whole-run counter deltas from the before/after scrapes of every pod
(19:5xZ to 20:52Z, the cluster otherwise idle):

| counter | today | 2026-08-25 |
|---|---|---|
| `buffer_rows_committed_total` | 1,000,000,000 | 1,000,000,000 |
| `seal_segment_rows_total` | 1,000,000,000 | 1,012,583,470 (incl. the `onebrc_v1` tail) |
| `seal_attempts_total{ok}` | 78 | 82 |
| `seal_segments_total{ok}` | 4,928 | 4,989 |
| `seal_segment_bytes_total` | 1,277,450,236 | 1,293,512,714 |
| `seal_microseconds_total{ok}` | 277.5 s (3.56 s per seal) | 267.2 s (3.26 s per seal) |
| restarts, counter resets | 0, 0 | 0, 0 |

4,928 hot segments sealed for 4,928 accepted bodies: one micro-segment per
insert, and all of them consumed. The seal got 9% slower per attempt while
merging 63 segments each (yesterday 61); S3 put time per seal is the same,
so the extra 0.3 s is in the merge, inside noise for one run.

No counter with `replic`, `reconcil`, `tombstone` or `compensat` in its
name moved, and none exists yet in the render — the F-2 re-ship path has
no series of its own. This run does not prove that path was exercised;
it proves that a clean upload does not pay for it.

## The queries

| case | today median | today range | 2026-08-25 median | 2026-08-25 range |
|---|---|---|---|---|
| aggregate (distributed) | **11.30 s** | 11.19–18.87 s | 10.80 s | 10.74–10.94 s |
| aggregate, `distributed: false` | 28.24 s | 25.96–32.84 s | 27.56 s | 27.44–27.69 s |
| `count(*)` | 1.94 s | 1.83–2.01 s | 1.99 s | 1.91–2.05 s |

Ten runs each, zero errors. `durationMs` medians: 11.10 s, 27.90 s, 1.71 s.
The aggregate's ten wall times, in order: 11.25, 11.39, 11.30, 11.19,
11.26, **18.87**, 12.02, 12.18, 11.31, 11.20 s. Run 6 and the two after it
are the outlier; the other seven sit 0.4–0.6 s above yesterday's. The
single-engine case ranges wider than yesterday in both directions
(25.96 s is the fastest single-engine run measured so far); its 32.8 s
first run started seconds before two hand-run probes against the same
table, so do not read that maximum.

`smolquery_query_jobs_total{done}` grew by 43, `query_scattered_total` by
29, `scatter_shards_total` by 87 — three shards per scattered query,
across the three api pods, as yesterday.

## S3 request timings

Whole-run deltas from the scrapes, storage pods only:

| op | requests | bytes | time | mean | 2026-08-25 mean |
|---|---|---|---|---|---|
| `put` | 78 | 1,277,450,236 | 14.64 s | **188 ms** | 178 ms |
| `list` | 36 | — | 3.45 s | 96 ms | 88 ms |
| `head`, `delete` | 0 | | | | |

Per pod: 26 / 26 / 26 puts, 427.8 / 375.7 / 424.2 MB, 186 / 164 / 192 ms
mean. 77 of 78 puts in the 50–250 ms bucket, one in 250 ms–1 s (yesterday:
all 82 under 250 ms). Put bytes equal `seal_segment_bytes_total` to the
byte again: one put per seal, 16.4 MB per object. S3 is 5.3% of seal time
(14.64 s of 277.5 s). The 36 lists are the GC sweep at 300 s per pod over
a 62-minute window, four pages each, against a bucket that now holds one
more billion-row table.

## The lost explain

The harness sends `"explain": "analyze"` once per case after its timed
runs, with `timeoutMs` 600,000 and an HTTP receive timeout 30 s longer
(`scripts/loadgen.exs:822-841`). The aggregate case's ten runs ended about
20:28:20Z; its explain returned `{:error, :timeout}` 630 s later, so the
case shows `engine ?s` and `explain_error: ":timeout"`. The single-engine
and count explains, sent after 20:38:50Z, answered normally (27.74 s and
0.0 s engine time).

The pod sampler on the same machine logged `pod listing failed: … lookup
<eks endpoint>: no such host` 52 times, and the metrics database has no
tick between 20:28:35Z and 20:38:31Z. The api pods logged nothing but the
usual Bandit body-read errors from the 429 chain, all before 20:25:17Z.
Run by hand at 20:53Z, the same explain on the same table answered in
25.9 s (engine `Total Time: 25.32s`, `scatter: null` — explain runs the
single-engine plan, which is why yesterday's "distributed" explain also
read 26.6 s). The request left this machine into a dead network and its
response never arrived. Nothing server-side is implicated.

Two harness consequences, not fixed here:

- A lost explain costs the sweep the whole `timeoutMs` plus 30 s. The
  explain is diagnostic; it should carry its own, shorter timeout.
- The sampler prints one line per failed tick and keeps going, which is
  right; but the HTML report then buckets the hole as missing, and any
  `max - min` over the database under-reads. Use the scrapes.

## Caveats

- One run, one point. The upload matches two previous runs within 1%;
  the 0.5 s on the aggregate is one day against one day.
- The metrics database has a 596 s hole in the query phase. Every
  whole-run number above comes from the before/after `/metrics` scrapes,
  which are not affected. Per-phase splits from the database are
  incomplete for the query phase.
- `onebrc_v1` still holds 1,246,393,006 rows from yesterday's aborted
  launch.

## Next

1. A third aggregate run on this build, on `onebrc_v6`, with
   `ONEBRC_UPLOAD=false` — twenty repeats — to settle whether 11.3 s is the
   number now or 10.8 s was.
2. Give the explain call its own timeout in `scripts/loadgen.exs`
   (`EXPLAIN_TIMEOUT_MS`, default 120 s) so a lost response costs two
   minutes, not ten.
3. Unchanged from 2026-08-25: chart `smolquery_s3_*` in the HTML report;
   fix the `with`/`else` scope in `insert_controller.ex:68-83`.

## References

- HTML report: [loadgen-20260826T202252Z-v6-w48.html](loadgen-20260826T202252Z-v6-w48.html)
  — `results/raw-loadgen/loadgen-onebrc-v6-w48.{upload,onebrc}.json`,
  `results/raw-loadgen/loadgen-20260826T202252Z-v6-w48.metrics.sqlite3`
  (holed 20:28:35–20:38:31Z).
- The build: `~/Dev/supabase/smolquery` `git diff --stat 18117bb..1a6a543 -- lib`
  — 15 files, all under `buffer_service/` and `storage_service/`.
  Deploy: `~/Dev/supabase/smolquery-deploy` `d06db16`.
- The explain path in the harness: `scripts/loadgen.exs:822-841`.
