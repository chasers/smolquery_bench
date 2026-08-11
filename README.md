# smolquery_bench

Ingest benchmark: [smolquery](https://github.com/chasers/smolquery) against
ClickHouse, as fairly as possible, following
[abc3/load-rig](https://github.com/abc3/load-rig). Both arms get the **identical
NDJSON body** — 3,062 OpenTelemetry log rows × 62 columns, ~6.7 MiB — smolquery
via `POST …/insert` (`application/x-ndjson`), ClickHouse via
`INSERT … FORMAT JSONEachRow`.

## Prerequisites

macOS with k6 and ClickHouse (`brew install k6 clickhouse`), Go, Elixir 1.18 or
later, and a smolquery checkout with compiled deps (`SMOLQUERY_DIR`, default
`~/Dev/supabase/smolquery`).

## Quick start

```sh
scripts/gen-bodies.exs               # bodies/eachrow.3062.ndjson, seed 42

scripts/setup-smolquery.exs          # cold data dir, server, dataset, table, clustering
scripts/run-arm.exs smolquery        # preflight, 20s warm-up, 15s pause, 60s measured

scripts/setup-clickhouse.exs         # cold path, server, table, fsync settings
scripts/run-arm.exs clickhouse

scripts/report.exs                   # markdown table from results/raw/
scripts/stop.exs                     # stops both servers

scripts/sweep.exs smolquery          # full VU sweep, VUS_LIST="1 4 8 16 32 64"
scripts/sweep.exs clickhouse         # cold table before each run
```

## Knobs

- **Load**: `VUS`, `DURATION_S`, `WARMUP_S`, `ROWS`, `SEED`; `MODE=rate RATE=30`
  for an open loop.
- **smolquery**: `FLUSH_MAX_BYTES`, `FLUSH_INTERVAL_MS`, `WRITE_POOL_SIZE`,
  `ENCODE_CONCURRENCY`, `WRITE_ENGINE_THREADS` (DuckDB threads per pool member;
  unset means they divide across the pool), plus `COMMIT_SIBLINGS` and
  `FLUSH_IDLE_INTERVAL_MS` on builds that carry the adaptive group-commit wait.
- **ClickHouse durability**: `FSYNC=0`. Servers log to `/tmp/sqbench/`.
- **Run naming**: `LABEL_SUFFIX` tags a run, and `RESULTS` sends its JSON to
  another directory. Use both to keep an A/B out of the baseline raw files.

## Fairness rules (equal across arms)

- Identical bodies from one deterministic `gen-bodies.exs` run.
- Cold table each run: data dir erased, server restarted.
- One server at a time; k6 shares the machine, and the watcher reports its CPU.
- Durability parity: `async_insert` off (default) plus `fsync_after_insert = 1`
  and `fsync_part_directory = 1`, to match how smolquery fsyncs before a 200.
  `FSYNC=0` is the weaker page-cache-only arm.
- Same sort key on both: `(project_id, timestamp)`.
- Per run: preflight (fails on `insertErrors`), 20 s warm-up, 15 s pause, 60 s
  measured, 5 s stop.
- On a 429 (`buffer_full`) the VU sleeps out `retry-after`, up to 2 s.
  Percentiles cover accepted requests; refusals count separately.

## How to read the low-VU smolquery numbers

Group commit acks on the first trigger: 48 MiB (`FLUSH_MAX_BYTES`) or 1,000 ms
(`FLUSH_INTERVAL_MS`). Below ~5 VUs a closed loop never reaches the byte trigger,
so p50 sits near 1 s — **the configured durability cadence, not a ceiling**.

## Known asymmetries (denoted, not hidden)

| Dimension | smolquery | ClickHouse |
|---|---|---|
| What a 200 means | Manifest fsynced, rows queryable | Part fsynced, with the settings above |
| Row validation | Deferred to the flush; a failed batch is salvaged row by row | Every JSONEachRow row parsed inline |
| Nullability | Every column nullable | Every column except the two ordering keys, since MergeTree keys cannot be nullable — load-rig declared only 4, which favors ClickHouse |
| Timestamp parsing | ISO 8601 without a zone suffix (`2026-08-01T10:00:00.000000`), the one format both default parsers accept; the `basic` parser rejects a trailing `Z` | Same body, default `date_time_input_format=basic` |
| Platform | BEAM release on macOS | Linux-tuned binary on macOS |
| Tuning applied | `FLUSH_MAX_BYTES=48MiB`, `WRITE_POOL_SIZE=10`, `ENCODE_CONCURRENCY=10` (schedulers online), `MAX_BUFFERED_BYTES=128MiB` | Table-level fsync settings only |

## Layout

```
tools/genbody/    deterministic 62-column OTel NDJSON generator
tools/watch/      CPU and RSS sampler, ps-based, for the server and k6
k6/insert.js      load script, closed loop (VUS) or open loop (RATE)
schemas/          smolquery table-create JSON, ClickHouse MergeTree DDL
scripts/          setup, run, sweep, stop, report
results/raw/      k6 and watch JSON per run (gitignored)
results/*.md      dated baseline writeups
```

## Reference numbers

load-rig, on an M1 Pro with 10 cores and 16 GB: smolquery peaked at **383,157
rows/s** (32 VU, pool=4, enc=4), ClickHouse at **165,814 rows/s** with matching
fsync. Land in that range, and **investigate a large gap before you publish**.

Latest measured baseline:
[results/2026-08-10-baseline.md](results/2026-08-10-baseline.md). ClickHouse runs
well above its reference here, because fsync costs ~3% on this hardware against
54% on the reference setup. The low-VU floor above is what smolquery
[PR #124](https://github.com/chasers/smolquery/pull/124) removes — see
[results/2026-08-11-pr124-adaptive-group-commit.md](results/2026-08-11-pr124-adaptive-group-commit.md).
