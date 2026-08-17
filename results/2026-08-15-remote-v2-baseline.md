# Remote sandbox baseline — `otel_logs_v2`, 2026-08-15

The latest bench run against the deployed cluster at
`eu-central-1-sandbox.smolquery.com:8443`, driven from a laptop over the public
internet. Supersedes the narrative in
[2026-08-14-remote-sandbox.md](2026-08-14-remote-sandbox.md), which records how
we got here.

**Peak: 22,579 rows/s at 16 VUs. Zero refusals at every load level. Zero pod
restarts.** Raw data in `results/raw-remote-v2/`.

## Results

| VU | rows/s | MiB/s | p50 ms | p95 ms | p99 ms | refused |
|---|---|---|---|---|---|---|
| 8 | 22,201 | 49.9 | 991 | 1,740 | 2,135 | 0 |
| 16 | **22,579** | **50.7** | 2,111 | 2,694 | 3,298 | 0 |
| 32 | 18,748 | 42.1 | 4,935 | 6,174 | 6,330 | 0 |
| 64 | 18,809 | 42.3 | 10,283 | 10,909 | 11,089 | 0 |

Ran 01:13:23Z to 01:55:27Z. Per step: preflight, 10 s warm-up, 8 s pause, 30 s
measured, 5 s stop.

## What ran

- Body: `bodies/eachrow.3062.ndjson`, 3,062 OTel rows, **63 columns**,
  6.87 MiB, seed 42.
- Table: `bench.otel_logs_v2`, clustering `(project_id, timestamp)`,
  `SMOLQUERY_WRITE_PARTITIONS=3`.
- Engine caps: `SMOLQUERY_MEMORY_LIMIT=1GB`,
  `SMOLQUERY_WRITE_ENGINE_MEMORY_LIMIT=512MB`.
- Client: laptop on Wi-Fi, 21 ms RTT. Path is laptop → Cloudflare → NLB → api.

### Topology — corrected

This run did **not** use the 3× m7i.xlarge shape reported earlier. The cluster
gained a dedicated, tainted node group for the api pod before the sweep
started. Nodes were created 00:07:5xZ and pods scheduled 00:10–00:21Z, all
stable with zero restarts through the sweep window.

| node | type | allocatable | pods |
|---|---|---|---|
| ip-10-61-25-108 | **m7i.large** | 1,930m | `smolquery-api-0` |
| ip-10-61-7-70 | m7i.xlarge | 3,920m | `buffer-0`, `buffer-1` |
| ip-10-61-25-6 | m7i.xlarge | 3,920m | `buffer-2`, `storage-1` |
| ip-10-61-35-187 | m7i.xlarge | 3,920m | `storage-0` |

Node group `api-…`: 1× m7i.large, label `workload=api`, taint
`dedicated=api:NoSchedule`. Node group `default-…`: 3× m7i.xlarge.
**13.7 vCPU allocatable in total.**

The api pod now has a node to itself. `buffer-0` and `buffer-1` still share
one, because the anti-affinity rule covers the api pod only.

## The storage pods are the pressure point

Both hit their **3 GiB memory limit exactly** during the sweep. Peak resident
per step:

| VU | api | storage-0 | storage-1 |
|---|---|---|---|
| 8 | 487 MB | 1,327 MB | **3,072 MB** |
| 16 | 573 MB | 1,416 MB | **3,072 MB** |
| 32 | 716 MB | 1,494 MB | 2,813 MB |
| 64 | 1,149 MB | **3,072 MB** | 1,921 MB |

3,072 MB is not a coincidence — it is `limits.memory: 3Gi`. The pods do not
grow to a natural working set and stop; they grow until the cgroup stops them.

**They are still doing it.** Sampled after the sweep, `storage-1` sits pinned
at 3,072 MB across consecutive reads while `storage-0` rests at 863 MB. Seal
and compactor crashes in the ten minutes after the sweep: **10 on storage-0,
15 on storage-1.**

Nothing restarted. That is the limit working as designed — seal tasks die under
memory pressure and their supervisor respawns them, so the blast radius is one
pod's tasks rather than the kernel killing a neighbour. Contained, not healthy.

The declared budget is 2 engines × `SMOLQUERY_MEMORY_LIMIT=1GB` = 2 GB, and the
observed ceiling is 3 GB. The extra ~1 GB is BEAM plus DuckDB allocation
outside its own accounting. **A 3 GiB container limit leaves a storage pod no
real headroom.** Either raise the limit or lower the engine cap; the two have
to be set together.

The root cause is unchanged and upstream: **T-244**, bounding segments per seal
batch. Segment counts per `read_parquet` grew 36–44 → 47 → 64 as throughput
rose.

## CPU was never the constraint

Average percent of one core:

| VU | cluster total | api | buffers |
|---|---|---|---|
| 8 | 106% | 13.0 | 17/18/17 |
| 16 | 129% | 19.9 | 20/19/19 |
| 32 | 130% | 24.9 | 22/22/23 |
| 64 | 166% | 37.5 | 24/25/26 |

166% of 1,370% available at the top of the sweep. The api pod peaked at 155.9%
of its 200% node — the one figure worth watching, since it now runs alone on a
2-vCPU instance.

## The client is still the limit, and it is noisy

Throughput per step tracks MiB/s, not the cluster. This run reached
**50.7 MiB/s** at 16 VUs and fell to 42 MiB/s at 32 and 64.

That **corrects an earlier claim** in the previous writeup, which called
~46 MiB/s a hard uplink ceiling. It is not a wall. It is a band of roughly
**42–51 MiB/s**, and which step lands high varies between runs. Read the −8% at
32 and 64 VUs as network variance, not as a cost of the new column: 8 and 16
VUs went *up* with the larger body, and the per-request stamping costs about 4%
of one client core at these request rates.

**The cluster's ingest ceiling remains unmeasured.** An in-region load
generator is the only way to get a real number — Phase 2 of
`.plans/2026-08-14_01_remote-sandbox-bench.md`.

## The `inserted_at` column

Every row now carries the send time. `gen-bodies.exs` writes a fixed-width
placeholder and the sender substitutes the real value: `k6/insert.js` per
request, the preflight in `scripts/bench.exs` for its own.

Verified in the database after the sweep:

| | |
|---|---|
| rows | 3,796,880 |
| distinct `inserted_at` | 1,125 |
| oldest | 2026-08-15T01:13:23.692778 |
| newest | 2026-08-15T01:55:27.374000 |

The measured windows accepted 2,633,320 rows; warm-ups and preflights account
for the rest.

Format is `2026-08-15T01:13:25.349000` — zone-less microseconds. **A trailing
`Z` fails**: smolquery's `basic` parser and ClickHouse's
`date_time_input_format=basic` both reject it. The column forced a new table,
because smolquery answers 409 on a `CREATE TABLE` whose schema differs and
offers no `add_column` route.

## Open

1. **T-244** — bound segments per seal batch, upstream. The only item that
   makes storage stop riding its limit.
2. **Re-tune the storage memory pair** — `SMOLQUERY_MEMORY_LIMIT` against
   `limits.memory`. 1 GB × 2 engines does not fit 3 GiB in practice.
3. **Measure from in-region** — every number past 8 VUs here is the laptop.
4. **Drop `bench.otel_logs`** — the old table, ~7.8M rows, no `inserted_at`.
