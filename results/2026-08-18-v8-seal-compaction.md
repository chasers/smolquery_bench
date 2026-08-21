# 2026-08-18: otel_logs_v8 — sealing and compaction under ingest

The first sweep with per-pod metrics sampling. One ingest step at 16 VUs from
the in-region load generator, then a 600 s compaction watch. Fresh table
`otel_logs_v8`, clustering `[project_id, inserted_at]`. Metrics database:
`results/raw-loadgen/loadgen-20260818T150149Z.metrics.sqlite3` (48 ticks,
10 s apart, phase-tagged).

## Verdict

**Sealing and compaction kept up — at the cost of one storage pod.** Every
row sealed, and compaction collapsed the table to 5 files. But the seal
drain OOM-killed `smolquery-storage-1` at 15:04:38Z, about 90 s after
ingest stopped.

## Ingest

| run | rows/s | MiB/s | p50 ms | p95 ms | p99 ms | refused |
|---|---|---|---|---|---|---|
| loadgen-vus16 (v8) | 175,511 | 393.5 | 242 | 524 | 645 | 0 |

38% above the 2026-08-15 in-region baseline (127k rows/s, `otel_logs_v2`).
7,330,430 rows committed, balanced across the three buffer pods (~2.44M
each). Zero refusals, zero rejected rows, zero dedup.

## Sealing

Counter deltas over the sweep window, summed across the storage pods:

- `seal_attempts_total{ok}` +18, `{error}` **0**
- `seal_segments_total{ok}` +6,778 micro-segments
- `seal_stuck_attempts_total` 0, `seal_release_failures_total` 0
- Seal attempts ran up to ~115 s each on storage-1, which drained the
  largest share (5,346 segments) before it died.

End state, from the count query's statistics: **hot files 0, sealed files
5, 7,330,428 rows** — the whole table sealed and compacted, nothing left in
the hot tier ten minutes after ingest.

## The OOM

`smolquery-storage-1` was OOMKilled at 15:04:38Z, during the post-ingest
seal drain. The sampler caught it as a counter reset (its compaction error
counter fell from 115 to 1) and a 7-minute sampling gap; the log-based
compaction watcher missed it, because the restart check reads a point-in-time
`restartCount`. After the restart the pod resumed and the backlog still
drained. This is the same failure mode as the 2026-08-16 T-245 OOMKill —
the seal path can still outrun the pod's memory under a 30 s burst at 175k
rows/s.

## The poison loops (pre-existing, not v8)

Two corrupt sealed segments from the 2026-08-17 runs fail compaction
forever, one attempt every ~6.5 min, ~88 s per attempt:

- storage-0, `otel_logs_v6__p1/01M0912MKBBHFWYC7SD298ACZS.parquet`
  (ULID mints at 2026-08-17T23:32:00Z): "No magic bytes found at end of
  file" — a truncated object. 120 failures and counting.
- storage-1, `otel_logs_v7`: "Content-Length from server mismatches
  requested range" — the object is shorter than the reader expects. Also
  consistent with a truncated upload.

