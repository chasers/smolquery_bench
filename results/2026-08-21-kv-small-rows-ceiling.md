# 2026-08-21: small rows move the ceiling to 3.5M rows/s

**The cluster ingests 3,461,443 small rows/s at 32 VUs with zero refusals,
sealing at parity.** The absolute peak is 3,700,747 rows/s at 96 VUs, but
796 requests were refused there — the clean ceiling is 32 VUs.

**In bytes, small rows and wide rows share one ceiling.** The kv peak moves
~450–470 MiB/s of wire bytes; the otel record (254,163 rows/s) moves
~570 MiB/s. Rows/s scales with row width. The cluster is byte-bound, not
row-bound.

**Sealing held parity at every load level** — `seal:commit` 0.93–1.01 across
all six points — and no pod restarted.

## Setup

- Table `bench.kv_v1`: `key` STRING, `timestamp` TIMESTAMP, `value` STRING,
  `inserted_at` TIMESTAMP. Clustering `[key, inserted_at]`.
- Body: 50,000 rows, 6.36 MiB, **133 B/row** — the same wire size as the
  6.87 MiB otel body, so the sweep isolates row width.
- Cluster tuning: the 2026-08-21 winning config, unchanged
  (3 write partitions, 8 live claims, `STORAGE_MEMORY_LIMIT` 3584MiB,
  `seal_max_bytes` 24MiB, valve factor 1, idle interval 300 ms,
  `flush_max_bytes` 94 MB).
- 60 s measured per point, 10 s warm-up, drain gate between points.
  In-region loadgen, 3 api pods.

## The sweep

| VUs | rows/s | refused | p50 | p95 | seal:commit |
|---|---|---|---|---|---|
| 8 | 1,522,879 | 0 | 186 ms | 386 ms | 0.928 |
| 16 | 2,742,479 | 0 | 229 ms | 421 ms | 1.014 |
| **32** | **3,461,443** | **0** | 386 ms | 679 ms | 0.981 |
| 64 | 3,493,246 | 134 | 845 ms | 1,250 ms | 0.974 |
| 96 | 3,700,747 | 796 | 1,021 ms | 1,430 ms | 0.982 |
| 128 | 3,453,614 | 1,779 | 1,166 ms | 1,707 ms | 0.988 |

Throughput is flat from 32 VUs up. The extra VUs buy refusals and latency,
not rows. Zero counter resets across the whole sweep — no restarts, no OOM.

## What binds at 64+ VUs

The buffer tier's memory. At 96 VUs all three buffer pods peak at the
4,096 MB container limit (RSS 4,089–4,096 MB), and admission sheds load with
429s — the same regime the otel soaks hit. `smolquery-storage-1` also peaked
at exactly its 6 GiB limit during the 96 VU point, without restarting.

The hot tier drained in 46–60 s after every point. The seal path is not the
constraint for this shape at this load.

## Caveats

- 60-second bursts, not soaks. The otel experience says a soak can collapse
  the buffer tier at loads a burst survives.
- Seal counters are cluster-wide. T-343 and T-344 still retry on old tables,
  so a few million sealed rows leak into the drain phases. `seal:commit` per
  ingest phase is computed over the same window and is directionally safe.
- Single runs per point, OTP 29, image `sha256:cf6f3786` (T-339).

## Next

1. **Soak 32 VUs for 30 minutes.** The burst holds parity; the buffer heap
   garbage problem (T-330 area) is what a soak would expose.
2. **Sweep rows-per-body at fixed wire size.** 133 B/row at 50k rows is one
   point; 10k and 200k rows per body would show whether per-request or
   per-row cost dominates.
3. If the byte-bound model is right, api-tier or wire-path work moves the
   ceiling — not buffer or seal tuning.

## References

- Run report: [loadgen-20260821T030837Z-kv1.html](loadgen-20260821T030837Z-kv1.html)
- Config context: [2026-08-21-memory-is-the-seal-ceiling.md](2026-08-21-memory-is-the-seal-ceiling.md)
