# 2026-08-27: the last 100 events per project, while rows stream in

> Four rounds in one day. The first section is the morning's baseline on
> the api pods with the wide query; the sections from "Rounds 2 and 3"
> on carry the changes that took one project from 1.59 s to 0.61 s idle
> and from 2.97 s to 0.70 s under ingest: a narrow projection, a 5-minute
> window, dedicated query pods, and four warm engines. The final numbers
> are in the addendum at the end.

**One project asking for its last 100 events gets them in 1.59 s idle and
2.97 s while 32 VUs push 95,000 rows/s into the same table. Four projects
asking at once get 3.2 s idle and 5.1–5.4 s under ingest.** Every query
returned exactly 100 rows, zero errors, across 771 queries. The 1 s target
is not met in any phase, and the gap is not the engine: the engine's own
time on this query is 0.86–0.98 s, and the rest is engine acquisition,
hot-tier fetches, and the request path around it.

**Distributing the query does nothing.** `ORDER BY inserted_at DESC LIMIT
100` is not a shape the scatter path decomposes, so every query ran on one
engine whatever `options.distributed` said — `shards: 0` in both modes,
wall times equal within noise in all eight phase-mode pairs. There is
nothing to gain or lose from the flag on this query today.

**Concurrency costs more than ingest.** Going from one querying project to
four doubles the idle latency (1.59 s → 3.2 s) and the reason is in the
counters: the api pods keep two warm engines each (`warm_engines: 2`,
`runtime.ex:162`), four back-to-back queriers drain them, and engine
acquisition goes from 85 ms (all warm) to 459 ms with 35 of 122
acquisitions cold. Ingest then adds ~1.4–2 s on top at either
concurrency — every tail query under ingest read the whole hot tier for the
table: ~600 hot-segment GETs and ~300 HEADs, ~35 MB, per query.

## Setup

- Cluster: smolquery `main@43f1b30` (image `sha256:bba2b12e`), the same
  as the T-393 bench earlier today. `SMOLQUERY_MEMORY_LIMIT=1GB` per
  engine, `warm_engines` 2 per api pod (default, no override), 3 api pods
  on m7i.large (the query role), 3 buffer and 3 storage on m7i.xlarge. Zero
  restarts.
- Table: `bench.clickstack_map_v2` — `MAP(STRING, STRING)` attributes,
  clustering `[project, timestamp]`, 6.0M rows at the start, 30.9M at the
  end (the ingest phases append). 73 sealed files at the end.
- The query, one per iteration per tail VU, each VU its own project
  (`proj_0617`, `proj_0589`, `proj_0878`, `proj_0809` — seven or more rows
  per body each; 14k–24k rows per project at the start):

      SELECT inserted_at, timestamp, severity_text, service_name, body, log_attributes
      FROM bench.clickstack_map_v2 WHERE project = 'P'
      ORDER BY inserted_at DESC LIMIT 100

  `inserted_at` is the per-request stamp, so this is the real "last 100";
  `timestamp` repeats per body and would tie. The map column rides along
  so the result is what a log view shows: 100 rows, ~250 KB of JSON.
- `k6/tail.js` on the in-region box (`i-00263f8738038c717`): closed loop,
  no think time, round-robin over the three api pod IPs, alternating
  `options.distributed` true and false per iteration. Three phases of 90 s:
  `tail-idle`, `tail-ingest-vus<N>` (the insert k6 warms up 10 s, then the
  tail k6 is detached while the measured insert runs), `tail-sealed` after
  the hot tier drains. Two runs: four tail VUs with ingest at 8 and 32 VUs
  (`-tail4`, 18:52–19:08Z), then one tail VU with ingest at 32 VUs
  (`-tail1`, 19:08–19:17Z). `mise run bench-tail`.

## The numbers

Wall is what k6 saw on the box, per query, in ms. `durationMs` is the
job's own clock. Modes are pooled where they agree; they agreed everywhere.

