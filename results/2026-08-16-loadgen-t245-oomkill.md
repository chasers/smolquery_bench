# 2026-08-16: in-region sweep OOMKills buffer-0; compaction fails 45% of the time

**The result is a bug report, not a baseline.** The buffer tier fell over
before the cluster showed its ceiling. Do not compare these numbers with the
2026-08-15 127k rows/s run.

> **Corrected 2026-08-16, 14:22 UTC.** The first version of this page claimed
> merge health stayed clean. That claim was wrong. The monitor window covered
> the one clean stretch in three hours. See
> [Merge health: not clean](#merge-health-not-clean). The buffer memory limit
> is 4 Gi, not 3 Gi.

## Setup

- Load generator: c7i.2xlarge (`i-02a17ae3b82530c27`), eu-central-1a, posts
  to the api pod at `http://<api-pod-ip>:4000`.
- Target: `bench.otel_logs_v2`, cluster on `main@9574a4e` (T-250/251/259/260/261
  in; PR #166 not deployed).
- Sweep: 8 to 128 VUs, 30 s measured per step. The body carries the
  `inserted_at` stamp, so k6 rewrites 6.87 MiB per request.

## Numbers

| run | rows/s | MiB/s | p50 ms | p95 ms | p99 ms | refused | api cpu avg % | api cpu peak % | api rss peak MB | cluster cpu avg % |
|---|---|---|---|---|---|---|---|---|---|---|
| loadgen-vus8 | 72971 | 163.6 | 137 | 809 | 872 | 0 | 21 | 27 | 492 | 444 |
| loadgen-vus16 | 44502 | 251.7 | 188 | 2004 | 2182 | 702 | 51 | 104 | 601 | 270 |
| loadgen-vus32 | 66567 | 160.6 | 217 | 4648 | 4791 | 56 | 24 | 49 | 774 | 539 |
| loadgen-vus64 | 67551 | 246.8 | 1825 | 4655 | 5650 | 474 | 57 | 134 | 1066 | 627 |
| loadgen-vus128 | 69811 | 369.7 | 2248 | 7059 | 7575 | 971 | 109 | 157 | 1848 | 511 |

Only the 8 VU row measures a healthy cluster. Every later row measures a
crash loop.

## What happened: T-245, reproduced in-region

`smolquery-buffer-0` was **OOMKilled three times** inside the sweep (last
kill 00:47:50 UTC). The admission 429 fires after the request body is in
RAM, so concurrent 6.87 MiB bodies grow the pod past its 4 Gi limit instead
of shedding load. The kills explain the whole shape of the table:

- 702 refusals at 16 VUs: the first kill.
- gen_rpc `econnrefused` from both peer buffers; one replica claim on
  `otel_logs_v2__p2` failed mid-seal.
- Bandit request-line errors on the api pod: k6 kept writing bodies into
  half-closed connections.

The uplink was not the limit. The client sent 370 MiB/s at 128 VUs.
Evidence is on tracker task **T-245**.

The pod state confirms the kills:

    restartCount: 3
    lastState.terminated.exitCode: 137
    lastState.terminated.reason: OOMKilled
    lastState.terminated.finishedAt: 2026-08-16T00:47:50Z

### Pod memory limits, as deployed

| pod | requests | limits |
|---|---|---|
| api | 1Gi | 3Gi |
| buffer-0/1/2 | 1536Mi | 4Gi |
| storage-0/1 | 2Gi | 4Gi |

The 4 GiB buffer limit matters for the T-245 fix. The admission bound has to
derive from 4 Gi, not from the 3 Gi this page first reported.

## Merge health: not clean

**Compaction failed 15 times out of 33 attempts — a 45% failure rate.** The
window is 23:37 to 02:42 UTC, read from the `storage-0` log after the sweep.

Every failure is the same DuckDB error, on the same table:

    [warning] compaction of {"bench", "otel_logs_v2"} failed:
      {:put_failed, "...parquet", {:merge_failed, #Adbc.Error<message:
      "Out of Memory Error: failed to pin block of size 256.0 KiB
      (1.0 GiB/1.0 GiB used)" ...>}}

The engine hits its 1 GiB pin budget, fails, and retries with fewer segments
until one lands. At 02:12 it failed on 5 segments, failed again at 02:18, and
landed the same 5 at 02:23. Two full cycles buy one merge.

All 15 failures are on `storage-0`. `storage-1` logged **zero** compaction
attempts in the same window — only sealed-tier sweeps. The work is not shared.

### Why the first version of this page said "clean"

The monitor sampled both storage pods every 2 minutes, but only through the
sweep — about 00:43 to 00:54 UTC. That window holds two successes and no
failures. It is the single clean stretch in three hours:

| time UTC | result |
|---|---|
| 00:33:36 | failed |
| 00:40:00 | failed |
| 00:46:27 | compacted 10 segments — inside the monitor window |
| 00:53:04 | compacted 10 segments — inside the monitor window |
| 00:59:40 | compacted 8 segments |
| 01:06:09 | failed |

The "zero failures" reading is true for its window and wrong as a conclusion.
**Widen the monitor to cover the hour before and after the next sweep.**

The 00:46:27 group is the one that had OOMed eight consecutive sweeps. It sat
within ~1% of the 1 GiB pin budget, so success was a coin flip, not a fix. The
45% failure rate is what that coin flip looks like over a longer sample. PR
[smolquery#166](https://github.com/chasers/smolquery/pull/166) removes the
flip: the row cap derives from the engine budget at 512 B/row (T-262).

The dedicated compaction engine (T-259) still did its job. The merge failures
never crashed a pod and never touched the ingest path. The damage is contained,
not absent.

## Harness note

This fetch overwrote the 2026-08-15 sweep's same-label raw files in
`results/raw-loadgen/`. The old numbers survive in the dated writeups.

> **Corrected 2026-08-16, 15:04 UTC.** This section first said to set
> `LABEL_SUFFIX` or `RESULTS`. `LABEL_SUFFIX` did nothing on this path —
> `scripts/loadgen.exs` hardcoded its label and only `scripts/bench.exs` read
> the variable. The post-deploy sweep set the flag and overwrote these raw
> files anyway. `scripts/loadgen.exs` now reads it. Use `RESULTS` as well; see
> [2026-08-16-post245-sweep.md](2026-08-16-post245-sweep.md).

## Cluster state after the sweep

Checked at 14:22 UTC, about 12 hours after ingest stopped. All 6 pods
`Running`. No restart since the 00:47:50 kill. Memory is low everywhere:
api 362Mi, buffers 459/1030/1618Mi, storage 893/478Mi. No compaction has run
since 02:42 UTC, because no new segments arrive.

## Next

All four items below are done or superseded. PR #166, #167, and #169 deployed
at 14:43 UTC and the re-sweep ran at 14:54 UTC. It killed three pods instead of
one, and compaction never ran. Read
[2026-08-16-post245-sweep.md](2026-08-16-post245-sweep.md) for the outcome.

1. ~~**Deploy PR #166.**~~ Deployed. Still unexercised — no `otel_logs_v2`
   group has compacted since.
2. ~~Land and deploy T-245 (bound admission).~~ Deployed. The bound fires, and
   the api pod OOMKills anyway; it counts wire bytes, not resident bytes.
3. ~~Widen the pod monitor.~~ Still open. `storage-0` died 7 minutes after the
   last request, outside any sweep window.
4. ~~Re-sweep with `LABEL_SUFFIX=-post245`.~~ Ran. The flag did nothing — see
   the harness note above.
