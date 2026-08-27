# 2026-08-27: OTel attribute bags as `MAP(STRING, STRING)` vs `VARIANT` vs 63 flat columns (T-393)

**Recommend `MAP(STRING, STRING)` for attribute bags. On realistic rows the
`VARIANT` arm cannot be queried at all: every query that names the variant
column dies with DuckDB `Out of Memory Error: failed to allocate data of size
128.0 MiB (… / 953.6 MiB used)` — the 1 GB engine limit — scoped to one
project or not, scattered or single-engine, over 7.9M rows.** The map arm
answers the same key filter over 6.0M rows in 2.8 s, and the flat arm in
1.5 s.

**Ingest favours the variant, then flat, then map.** At 32 VUs: variant
148,028 rows/s (357 MiB/s), flat 131,526 (295 MiB/s), map 101,867
(246 MiB/s) — a map costs 23% of the flat rate, because the row path
re-encodes to NDJSON for a map schema (T-140) while a variant passes
through. Zero refusals, zero restarts, on every arm.

**Clustering by `project` does not prune files.** Every sealed file holds
every project — each request body carries 955 of the 1,000 projects — so
`Total Files Read` is the whole table on every case (17, 23, 16 files). What
the sort does buy is row-group skipping inside a file: the deployed
`SMOLQUERY_SEAL_ROW_GROUP_SIZE` is 100,000 rows, a ~400k-row sealed file has
four sorted groups, and a project-scoped key filter runs at 0.6 s engine
against 3.7 s unscoped on the map arm. Per-project isolation at file level
needs a partition key, which the catalog does not have.

**The benchmark body repeats per request, and that decides what a Parquet
column costs.** The first round (`_v1` tables) fed the same 3,062 rows on
every request. Parquet dictionary-encoded the whole variant string — 3,062
distinct values — and DuckDB evaluated `variant_extract(...) = 'POST'` on
dictionary entries, so the variant filter looked 3× *faster* than the map
(1.1 s vs 3.7 s) while its group-by, which must parse every row, took 18.1 s
(2.2 µs/row). Round 2 (`_v2` tables) stamps a per-request value into
`log_attributes`, which is what breaks the dictionary and what makes the
variant column 1.3 KB of JSON text per row in memory. The map column
dictionary-encodes per key, so the stamp changed its numbers by a few
percent. A production attribute bag has per-row unique values (session,
client address, request id); round 2 is the honest round.

## Setup

- Cluster: smolquery `main@43f1b30` (image `sha256:bba2b12e`, deploy
  `2986cbb`), rolled 16:54Z today — the first build with `MAP(STRING,
  STRING)` (T-140) and `VARIANT` (T-392). Tuning unchanged since
  2026-08-21; `SMOLQUERY_MEMORY_LIMIT=1GB` for the query engines,
  `SMOLQUERY_SEAL_ROW_GROUP_SIZE=100000`. 3 api pods on m7i.large (the
  query role lives there), 3 buffer and 3 storage on m7i.xlarge. Zero
  restarts before, during and after.
