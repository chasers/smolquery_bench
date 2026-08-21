# Agent notes

Read `README.md` first. It is the source of truth. This file only lists the
traps that cost past sessions real time.

## Read the code before you conclude

This repo measures smolquery. It does not contain it. **Never name a mechanism
from counters alone** — metrics say what happened, the source says why.

Both checkouts are on this machine:

- `~/Dev/supabase/smolquery` — the server. Its `@moduledoc`s are unusually
  complete and explain the reasoning, not just the API. Read them first.
- `~/Dev/supabase/smolquery-deploy` — the manifests and the overlay that the
  sandbox actually runs.

Check the **deployed** value, not the default. A setting in `config/config.exs`
may be overridden in `config/runtime.exs`, in `overlay/sandbox/*.yaml`, or by an
env name in `secrets.env.json`. `config/runtime.exs:355` points the S3 store at
`StorageService` and `QueryService` only — reading `config.exs` alone would tell
you the buffer uses it too, and it does not.

Three conclusions from 2026-08-19 that the counters supported and the code
overturned:

- "The sealer takes a fixed 1,024-segment batch and fails on it." The number was
  right, the reading was wrong. It is `@claim_valve_factor 16`
  (`buffer_service/table_buffer.ex:174`) times `seal_max_files: 64`
  (`config/config.exs:108`) — the T-288 count valve, working as designed.
- "Sealing runs on the storage pods, so it cannot contend with the buffer." It
  does contend. The hot tier is `Segments.Store.Local` on the buffer's own
  volume and `Store.shared?/1` is `false`, so `BufferService.HotServer` serves
  every seal input to the storage pod's DuckDB over HTTP — from the same BEAM
  and the same disk that is committing.
- "The buffer StatefulSet has no data volume, so hot segments land on the
  container's writable layer." `deploy/base/buffer.yaml:103` carries a `data`
  volumeClaimTemplate mounted at `/data`, patched to 20 GiB gp3 in the sandbox
  overlay. (This one is still uncorrected in
  `results/2026-08-19-v8-soak-collapse.md`.)

Cite `file:line` in a write-up. It costs one line and lets the next session
re-check the claim instead of re-deriving it.

## Metrics

- `GET /metrics` authenticates with the **`x-smolquery-internal`** header
  (`SMOLQUERY_INTERNAL_SECRET` in the deploy repo's `secrets.env.json`). The
  tenant api key gets a 401.
- Since smolquery 0.12.0 (T-302) every node serves the route on port 4003.
  Counters are node-local ETS, so one pod's answer never includes another
  pod's counters — scrape every pod. The seal and compaction series live on
  the storage pods.
- Use `mise run metrics -- <seconds> <out.sqlite3>`, or a sweep's automatic
  `*.metrics.sqlite3`, to collect per-pod metrics. See
  "Pod metrics sampling" in the README.

## Run reports

- `mise run report-html -- results/raw-loadgen/<run>.metrics.sqlite3` writes
  `results/<run>.html`. Every sweep now does it automatically at the end.
- **Unlabelled metrics store `''`, not `'{}'`.** Key every series by the exact
  `(metric, labels)` pair the database holds. `smolquery_compactions_total` is
  `{result="ok"}`, but `smolquery_compaction_segments_replaced_total` carries no
  labels at all. Keying compaction on `''` reports "no compaction ran", which
  looks like a finding and is a bug.
- A counter that falls is a pod restart, never a negative delta. `max - min`
  across a crash is wrong.
- A restart **during a missed scrape** is still a restart. Collect reset marks
  before the gap filter, or the report shows zero restarts for a run that spent
  fifteen minutes in a crash loop.
- Per-operation ratios need a denominator floor (`MIN_OPS`, default 20). A pod
  that boots and dies inside one bucket otherwise reports a mean commit of
  fourteen seconds.
- Rates sum per-pod rates. A tier delta over a wall clock reads low whenever one
  pod misses a scrape.
- Sidecar JSON joins a run by `inserted_at` inside the sampling window, not by
  filename. Names drift between sweeps; timestamps do not.
- Edit `scripts/report/report.css` and `scripts/report/report.js`. The generator
  inlines them, so changes to the emitted HTML are lost on the next run.

## Tuning the deployed cluster

**Never set tuning values with `kubectl set env`.** An inline `env` entry beats
the `envFrom` Secret silently, so the cluster stops matching the repo and nobody
can tell what is live. That happened on 2026-08-20 and cost a run.

Every knob is managed in the deploy repo:

    ~/Dev/supabase/smolquery-deploy/smolquery-deploy/push-secrets.exs

It writes the `smolquery-env` Secret, which every pod reads through `envFrom`.
The tuning block holds `SMOLQUERY_FLUSH_MAX_BYTES`, `SMOLQUERY_COMMIT_SIBLINGS`,
`SMOLQUERY_FLUSH_IDLE_INTERVAL_MS`, `SMOLQUERY_MAX_BUFFERED_BYTES`,
`SMOLQUERY_STORAGE_MEMORY_LIMIT`, `SMOLQUERY_STORAGE_COMPACT_MEMORY_LIMIT`,
`SMOLQUERY_WRITE_PARTITIONS`, `SMOLQUERY_SPILL_DIR`,
`SMOLQUERY_MAX_TEMP_DIRECTORY_SIZE` and the engine memory limits.

To change a tuning value: edit `push-secrets.exs`, push it, roll the
StatefulSet, then **verify from the pod, not from the file**. The boot log is
the only honest answer:

    kubectl logs -n smolquery smolquery-buffer-0 --tail=300 | grep -o "buffer shape:.*"
    kubectl logs -n smolquery smolquery-storage-0 --tail=300 | grep -oE "[a-z]+ engine memory_limit=[^ ]*"

Check for stray inline overrides before trusting any measurement:

    kubectl get statefulset smolquery-buffer -n smolquery \
      -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'

Not every knob is reachable this way. `seal_max_files`, `seal_max_bytes` and
`@claim_valve_factor` (16, in `table_buffer.ex`) have no env override, so claim
size can only change in code — which matters, because the merge engine has to be
large enough for whatever a claim contains.

## Explain queries

- The query API supports explain. Pass `"explain"` in the body of
  `POST /v1/queries` or `POST /v1/jobs`, next to `"query"`:

      curl -s -X POST "$BASE/v1/queries" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"query": "SELECT count(*) FROM bench.otel_logs_v8", "explain": "plan"}'