Root cause, confirmed 2026-08-18 evening from the object's metadata: the
v6 object's S3 `LastModified` is **02:09:42Z** — hours after its ULID mint
(23:32:00Z) and 22 s after a storage OOMKill — with a single-PUT ETag and
a body that ends mid-stream. `Catalog.register_segments` is idempotent by
path by design ("a sealer that crashed between committing and retiring can
safely retry"), so a crash-recovery retry re-merges the claim and
**re-PUTs the same committed path** with no validation of the replacement
bytes. The retry during the OOM window shipped a truncated staging file
over a good committed object; re-registration no-ops, so the catalog kept
the original byte_size — which is exactly the v7 twin's symptom
("Content-Length from server mismatches requested range"). Three smolquery
bugs to file: the blind overwrite of a committed path (write-if-absent
would prevent it), the unvalidated staged upload, and the compactor's
missing quarantine for a permanently corrupt segment.

## Remediation (2026-08-18, late): all corrupt segments dropped

**v6 and v7 are healthy again.** Snapshots 491 (v6) and 492 (v7) drop the
corrupt segments. Full scans pass through the engine and through
`POST /v1/queries` (v6: 9,599,370 rows; v7: 3,940,794 rows).

There were **three** corrupt segments, not two. A recorded-size sweep
(`ducklake_data_file.file_size_bytes` vs `aws s3api list-objects-v2`)
found them all:

- `otel_logs_v6__p1/01M0912MKBBHFWYC7SD298ACZS.parquet` — recorded
  18,198,101; actual 18,201,134 (actual > recorded).
- `otel_logs_v6__p2/01M09114FBX8PE0K5N8JXRKHTC.parquet` — recorded
  48,116,640; actual 44,571,865.
- `otel_logs_v7/01M098JYKFE5XWH67EMP7W8N70.parquet` — recorded
  25,919,984; actual 25,822,315.

**The stale-cache theory was wrong.** The first padded replacement failed
on every engine, fresh or not, because it targeted the wrong size. The
plan's recorded size (18,201,134) was the corrupt object's *actual* size.
DuckLake reads with the *recorded* size, so the trailing-8-byte check
landed mid-footer. Two rules for a replacement object:

1. The total size must equal `ducklake_data_file.file_size_bytes`.
2. The declared footer length must equal `ducklake_data_file.footer_size`.
   DuckLake validates it ("Parquet footer length stored in file is not
   equal to footer length provided"). Place the real footer thrift at the
   start of the declared footer region and zero-pad the rest
   (`pad_parquet2.py`, session scratchpad).

One engine-cache effect is real but small: an engine that has already
opened a path can serve a stale read after a re-upload. A pod recreate
cleared it. Note: `kubectl delete pod` is safe for engine state — `/data`
is an emptyDir with no segment cache.

**The drop wrote pod-local delete files and broke reads cluster-wide.**
DuckLake's `data_path` is `/data/ducklake/` (pod-local). Data files carry
absolute `s3://` paths, but the DELETE wrote its three delete files with
`path_is_relative = true`, so every other pod resolved them to its own
empty disk. The fix: copy the delete files off storage-0, upload them to
the table directories in the sealed bucket, and repoint the three
`ducklake_delete_file` rows (`path` absolute, `path_is_relative = false`).
An operator drop route must write delete files to the object store, not
to the engine-local `data_path`. This belongs on T-310 with the missing
quarantine.

**The drop then poisoned compaction a second way — count mismatch.**
`drop_segments` compiles to a row DELETE, so the padded files stayed live
with delete vectors instead of retiring. Their recorded `record_count`
still held the corrupt originals' counts (1.37M / 3.14M / 2.05M), while
the delete vectors covered only the padded content (195,968 rows each).
The compactor read the padded files **raw** (no delete-vector
application), merged their junk rows into real outputs, and then failed
the swap (`:inputs_survived_swap`) because metadata said live rows
remained. Each ~5-minute sweep added 391,936 junk rows to v6 and left the
merged output registered — a *growing* poison loop. Five v6 sweeps and
one v7 sweep landed before the fix (+1,959,680 / +195,968 junk rows).

The fix, in order:

1. Set `ducklake_data_file.record_count = 195968` on the three padded
   files, so metadata reads them as fully deleted. This alone stopped the
   loop — no compactor warnings or snapshots afterward.
2. Roll the metadata back to the post-drop state (snapshot 492):
   unregister every table-9/10 file with `begin_snapshot >= 493`
   (`end_snapshot = begin_snapshot`, 6 junk outputs), and un-retire the 7
   healthy inputs the failed swaps had consumed (`end_snapshot = NULL`).
   All 7 objects were still in S3 (verified before the update).
3. Verify: engine scans and API queries return the exact post-drop
   values (v6: 9,599,370 rows; v7: 3,940,794), and the compaction error
   counter stays flat across two sweep intervals.

More T-310 material: the operator drop path must retire a fully-dropped
file outright (or record the replacement's true `record_count`), the
compactor must apply delete vectors when it rewrites, and a failed swap
must roll back its registered outputs.

The padded objects stay in place for GC after snapshot expiry. Do not
delete them by hand. The six junk merge outputs
(snapshots 493–498, `bench/otel_logs_v6/01M0912MKB*` and
`bench/otel_logs_v7/01M098JYKFH8J81YF6GEWAGT58.parquet`) are unregistered
and also wait for GC.

## The 2-row "gap" — resolved, no loss

The buffer commit counters sum to 7,330,430 and the table holds 7,330,428.
The 2 extra rows are the deploy's smoke test, not lost bench rows.

The evidence chain:

1. The cluster redeployed at ~01:45Z (every pod is the same age), which
   zeroed all counters.
2. The deploy verification (`verify.exs` in the deploy repo) inserts
   **2 rows into `smoke.events`**. api-2's edge counters held exactly 2
   insert calls and 3,064 accepted rows before any bench traffic: the
   3,062-row preflight plus that 2-row smoke insert. buffer-2 held exactly
   2 committed rows.
3. `smoke.events` holds 54 rows — 27 deploys × 2. Its `ts` column carries
   the fixture's hardcoded 2026-08-14 timestamps, which is why the rows
   look old.
4. `otel_logs_v8` holds 7,330,428 = exactly **2,394 bodies × 3,062 rows**
   (1 preflight + 659 warm-up + 1,734 measured requests). Zero NULL
   stamps, zero dedup, zero rejected rows.

The lesson for future counter accounting: `rows_committed` counts every
table on the node since process boot. Subtract a pre-bench baseline tick
per pod before comparing against one table's count — and the baseline must
come from a tick that actually sampled that pod, which the first tick does
not always do (buffer-1's first sample landed mid-warm-up).

## Open questions

- Storage pod memory headroom: three of three storage pods have now been
  OOMKilled within 24 h under bench load.

## Reading the metrics database

```sql
SELECT pod, metric, labels, max(value) - min(value)
FROM samples
WHERE metric LIKE 'smolquery_seal%'
GROUP BY pod, metric, labels;
```

Counters reset on a pod restart, so a `max - min` delta is wrong across a
crash — split the window at the reset, or read consecutive-tick
differences and drop the negative one.