| tail VUs | phase | ingest | wall p50 | p90 | p95 | p99 | max | durationMs p50 | hot files seen |
|---|---|---|---|---|---|---|---|---|---|
| 1 | idle | — | **1,589–1,592** | 1,648–1,677 | 1,659–1,698 | 1,674–1,720 | 1,728 | 1,464–1,488 | 0 |
| 1 | ingest, 32 VUs | 95,274 rows/s, insert p50 947 ms | **2,970–2,990** | 3,524–3,785 | 3,643–3,883 | 3,872–4,183 | 4,258 | 2,782–2,808 | 128 / 265 |
| 1 | sealed | — | 1,684–1,709 | 1,780–1,816 | 1,810–1,836 | 1,866–1,903 | 1,933 | 1,570–1,572 | 0 |
| 4 | idle | — | **3,164–3,191** | 3,559–3,580 | 3,613–3,645 | 3,781–3,872 | 4,100 | 2,708–2,724 | 0 |
| 4 | ingest, 8 VUs | 45,832 rows/s, insert p50 524 ms | 5,103–5,313 | 7,347–7,528 | 7,509–7,703 | 7,902–8,494 | 8,673 | 4,725–4,879 | 75 / 122 |
| 4 | ingest, 32 VUs | 89,151 rows/s, insert p50 999 ms | **5,120–5,424** | 7,018–7,073 | 7,735–8,075 | 8,371–8,896 | 9,011 | 4,743–5,198 | 123–141 / 257 |
| 4 | sealed | — | 3,706–3,754 | 4,241–4,299 | 4,342–4,433 | 4,495–4,562 | 4,575 | 3,488–3,510 | 0 |

Ranges are the two modes. Every phase-mode pair returned 100 rows on every
query; errors 0. The four-VU sealed phase is slower than its idle phase
because the table grew from 6M to 31M rows and from 19 to 73 sealed files
between them.

Ingest paid for the queries: 32 VUs gave 89,151 rows/s with four tail
VUs and 95,274 with one, against 97,552–101,867 rows/s on this table with
no queries (T-393 sweeps). Api pods ran 1.2–1.4 of their 2 cores on
average during the 32-VU point and touched 2.0–2.2 at peaks: the query
engines and the insert path share those cores.

## Where the time goes

From each run's metrics database, consecutive-sample deltas over the phase,
divided by the phase's jobs.

| tail VUs | phase | jobs | job ms/job | engine acquire ms | cold / warm | manifest GETs/query | segment GETs+HEADs/query | hot-tier MB/query | hot-server ms/query |
|---|---|---|---|---|---|---|---|---|---|
| 1 | idle | 57 | 1,478 | **85** | 0 / 61 | 9.2 | 0 | 3.0 (manifests) | 55 |
| 1 | ingest 32 | 34 | 2,834 | 70 | 0 / 33 | 8.7 | 600 + 387 | 37.5 + 2.4 | 785 |
| 1 | sealed | 54 | 1,582 | 95 | 0 / 58 | 9.1 | 0 | 2.0 (manifests) | 34 |
| 4 | idle | 119 | 2,560 | **459** | 35 / 87 | 9.0 | 0 | 0.7 (manifests) | 10 |
| 4 | ingest 8 | 74 | 4,663 | 290 | 9 / 69 | 9.5 | 598 + 258 | 35.0 + 2.2 | 490 |
| 4 | ingest 32 | 75 | 5,213 | 133 | 0 / 75 | 9.0 | 633 + 417 | 35.7 + 4.4 | 1,141 |
| 4 | sealed | 102 | 3,404 | 142 | 0 / 105 | 9.0 | 0 | 4.7 (manifests) | 100 |

Read it as a stack, for one project, idle: wall 1.59 s = job 1.48 s +
0.11 s of HTTP and API. Inside the job: 85 ms acquiring an engine, ~55 ms
of hot manifest reads (nine per query — the count matches three buffer
pods times three write partitions, though nothing here proves that is
why), 0.86–0.98 s in the engine (`Total Time` from `explain: analyze`,
before and after the runs), and ~0.4–0.5 s unaccounted between engine and
job — result frame, map decoding, JSON. **The engine is 60% of the
wall; everything else is the other 40%.** The 1 s target needs both
halves to move.

Under ingest the job grows by 1.35 s (one VU) to 2.6 s (four). The hot
tier is read whole: at 32 VUs a query made ~600 segment GETs and ~400
HEADs against the buffer pods' `HotServer`, ~36 MB of micro-segments, for
0.8–1.1 s of hot-server time — and that is server time only; the engine
still has to read those 36 MB over HTTP into DuckDB. A project's last 100
rows live in a handful of the newest segments, but every micro-segment
holds every project, so nothing narrows the fetch (the same fact T-393
found for sealed files).

Four queriers versus one: engine acquisition 459 ms against 85 ms, 35 cold
starts in 122. `JobEngine` (`job_engine.ex:16-30`) prices a cold bootstrap
at ~650 ms on a production node — three extension loads and a catalog
`ATTACH` in another availability zone — and the pool holds two per pod.
Four closed-loop queriers over three pods exceed it, so one in three
queries starts cold, and the ones that get a warm engine still queue on
CPU behind the ones bootstrapping. The sealed phase at four VUs shows the
pool catching up (all 105 warm, 142 ms) and the wall still 2.2× the
one-VU figure: the remaining gap is the api pods' two cores shared by four
engines.

