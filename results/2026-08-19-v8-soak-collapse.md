# 2026-08-19: the 16 VU soak collapses the buffer tier

Plan: hold 16 VUs — the VU curve's peak — for 1,800 s against
`bench.otel_logs_v8` on smolquery 0.13.0, and read what throughput
degrades to. Actual: **the buffer tier collapsed after ~3 minutes and
never recovered under load.** The operator killed the run at ~03:31Z,
about 15 minutes in. Metrics database:
`results/raw-loadgen/loadgen-20260819T031419Z-0-13-0-soak.metrics.sqlite3`.
No k6 summary exists — k6 died by SIGKILL — so every number below is
server-side.

## Timeline (UTC)

| time | event |
|---|---|
| 03:14:35 | drain gate: hot tier empty after 56 s |
| 03:15:52 | measured window opens; ~116–138k rows/s |
| 03:17–03:18 | throughput slides: 117k, then 87k rows/s |
| ~03:18 | first buffer OOMKills; sampler loses the EKS API ("TLS handshake timeout") |
| 03:19–03:23 | commits collapse to ~3–19k rows/s; buffer-2 OOMKilled, buffer-1 at 3 restarts |
| 03:25 | zero ready buffer pods: OOMKilled / CrashLoopBackOff / not-ready |
| 03:25–03:31 | boot–commit–die loop; restart counts climb every check |
| ~03:31 | k6 killed; buffer-0 Ready again within a minute |

## The failure shape

- **Each buffer pod's life is ~1 minute.** A fresh pod boots with a
  zeroed counter, commits roughly half a million rows, and OOMs at the
  4,096 MB container limit. The counters show it directly: buffer-0
  30k → 483k then reset; buffer-2 211k → 502k then CrashLoopBackOff.
- **The cascade is self-reinforcing.** Survivors inherit the dead pods'
  partitions, hit the limit faster, and die sooner. Kubernetes' restart
  backoff grows, so the tier's alive-time fraction shrinks.
- **Admission control did not save the tier.** The 429 path (T-245) kept
  the 30 s bursts safe, but under sustained load the memory limit was
  reached before admission shed enough. The earlier 4-point sweep
  showed the same pods pinned at 4,096 MB *without* dying at 30 s — the
  soak shows 30 s of headroom is all that limit buys.
- **No recovery under load.** Fifteen minutes of boot–commit–die, with
  restart counts rising monotonically. Recovery began only when the
  load stopped.
- **Collateral**: five storage/buffer restarts before the collapse
  proper, and the EKS API server refused connections twice during the
  worst of it, blinding the metrics sampler for ~4 minutes.

## The post-load drain

The soak left 7,486 hot files (one file per 6.87 MiB body) unsealed. The
drain after the load stopped is its own measurement:

| time | hot files | sealed files |
|---|---|---|
| 03:33 | 7,486 | 19 |
| 03:37 | 2,697 | 24 |
| 03:40 | 1,673 | 25 |
| 03:46 | 458 | 27 |
| 04:08 | **458** | 25 |

- The tier drained 7,028 files in ~13 minutes, then **stopped**. The
  per-pod `smolquery_seal_segments_total{result="ok"}` counters are
  frozen at 7,727 / 5,971 / 1,215 from 03:50 to 04:10, so the last 458
  files are not sealing slowly — they are not being attempted.
- **storage-2 OOMKilled at 03:34:52Z**, during a drain with zero ingest
  load, and restarted three times before the drain finished. Sealing a
  backlog is itself a memory risk.
- **Seal attempts fail in bulk.** Since their last boot, storage-0
  records 7 errored attempts covering 4,885 segment-slots and storage-1
  records 4 covering 4,096. Successful attempts average ~300 segments;
  errored ones run 700–1,200. A sealer that takes its whole backlog
  share as one batch has memory cost proportional to the backlog.
- The falling sealed-file count (27 → 25) is compaction merging, not
  loss.

## No rows were lost or duplicated

The table's recorded total grew from 63.4M to 86.3M rows after the load
stopped, which looks like duplication and is not. The job statistics'
top-level `rowsScanned` reports **sealed** rows only; the growth is the
hot tier migrating into it. The arithmetic closes exactly:

- 84,884,764 − 63,365,028 = 21,519,736 sealed rows added
- 21,519,736 ÷ 3,062 rows per body = **7,028 bodies**
- 7,486 − 458 = **7,028 hot files drained**

`SELECT count(*)` returns 86,287,160 = 28,180 whole bodies, with no
remainder. The soak itself landed 20,873 bodies (63.9M rows) before the
tier died.

## What this changes

1. The published v8 numbers (200k rows/s at 16 VUs) are **burst**
   numbers. The sustainable rate at the current 4 GB buffer limit is
   far lower and is not yet measured.
2. Buffer memory, not CPU, is the binding constraint at every load
   level — the sweep showed it, and the soak shows the consequence.
3. For the smolquery side: buffered bytes must be bounded well below
   the container limit (`MAX_BUFFERED_BYTES` vs actual RSS growth
   deserves a look — RSS grew past whatever bound is configured), and a
   pod that OOMs under admission-controlled load means admission is
   counting the wrong thing.
4. The seal path needs a bounded batch size. Its memory cost currently
   scales with backlog, which is exactly the wrong direction: the pod
   is least able to afford a large batch precisely when the backlog is
   large. Tonight that cost one storage OOM with no ingest running.
5. A drain that stops with 458 files outstanding, no errors, and idle
   counters needs an explanation before any sustained-load number is
   published.

## The code side, read against these metrics

- `SmolqueryApi.Admission` (T-245) bounds ingest bytes in flight **on
  the api pod**, before the body is read. It works — the api tier was
  untouched all night. But the bodies forward to the buffer tier, and
  `SMOLQUERY_BUFFER_REPLICATION=2` doubles them there. Three bounded api
  pods can still concentrate an unbounded sum on one buffer pod.
- `TableBuffer.full?/3` checks only pre-flush buffered bytes against
  `max_buffered_bytes` (64 MB default). The deployed
  `flush_max_bytes` is 2 MB, so a 6.87 MiB body flushes immediately and
  the buffered count stays near zero. The real residents — in-flight
  RPC bodies, `encode_concurrency=4` encodes, `write_pool_size=4`
  DuckDB engines at 512 MB each, replication copies — sit outside every
  bound. Admission reads "fine" while RSS climbs to the 4 GiB limit.
- The buffer StatefulSet has `limits.memory: 4Gi` and no data volume,
  so hot segments land on the container's writable layer.

## Next measurements, in order

1. Re-run the soak at lower VUs (4, then 8) to bracket the sustainable
   rate at the current limits.
2. Raise the buffer memory limit and repeat 16 VUs.
3. File the collapse against the smolquery tracker with this file and
   the metrics database as evidence.
