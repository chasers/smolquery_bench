# Remote sandbox ingest, 2026-08-14

The deployed cluster at `eu-central-1-sandbox.smolquery.com:8443`, driven from a
laptop over the public internet.

**Peak: 22,579 rows/s at 16 VUs, zero refusals at every load level**, on 3×
m7i.xlarge with `SMOLQUERY_WRITE_PARTITIONS=3`, against `otel_logs_v2`.

Four sweeps, in order. Each fixed the previous one's binding constraint:

| Config | peak rows/s | 64-VU rows/s | refusals | what limited it |
|---|---|---|---|---|
| 2× t3.large, P=1 | 19,932 | 9,973 | 157 | one buffer pod owned the table |
| 2× t3.large, P=3 | 21,275 | 16,884 | 23 | client uplink |
| 3× m7i.xlarge, P=3 | 21,534 | 20,161 | **0** | client uplink |
| 3× m7i.xlarge, P=3, `otel_logs_v2` | **22,579** | 18,809 | **0** | client uplink |

The peak moved 13% across all that work. The *shape* changed completely: the
first run collapsed to half its peak under load, the last one holds flat to 64
VUs with nothing refused.

**The cluster's ingest ceiling is still unmeasured.** At 64 VUs it uses 166% of
1,200% available CPU while the laptop saturates somewhere in a noisy 42–51 MiB/s
band. Two things remain
open: an in-region load generator to find the real ceiling, and the seal path,
which still times out and got worse with more hardware.

## What ran

- Arm: `remote`. Dataset `bench`, clustering `(project_id, timestamp)`. Table
  `otel_logs` for sweeps 1–3, `otel_logs_v2` for sweep 4, which adds the
  `inserted_at` column.
- Body: the same `bodies/eachrow.3062.ndjson` the local arms use — 3,062 OTel
  rows, seed 42. 62 columns and 6.81 MiB for sweeps 1–3; 63 columns and
  6.87 MiB for sweep 4.
- Per step: preflight, 10 s warm-up, 8 s pause, 30 s measured, 5 s stop.
- Client: a laptop on Wi-Fi, 21 ms from the endpoint. Path is laptop →
  Cloudflare → NLB → api pod.
- Cluster, sweeps 1 and 2: 2× t3.large, so 4 vCPU for 6 pods. Pods request 100m
  CPU and set no limit. `smolquery-api-0`, `buffer-0`, `buffer-1` and
  `storage-0` share one 2-vCPU node.
- Cluster, sweeps 3 and 4: 3× m7i.xlarge, so 12 vCPU for 6 pods, 2 per node,
  with memory requests and limits on every StatefulSet.

## Results, first sweep (`SMOLQUERY_WRITE_PARTITIONS` unset, so P=1)

| run | rows/s | MiB/s | p50 ms | p95 ms | p99 ms | refused | api cpu avg % | api cpu peak % | api rss peak MB | cluster cpu avg % |
|---|---|---|---|---|---|---|---|---|---|---|
| remote-vus1 | 5466 | 12.1 | 552 | 618 | 701 | 0 | 4 | 5 | 414 | 37 |
| remote-vus2 | 8059 | 17.8 | 722 | 1087 | 1266 | 0 | 6 | 8 | 421 | 79 |
| remote-vus4 | 14636 | 32.3 | 778 | 1195 | 1472 | 0 | 10 | 13 | 429 | 83 |
| remote-vus8 | 19317 | 42.6 | 1110 | 2112 | 2893 | 0 | 15 | 20 | 458 | 169 |
| remote-vus16 | **19932** | 43.9 | 2237 | 3309 | 4102 | 0 | 16 | 20 | 523 | 209 |
| remote-vus32 | 15157 | 44.8 | 4849 | 7591 | 8479 | 56 | 22 | 42 | 652 | 217 |
| remote-vus64 | 9973 | 46.3 | 9581 | 11324 | 11929 | 101 | 35 | 129 | 1305 | 179 |

