# 2026-08-18 evening: v8 re-bench after the T-304 partition release

Same shape as the morning run
([2026-08-18-v8-seal-compaction.md](2026-08-18-v8-seal-compaction.md)):
16 VUs, 30 s measured, 600 s compaction watch, `otel_logs_v8` (appends,
`partitions: null` = deployment default 3). The sandbox redeployed at
20:23Z with T-304 (per-table write-partition counts) and T-301 (the
storage ring deals partitions across pods). Counters were zeroed by the
redeploy. Metrics database:
`results/raw-loadgen/loadgen-20260818T203512Z-t304.metrics.sqlite3`.
This is the first run scraped over `GET :4003/metrics` (no rpc VM), so
pod CPU/RSS numbers are cleaner than the morning's.

## Verdict

**The seal work now spreads.** The morning's 12% / 79% / 9% skew became
**25% / 36% / 39%** (493 / 697 / 762 micro-segments per storage pod).
Throughput held, the hot tier drained fully — **and a storage pod still
OOMed**, this time the one whose poison v6 compaction ran concurrently
with the drain.

## Numbers against the morning

| | morning | post-T304 |
|---|---|---|
| rows/s at 16 VU | 175,511 | 169,248 (−3.6%) |
| p50 / p95 / p99 ms | 242 / 524 / 645 | 262 / 521 / 626 |
| refusals | 0 | 0 |
| seal errors / stuck / release failures | 0 / 0 / 0 | 0 / 0 / 0 |
| seal skew across storage pods | 12% / 79% / 9% | 25% / 36% / 39% |
| micro-segments sealed per commit | ~3.1 (6,778 / 2,173) | ~1.04 (1,952 / 1,874) |
| hot files at end | 0 | 0 |
| storage OOMKill during drain | storage-1 (the 79% pod) | storage-0, 20:37:01Z |

The rows landed: v8 grew 7,330,428 → 14,324,036, exactly the 2,284 bodies
sent (1 preflight + 612 warm-up + 1,671 measured). Sealed files went
5 → 7.

## The OOM

storage-0 died at 20:37:01Z, ~40 s after measured ingest ended — 18 s
after its v6 poison compaction attempt logged its failure (20:36:43). With
the seal work now spread, the pod that died is not the biggest sealer but
the pod that ran a poison compaction concurrently with its share of the
drain. The poison loops are not just a CPU tax: a v6-sized compaction read
plus seal work plausibly exceeds the pod's memory. Removing the corrupt
segments (or the missing compactor quarantine) is now on the OOM path,
not only a hygiene bug.

## Observations

- Micro-segments per commit fell from ~3.1 to ~1.04. Same partition count
  (3), so the release changed how many partition files a commit produces,
  or the commit sizes shifted. Worth a question to the smolquery side; it
  makes seal batches smaller and cheaper.
- The v6 and v7 poison loops survived the redeploy, as expected: corrupt
  data does not heal on deploy. storage-0 and storage-1 each resumed
  failing within minutes of boot.
- storage-0's seal counters vanished for 3 ticks around the OOM and came
  back without a visible reset (no seals after restart), so its 493-segment
  share slightly undercounts its true pre-OOM work.
