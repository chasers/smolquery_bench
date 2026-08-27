# 2026-08-25: a billion rows again on `main@18117bb`, and the first S3 request timings

**The cluster took 1,000,000,000 rows in 103.6 s — 9,649,356 rows/s — at 48
workers, `count(*)` exact, zero restarts, and answered the 1BRC aggregate in
10.80 s median.** Same numbers as 2026-08-24 (48 workers: 9.93M rows/s) and
2026-08-22 (10.7 s), within noise. Today's build adds nothing to the ingest
path; this run re-checks it.

**The sealed object store cost 82 `put` requests, 178 ms each, for the whole
billion rows.** One put per seal attempt, 15.8 MB per object, 1,293,512,714
bytes in total — 1.29 B per row of Parquet. Every put landed between 50 ms and
250 ms. Each storage pod spent 4.7–5.0 s waiting on S3 during the 103.6 s
upload, and **S3 is 5.5% of seal time**: 82 seals took 267.2 s of merge work
(3.26 s each) against 14.6 s of put. The rest is DuckDB reading ~61 hot
micro-segments per seal off the buffer pods. No `head`, no `delete`, and the
only `list` calls were the GC sweep, 12 of them at 88 ms mean.

## Setup

Same harness and data as [2026-08-24-onebrc-ingest-worker-sweep.md](2026-08-24-onebrc-ingest-worker-sweep.md),
one point, with the query phase on.

- Cluster: smolquery `main@18117bb` (image `sha256:388d9e20`, deploy
  `77aa26a`), rolled 16:45Z today. It carries T-379 (every `Store.S3` request
  timed and counted), T-380 and T-381 (`Telemetry.span/3`, one clock). Tuning
  unchanged since 2026-08-21. All nine pods zero restarts before, during and
  after. The 429 conn-scope bug in `insert_controller.ex:68-83` is still in
  main, so every 429 still costs one reset and one re-sent body.
- Table: `bench.onebrc_v5`, fresh, `onebrc_v1` schema, clustering `[station]`.
- Data: `measurements.1000000000.txt`, seed 42, regenerated on a fresh
  c7i.2xlarge (`i-0224797897137b25a`) in 22 s. Same bytes as before.
- Upload: `tools/upload1brc`, 48 workers, ~200,000 rows (8.9 MB) per request,
  600 s deadline. Launched 17:02Z as
  `mise exec -- sh -c 'BASE_URL=… BENCHES=onebrc TABLE=onebrc_v5 ONEBRC_WORKERS=48 ONEBRC_UPLOAD_DEADLINE_S=600 LABEL_SUFFIX=-v5-w48 elixir scripts/loadgen.exs sweep'`.

## The upload

| workers | wall | rows/s | sent MiB/s | requests | 429 | resets | p50 | p95 | p99 | max | client cores | drain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 48 | 103.6 s | 9,649,356 | 431.1 | 5,523 | 299 | 296 | 733 ms | 1,462 | 1,699 | 2,115 | 0.87 | 28 s |

`count(*)` = 1,000,000,000 = `rows_accepted`. 4,928 bodies were accepted;
the other 595 requests were the 299 refusals and their 296 resets. Against
the 2026-08-24 48-worker point (100.7 s, 207 × 429, p50 813 ms) this is 3%
slower with 44% more refusals — one run each, so noise, not a trend.

Pod CPU over the upload window, from `bench_pod_cpu_usec_total`: api
0.85–0.92 cores, buffer 1.37–1.59, storage 1.01–1.13. Peak
`memory.current`: api 873–925 MB, buffer 1,893–2,044 MB, storage
1,779–2,154 MB. The buffer tier sat 2.2 GB under its 4,295 MB limit; on
2026-08-24 the 48-worker point peaked at 3,654–3,813 MB. Page cache is
included in both figures, so read the gap as headroom, not a change.