CPU percent is one core, read from each pod's cgroup. A t3.large gives 200%.
`MiB/s` counts every byte k6 sent, including the bodies of refused requests, so
it stays flat while accepted `rows/s` falls.

The sweep inserted 2,948,706 rows in its measured windows. A count query after
the sweep returned **4,228,622** rows, which adds the warm-ups and the
preflights. Every row is queryable.

## Why the first sweep collapsed: partitioned writes were off

smolquery ships the fix for this. The sandbox had not enabled it.

`Smolquery.Partitions` (PL-5 Stage 2, T-170) splits one table's writes into P
sibling buffer identities. Partition `i` of `{"logs","events"}` is the ordinary
ref `{"logs","events__p<i>"}`, and `Smolquery.BufferService.Ring` walks it to
the `i mod N`-th node clockwise from the parent, so P partitions cover
`min(P, N)` nodes **exactly** rather than on average.

The count comes from `SMOLQUERY_WRITE_PARTITIONS`
(`config/runtime.exs:203`). It defaults to **1** in both
`Smolquery.IngestService` and `Smolquery.QueryService`, and
`smolquery-deploy` never sets it. At a count of 1, `Partitions.write_ref/3`
returns the bare ref — partition 0 — so the table has exactly one owner.

That is what the first sweep measured. `Smolquery.Partitions` states the consequence
plainly: "a single table's ingest is bounded by that node no matter how many
nodes the cluster has." All ingest for `bench.otel_logs` landed on
`smolquery-buffer-1`.

| VUs | accepted rows | buffer-1 cpu avg % | buffer-1 cpu peak % | buffer-1 rss peak MB |
|---|---|---|---|---|
| 1 | 165,348 | 21.8 | 44.8 | 484 |
| 2 | 248,022 | 34.8 | 53.1 | 661 |
| 4 | 443,990 | 67.7 | 88.4 | 917 |
| 8 | 600,152 | 118.0 | 158.1 | 1366 |
| 16 | 636,896 | **144.3** | 168.5 | 1809 |
| 32 | 505,230 | 132.7 | 160.7 | 2088 |
| 64 | 349,068 | 116.1 | 175.0 | 2455 |

Read the table from 8 VUs down. `buffer-1` climbs to 144% of a core — of the
200% its node has, and it shares that node with the api pod. Throughput gains
3% from 8 to 16 VUs while `buffer-1` burns 22% more CPU. Past 16 VUs its CPU
*falls* while resident memory keeps climbing to 2.4 GB. That is the buffer
filling faster than it drains, so the api pod starts answering 429
`buffer_full`, and goodput collapses to half the peak.

`buffer-0` and `buffer-2` idle near 1% throughout. Two thirds of the deployed
buffer capacity never takes a row.

## Then we turned partitions on

`SMOLQUERY_WRITE_PARTITIONS=3`, pushed to Secrets Manager, fleet restarted
together. Verified live on the api, buffer and storage pods. Same body, same
step parameters, results in `results/raw-remote-p3/`.

| VU | P=1 rows/s | P=3 rows/s | change | P=1 refused | P=3 refused | P=1 p99 | P=3 p99 |
|---|---|---|---|---|---|---|---|
| 8 | 19,317 | 19,471 | +1% | 0 | 0 | 2,893 | **1,988** |
| 16 | 19,932 | **21,275** | +7% | 0 | 0 | 4,102 | **3,377** |
| 32 | 15,157 | 20,904 | **+38%** | 56 | **0** | 8,479 | **6,728** |
| 64 | 9,973 | 16,884 | **+69%** | 101 | **23** | 11,929 | 12,286 |

**The peak moved only 7%. The shape changed completely.** P=1 collapsed past 16
VUs — 15,157 then 9,973, with 157 refusals between them. P=3 holds ~21,000 rows/s
through 32 VUs with zero refusals, and still returns 16,884 at 64 VUs.