### What the plan says

`explain: analyze` on the idle table at the end:
`Total Files Read: 19`, the rest of the 73 skipped, `Total Time: 0.977s`,
23,478 rows scanned for the project before the Top-N. The same table's
`count(*) WHERE project = …` reads all 73. The skip is not the `project`
filter — it prunes no files, as T-393 found — it is DuckDB's Top-N
pushing a dynamic `inserted_at` bound into the scan once it holds 100
rows, and sealed files being time-contiguous. **The "last N" shape gets
file pruning for free from the time order of sealing**, which is why this
query reads 19 files at 31M rows and not 73.

## Caveats

- One run per shape, 90-second phases, one day, one build. The one-VU and
  four-VU idle numbers repeat within 3% across their idle and sealed
  phases (once the table growth is allowed for), so the ordering is solid;
  the absolute ms are one sample each.
- The queriers run with no think time. Four VUs back to back is four
  concurrent queries at all times — harsher than four users. `TAIL_SLEEP_S`
  models a gentler client.
- `distributed` is a no-op for this query because the scatter path does not
  decompose `ORDER BY … LIMIT`; that is a statement about today's
  decomposer, not about whether a scattered Top-N could help.
- Hot-tier bytes per query come from the hot server's counters on the
  buffer pods, summed across all tail queries in the phase and divided by
  the phase's job count; a few of those requests belong to the seal path.
- The table grew 5× during the run. Idle-vs-sealed comparisons carry that.

## Next (written after round 1; rounds 2–4 below did items 1 and part of 3)

1. **Warm engines: size the pool to the concurrency.** `SMOLQUERY_WARM_ENGINES`
   at 4–6 per api pod turns the four-VU idle case's 459 ms acquisition into
   ~90 ms; that is ~0.4 s off the 3.2 s. Cheap to try, one env value in
   `push-secrets.exs`.
2. **The hot tier is fetched whole per query.** For a "last N" query the
   engine needs only the newest segments that can hold the project — a
   Top-N bound on the hot manifest (the segments' `inserted_at` ranges are
   in the manifest) would cut ~600 GETs to a few. That is the 1.4–2 s
   under ingest.
3. **The engine's 0.9 s** is a scan of the project's ~15–23k rows across 19
   files plus the Top-N; per-file `project` row-group skipping is already
   in play. Profile before guessing.
4. Repeat with `TAIL_SLEEP_S=1` and eight projects to see the shape a real
   fleet of tenants makes, and with `TAIL_ORDER=timestamp` to see what a
   tie-heavy sort costs.

## References

- Sidecars: `results/raw-loadgen/loadgen-tail-{idle,ingest-vus8,ingest-vus32,sealed}-tail{4,1}.tail.json`,
  `loadgen-tail-tail{4,1}.tail.json`, `loadgen-tail-vus{8,32}-tail{4,1}.{k6,pods}.json`,
  `loadgen-20260827T185143Z-tail4.metrics.sqlite3`, `loadgen-20260827T190412Z-tail1.metrics.sqlite3`.
  HTML: [loadgen-20260827T185143Z-tail4.html](loadgen-20260827T185143Z-tail4.html),
  [loadgen-20260827T190412Z-tail1.html](loadgen-20260827T190412Z-tail1.html).
- Rounds 3–4 sidecars: `loadgen-tail-*-tail4q.*`, `loadgen-tail-*-tail{4,1}-warm4.*`;
  HTML: [loadgen-20260827T195338Z-tail4q.html](loadgen-20260827T195338Z-tail4q.html),
  [loadgen-20260827T201913Z-tail4-warm4.html](loadgen-20260827T201913Z-tail4-warm4.html),
  [loadgen-20260827T202534Z-tail1-warm4.html](loadgen-20260827T202534Z-tail1-warm4.html).
  Tracker: T-400 under PL-49.
- Engines: `~/Dev/supabase/smolquery/lib/smolquery/query_service/job_engine.ex:16-30,61-68,122-145`,
  `engine_pool.ex:1-22`, `runtime.ex:100-110,162-164`. Hot server counters:
  `lib/smolquery/telemetry.ex` (`smolquery_hot_server_*`, T-315).
- Harness: `k6/tail.js`, `scripts/loadgen.exs` `run_tail/5`, `mise run bench-tail`.

## Rounds 2 and 3, 19:36–20:14Z: the narrow windowed query, then the query pods

