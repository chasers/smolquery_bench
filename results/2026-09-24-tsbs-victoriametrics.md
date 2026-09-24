# 2026-09-24: TSBS through the VictoriaMetrics edge

**The edge answers every TSBS query type at scale 100 in 0.7 to 1.8 s. At
scale 1,000, two of eleven types fail.** `double-groupby-5` passes the 30 s
query timeout at 4 workers. `double-groupby-all` OOM-kills a query pod. The
smallest query costs about 0.7 s at scale 100 and 1.3 s at scale 1,000, so a
fixed cost per query sets the floor, not the data a query reads. Every file
holds every metric name, so no `name` predicate skips a file.

- smolquery `f4303d0`: `main` with the pushdown stack merged (T-568, T-585,
  T-586). All the TSBS shapes push down to SQL on this build.
- The deployed sandbox cluster: 3 api, 3 buffer, 3 storage and 3 query
  pods. A query pod has a 3 GiB memory limit and no CPU limit.
- The load generator: one `c7i.2xlarge` in the cluster's VPC. It writes to
  the api pod IPs and reads from the query pod IPs on port 8428.
- TSBS `8323e59`, use case `cpu-only`, seed 123, one sample every 10 s for
  24 h. Scale 100: 2026-09-23. Scale 1,000: 2026-09-22.
- Every sample goes to `metrics.samples`, the table that vmagent also writes.
- Run with `mise run bench-tsbs`. Raw results in `results/raw-tsbs/`. Cluster
  reports: [scale 100](loadgen-20260924T023413Z.html),
  [scale 1,000](loadgen-20260924T025423Z.html).

There is no "before" run. The stack rolled out at 02:21 UTC, before the first
load. These numbers are the stack, not a before-and-after comparison.

## Load

`tools/tsbsrw` sends Prometheus remote write 1.0, snappy framed, 10,000
samples a request. It names each series `cpu_<field>`, as VictoriaMetrics
names an Influx field.

| scale | samples | writers | time | samples/s | p50 ack | busy retries | lost |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | 8,640,000 | 8 | 215 s | 40,245 | 2.0 s | 0 | 0 |
| 1,000 | 86,400,000 | 32 | 1,120 s | 77,114 | 4.1 s | 3 | 0 |

**Four times the writers gave 1.9 times the rate.** Median ack latency
doubled, from 2.0 s to 4.1 s. The write path queues. The api pods do not cause
it: they used about 0.7 cores each at 8 writers and 1.7 at 32, with no CPU
limit. The buffer pods used 0.4 to 1.0 cores. The seal kept up. The hot tier
was back to its file count from before the load 13 s after scale 100 and 3 s
after scale 1,000.

## Queries

Fifty queries per type, TSBS's own runner, answers read back in full. Median
and p99 in milliseconds.

| query | s100, 1 worker | s100, 4 workers | s1000, 1 worker | s1000, 4 workers |
|---|---:|---:|---:|---:|
| single-groupby-1-1-1 | 684 / 1,508 | 842 / 1,516 | 1,316 / 2,526 | 1,372 / 2,680 |
| single-groupby-1-1-12 | 746 / 1,170 | 936 / 1,643 | 1,940 / 2,893 | 2,106 / 3,663 |
| single-groupby-1-8-1 | 705 / 1,563 | 844 / 1,375 | 1,137 / 1,558 | 1,394 / 4,683 |
| single-groupby-5-1-1 | 833 / 1,733 | 1,011 / 2,599 | 1,508 / 3,242 | 1,699 / 4,603 |
| single-groupby-5-1-12 | 1,322 / 2,441 | 1,637 / 3,044 | 5,774 / 10,989 | 6,168 / 18,838 |
| single-groupby-5-8-1 | 821 / 1,300 | 1,144 / 2,258 | 1,465 / 1,768 | 1,821 / 2,909 |
| cpu-max-all-1 | 1,272 / 2,155 | 1,469 / 2,429 | 6,085 / 8,735 | 9,440 / 12,648 |
| cpu-max-all-8 | 1,389 / 2,334 | 1,690 / 5,340 | 6,782 / 10,371 | 9,200 / 18,832 |
| double-groupby-1 | 736 / 1,267 | 953 / 2,343 | 2,192 / 2,517 | 3,459 / 6,940 |
| double-groupby-5 | 1,347 / 2,655 | 1,479 / 2,817 | 12,205 / 14,789 | **503 timeout** |
| double-groupby-all | 1,836 / 2,535 | 2,749 / 4,592 | **pod OOM-killed** | **pod OOM-killed** |