The rotation places partitions exactly as documented. Buffer CPU, average
percent of one core:

| VU | buffer-0 | buffer-1 | buffer-2 |
|---|---|---|---|
| 8, P=1 | 0.7 | **118.0** | 4.9 |
| 8, P=3 | 32.3 | 32.2 | 39.8 |
| 32, P=3 | 47.4 | 48.5 | 52.4 |
| 64, P=3 | 45.9 | 46.3 | 57.8 |

Three even shares, and no buffer above 58% of a core at 64 VUs against 200%
available. Peak resident memory per buffer fell from 1,366 MB on one pod to
~470 MB on each at 8 VUs. Nothing accumulates on a single owner any more.

**The buffer is no longer the limit.** The peak gained only 7% because the
laptop is now the limit: 21,275 rows/s is 46.6 MiB/s. Sweep 4 later reached
50.7 MiB/s, so treat that figure as one sample of a noisy band, not a wall.

### A client-side failure worth knowing about

The first 16-VU attempt returned 0 rows/s — 8 requests, 8 refused. No pod
restarted. The api pod logged `Bandit.HTTPError: Body read timeout` dozens of
times.

That is the client starving its own streams. Sixteen 6.7 MiB uploads share a
~46 MiB/s uplink, TCP does not divide it fairly, and a single body read stalls
past Bandit's timeout, so the server drops the connection. Partitioning made
the server faster, so k6 pushed harder and oversubscribed the pipe. A re-run of
the same step gave 21,275 rows/s with no refusals.

Read it as a property of a narrow uplink, not a cluster fault. It also caps how
much more this laptop can teach us.

## Then we resized the cluster

The deploy repo's `2026-08-14_04_cluster-resource-limits.md` landed: **3×
m7i.xlarge** (12 vCPU, 45 GiB, non-burstable) against 2× t3.large, memory
requests and limits on every StatefulSet, engine caps below those limits
(`SMOLQUERY_MEMORY_LIMIT=1GB`, `SMOLQUERY_WRITE_ENGINE_MEMORY_LIMIT=512MB`),
preferred anti-affinity for the api pod, and metrics-server. Results in
`results/raw-remote-m7i/`.

| VU | t3 P=1 | t3 P=3 | m7i P=3 | refused, t3 P=1 → m7i | p99 t3 P=3 | p99 m7i |
|---|---|---|---|---|---|---|
| 8 | 19,317 | 19,471 | 20,917 | 0 → 0 | 1,988 | **1,492** |
| 16 | 19,932 | 21,275 | **21,534** | 0 → 0 | 3,377 | 4,214 |
| 32 | 15,157 | 20,904 | 20,484 | 56 → **0** | 6,728 | **5,597** |
| 64 | 9,973 | 16,884 | 20,161 | 101 → **0** | 12,286 | **10,696** |

**Zero refusals at every step, and the curve is now flat.** 64 VUs went 9,973 →
20,161, a **+102%** gain over the original run. Nothing collapses.

The throughput is flat because it is not the cluster's: 46.1, 47.5, 45.2 and
44.5 MiB/s. That is the laptop's uplink at every step. Pod CPU says the same
thing — average percent of one core, against 1,200% now available:

| VU | cluster total | api | buffers | storage |
|---|---|---|---|---|
| 8 | 95% | 18 | 16/16/17 | 9/18 |
| 64 | 159% | 38 | 22/22/25 | 7/43 |

At 64 VUs the whole cluster uses **159% of 1,200%**. `kubectl top nodes`
agrees: 10–19% CPU, 15–18% memory. **The cluster is idle and the client is
saturated.**

### The limits did their job

Zero pod restarts across the sweep. Peak memory against limit: api 1,079 Mi of
2 Gi, buffers 764–919 Mi of 3 Gi, storage-1 riding 3,072 Mi of 3 Gi.
`storage-1` held ~6,200 MB uncapped before; it is now bounded.