- Shape: `tools/genbody -shape clickstack` — the ClickStack logs layout
  (<https://clickhouse.com/docs/clickstack/ingesting-data/schemas#logs>),
  snake_case, plus `project` and `inserted_at`: 15 scalar columns and
  `resource_attributes` (25 keys), `scope_attributes` (1 key),
  `log_attributes` (23–27 keys: `http.*`, `url.*`, `code.*`, `client.address`,
  `server.*`, `enduser.id`, `session.id`, `duration_ms`, the four
  `exception.*` keys on the 3% error rows, and in round 2 `ingest.stamp`).
  Same generator values as the 63-column `otel` shape, so the flat arm is
  the same rows flattened. 3,062 rows per body: 7.38 MiB clickstack
  (7.51 MiB stamped), 6.87 MiB flat. Numbers stay JSON numbers in the body:
  a map stores them as text, a variant keeps the type — one body, both tables.
- Tables, all fresh: `clickstack_map_v1`/`_v2` (`MAP(STRING, STRING)`),
  `clickstack_variant_v1`/`_v2` (`VARIANT`), clustering `[project, timestamp]`;
  `otel_logs_v34` (63 columns), clustering `[project_id, timestamp]`.
- Sweep per arm: preflight, drain, 8 VUs 30 s, drain, 32 VUs 30 s, then the
  twelve query cases over hot ∪ sealed, drain, the cases again over sealed.
  Three repeats per case plus one `explain: analyze`. Scoped cases use
  `proj_0617`, whose seven body rows include a `POST`, a 5xx, an exception
  and a slow-query body. `mise run bench-attrs` from the in-region box
  (`i-06d4147bf6045778d`), 17:20–18:15Z.

## Ingest

| arm | body | vus | rows/s | MiB/s | requests | 429 | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|---|---|---|
| map v1 | repeated | 8 | 46,850 | 113 | 466 | 0 | 514 | 608 | 637 | 701 |
| map v1 | repeated | 32 | **101,867** | 246 | 1,021 | 0 | 924 | 1,202 | 1,400 | 1,603 |
| map v2 | stamped | 8 | 47,066 | 116 | 464 | 0 | 514 | 601 | 633 | 674 |
| map v2 | stamped | 32 | 97,552 | 239 | 978 | 0 | 930 | 1,419 | 1,578 | 1,795 |
| variant v1 | repeated | 8 | 54,168 | 131 | 535 | 0 | 456 | 511 | 569 | 641 |
| variant v1 | repeated | 32 | **148,028** | 357 | 1,481 | 0 | 653 | 814 | 958 | 1,236 |
| variant v2 | stamped | 8 | 53,536 | 131 | 528 | 0 | 453 | 493 | 513 | 528 |
| variant v2 | stamped | 32 | 141,681 | 348 | 1,408 | 0 | 677 | 827 | 867 | 892 |
| flat | repeated | 8 | 53,836 | 121 | 528 | 0 | 449 | 500 | 557 | 580 |
| flat | repeated | 32 | **131,526** | 295 | 1,318 | 0 | 712 | 1,014 | 1,218 | 1,367 |

Latencies in ms over accepted requests. 30-second bursts, not sustained
rates. The map arm's p50 at 32 VUs is 30% above the flat arm's and its
rows/s 23% below: `Schema.value_from_json/2` decodes and re-encodes every
row for a map schema, where a flat or variant body passes the client's
bytes through. The variant arm beats flat by 13% on rows/s — three JSON
objects per row are cheaper for `read_json` than 63 scalar columns.

Pod CPU over the 32-VU point (averages; peak `memory.current`, page cache
included): api 0.12–0.23 cores on every arm; buffer 0.40–0.56 cores,
1.5–2.1 GB; storage 0.31–2.06 cores, **6,144–6,442 MB on every arm** —
the storage tier's cgroup limit is 6,442 MB, and it sat there through every
32-VU point and the map arm's first query tier, with nothing killed. Same
reading as 2026-08-24: page cache, not proof either way.

## Sealed size and seal cost

From each sweep's metrics database, consecutive-sample deltas:

| arm | rows sealed | sealed bytes | B/row | seals | s per seal |
|---|---|---|---|---|---|
| map v1 | 6,120,938 | 36,503,755 | 6.0 | 15 | 13.4 |
| map v2 | 5,986,210 | 33,999,312 | 5.7 | 16 | 14.5 |
| variant v1 | 8,209,222 | 24,523,647 | 3.0 | 22 | 6.8 |
| variant v2 | 7,936,704 | 59,152,926 | 7.5 | 22 | 7.7 |
| flat | 7,575,388 | 18,129,007 | 2.4 | 16 | 7.4 |

**Do not read the bytes per row as a size claim.** The flat arm's preflight
— 3,062 unique rows in one seal — came out at 189.7 B/row; the repeated
rows of the sweeps compress 30–80× on top of that, in every arm, because
every value repeats across requests. The only honest size number here is
the ratio the stamp exposed: making each variant string unique took the
variant arm from 3.0 to 7.5 B/row (2.5×) while the map arm moved from 6.0
to 5.7. A map dictionary-encodes each key's values separately; a variant
is one string per row, and any per-row unique value inside it defeats the
dictionary for the whole bag.

**The map seal costs twice the flat seal.** 13.4–14.5 s per seal for a map
table against 7.4 s flat and 6.8–7.7 s variant, for the same ~400k rows per
seal. The merge reads ~24 hot micro-segments per seal off the buffer pods
and writes Parquet MAP columns, which are nested (repeated key/value
groups) where a JSON string is one BYTE_ARRAY column. Sealing still kept
pace: every arm's hot tier emptied 49–60 s after each point.

## Queries

Sealed tier, wall median over three runs in ms, then the engine's own
`Total Time` from `explain: analyze`. Every query pays a ~1.0–1.6 s floor
outside the engine (see 2026-08-19); read the engine column for the scan.
Rows differ per arm because each arm ingested a different count.

| case | map v2 wall / engine | variant v2 wall / engine | flat wall / engine |
|---|---|---|---|
| count-project | 1,659 / 0.28 | 1,727 / 0.42 | 1,161 / 0.19 |
| count-all | 1,599 / 0.00 | 1,605 / 0.00 | 1,017 / 0.00 |
| method-project | 1,873 / 0.65 | **OOM** | 1,537 / 0.57 |
| method-all | 3,011 / 4.19 | **OOM** | 1,544 / 0.59 |
| status-project | 1,755 / 0.47 | **OOM** | 1,282 / 0.23 |
| status-all | 2,949 / 4.29 | **OOM** | 1,497 / 0.51 |
| errors-project | 1,905 / 0.60 | **OOM** | 1,220 / 0.20 |
| errors-all | 3,005 / 4.18 | **OOM** | 1,463 / 0.53 |
| route-group-project | 1,346 / 0.44 | **OOM** | 1,141 / 0.21 |
| route-group-all | 5,237 / 4.25 | **OOM** | 1,465 / 0.53 |
| body-like-project | 1,695 / 0.31 | 1,691 / 0.47 | 1,270 / 0.21 |
| body-like-all | 1,747 / 0.61 | 1,822 / 0.82 | 1,634 / 0.52 |

The hot ∪ sealed tier, run right after the 32-VU point with 46–132 hot
files present, reads the same within 10% on every case, so it is not
tabled; both tiers are in the `*.attrs.json` files.

Per row, on the unscoped key-filter scan: flat 0.08 µs (0.59 s / 7.6M),
map 0.70 µs (4.19 s / 6.0M), variant — in round 1, where it ran — 2.2 µs
on the group-by (18.1 s / 8.2M) and 0.13 µs on the filter, the latter a
dictionary artifact. **A map key filter costs ~9× a flat column and a
variant key extraction ~3× a map's**, when it runs at all.

### The variant OOM

Every variant-v2 case that names `log_attributes` failed three times out of
three, in both tiers, and the explain failed too — 36 `Out of Memory Error`
lines on api-1. Reproduced by hand after the sweep, cluster idle:

```
SELECT count(*) FROM bench.clickstack_variant_v2
WHERE log_attributes['http.request.method']::VARCHAR = 'POST'
  → Out of Memory Error: failed to allocate data of size 128.0 MiB (1.2 GiB/953.6 MiB used)
… WHERE project = 'proj_0617' AND …                       → same, 928.1 MiB used
… with "distributed": false                               → same, 878.7 MiB used
SELECT count(*) FROM bench.clickstack_map_v2 WHERE log_attributes['http.request.method'] = 'POST'
  → 1,589,415 rows in 2.8 s, 3 shards
```

The variant column is `JSON` text on disk (`schema.ex`, "stored as JSON and
queried as VARIANT"): ~1.3 KB per row, 7.9M rows, ZSTD-compressed to 7.5
B/row but decoded to full strings. The Parquet reader allocates column
chunks per row group and per thread; DuckDB's own hint in the error is to
reduce threads. With the query engine capped at 1 GB
(`SMOLQUERY_MEMORY_LIMIT=1GB`, `push-secrets.exs:57`) against a 3 GiB api
pod, the string column of a few row groups is enough. The project filter
does not help: row-group skipping still leaves whole 100k-row groups of
1.3 KB strings to decode. On the `_v1` table the same queries ran because
the dictionary held 3,062 strings.

`count(*)` and the `body LIKE` cases pass on the variant table: DuckDB
does not read a column no expression names.

### What the plans say about `project`

`Total Files Read` on every scoped and unscoped case: 17 (map v1), 16
(map v2), 23 (variant), 16 (flat) — the whole table each time. The
clustering sort is applied at seal (`merge.ex:143-170`, `ORDER BY` on the
`COPY`), so within a file rows are ordered by `project`, and the four
100k-row groups per file carry tight `project` bounds; that is where the
6× engine-time gap between `method-project` and `method-all` comes from.
File-level pruning would need each file to hold a slice of projects, which
a write path that sorts a batch of *every* project's rows cannot produce.
The 2026-08-16 pruning bench pruned on the date because the bodies were
backdated per run; a project is not a date.

## Caveats

- One sweep per arm, 30-second points, one day. The ingest ordering
  (variant > flat > map) is consistent across both rounds and both VU
  points; the query numbers are one engine run each plus three walls.
- The body repeats per request. Round 2 fixes the variant column's
  dictionary artifact; the map and flat columns still dictionary-encode
  values that repeat across requests, so their bytes per row and part of
  their scan cost are lower bounds.
- The scoped cases hit `proj_0617`, 0.23% of the rows. A wider project
  would sit between the scoped and unscoped columns.
- The flat arm's queries scattered 23 of 109 jobs; the map and variant
  arms 65–69 of ~110. Not explained here; the flat arm's wall times may
  understate what scatter would give it.
- The storage tier sat at its memory limit through every 32-VU point on
  every arm. Nothing was killed.
- `otel_logs_v34` took a preflight body and a partial warm-up from an
  aborted first launch before its sweep; ~3,000 extra rows.

## Next

1. **T-393 answer: `MAP(STRING, STRING)`.** VARIANT as stored today is not
   queryable at this row count under the 1 GB engine limit; T-394 (native
   shredded VARIANT) is the path that changes that, and this bench is the
   one to re-run when it lands.
2. Raise `SMOLQUERY_MEMORY_LIMIT` on the api pods (3 GiB pods, 1 GB engines)
   and re-run the variant-v2 cases to find where they fit — and whether
   the answer is memory or threads (`SET threads`).
3. The map ingest tax (23% of flat rows/s) is the re-encode in
   `Schema.value_from_json/2`; a passthrough for object-valued map columns
   would remove it.
4. The map seal at 2× the flat seal: profile the Parquet MAP write in the
   merge before sizing storage pods for map tables.
5. Per-project file pruning needs a partition key. Cost it separately.

## References

- Write-ups this builds on: [2026-08-22-one-billion-rows.md](2026-08-22-one-billion-rows.md),
  [2026-08-25-onebrc-v5-and-s3-timings.md](2026-08-25-onebrc-v5-and-s3-timings.md).
- HTML reports: `loadgen-20260827T171953Z-attrs-map.html`,
  `loadgen-20260827T173245Z-attrs-variant.html`,
  `loadgen-20260827T174317Z-attrs-flat.html`,
  `loadgen-20260827T175038Z-attrs-map2.html`,
  `loadgen-20260827T175937Z-attrs-variant2.html`. Sidecars in
  `results/raw-loadgen/loadgen-{vus8,vus32,attrs}-attrs-{map,variant,flat,map2,variant2}.*`.
- Types: `~/Dev/supabase/smolquery/lib/smolquery/schema.ex:20-100`,
  `docs/api.md:60-101`. Seal sort and row groups:
  `lib/smolquery/storage_service/merge.ex:143-170,351`. Limits:
  `~/Dev/supabase/smolquery-deploy/smolquery-deploy/push-secrets.exs:57,60`.
- Tracker: T-393, PL-56, T-140, T-392, T-394.