Sealing over the run: 82 attempts, all ok, 4,989 hot segments merged,
1,012,583,470 rows written. The 12.6M excess over the billion committed is
the tail of the aborted launch (below) sealing into `onebrc_v1` inside the
first samples. Zero compaction, zero GC deletes, zero counter resets.

## The queries

| case | wall median | wall range | `durationMs` median | engine |
|---|---|---|---|---|
| aggregate (distributed) | **10.80 s** | 10.74–10.94 s | 10.55 s | 26.59 s |
| aggregate, `distributed: false` | 27.56 s | 27.44–27.69 s | 27.29 s | 26.84 s |
| `count(*)` | 1.99 s | 1.91–2.05 s | 1.78 s | — |

Ten runs each, zero errors. 2026-08-22 measured 10.7 s, 27.5 s and 2.0 s.

**The query role lives on the api pods, not the storage pods.** The
`smolquery-api` StatefulSet runs `SMOLQUERY_ROLES=api,ingest,query,web`;
buffer and storage pods hold only their own role. During the eight-minute
query phase the storage pods averaged 0.01–0.03 cores and the buffer pods
0.01, while api-1 averaged 1.74 cores and api-0 and api-2 0.41–0.44. The
sealed Parquet is read from S3 by DuckDB on the api pods; nothing on the
storage tier serves a query once the hot tier is empty. The 2026-08-22
write-up's "three shards across the three storage pods" was wrong on that
point — the shards fan out across the three api pods.

## S3 request timings

T-379 wraps every `Store.S3` HTTP request in `Telemetry.span/3`
(`segments/store/s3.ex:437`). The `put` span (`s3.ex:369`) times only the
upload of an already-encoded staged file — the DuckDB copy that produces the
file runs before it. Four series, on the storage pods only, since the buffer
tier's store is local (`config/runtime.exs:355`):
`smolquery_s3_requests_total{op,class}`,
`smolquery_s3_request_microseconds_total{op}`,
`smolquery_s3_request_bytes_total{op}` and
`smolquery_s3_request_microseconds_bucket{op,le}` with bounds 10 ms, 50 ms,
250 ms, 1 s, 5 s. Ops are `put`, `head`, `list`, `delete`. There is no `get`:
reads go through DuckDB httpfs, not `Store.S3`.

Deltas over the run's metrics database (17:02:40–17:13:40Z), summed from
consecutive samples so phase boundaries lose nothing:

| op | requests | class | bytes | time | mean | where |
|---|---|---|---|---|---|---|
| `put` | 82 | all 2xx | 1,293,512,714 | 14.63 s | **178 ms** | 79 in the upload window, 3 in the drain tail |
| `list` | 12 | all 2xx | — | 1.07 s | 88 ms | 4 in the drain, 8 in the query phase |
| `head` | 0 | | | | | |
| `delete` | 0 | | | | | |

Per storage pod: storage-0 27 puts, 422.1 MB, 4.72 s (175 ms mean);
storage-1 28 puts, 441.2 MB, 4.99 s (178 ms); storage-2 27 puts, 430.1 MB,
4.92 s (182 ms). Even to within one put.

Every put fell in the 50–250 ms bucket; none under 50 ms, none over 250 ms.
Every list fell in the same bucket. The buckets are cumulative counters, and
the render omits an empty one — a missing `le="10000"` line means zero, not
missing data.

What the puts are, from the code, not the counters:

- **One put is one seal attempt.** `storage_service/merge.ex:300` calls
  `Store.put` once per merged output. 82 puts against
  `smolquery_seal_attempts_total{result="ok"}` = 82, and
  `smolquery_s3_request_bytes_total{op="put"}` = 1,293,512,714 =
  `smolquery_seal_segment_bytes_total` to the byte. So `put` bytes are the
  sealed table's size: 1,233.6 MiB of Parquet for a billion two-column rows,
  15.8 MB per object at ~24 MiB `seal_max_bytes`.