The runner stops a type at its first error, so a failed cell has no
latency.

- **`double-groupby-5`, scale 1,000, 4 workers.** One query passed
  `SMOLQUERY_VICTORIAMETRICS_MAX_QUERY_DURATION_MS` (30 s) and got a 503. At
  1 worker the same type answered in 12.2 s.
- **`double-groupby-all`, scale 1,000.** `smolquery-query-1` was OOM-killed at
  04:00:20 UTC at its 3 GiB limit (exit 137). The runner then got
  `connection refused` from that pod and stopped. The query is
  `avg(avg_over_time({__name__=~'cpu_(10 metrics)'}[1h])) by (__name__,
  hostname)` over 12 h: 10,000 output series of 13 points. Pushdown removes
  the samples budget, but the answer still has to fit in the pod. The pod
  restarted by itself and served again about a minute later. **This crashed a
  shared query pod.** Do not re-run this type at scale 1,000 against the
  shared cluster without a higher memory limit.

Three answers per type were hashed on the box (`tools/tsbsdigest`). Every
answer that returned was data, not an empty result: for example 5,000 series
of 13 points for `double-groupby-5` at scale 1,000.

## Finding 1: a floor of about 0.7 s, and it grows with the table

`single-groupby-1-1-1` reads one metric of one host for one hour, 360
samples. It takes 684 ms at scale 100 and 1,316 ms at scale 1,000. The edge's
own bench on the dev box found the same floor ("a fetch has a ~0.7 s floor",
smolquery commit `2e9f7d5`). An S3 GET is 30 to 240 ms. So most of the floor
is the job, the catalog and the engine, not the object store. The floor
doubling with the table says part of it scales with the files the planner
looks at, not with the rows the query reads.

## Finding 2: the file layout sets the cost, not the regex

Four query types select several metrics with `{__name__=~'cpu_(...)'}`. The
edge writes that as `regexp_full_match(name, $n)`
(`lib/smolquery_victoriametrics/samples.ex:72`). Those types grew the most from
scale 100 to scale 1,000:

| query | selector | s100 → s1000, 1 worker p50 |
|---|---|---:|
| single-groupby-1-1-12 | `cpu_usage_user{hostname=...}` | 2.6× |
| single-groupby-5-1-12 | `{__name__=~'cpu_(5)', hostname=...}` | 4.4× |
| cpu-max-all-8 | `{__name__=~'cpu_(10)', hostname=~...}` | 4.9× |
| double-groupby-5 | `{__name__=~'cpu_(5)'}` | 9.1× |

The regex is not the reason. `count(*)` over the same 12 h window of the
scale 1,000 data, with `"explain": "analyze"`, two runs each:

| filter on `name` | files read | engine time |
|---|---:|---:|
| none | 37 | 1.8 to 2.3 s |
| `= 'cpu_usage_user'` | 37 | 0.77 to 0.81 s |
| `IN (5 names)` | 37 | 2.24 to 2.26 s |
| `regexp_full_match(name, 'cpu_(5 names)')` | 37 | 2.30 to 2.39 s |
| `OR` of 5 equalities | 37 | 2.33 to 2.44 s |
| `UNION ALL` of 5 one-name scans | — | 2.84 to 2.92 s |

- **No `name` predicate skips a file.** The catalog's column statistics
  (read-only from the DuckLake catalog) show all 296 current files span
  `cpu_usage_guest` to `up`. A remote write block carries every metric of a
  moment, so every seal holds every name. `Smolquery.QueryService.Pruner`
  works per file, so it can never drop one by name.
