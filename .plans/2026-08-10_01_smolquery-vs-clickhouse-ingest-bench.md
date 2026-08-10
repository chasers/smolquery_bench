# smolquery vs ClickHouse ingest benchmark suite

## Goal

A simple, repeatable ingest benchmark comparing smolquery (DuckDB writer — the
only supported writer now; Polars is gone) against ClickHouse, as fairly as
possible. Modeled on abc3/load-rig, whose published results are the reference:

| System | Peak rows/s | Config | p50 |
|---|---|---|---|
| smolquery DuckDB writer | 383,157 | 32 MB flush, 32 VU, pool=4, enc=4 | 242 ms |
| smolquery DuckDB writer | 231,898 | 32 MB flush, 16 VU, enc=4 | 193 ms |
| ClickHouse (fsync on) | 165,814 | 4 VU closed-loop | 73 ms |

We should land in the same ballpark as the DuckDB-writer numbers. Reference:
https://github.com/abc3/load-rig/blob/main/results/smolquery-polars-vs-duckdb-and-clickhouse.md

## Answer: should we use kind?

**No.** Reasons:

- The reference numbers were produced on bare macOS (M1 Pro). Docker on macOS
  runs inside a VM; kind adds a Kubernetes layer on top of that. Numbers would
  not be comparable to the reference at all.
- kind adds network hops (kube-proxy/NAT), control-plane noise, and makes
  per-process CPU/RSS accounting (the `watch.go` metric) much harder.
- Neither system needs orchestration for a single-node ingest test.

Start bare-metal on macOS exactly like load-rig did. If we later want Linux
parity, plain Docker (or two dedicated VMs) with pinned `--cpus`/`--memory` is
the step after this — still not kind.

## Approach

**Update 2026-08-10: rebuild the harness from scratch** (user decision — no
submodule). Same shape as load-rig: a body generator, a k6 insert script, and a
process watcher. Generator and watcher are small Go programs; only the load
script needs k6. Workload parity with the reference comes from reusing the same
schema: smolquery's own 61-column OTel fixture (`bench/otel_support.exs`) plus
`project_id STRING` — exactly load-rig's `schema.json`.

Both systems receive **the same NDJSON body** (`eachrow.N.ndjson` from
`generate.js`) — smolquery now accepts NDJSON exclusively, ClickHouse takes it
as `FORMAT JSONEachRow`. Same 3,062 rows × 62 OTel columns per request, same
seed, no compression.

### Repo layout

```
smolquery_bench/
  .plans/
  tools/
    genbody/main.go  # deterministic NDJSON body generator (62-col OTel rows, SEED)
    watch/main.go    # CPU/RSS sampler for server + k6 processes (via ps)
  k6/
    insert.js        # closed-loop (VUS) or open-loop (RATE) POST of one body file
  schemas/
    otel_logs.smolquery.json   # table-create payload
    otel_logs.clickhouse.sql   # equivalent MergeTree DDL
  scripts/               # Elixir scripts since 2026-08-10 (bench.exs = shared lib; see plan _02)
    gen-bodies.exs       # build eachrow.N.ndjson with fixed seed
    setup-smolquery.exs  # fresh SMOLQUERY_DATA_DIR, start server, create dataset/table + clustering
    setup-clickhouse.exs # fresh data dir, start server, create table, apply fsync settings
    run-arm.exs          # preflight → warm-up → pause → measured run with watch, writes JSON
    sweep.exs            # runs the full VU matrix for one target
    stop.exs             # stop a running server
    report.exs           # markdown table from results/raw/*.json
  results/raw/         # per-run k6 + watch JSON
  README.md
```

Notable knobs confirmed against the current smolquery repo: the reference
tuning maps to `SMOLQUERY_FLUSH_MAX_BYTES=33554432`,
`SMOLQUERY_WRITE_POOL_SIZE=4`, `SMOLQUERY_ENCODE_CONCURRENCY=4`,
`SMOLQUERY_FLUSH_WRITER=duckdb` (the default and only writer; polars is
legacy). `SMOLQUERY_MAX_BUFFERED_BYTES` must stay comfortably above the flush
threshold, so the bench sets it to 128 MB. Inserts are NDJSON-only
(`application/x-ndjson`) — both arms receive the identical body file.

### Fairness rules (equal across arms)

- Identical NDJSON bodies, identical rows, single `generate.js` output reused.
- Cold table each run: data dir erased, server restarted.
- Sequential: one server running at a time, k6 on the same machine (as in the
  reference — note this as a shared caveat).
- Durability parity: ClickHouse gets `async_insert` off (default) and
  `ALTER TABLE ... MODIFY SETTING fsync_after_insert = 1, fsync_part_directory = 1`
  to match smolquery's fsync-before-200. Also record a ClickHouse-defaults
  (no fsync) arm, clearly labeled as weaker durability.
- Same clustering/sort key: `(project_id, timestamp)` on both.
- Protocol: 60 s measured, 20 s warm-up, 15 s pause, 5 s graceful stop.
- VU sweep: 1, 4, 8, 16, 32 closed-loop; optional open-loop rate probes later.