By hand on the idle table first: the six-column query is a 1.5–1.6 s job
(engine 1.01 s, 23 files, 145 KB of result); `timestamp, trace_id,
span_id, body` alone brings the engine to 0.78 s and the result to 41 KB;
adding `inserted_at >= newest − 5 min` brings the engine to 0.32–0.39 s
over 12–15 files, a 0.94–1.17 s job. An empty window is a 0.63–0.72 s job
with the engine at 0.004 s, and `SELECT 1` a 0.14–0.25 s job: touching a
table costs ~0.45 s before any scan. `TAIL_COLUMNS` and `TAIL_WINDOW_S`
(default 300 s) make that the harness's query.

Round 2 (`-tail4w`, api pods still serving queries, four queriers): the
empty-window idle phase read **2.23 s p50 with the engine doing nothing** —
the per-job path under concurrency, not the scan. Its ingest phase lost
the tail k6 to a quoting bug in the detached command (fixed) and its
sealed phase overlapped the 19:50Z rollout that added the query pods
(14 errors); both discarded.

Round 3 (`-tail4q`, queries to the three new query pods,
`SMOLQUERY_ROLES=api,query,web`, two warm engines each, four queriers):
idle 1.31 s (empty window), under 32-VU ingest at 83k rows/s
**2.64–2.71 s p50, p95 5.1–5.4 s**, sealed 1.45 s; 100 rows every query.
Engine acquisition ~550 ms with 119 cold starts in 253; the query pods at
1.3–1.9 cores on an empty window. The window cut the hot fetch from ~600
GETs and 36 MB per query to ~370 GETs and 11 MB, but under ingest the
whole hot tier is younger than five minutes, so the conjunct prunes only
just-sealed leftovers; the buffer pods still spent ~2 s of hot-server time
per query. The one-querier pass of this round overlapped the warm-engine
re-roll and is discarded.

## Addendum, 20:2x–20:4xZ: query pods, the narrow windowed query, and four warm engines

The cluster gained three query pods (`smolquery-query-0..2`,
`SMOLQUERY_ROLES=api,query,web`, the api pods now `api,ingest`, the ingress
routing `/v1/queries` to the query pods), and `SMOLQUERY_WARM_ENGINES` went
from 2 to 4 on them. The query changed too: `timestamp, trace_id, span_id,
body` only, and `AND inserted_at >= now − 300 s` (`TAIL_COLUMNS`,
`TAIL_WINDOW_S`, `TAIL_QUERY_SERVICE=smolquery-query`). 60-second phases.

| queriers | phase | ingest | wall p50 | p95 | p99 | rows | engine acquire | cold |
|---|---|---|---|---|---|---|---|---|
| 1 | idle (window holds the previous run's rows) | — | **614–616 ms** | 676–698 | 688–740 | 100 | — | — |
| 1 | ingest, 32 VUs | 90,216 rows/s | **683–718 ms** | 1,590–1,980 | 2,288–2,348 | 100 | — | — |
| 1 | sealed | — | 628–635 ms | 677–705 | 687–743 | 100 | — | — |
| 4 | idle (window empty) | — | 1,270–1,307 ms | 1,424–1,435 | 1,436–1,473 | 0 | 63 ms | 0 / 147 |
| 4 | ingest, 32 VUs | 84,226 rows/s | **1,732–1,905 ms** | 3,905–4,277 | 4,600–4,770 | 100 | 65 ms | 0 / 152 |
| 4 | sealed | — | 1,467–1,498 ms | 1,792–1,793 | 1,821–1,851 | 100 | 54 ms | 0 / 181 |

Against the same four-querier shape with two warm engines (round 3, an
hour earlier): under ingest 2.64–2.71 s p50 → 1.73–1.90 s; sealed 1.45 s →
1.47–1.50 s (unchanged); idle 1.31 s → 1.27–1.31 s (unchanged). Engine
acquisition went from ~550 ms with 119 cold starts in 253 to 63 ms with
none. **The warm pool removed the cold starts, and that is worth ~0.9 s
under ingest and nothing when idle** — at four queriers the idle job is
still 1.16 s on an empty window with the query pods at ~1.4 cores each,
which is the per-job path under concurrency, not the pool.

**One project meets the target: 0.6 s idle, 0.7 s p50 under 90k rows/s of
ingest**, with a p95 of 1.6–2.0 s under ingest that is the hot-tier fetch
(~290 segment GETs and ~200 HEADs per query, 0.9 s of hot-server time —
T-400). Four projects back to back do not: 1.3 s idle, 1.7–1.9 s under
ingest. `distributed` is a no-op throughout (`shards 0`).
