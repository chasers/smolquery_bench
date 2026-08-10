# smolquery_bench

Ingest benchmark comparing [smolquery](https://github.com/chasers/smolquery)
against ClickHouse, as fairly as possible, modeled on
[abc3/load-rig](https://github.com/abc3/load-rig). Both systems receive the
**identical NDJSON body** — 3,062 OpenTelemetry log rows × 62 columns
(~6.4 MiB) — over HTTP: smolquery via `POST …/insert`
(`application/x-ndjson`), ClickHouse via `INSERT … FORMAT JSONEachRow`.

## Prerequisites

- macOS with [k6](https://k6.io) and ClickHouse: `brew install k6 clickhouse`
- Go (for the body generator and the process watcher)
- A smolquery checkout with compiled deps (default `~/Dev/supabase/smolquery`,
  override with `SMOLQUERY_DIR`)

## Quick start

```sh
scripts/gen-bodies.sh                 # bodies/eachrow.3062.ndjson, seed 42

scripts/setup-smolquery.sh           # cold data dir, server, dataset + table + clustering
scripts/run-arm.sh smolquery         # preflight → 20s warm-up → 15s pause → 60s measured

scripts/setup-clickhouse.sh          # cold path, server, table, fsync settings
scripts/run-arm.sh clickhouse

scripts/report.sh                    # markdown table from results/raw/
scripts/stop.sh                      # stop both servers
```

Full VU sweep (cold table before every run):

```sh
scripts/sweep.sh smolquery           # VUS_LIST="1 4 8 16 32" by default
scripts/sweep.sh clickhouse
```

Knobs (env vars): `VUS`, `MODE=rate RATE=30` (open loop), `DURATION_S`,
`WARMUP_S`, `ROWS`, `SEED`; smolquery tuning via `FLUSH_MAX_BYTES`,
`FLUSH_INTERVAL_MS`, `WRITE_POOL_SIZE`, `ENCODE_CONCURRENCY`; ClickHouse
durability via `FSYNC=0`. Servers log to `/tmp/sqbench/`.

Reading low-VU smolquery numbers: group commit acks when either
`FLUSH_MAX_BYTES` accumulates or `FLUSH_INTERVAL_MS` elapses. At the default
32 MiB / 1000 ms, closed-loop runs below ~5 VUs never hit the byte trigger, so
p50 sits at ~1 s and throughput is ack-latency-bound — that is the configured
durability cadence, not a ceiling. The load-rig reference used a 4.5 MB flush
threshold for its low-VU rows for exactly this reason.

## Fairness rules (equal across arms)

- Identical NDJSON bodies from one deterministic `gen-bodies.sh` run.
- Cold table each run: data directory erased, server restarted.
- One server at a time; k6 runs on the same machine (shared caveat — the
  watcher reports k6's CPU so contention is visible).
- Durability parity: ClickHouse runs with `async_insert` off (default) plus
  `fsync_after_insert = 1, fsync_part_directory = 1`, matching smolquery's
  fsync-before-200. `FSYNC=0` gives the weaker page-cache-only arm.
- Same clustering/sort key on both: `(project_id, timestamp)`.
- Protocol per run: preflight insert (fails on `insertErrors`), 20 s warm-up,
  15 s pause, 60 s measured, 5 s graceful stop.

## Known asymmetries (denoted, not hidden)

| Dimension | smolquery | ClickHouse |
|---|---|---|
| What a 200 means | manifest fsynced, rows queryable | part fsynced (with the settings above) |
| Row validation | deferred to flush; failed batches salvaged row by row | parses/validates every JSONEachRow row inline |
| Nullability | all columns nullable | all `Nullable(...)` except the two ordering keys (MergeTree keys cannot be nullable) — note the load-rig reference declared only 4 nullable columns, which favors ClickHouse |
| Timestamp parsing | ISO 8601 without zone suffix (`2026-08-01T10:00:00.000000`) — the one format both default parsers accept; ClickHouse's `basic` parser rejects a trailing `Z` | same body, default `date_time_input_format=basic` |
| Platform | BEAM release on macOS | Linux-tuned binary on macOS |
| Tuning applied | `FLUSH_MAX_BYTES=32MiB`, `WRITE_POOL_SIZE=4`, `ENCODE_CONCURRENCY=4`, `MAX_BUFFERED_BYTES=128MiB` | table-level fsync settings only |

## Layout

```
tools/genbody/    deterministic 62-column OTel NDJSON generator
tools/watch/      CPU/RSS sampler (ps-based) for server + k6
k6/insert.js      closed-loop (VUS) or open-loop (RATE) load script
schemas/          smolquery table-create JSON + ClickHouse MergeTree DDL
scripts/          setup / run / sweep / stop / report
results/raw/      per-run k6 + watch JSON
```

## Reference numbers

From load-rig's published run (M1 Pro, 10 cores, 16 GB):
smolquery DuckDB writer peaked at **383,157 rows/s** (32 VU, pool=4, enc=4)
vs ClickHouse's **165,814 rows/s** with matching fsync durability. New results
should land in that ballpark; investigate before publishing if they don't.
