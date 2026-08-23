# 2026-08-22: one billion rows in 113 seconds, and the 1BRC query in 10.7 s

**The cluster took 1,000,000,000 rows in 113.3 s — 8,825,572 rows/s sustained
— with zero refusals, zero retries, zero restarts, and sealing at parity.**
`count(*)` afterwards returned exactly 1,000,000,000. That was 16 workers; 8
workers did it in 152.8 s (6,542,846 rows/s). Neither run saturated anything,
so the ceiling is still above 16 workers.

**The 1BRC aggregate over those rows answers in 10.7 s median** (10.6–12.1 s
over ten runs) on the distributed path, three shards across the three storage
pods. The single-engine path takes 27.5 s (27.2–27.8 s). `count(*)` takes
2.0 s.

**A `round()` around `avg()` silently cost 2.6×.** The first query pass wrote
`round(avg(temperature), 1)` into the SQL — the challenge's one-decimal output
format, folded into the query — and `decomposer.ex:327` refuses any function
that wraps an aggregate (`unsupported_aggregate_shape`), so both the default
and `distributed: false` ran the same single-engine plan at 27.5 s. Rounding is
presentation. Keep it out of the SQL.

## Setup

The challenge in spirit, not by its rules: the 413 stations and means from
[gunnarmorling/1brc](https://github.com/gunnarmorling/1brc), Gaussian
temperatures (stddev 10) to one decimal, and the same query. Not the Java
generator, not the same bytes.

- Cluster: smolquery `07f632e` (image `sha256:eac686a9`), the 2026-08-21
  tuning unchanged — 3 write partitions, 8 live claims,
  `STORAGE_MEMORY_LIMIT` 3584MiB, `seal_max_bytes` 24MiB, valve factor 1,
  `INSERT_MAX_NDJSON_BYTES` 100 MB. 3 api pods on m7i.large, 3 buffer and 3
  storage pods on m7i.xlarge. Distributed query on by default (PL-49).
- Table: `bench.onebrc_v1` — `station` STRING, `temperature` FLOAT64, no
  `inserted_at`. Clustering `[station]`. The 16-worker run used a fresh
  `onebrc_v2` with the same schema, so each table holds exactly 1B rows.
- Data: `tools/gen1brc` wrote `measurements.1000000000.txt` on the loadgen
  box — 13,796,047,297 bytes, 13.8 B/row, seed 42 — in about 17 s at
  830 MiB/s. The file stayed on disk as the source.
- Upload: `tools/upload1brc` streamed the CSV as NDJSON
  (`{"station":"Abha","temperature":18.3}`, ~42 B/row) to
  `POST …/insert`, ~200,000 rows per request (8.5 MB), round-robin across
  the three api pod IPs from the in-region c7i.2xlarge. Every batch carried
  an `insertId`, so a retry could not double-count. The `/load` route takes
  CSV but parses the whole body through Explorer on the api pod before the
  same insert client; it was not used.
- Queries: from this machine over Cloudflare to port 8443, the same path as
  every pruning number in this repo. `wall_ms` is the full round trip;
  `durationMs` is the job's own clock.

The query:

    SELECT station, min(temperature) AS min, avg(temperature) AS mean,
           max(temperature) AS max
    FROM bench.onebrc_v1 GROUP BY station ORDER BY station

## Upload

| workers | wall | rows/s | MiB/s | requests | 429 | p50 | p95 | p99 | restarts |
|---|---|---|---|---|---|---|---|---|---|
| 8 | 152.8 s | **6,542,846** | 260.8 | 4,928 | 0 | 219 ms | 371 ms | 474 ms | 0 |
| 16 | 113.3 s | **8,825,572** | 351.8 | 4,928 | 0 | 329 ms | 614 ms | 757 ms | 0 |

Every request answered 200 on the first attempt in both runs. The server's
`insertedRows` summed to 1,000,000,000, and `count(*)` after the drain
matched it on both tables.

Sealing kept up. Per the metrics database, `smolquery_seal_segment_rows_total`
grew 922M against 906M committed inside the 8-worker upload window and 909M
against 874M inside the 16-worker window — the sealer ran ahead of the
commits it could see. The hot tier was empty 40 s (8 workers) and 39 s (16
workers) after the last insert. 4,927 segments sealed into **78 Parquet files**
per table (`seal_max_files: 64`), **1,277,530,969 bytes** — 1.28 B/row, a
10.8× reduction from the CSV and 31× from the NDJSON on the wire. Zero
compactions ran; zero counters reset.

Nothing was saturated:

| pod tier | 8 workers: CPU / peak RSS | 16 workers: CPU / peak RSS | limit |
|---|---|---|---|
| api (×3) | 0.54–0.61 cores / 567–604 MB | 0.70–0.76 cores / 699–789 MB | 3,072 MB |
| buffer (×3) | 0.99–1.15 cores / 2,160–2,342 MB | 1.25–1.48 cores / 2,368–2,559 MB | 4,096 MB |
| storage (×3) | 0.81–0.94 cores / 1,771–2,060 MB | 0.95–1.18 cores / 2,441–2,548 MB | 6,144 MB |

CPU is the average over the upload window from `bench_pod_cpu_usec_total`.
The api pods sit on 2-vCPU nodes, the others on 4-vCPU nodes. At 16 workers
the closed loop was still the limit: 16 in flight × 200k rows ÷ 330 ms p50
≈ 9.7M rows/s theoretical against 8.8M measured. In wire bytes, 352 MiB/s is
below the ~450–500 MiB/s where the kv and otel shapes topped out
([2026-08-21-kv-small-rows-ceiling.md](2026-08-21-kv-small-rows-ceiling.md)).
**A 32-worker run was planned and skipped.** Expect it to land near that byte
ceiling; expect the buffer tier's memory, not CPU, to be what gives first.

## The query

Ten runs each, `bench.onebrc_v1`, hot tier empty, all from this machine:

| case | min | median | max | all ten |
|---|---|---|---|---|
| **distributed** (default) | 10,579 | **10,697** | 12,092 | 10579 10589 10624 10651 10674 10720 10785 10788 10942 12092 |
| single engine (`distributed: false`) | 27,203 | 27,482 | 27,843 | 27203 27334 27367 27419 27430 27535 27590 27667 27679 27843 |
| `count(*)` | 1,958 | 2,021 | 2,334 | 1958 1968 1993 1993 2008 2034 2043 2045 2062 2334 |

Wall milliseconds. `durationMs` runs about 300 ms under wall in every case —
the round trip through Cloudflare. On `onebrc_v2` after the 16-worker upload,
three runs each: distributed 10,786–10,817 ms, single engine 27,394–27,455 ms,
`count(*)` 2,053–2,118 ms. Same numbers on a fresh table.

The result is right: 413 rows, `Abha` mean 17.9998 against its seed mean
18.0, `Abidjan` 26.0.

Evidence the distributed path ran: `smolquery_query_scattered_total` grew by
11 on the api pods during the query phase (ten runs plus the explain) and
`smolquery_query_scatter_shards_total` by 33 — three shards per query, one
per storage pod. The first pass, with `round()` in the SQL, grew neither and
timed the same as `distributed: false`.

What the single-engine plan does with 26.5 s: `TABLE_SCAN` over 78 files
reports 378 s of operator time and 10,086 HTTP GETs for 1.1 GiB — 16 read
threads (`SMOLQUERY_READ_ENGINE_THREADS=16`) on one 4-vCPU pod, busy the
whole time. `HASH_GROUP_BY` takes 40 s of operator time, `ORDER_BY` nothing.
Three pods reading a third each is where the 2.6× comes from; the remaining
gap to 3× is the merge plus the single coordinator's own work.

`count(*)` at 2.0 s reads no row data — footer statistics — so that is the
fixed floor for a query over 78 sealed files from here: engine start,
manifest, 78 footers, the round trip.

## Caveats

- **`"explain": "analyze"` always ran single-engine.** Every recorded
  `engine_total_s` is 26.3–26.7 s, including the distributed case, and the
  explain counted as one scattered query but reported a single `TABLE_SCAN`.
  There is no engine-side timing for the scatter path in these files.
- The 8- and 16-worker rates are one run each, on fresh tables, 113–153 s
  long. They are sustained over the whole billion rows, not bursts, but they
  are not 30-minute soaks.
- The upload number includes the client's read and JSON encode, on 8 vCPUs.
  It never reached the box's limits, but it is part of the measurement.
- Two columns, 42 B per NDJSON row. Do not compare rows/s here with the
  63-column otel shape; compare MiB/s.
- The CSV was generated on the box, not downloaded; the station set and
  means match the challenge, the bytes do not.

## Next

1. The 32-worker run, on a fresh `onebrc_v3`. It is one command:
   `ONEBRC_WORKERS=32 TABLE=onebrc_v3 SCHEMA_FILE=schemas/onebrc_v1.smolquery.json CLUSTERING=station mise run bench-sweep` with `BENCHES=onebrc`.
2. Make the decomposer accept a scalar function over an aggregate, or
   document the gate where users write SQL. `round(avg(x), 1)` is the most
   natural way to write this query and it costs 2.6×.
3. A distributed-aware explain, so the scatter path reports its own engine
   time.
4. Compaction did not run on 78 files of 16 MB each. Check whether a
   compacted table changes the 10.7 s.

## References

- Upload run, 8 workers: [loadgen-20260822T231141Z-1b.html](loadgen-20260822T231141Z-1b.html)
  — `results/raw-loadgen/loadgen-onebrc-1b.{onebrc,upload}.json`
- Query re-time with plain `avg`: [loadgen-20260822T232908Z-1b-avg.html](loadgen-20260822T232908Z-1b-avg.html)
  — `results/raw-loadgen/loadgen-onebrc-1b-avg.onebrc.json`
- Upload run, 16 workers: [loadgen-20260822T233741Z-1b-w16.html](loadgen-20260822T233741Z-1b-w16.html)
  — `results/raw-loadgen/loadgen-onebrc-1b-w16.{onebrc,upload}.json`
- The gate: `~/Dev/supabase/smolquery/lib/smolquery/query_service/decomposer.ex:316-335`;
  the defaults: `config/runtime.exs:405-416`.
- Harness: `tools/gen1brc`, `tools/upload1brc`, `BENCHES=onebrc` in
  `scripts/loadgen.exs`.