- **Row groups are sorted, and DuckDB uses them for one equality only.** The
  seal and the compactor write `ORDER BY name, ts` in 100,000-row groups, so
  `name = 'x'` skips row groups: 0.8 s against 2.0 s. `IN`, `OR` and the regex
  skip none. A rewrite of the regex to `IN` changes nothing.
- **Even ideal skipping gains less than 2× here.** Five of ten names is half
  the rows in the window. `UNION ALL` of one-name scans pays each file's
  fixed cost five times, and the pruner reads nothing from a table that one
  statement reads twice (T-533).
- **Files mix time ranges.** One seal takes whatever the hot tier holds, so
  the backfilled TSBS rows and vmagent's live rows land in the same files.
  A file spans 6.75 h of `ts` on average and up to 51 h, so a 12 h window
  opens 37 of 296 files. Live data alone would not do this, because its write
  time is its `ts`. A backfill does. Compaction does not undo it: it merges
  within a bucket of *write* time (`compact_bucket_ms`, 1 h), and every file
  is still under 18 MiB.

What would help, in order:

1. **Files that cover a narrow range of names or of `ts`.** Compaction could
   re-sort a window by `name, ts` into several outputs split by name, and
   bucket by `ts` instead of write time. The pruner's existing `name` and `ts`
   ranges would then drop files with no new code.
2. **A regex rewritten to `name IN (...)` plus a `name` range**, once step 1
   exists. The pruner reads `=`, `<`, `>` and `BETWEEN`, not `IN`.
3. **A names or series table (T-569)** for a regex with no literal list, such
   as `.*_total`. Prometheus and VictoriaMetrics match a regex against the
   distinct label values, then read only the matching series. Their storage
   keeps a series' samples together, which is the other half of the trick.

## Against published results

No published TSBS run reads from object storage, so there is no
like-for-like peer. The nearest numbers:

| query | VictoriaMetrics v1.146.0 | GreptimeDB v0.12.0 | smolquery edge |
|---|---:|---:|---:|
| setup | scale 100, 4 workers, local disk | c5d.2xlarge, GP3 disk | scale 100, 4 workers, S3 |
| single-groupby-1-1-1 | 0.32 ms | 4.06 ms | 842 ms |
| single-groupby-5-8-1 | 2.24 ms | 9.74 ms | 1,144 ms |
| cpu-max-all-8 | 4.82 ms | 24.20 ms | 1,690 ms |
| double-groupby-1 | 6.73 ms | 673 ms | 953 ms |
| double-groupby-all | 67.95 ms | 1,330 ms | 2,749 ms |
| load | 3.63M samples/s | 327k rows/s (3.3M samples/s) | 40k samples/s |

- The VictoriaMetrics run is the same workload as our scale 100 run: `cpu-only`,
  one day at 10 s, seed 123, 4 workers. It ran on one 4-core Linux box with the
  client on the same machine
  ([softalink/esmetrics](https://github.com/softalink/esmetrics/tree/main/benchmarks/results)).
- GreptimeDB stores Parquet in object storage, but its published TSBS tables
  use a local disk. The file does not state its scale. Its TimescaleDB
  comparison on the same machine type used scale 4,000 over 3 days
  ([GreptimeDB TSBS](https://github.com/GreptimeTeam/greptimedb/tree/main/docs/benchmarks/tsbs)).
- Every S3-backed system that publishes numbers puts a local cache in front
  of S3 (GreptimeDB, ClickHouse Cloud, Mimir's store-gateway).

The two `double-groupby` queries are 1.4 and 2.1 times GreptimeDB's times on
disk. The light queries are 70 to 200 times GreptimeDB's times and 350 to
2,600 times VictoriaMetrics's. The floor in Finding 1 dominates them.

## Caveats

- **A shared table.** vmagent writes the cluster's own metrics to
  `metrics.samples` all the time. The regex queries scan those rows too.
- **A shared cluster.** Other traffic was not stopped. The query pods also
  serve the ClickHouse and Postgres edges.
- **The data stays.** The table has no retention, so the 95M TSBS rows
  remain until someone deletes them. TSBS series have the names `cpu_*` and a
  `hostname=host_N` label.
- **Pods restarted at 02:21 UTC** for the stack rollout, 14 minutes before
  the first load.