- **A put moves 15.8 MB in 178 ms — 88 MB/s per request**, one request at a
  time per pod. That is the sealed tier's write bandwidth as the code uses
  it today: ~3 × 88 MB/s across the tier if every pod is mid-put.
- **S3 is 5.5% of a seal.** `smolquery_seal_microseconds_total{result="ok"}`
  grew 267.2 s over 82 attempts, 3.26 s each, against 178 ms of put. The
  other 3.08 s is the merge: DuckDB on the storage pod reading ~61 hot
  micro-segments (4,989 / 82) from the buffer pods' `HotServer` over HTTP
  and writing the Parquet. Faster S3 would not move the seal rate; a cheaper
  hot-tier read would.
- **The lists are GC.** `storage_service/gc.ex:136` lists the whole store
  prefix every `gc_interval_ms` = 300 s (`config/config.exs:132`). 88 ms per
  page against a bucket that now holds fifteen `onebrc*` and thirty
  `otel_logs*` tables. `hot_manifest.ex:733` also lists, but on the buffer
  tier, whose store is local.

## The aborted first launch

The first launch, 17:00Z, went into `bench.onebrc_v1`: the `bench-onebrc`
mise task carries `env = { TABLE = "onebrc_v1" }`, and mise applies the task
env over an inline `TABLE=onebrc_v5`. `onebrc_v1` already held the
2026-08-22 8-worker billion. The orchestrator was killed after ~30 s and the
uploader stopped on the box over SSM (`pkill -f upload1brc`). **`onebrc_v1`
now holds 1,246,393,006 rows**, not 1,000,000,000 — do not use it for a
query number. Its 246M extra rows sealed into 18 puts before this run's
sampler started, which is why the whole-day scrape delta (100 puts,
1,592 MB) is larger than the run's (82, 1,293 MB). The run's own metrics
database is clean of them.

To pick a table or a worker list, bypass the task:
`mise exec -- sh -c 'BENCHES=onebrc TABLE=… elixir scripts/loadgen.exs sweep'`.

## Caveats

- One run, one point, one build. It matches two earlier runs; it is not a
  curve.
- The S3 series see `Store.S3` only: seal puts, GC lists and heads, deletes.
  Query reads through httpfs are invisible here, so nothing above prices a
  query's S3 cost.
- `put` time is the HTTP upload of a staged file. Encoding time is in the
  seal counter, not the S3 counter.
- The HTML report does not chart the `smolquery_s3_*` series yet; they
  appear in its trailing table.

## Next

1. Chart `smolquery_s3_*` in `scripts/report_html.exs`: requests, mean
   ms and bytes per op, per bucket.
2. The seal is 95% merge. Time the hot-tier read inside a seal
   (`smolquery_hot_*` series against `smolquery_seal_microseconds_total`)
   before touching S3.
3. Fix the `with`/`else` scope in `insert_controller.ex:68-83` (2026-08-24
   write-up) and re-run 48 and 64 workers.

## References

- HTML report: [loadgen-20260825T170240Z-v5-w48.html](loadgen-20260825T170240Z-v5-w48.html)
  — `results/raw-loadgen/loadgen-onebrc-v5-w48.{upload,onebrc}.json`,
  `results/raw-loadgen/loadgen-20260825T170240Z-v5-w48.metrics.sqlite3`.
- The spans: `~/Dev/supabase/smolquery/lib/smolquery/segments/store/s3.ex:244,275,369,388,437`;
  the series: `lib/smolquery/telemetry.ex:283-296,327,592-599`. Seal put:
  `lib/smolquery/storage_service/merge.ex:300`. GC list:
  `lib/smolquery/storage_service/gc.ex:136`, `config/config.exs:132`.
- Roles: `kubectl get statefulset smolquery-api -n smolquery -o jsonpath=…env`
  → `SMOLQUERY_ROLES=api,ingest,query,web`; buffer `buffer`; storage `storage`.
