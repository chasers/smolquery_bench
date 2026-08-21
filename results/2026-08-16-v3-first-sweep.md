# 2026-08-16 (v3): the harness measured one api pod for its whole life

**Two sweeps, and the second one is the finding.** `otel_logs_v3` landed with
date partitioning on ClickHouse and `project_id` clustering on smolquery. The
first sweep against it exposed a harness bug: every run this repo has ever
produced sent all its load to a single api pod. The second sweep, after the
fix, killed no pods and moved the bottleneck to the buffer tier.

Neither sweep is a baseline. Read the section on confounders before you quote a
number.

## Setup

- Load generator: c7i.2xlarge (`i-09251ca61cc15a2b0`), eu-central-1a.
  Terminated after the run.
- Target: `bench.otel_logs_v3`, created fresh at 15:26 UTC. Clustering
  `["project_id"]`, 63 columns, verified through the API.
- Cluster: `main@10b019b`, image `sha256:fe24bd51`. **Nine pods** — 3 api, 3
  buffer, 3 storage. `api-1`, `api-2` and `storage-2` appeared at 15:17:45 UTC.
  Every earlier sweep in these results ran against 6 pods.
- Sweep: 8, 16, 32 VUs, 30 s measured per step, 3,062 rows per 6.87 MiB body.
  The body is byte-identical in size to v2, so ingest stays comparable on that
  axis.

## The harness bug

`Bench.Loadgen.api_pod_ip/0` resolved one pod — `API_POD`, default
`smolquery-api-0` — and built one URL. That was invisible while the cluster ran
a single api pod. With three, the pod sampler showed it plainly:

| pod | rss peak | cpu avg |
|---|---|---|
| api-0 | 2,331 MB | 73% |
| api-1 | 308 MB | **0%** |
| api-2 | 332 MB | **0%** |

Two thirds of the api tier never took a request, while the third rode toward its
3 Gi limit and was OOMKilled at 15:31:22 UTC.

The load generator cannot use the `smolquery-api` ClusterIP — it sits outside
the cluster, and kube-proxy only balances from inside. So the fix resolves every
*ready* endpoint of the Service and hands k6 the list. Each VU keeps one pod
(`urls[(__VU - 1) % urls.length]`), which spreads VUs evenly and still reuses
connections. `API_POD` pins a run to one pod when that is what you want.

## Sweep 1: one api pod (15:28–15:32 UTC)

| VUs | rows/s | MiB/s | p50 ms | p95 ms | p99 ms | refused |
|---|---|---|---|---|---|---|
| 8 | 135083 | 302.9 | 161 | 239 | 276 | 0 |
| 16 | **168746** | 378.4 | 256 | 453 | 567 | 0 |
| 32 | 116658 | 282.6 | 683 | 1132 | 1825 | 646 |

Two pods died: `api-0` OOMKilled at 15:31:22, `storage-0` at 15:32:30.

## Sweep 2: all three api pods (15:39–15:43 UTC)

| VUs | rows/s | MiB/s | p50 ms | p95 ms | p99 ms | refused |
|---|---|---|---|---|---|---|
| 8 | 95016 | 213.0 | 225 | 428 | 533 | 0 |
| 16 | 107048 | 240.0 | 399 | 799 | 996 | 0 |
| 32 | 119172 | 272.5 | 600 | 1499 | 1823 | 24 |

**No pod restarted.** Refusals at 32 VUs fell from 646 to 24.

Load spread as intended:

| pod | rss peak (32 VU) | cpu avg |
|---|---|---|
| api-0 | 454 MB | 12% |
| api-1 | 503 MB | 13% |
| api-2 | 1,005 MB | 11% |

`api-0` went from 2,331 MB to 454 MB at the same VU count. The api tier is no
longer near its limit.

## The buffers are the ceiling now

Peak resident, sweep 2, against a 4,096 MB limit:

| VU | buffer-0 | buffer-1 | buffer-2 | storage-0 | storage-1 | storage-2 |
|---|---|---|---|---|---|---|
| 8 | **4096** | **4096** | **4095** | **4096** | 2615 | 1926 |
| 16 | **4095** | **4093** | 4052 | 3808 | 2716 | 2325 |
| 32 | **4096** | **4095** | 4089 | 3566 | 3758 | 2377 |

**All three buffers sit on their limit at 8 VUs**, before load ramps at all.
They are not growing into the load; they start pinned. The api tier is
comfortable and storage has headroom, so the buffer tier is where the next fix
belongs. This is unrelated to T-245 and unrelated to v3.

## Do not read sweep 2 as a regression

Throughput fell at 8 and 16 VUs between the sweeps. Three things changed at
once, and the routing is only one of them:

1. **The table was empty for sweep 1 and held ~12.7M rows for sweep 2.** Segment
   count and merge cost differ, and that alone could account for the gap.
2. **Sweep 1 ran a cluster that lost two pods mid-sweep.** Its 16 VU number was
   measured before the kills; its 32 VU number after.
3. **Routing changed.** Per-VU pod assignment gives each pod fewer connections
   and less per-pod batching.

The one comparison that is clean: **sweep 2 killed nothing and refused 24
requests where sweep 1 killed two pods and refused 646.**

## What v3 has not yet answered

Nothing about partitioning was measured. No pruning bench ran, and no
`otel_logs_v3` compaction has happened. The schema is in place; the questions it
exists to answer are still open.

Both smolquery gaps are filed:

- **[T-267]** — the job response carries no scan statistics, so pruning can be
  timed but not counted.
- **[T-268]** — the catalog has no partition key, so date pruning relies on
  segment min-max and can decay when compaction merges across a boundary.

## Harness changes made during this run

1. `api_pod_ips/0` reads every ready `smolquery-api` endpoint. k6 takes `URLS`
   and assigns per VU. `API_POD` restores single-pod behavior.
2. Endpoint discovery uses `endpointslices`. The v1 `endpoints` API prints a
   deprecation warning, and `Bench.Kube.cmd` merges stderr, so the warning text
   was being parsed as IP addresses. An IPv4 filter guards it as well.
3. `run_ingest` now pushes the working tree and rebuilds the body at the start
   of every sweep. Before, a sweep ran whatever `bench-up` last pushed — which
   cost one failed run here, and contradicts the module's own documented intent.
4. `BASE_DATE` threads through to the remote body build.

## Next

1. **Look at the buffer tier.** Three pods pinned at 4 GiB during an 8 VU step
   is the clearest signal in this data.
2. **Run `BENCHES=pruning,compaction`.** Neither needs the load generator. There
   are ~12.7M rows on one date, so the empty-date probe is meaningful now.
3. **Re-sweep v2 on the 9-pod cluster** if a clean v2-vs-v3 comparison matters.
   Every existing v2 number was measured on 6 pods and one api pod.