- `"explain": "plan"` returns the plan text without a run.
  `"explain": "analyze"` runs the query and returns the plan with real
  timings. Any other value answers 400. The response has no rows — the
  plan text is in `job.explain`.
- Do not put `EXPLAIN` in the SQL text. The router rejects it with
  "Only SELECT statements can be serialized to json!".
- Judge pruning from the plan, never from `durationMs`. Every query pays
  a fixed ~1.3–4 s floor (engine start plus hot-tier manifest fetches),
  so a pruned query and a full scan can share a wall time. A pruned plan
  shows `EMPTY_RESULT`; the analyze header shows the engine's real
  `Total Time`.
- The job's `statistics` block reports the plan-time file inventory, not
  real reads. On a pruned query it claims every sealed file as scanned.
  Do not read `filesScanned` or `rowsScanned` as evidence.
- The pruning bench records all this per case: `engine_total_s` and
  `explain_analyze` in `*.prune.json`.

## Tables

- smolquery has no table delete and no `add_column`. A schema change, or a
  run that needs an empty table, gets a new `otel_logs_vN`. Duplicate
  `CREATE TABLE` with a different schema answers 409.
- New tables need three edits: both files in `schemas/`, the
  `default_clustering` clause in `scripts/bench.exs`, and the tables table
  in the README.

## Measurement traps

- Every published local number is OTP 29. Do not mix OTP 27 and OTP 29
  numbers in one table.
- The local smolquery server dies with SIGBUS in about a third of runs, and
  the crash looks like a flood of k6 refusals, not a crash. Check
  `/healthz` after every local run.
- Every remote number from before 2026-08-16 15:39 UTC is single-api-pod.
- Judge pruning by the `scan` cases, never the `count` cases.
- Loadgen sweep points from before 2026-08-19 are not independent: each
  point ingested while the previous point's seal drain still ran. The
  sweep now waits for an empty hot tier before each point. Read
  `drain_wait_s` in the point's `*.pods.json` to see the gate.
- **Almost every published rows/s figure is a 30-second burst.** A 30-minute
  soak at 16 VUs collapses the buffer tier in about three minutes. Never
  quote a burst number as a sustained rate.
- **One sustained number exists**, from 2026-08-20: **38,610 rows/s for 600 s**
  at 1 VU with **20,000 rows per insert**, zero restarts, zero 5xx, sealing at
  parity. It holds only at that batch size — 3,062-row inserts never let sealing
  keep up. Quote the batch size with the number or it means nothing. See
  `results/2026-08-20-batch-size-and-heap-garbage.md`.
- **The buffer tier OOMs on garbage, not live data.** ~98% of its memory is
  unreclaimed `TableBuffer` heap (`fullsweep_after: 65535`, `minor_gcs: 1`).
  A GC pass freed 2,394 MB in 70 ms. Do not read an RSS figure from before
  T-330 as a memory requirement.
- **About 80% of ingest request time has no counter behind it.** On the
  2026-08-19 soak an insert spent 795 ms in the api write phase while the buffer
  reported 163 ms of commit work, and
  `smolquery_buffer_wire_microseconds_total` had accumulated 876 **micro**seconds
  after 3,992 inserts. The wire counter is not carrying the transport. Do not
  read the write phase as buffer work.
- A job's top-level `statistics.rowsScanned` counts **sealed rows only**.
  It grows on its own while a hot tier drains, which looks like row
  duplication and is not. Read `hot` and `sealed` separately, and get a
  true total from `SELECT count(*)`.

## Workflow

- Plans live in `.plans/`, one file per effort, named
  `YYYY-MM-DD_NN_<slug>.md`. Keep the active plan current.
- The AWS runner needs `aws sso login --profile sandbox`.
- Update the README in the same change that alters anything it documents.