### Known asymmetries (documented, not hidden)

| Dimension | smolquery | ClickHouse |
|---|---|---|
| 200 means | manifest fsynced + queryable | part fsynced (with settings above) |
| Row validation | none per-row on DuckDB writer | parses/validates JSONEachRow |
| Nullability | all columns nullable | only 4 nullable in reference DDL — mirror smolquery (all nullable) or note it |
| Timestamp format | whatever generate.js emits | `date_time_input_format=basic` compatible |
| Platform | BEAM release, macOS | Linux-tuned binary running on macOS |
| Tuning | flush=32 MB, pool=4, enc=4 (reference best) | table settings only |

### Metrics captured per run

rows/s accepted, p50/p95/p99 latency, error/refused count, server CPU avg/peak,
server RSS mean/peak, k6 CPU (via watch.go). Raw k6 `JSON_OUT` + watch JSON
saved under `results/raw/`.

## Work items

1. [x] Confirm current smolquery knobs and schema (done: 61-col OTel fixture
       + `project_id`; `SMOLQUERY_FLUSH_MAX_BYTES` / `WRITE_POOL_SIZE` /
       `ENCODE_CONCURRENCY` / `FLUSH_WRITER=duckdb`; NDJSON-only inserts).
2. [x] `tools/genbody`: deterministic 62-column OTel NDJSON generator —
       6.74 MiB / 2308 B per row at 3062 rows (reference: 6.41 MiB). Timestamps
       are ISO without a zone suffix: ClickHouse's default `basic` parser
       rejects a trailing `Z` but accepts `2026-08-01T10:00:00.123456`, so one
       body serves both arms with default parsers.
3. [x] `tools/watch`: per-pattern CPU/RSS sampler over `ps`, JSON out.
4. [x] `k6/insert.js`: closed/open loop, rows-accepted counter, JSON summary.
5. [x] Schemas: smolquery table-create JSON + ClickHouse MergeTree DDL.
6. [x] Scripts: gen-bodies, setup-smolquery (also exposes
       `FLUSH_INTERVAL_MS`), setup-clickhouse (FSYNC=1 default), run-arm
       (preflight fails on non-empty `insertErrors`), sweep, stop, report.
7. [x] README + .gitignore, `git init` (no commit yet).
8. [x] Installed k6 2.2.0 + clickhouse 26.7.3 (brew; needed
       `xattr -d com.apple.quarantine` on the clickhouse binary). Smoke runs
       (10 s measured, 4 VUs): clickhouse-fsync 236,910 rows/s p50 46 ms;
       smolquery 11,063 rows/s p50 1,106 ms at 4 VUs (ack-latency-bound below
       the 32 MiB byte trigger — expected) and 244,077 rows/s p50 172 ms at
       16 VUs, in line with the reference's 231,898–306,733.
9. [x] Baseline session: full sweep both arms, sanity-check against reference
       numbers (smolquery ≈ 2× ClickHouse-with-fsync at peak). Investigate if
       we're far off before publishing.
   - Harness fix along the way: the watcher's `beam.smp` pattern also
     matched VS Code's ElixirLS BEAM (430 MB RSS), polluting every server
     CPU/RSS stat; it now matches `beam\.smp.*mix run --no-halt`.
   - Full writeup: `results/2026-08-10-baseline.md`.
   - Baseline (2026-08-10 12:59–13:27, Elixir scripts) completed both
     arms cleanly. Peaks: smolquery 254,240 rows/s @16VU (0 refused);
     ClickHouse-fsync 439,836 @32VU / 377,606 @16VU / 264,832 @4VU.
     Two deviations from the reference to investigate before publishing:
     - smolquery @32VU collapsed to 78,586 rows/s with 353,320 refusals
       (429 buffer_full: 32 VUs × 6.74 MiB ≈ 215 MiB in flight vs
       MAX_BUFFERED_BYTES=128 MiB; the new retry-after backoff also lowers
       offered load vs load-rig's immediate-retry behavior). Confirmed by
       diagnostic: `smolquery-vus32-buf256` (MAX_BUFFERED_BYTES=256 MiB) did
       306,287 rows/s, 0 refused, p50 302 ms, server CPU avg 468% — the
       32VU baseline row measures the buffer cap, not the writer. Publish
       either with the 256 MiB cap denoted as tuning, or keep 16VU as the
       128 MiB-config peak.
     - ClickHouse-fsync is ~1.6–2.7× the reference arm at every VU level
       (264,832 @4VU vs reference 165,814), so smolquery no longer leads at
       peak on this machine (M-series 10 cores / 64 GB, CH 26.7.3). Needs a
       closer look (newer ClickHouse, more RAM) before publishing claims.

## Out of scope (for now)

- Query benchmarks, mixed read/write workloads.
- kind/Kubernetes, multi-node smolquery, object-storage (S3) backends.
- Compression on the wire.
- Separate load-generator machine (note as caveat, revisit if CPU contention
  shows up in watch.go output).