### The seal path is still broken, and resizing made it worse

`storage-1` still fails:

    23:02:29 [error] GenServer Smolquery.StorageService.Compactor terminating
    23:02:44 [warning] seal of {"bench","otel_logs__p2"} crashed: {:timeout, ...
    23:03:15 [warning] seal of {"bench","otel_logs__p2"} crashed: {:timeout, ...

Nine crash or termination lines in four minutes, still looping after the sweep.
The segment count per `read_parquet` **grew from 36–44 to 47, then 64**. Faster
ingest produces more segments, so the seal batch gets bigger, so it is more
likely to exceed the same call timeout. More hardware feeds the loop.

`storage-1` rides its 3 GiB limit, drops to 289 MB, and climbs back — with the
pod never restarting. That is the seal tasks dying under memory pressure and
their supervisor respawning them. **Contained, which is what the limit bought,
but not fixed.** The blast radius is one pod's tasks instead of the kernel
killing the api pod on another node.

Bounding segments per seal batch is the fix, upstream in smolquery. Raising the
timeout would hide it until the next throughput increase.

## Sweep 4: `otel_logs_v2`, with the `inserted_at` column

> Written up standalone in
> [2026-08-15-remote-v2-baseline.md](2026-08-15-remote-v2-baseline.md), which
> is the current baseline. **Correction:** this sweep ran on 4 nodes, not 3 —
> a dedicated tainted `m7i.large` for the api pod plus 3× m7i.xlarge. Both
> storage pods hit their 3 GiB limit during it.

New table carrying a 63rd column stamped with the send time. The
body grew 6.81 → 6.87 MiB and k6 now substitutes a placeholder per request
(6.46 ms, measured in goja). Results in `results/raw-remote-v2/`.

| VU | m7i / old table | m7i / v2 | change | MiB/s | p99 old | p99 v2 | refused |
|---|---|---|---|---|---|---|---|
| 8 | 20,917 | 22,201 | +6% | 49.9 | 1,492 | 2,135 | 0 |
| 16 | 21,534 | **22,579** | +5% | **50.7** | 4,214 | 3,298 | 0 |
| 32 | 20,484 | 18,748 | −8% | 42.1 | 5,597 | 6,330 | 0 |
| 64 | 20,161 | 18,809 | −7% | 42.3 | 10,696 | 11,089 | 0 |

**New peak: 22,579 rows/s at 16 VUs.** Zero refusals at every step, zero pod
restarts.

### This corrects the "~46 MiB/s uplink ceiling" claim

Earlier sweeps pinned at 44–47 MiB/s and I called that the client's ceiling.
This one reached **50.7 MiB/s** at 16 VUs and fell to 42 MiB/s at 32 and 64.
The client limit is not a hard wall at 46 — it is a **noisy band, roughly
42–51 MiB/s**, and which step lands high or low varies between runs.

So read the ±8% spread here as network variance, not as an effect of the new
column. Two things argue against a systematic cost: 8 and 16 VUs went *up*
with the larger body, and the stamping costs ~4% of one client core at these
request rates — far too little to move throughput 8%.

The cluster stayed idle throughout: 106–166% of 1,200% available CPU, buffers
even at 17–26% of a core each.

### Data check

3,796,880 rows in `bench.otel_logs_v2`, across **1,125 distinct `inserted_at`
values** spanning 01:13:23 to 01:55:27. The measured windows accepted
2,633,320 rows; warm-ups and preflights account for the rest.

### The seal path still fails

Nine crash or termination lines on `storage-1` during the sweep, one on
`storage-0`. Unchanged by the new table, and expected — the fix is
[T-244](../.plans/2026-08-14_02_sandbox-cluster-hardening.md), bounding
segments per seal batch upstream. `storage-0` peaked at 2,109 Mi against its
3 Gi limit and no pod restarted.

## The api pod is not the limit, yet

`smolquery-api-0` stays at 16% of a core at the P=1 peak. It is a thin front
door. The work is in the buffer, and the seal path in `storage-1`, which peaks
near 171%.

At P=3 and 64 VUs it reaches 40% average and 83% peak, with resident memory at
1,168 MB. Still not the constraint, but it is the one pod with no replica, so
watch it as throughput grows.

## One denoted uncertainty

Total bytes sent pins at 44–46 MiB/s for every step from 16 VUs up. That is
close to the 43.9 MiB/s at the peak, so a client uplink near ~46 MiB/s
(~386 Mbps) cannot be fully ruled out as a co-limit.

The server-side evidence is stronger, for two reasons. The 429s are the
server's own backpressure, which a client cap cannot produce. And `buffer-1`
sits at 1.4–1.7 of its node's 2 cores while its memory grows without bound.

An EC2 load generator inside `eu-central-1` removes the doubt. See
`.plans/2026-08-14_01_remote-sandbox-bench.md`, Phase 2. After the partition
change this is no longer optional: the buffers idle near 50% of a core while
the laptop saturates, so **the cluster's ingest capacity remains unmeasured.**

## Burstable credits did not distort this

Both nodes run t3 `unlimited`. `CPUCreditBalance` **rose** through the sweep,
113 → 131, so no step ran throttled. At this duty cycle — 30 s of load per
~55 s step — the sweep earns credits faster than it spends them. A sustained
run is different: `buffer-1` at 72% of a 2-vCPU node against a 30% baseline
burns roughly 0.84 vCPU-minutes per minute, which drains a 131-credit balance
in about 2.5 hours. A long Phase 2 sweep should watch the balance, or move off
t3.

## One transient failure, denoted

The sweep's 64-VU step failed to start: `create table` returned a Cloudflare
520 immediately after the 32-VU run. No pod restarted, and `/healthz` answered
200 straight after. A saturated api pod simply answered the control request
too slowly for Cloudflare. Control-plane calls in the `remote` arm now retry,
and the 64-VU step ran on its own afterwards.

## Comparison, with care

The local baseline on an M1 Pro reached 383,157 rows/s
([2026-08-10](2026-08-10-baseline.md)). Do not read 19,932 against it as a
regression. That run had 10 cores to itself, a loopback network, and a write
pool of 10. This one has one buffer pod on a shared 2-vCPU node, reached over
the internet.

## What to change first

1. ~~**Set `SMOLQUERY_WRITE_PARTITIONS=3`.**~~ **Done.** Removed the
   single-buffer ceiling; the rotation splits load evenly three ways.
2. ~~**Stop the api pod and buffer-1 sharing a node.**~~ **Done.** Preferred
   anti-affinity plus 3 nodes gives 2 pods per node.
3. ~~**Set CPU requests that reflect reality.**~~ **Done**, with memory limits
   and engine caps beneath them. Zero restarts through a full sweep.
4. ~~**Leave t3.**~~ **Done.** 3× m7i.xlarge, non-burstable.

Open, in order:

5. **Bound segments per seal batch** — upstream in smolquery. The batch grew
   36–44 → 47 → 64 segments as ingest got faster, and `storage-1` now rides its
   3 GiB limit in a contained crash-respawn loop. This is the one problem more
   hardware made worse. Raising the call timeout would hide it until the next
   throughput increase.
6. **Measure the real ceiling from in-region.** Phase 2 of
   `.plans/2026-08-14_01_remote-sandbox-bench.md`. Every number in this document
   past 8 VUs is the laptop's uplink, not the cluster's capacity. The cluster
   sat at 159% of 1,200% CPU at 64 VUs.
7. **Drop the `bench` dataset.** It holds millions of rows and needs a
   catalog-side action; the router exposes no table delete.
