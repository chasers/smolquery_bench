# smolquery_bench

Ingest benchmark: [smolquery](https://github.com/chasers/smolquery) against
ClickHouse, as fairly as possible, following
[abc3/load-rig](https://github.com/abc3/load-rig). Both arms get the **identical
NDJSON body** — 3,062 OpenTelemetry log rows × 63 columns, 6.87 MiB — smolquery
via `POST …/insert` (`application/x-ndjson`), ClickHouse via
`INSERT … FORMAT JSONEachRow`.

## Prerequisites

macOS with k6 and ClickHouse (`brew install k6 clickhouse`), Go, Elixir 1.20 or
later, and a smolquery checkout with compiled deps (`SMOLQUERY_DIR`, default
`~/Dev/supabase/smolquery`).

**Every result in this repo was measured on Erlang/OTP 29.** On 2026-08-17 OTP
27.3.4.6 measured **6.2% faster** at 1 VU, with non-overlapping ranges, and it
did not hit the SIGBUS crash in six runs. **The next real local bench should move
to OTP 27 — but the switch has not been made**, because it needs its own
re-baseline rather than a quiet change mid-investigation. Never mix OTP 27 and
OTP 29 numbers in one table, and say which OTP produced a published figure. See
[results/2026-08-17-otp-27-vs-29.md](results/2026-08-17-otp-27-vs-29.md).

## Quick start

```sh
scripts/gen-bodies.exs               # bodies/eachrow.3062.ndjson, seed 42

scripts/setup-smolquery.exs          # cold data dir, server, dataset, table, clustering
scripts/run-arm.exs smolquery        # preflight, 20s warm-up, 15s pause, 60s measured

scripts/setup-clickhouse.exs         # cold path, server, table, fsync settings
scripts/run-arm.exs clickhouse

scripts/report.exs                   # markdown table from results/raw/
scripts/stop.exs                     # stops both servers

scripts/sweep.exs smolquery          # full VU sweep, VUS_LIST="1 4 8 16 32 64"
scripts/sweep.exs clickhouse         # cold table before each run
```

Against a deployed cluster, use the `remote` arm:

```sh
scripts/setup-remote.exs             # health check, dataset, table, clustering
scripts/run-arm.exs remote           # one run against BASE_URL
scripts/sweep.exs remote             # VU sweep

scripts/watch-pods.exs 30 pods.json  # pod CPU and RSS on its own
```

## Commands

`mise.toml` wraps every workflow. Run `mise tasks` for the list.

```sh
mise run bodies                      # regenerate the deterministic body
mise run remote-setup                # dataset + table on the deployed cluster
mise run remote-sweep                # sweep from this machine
mise run report                      # markdown table (RESULTS=... to pick a dir)
```

The in-region load generator, which removes this machine's uplink from the
measurement:

```sh
mise run bench-up                    # launch, install k6 + Go, push harness, build body
mise run bench-status                # instance, SSM ping, api pod it targets
mise run bench-sweep                 # run the selected benches (BENCHES=..., default ingest)
mise run bench-report                # table for results/raw-loadgen/
mise run bench-down                  # terminate
```

### Bench types

`BENCHES` selects what a sweep runs. It takes one type or several, separated by
commas. An unknown or empty value fails before anything starts.

```sh
mise run bench-ingest                # BENCHES=ingest
mise run bench-pruning               # BENCHES=pruning
mise run bench-compaction            # BENCHES=compaction
mise run bench-all                   # BENCHES=ingest,pruning,compaction
BENCHES=ingest,pruning mise run bench-sweep
```

| type | measures | writes |
|---|---|---|
| `ingest` | the VU sweep: rows/s, latency, refusals, pod CPU and memory | `<label>.k6.json`, `<label>.pods.json` |
| `pruning` | a `count` and a `scan` query against a live date, an empty date, and no filter | `<label>.prune.json` |
| `compaction` | compaction outcomes and pod restarts over a long window | `<label>.compact.json` |

The types always run in the order ingest, pruning, compaction, whatever order
you type them in. Pruning reads the rows ingest writes, and compaction needs
those rows sealed.

**Read the `scan` cases, not the `count` ones, to judge pruning.** `count(*)`
is answered from Parquet footer statistics without touching row data, so it
costs about the same whether pruning works or not. `sum(PRUNE_COLUMN)` forces a
column read, which is what makes a pruned query visibly cheaper. On 2026-08-16
the same table answered the empty-date `count` 9% faster than the control and
the empty-date `scan` **180x** faster.

`bench-up` and friends need a live SSO session:
`aws sso login --profile sandbox`.

## Knobs

- **Load**: `VUS`, `DURATION_S`, `WARMUP_S`, `ROWS`, `SEED`; `MODE=rate RATE=30`
  for an open loop.
- **Load spread**: the sweep resolves every ready endpoint of the
  `smolquery-api` Service and gives k6 the whole list. Each VU keeps one pod, so
  VUs spread across the api tier and connections stay alive. `API_POD` pins a
  run to a single pod — that was the accidental behavior of every sweep before
  2026-08-16, and it left extra api pods idle. The load generator cannot use the
  Service ClusterIP: it sits outside the cluster, and kube-proxy only balances
  from inside.
- **Bench selection**: `BENCHES` (default `ingest`). Pruning takes
  `PRUNE_DATES` (comma-separated `YYYY-MM-DD`, default today), `PRUNE_REPEATS`
  (default 3), `PRUNE_SETTLE_S` (default 30), `PRUNE_COLUMN` (default
  `duration_ms`) and `PRUNE_TIMEOUT_MS` (default 180000). Compaction takes
  `COMPACT_WATCH_S` (default 900).
- **Body dates**: `BASE_DATE=YYYY-MM-DD` backdates the `timestamp` column.
  Unset, the body carries the date of the run that generates it. Use it to put
  rows in more than one date partition.
- **smolquery**: `FLUSH_MAX_BYTES`, `FLUSH_INTERVAL_MS`, `WRITE_POOL_SIZE`,
  `ENCODE_CONCURRENCY`, `WRITE_ENGINE_THREADS` (DuckDB threads per pool member;
  unset means they divide across the pool), plus `COMMIT_SIBLINGS` and
  `FLUSH_IDLE_INTERVAL_MS` on builds that carry the adaptive group-commit wait.
  `SEAL_ROW_GROUP_SIZE` sets `ROW_GROUP_SIZE` on every sealed Parquet write.
  Builds from 0.11.0 default it to 1,048,576 rows, up from 16,384. DuckDB holds
  a whole row group in memory, so a large value can exhaust the writer's 2 GB
  `memory_limit` and fail the seal.
- **ClickHouse durability**: `FSYNC=0`. Servers log to `/tmp/sqbench/`.
- **The SIGBUS crash**: the server dies in about a third of local runs, at any VU
  count. No knob avoids it. Check the server is alive after every run — see
  [The SIGBUS crash](#the-sigbus-crash).
- **remote arm**: `BASE_URL` (default the eu-central-1 sandbox, port **8443** —
  port 443 is the web UI), `DATASET` (default `bench`), `TABLE` (default
  `otel_logs_v3`), `CLUSTERING`, `SCHEMA_FILE`, and `API_KEY`. With `API_KEY` unset it reads
  `SMOLQUERY_API_KEY` from `SECRETS_FILE`; `mise.toml` points that at the
  deploy repo's `secrets.env.json`. `TABLE` is authoritative: setup overrides
  the schema file's `id` with it. Pod sampling takes `KUBECONFIG` (required,
  set by `mise.toml`), `KUBE_CONTEXT`, `K8S_NAMESPACE` and `POD_SELECTOR`.
- **Run naming**: `LABEL_SUFFIX` tags a run, and `RESULTS` sends its JSON to
  another directory. Use both to keep an A/B out of the baseline raw files.
  Local arms default to `results/raw`; the remote arm defaults to
  `results/raw-remote`, so one remote run cannot flip the shared report into
  the remote table format.

## The SIGBUS crash

The smolquery server dies with `SIGBUS` / `KERN_PROTECTION_FAILURE` under
ordinary ingest. **There is no known workaround.** Roughly a third of runs at
1 VU die; 64 VU dies too.

**It is an out-of-bounds read, not a stack overflow, and not DuckDB.** All eight
crash reports from 2026-08-17 agree:

- The faulting thread is `erts_sched_N`, a **normal** scheduler.
- The ESR reads `(Data Abort) byte read` — a read.
- `sp` is a healthy thread stack, nowhere near the fault address.
- `far + 1` is the **exact start of a MALLOC region**, in 8 of 8.
- The PC lies in JIT-allocated memory, in **no loaded image** — not `beam.smp`,
  not `adbc_nif.so`, not the DuckDB driver.
- The instruction is `LDUR X7, [X9, #-1]`, then `LSR X7, X7, #8`.

BEAM JIT code reads the 8 bytes starting one byte before a heap buffer.

**The read is always out of bounds.** It only faults when the allocator places
the buffer at the very start of a VM region, leaving the previous page unmapped.
Every other run performs the same read and silently gets adjacent heap. A 33%
crash rate is not a 33% bug rate.

An earlier version of this section told you to set
`ERL_FLAGS="+sssdcpu 512 +sssdio 512"`. **That does nothing** — those flags size
*dirty* scheduler stacks, and every crash is on a normal scheduler. Do not use
it.

Tracked as T-286, which carries the full analysis.

**Know what a crash looks like**, because it does not look like a crash:

- k6 reports a flood of refusals. They are
  `dial tcp 127.0.0.1:4000: connect: connection refused`, not HTTP rejections.
- The tell is `data_sent_mib / requests`. A crashed run averages ~81 KB against a
  6.87 MiB body, because the failed requests never opened a connection.
- **The Elixir log shows nothing** — no error, no crash dump, no supervisor
  report. Diagnose from the macOS reports, and look in the `Retired/`
  subdirectory, where macOS moves them:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4000/healthz   # 000 when dead
find ~/Library/Logs/DiagnosticReports -name 'beam.smp-*.ips' | sort | tail
```

Do not use `pgrep -f 'mix run --no-halt'` to check liveness from a shell script —
the pattern matches the script's own command line. Use the health endpoint.

The extracted evidence is in
[results/2026-08-17-sigbus-evidence.md](results/2026-08-17-sigbus-evidence.md).
The raw `.ips` reports are gitignored — they carry host paths and hardware
identifiers. Fourteen reports from 2026-08-10 carry the same signature, so the
bug predates every change made on 2026-08-17. Tracked as T-286.

## Fairness rules (equal across arms)

- Identical bodies from one deterministic `gen-bodies.exs` run.
- Cold table each run: data dir erased, server restarted.
- One server at a time; k6 shares the machine, and the watcher reports its CPU.
- Durability parity: `async_insert` off (default) plus `fsync_after_insert = 1`
  and `fsync_part_directory = 1`, to match how smolquery fsyncs before a 200.
  `FSYNC=0` is the weaker page-cache-only arm.
- Same sort key on both: `(project_id, timestamp)`.
- Per run: preflight (fails on `insertErrors`), 20 s warm-up, 15 s pause, 60 s
  measured, 5 s stop.
- On a 429 (`buffer_full`) the VU sleeps out `retry-after`, up to 2 s.
  Percentiles cover accepted requests; refusals count separately.

## How to read the smolquery VU curve

Group commit acks on the first trigger: 48 MiB (`FLUSH_MAX_BYTES`) or the window
timer. `TableBuffer` sets that timer **once**, when the window opens, and reads
`in_flight_inserts` at that instant only. Below `COMMIT_SIBLINGS` (5) the window
gets `FLUSH_IDLE_INTERVAL_MS` (5 ms). At or above it, the window gets
`FLUSH_INTERVAL_MS` (1,000 ms), so in practice only the byte trigger ends it.

That leaves three regimes, and the middle one is a dead band:

| load | what closes the window | cost |
|---|---|---|
| below ~5 VU | the 5 ms idle timer | one short window |
| **5 to ~32 VU** | **48 MiB only** | **wait for ~7 bodies to arrive** |
| above ~32 VU | 48 MiB, reached at once | none |

**The mid range is where smolquery loses to ClickHouse**, at about 0.46 of its
throughput at 8 VU. Cutting `FLUSH_MAX_BYTES` to 8 MiB raises 8 VU by 68% and
lowers 64 VU by 38%, so the default is not a wrong number — it is one constant
across two regimes. See
[results/2026-08-17-mid-range-flush-dead-band.md](results/2026-08-17-mid-range-flush-dead-band.md).

On builds before the adaptive wait, below ~5 VUs a closed loop never reached the
byte trigger, so p50 sat near 1 s — **the configured durability cadence, not a
ceiling**.

## Known asymmetries (denoted, not hidden)

| Dimension | smolquery | ClickHouse |
|---|---|---|
| What a 200 means | Manifest fsynced, rows queryable | Part fsynced, with the settings above |
| Row validation | Deferred to the flush; a failed batch is salvaged row by row | Every JSONEachRow row parsed inline |
| Nullability | Every column nullable | Every column except the two ordering keys, since MergeTree keys cannot be nullable — load-rig declared only 4, which favors ClickHouse |
| Timestamp parsing | ISO 8601 without a zone suffix (`2026-08-01T10:00:00.000000`), the one format both default parsers accept; the `basic` parser rejects a trailing `Z` | Same body, default `date_time_input_format=basic` |
| Platform | BEAM release on macOS | Linux-tuned binary on macOS |
| Tuning applied | `FLUSH_MAX_BYTES=48MiB`, `WRITE_POOL_SIZE=10`, `ENCODE_CONCURRENCY=10` (schedulers online), `MAX_BUFFERED_BYTES=128MiB` | Table-level fsync settings only |
| Date partitioning (`otel_logs_v3`) | None. The catalog has no partition key, so a date query prunes only by segment min-max statistics | `PARTITION BY toDate(inserted_at)`, a real partition key |
| Query statistics | `durationMs` and `totalRows` only — no files-read or bytes-read counter, so pruning is timed, not counted | `system.query_log` exposes `SelectedParts` and `ReadBytes` |

## The remote arm

The `remote` arm drives an already-deployed cluster. This harness does not own
that server, so three rules change.

- **No cold table.** The router exposes no table delete, so every run appends
  to the same table.
- **No process watcher.** `tools/watch` reads `ps` on this machine, so it sees
  k6 only. `scripts/watch-pods.exs` supplies the server side: one
  `kubectl exec` per pod reads `/sys/fs/cgroup/cpu.stat` once a second, because
  the sandbox cluster runs no metrics-server. 100% means one core.
- **The client can be the bottleneck.** A 6.7 MiB body over a home uplink caps
  throughput well below the server. Read `MiB/s` in the report before you read
  `rows/s`.

## The load generator

`scripts/loadgen.exs` runs k6 inside `eu-central-1`, because a laptop measures
its own uplink. One instance in the cluster's VPC carries the **EKS cluster
security group**, which permits traffic from itself, so it posts straight to the
api pod IP over plain HTTP:

```
http://<api-pod-ip>:4000/v1/datasets/bench/tables/otel_logs_v2/insert
```

No Cloudflare, no NLB, no TLS, no internet hop, and no new security-group rule.

Access is SSM Session Manager — no public IP, no SSH key, no inbound rule. Code
goes up as an inline base64 tarball (~10 KB) rather than a `git clone`, so a run
always ships the working tree. Results come back the same way (~4 KB). Both sit
well inside SSM's limits, so this needs no S3 bucket. The api key moves through
SSM Parameter Store, not command text, because SSM keeps command history. Each
sweep starts with a stamped preflight insert — k6 discards response bodies, so
it cannot see per-row rejections — and clears the box's results directory, so
`fetch` stays under the inline output limit.

`k6` and `genbody` run on the box; the body is rebuilt there from seed 42, so it
is byte-identical without shipping 6.87 MiB. Pod sampling stays on this machine,
because it needs the kubeconfig.

Knobs: `LOADGEN_INSTANCE_TYPE` (default `c7i.2xlarge`), `LOADGEN_SUBNET`,
`VUS_LIST`, `DURATION_S`, `WARMUP_S`, `PAUSE_S`, `RESULTS`.

The instance is not Terraform-managed. It is found by tag
`Name=smolquery-bench-loadgen`, and `mise run bench-down` terminates it.

## Layout

```
tools/genbody/        deterministic 63-column OTel NDJSON generator
tools/watch/          CPU and RSS sampler, ps-based, for the server and k6
k6/insert.js          load script, closed loop (VUS) or open loop (RATE)
schemas/              smolquery table-create JSON, ClickHouse MergeTree DDL
scripts/              setup, run, sweep, stop, report, watch-pods, loadgen
mise.toml             every workflow as a task — `mise tasks`
results/raw/          k6 and watch JSON per run (gitignored)
results/raw-remote*/  the same, plus *.pods.json, for the remote arm
results/raw-loadgen/  the in-region load generator's runs
results/*.md          dated baseline writeups
```

Every result file carries `inserted_at`, an ISO 8601 UTC timestamp written when
the run finishes — `*.k6.json`, `*.watch.json` and `*.pods.json` alike. Files
that predate the field were backfilled from their modification time, which is
when the run wrote them.

## The `inserted_at` column

Every inserted row also carries `inserted_at`, the send time. `gen-bodies.exs`
writes a fixed-width placeholder, `____INSERTED_AT___________`, and whoever
posts the body substitutes the real time — `k6/insert.js` per request, and the
preflight in `scripts/bench.exs`. One value per request, shared by that
request's rows, because a batch lands at one instant.

The format is `2026-08-15T01:13:25.349000`: zone-less microseconds, matching
the other timestamp columns. **A trailing `Z` fails**, since smolquery's
`basic` parser and ClickHouse's `date_time_input_format=basic` both reject it.
The placeholder is exactly as wide as the timestamp, so body size stays
constant at 6.87 MiB.

### How k6 writes the stamp

`k6/insert.js` finds every placeholder offset once, at init, then writes the
26 bytes in place per request:

```js
for (let k = 0; k < stampOffsets.length; k++) bodyBytes.set(stampBytes, stampOffsets[k]);
```

It posts the same `ArrayBuffer` every time. Each VU runs the init context on its
own, so the buffer it patches is its own.

**Do not go back to a string rewrite.** Until 2026-08-17 the script ran
`rawBody.split(PLACEHOLDER).join(nowIso())`, which allocated a fresh 6.87 MiB
string per request per VU. At 64 VU that cost k6 134–158% CPU and 4.2–6.5 GB of
RSS, against 45–57% and ~1.9 GB unstamped. On a laptop that shares ten cores
with the server, it cut both arms by 37–39%. The byte patch writes ~80 KB
instead of 6.87 MiB and keeps the real per-request time.

**The stamp resolves to a millisecond, not a microsecond.** k6 exposes no
high-resolution clock — `performance` is undefined — so `nowIso()` reads
`Date.now()` and pads three zeros. Concurrent VUs that post inside the same
millisecond therefore share a value. The digits are real; the last three are
always zero.

Baselines from before this column carry no stamp at all. Do not compare them
with stamped runs at high VU counts.

Adding the column changed the schema, and smolquery answers 409 on a
`CREATE TABLE` whose schema differs from what exists — there is no
`add_column` route. Each schema change therefore gets a new table. The older
`bench.otel_logs` keeps its rows and has no `inserted_at`.

## The tables

| table | ClickHouse | smolquery | notes |
|---|---|---|---|
| `otel_logs` | `ORDER BY (project_id, timestamp)` | clustering `[project_id, timestamp]` | no `inserted_at` |
| `otel_logs_v2` | same | same | adds `inserted_at` |
| `otel_logs_v3` | **`PARTITION BY toDate(inserted_at)`**, `ORDER BY (project_id, timestamp)` | clustering `[project_id]` | the default |

`otel_logs_v3` is what `TABLE` defaults to. It exists to answer one question:
does a query for a single date read only that date's files?

**The two arms do not answer it the same way.** ClickHouse has a real partition
key, so it prunes whole partitions. smolquery has no partition key at all —
`lib/smolquery/catalog.ex` offers `retention` and `clustering` and nothing else
— so it prunes by segment min-max statistics, which works only while segments
stay date-contiguous. Never publish a pruning comparison that reads as
like-for-like. Say which mechanism produced each number.

`inserted_at` is non-nullable on the v3 ClickHouse DDL. A nullable partition key
collects NULLs in a partition of their own.

## Reference numbers

load-rig, on an M1 Pro with 10 cores and 16 GB: smolquery peaked at **383,157
rows/s** (32 VU, pool=4, enc=4), ClickHouse at **165,814 rows/s** with matching
fsync. Land in that range, and **investigate a large gap before you publish**.

Deployed sandbox cluster (3× m7i.xlarge plus a dedicated m7i.large for the api
pod, `SMOLQUERY_WRITE_PARTITIONS=3`, table `otel_logs_v2`): **22,579 rows/s**
at 16 VUs, flat to 64 VUs with zero refusals. Leave the partition count unset
and it defaults to 1, so one buffer pod owns the whole table and throughput
halves past 16 VUs. The laptop's uplink — a noisy 42–51 MiB/s — caps every
number past 8 VUs, so the cluster's real ceiling is still unknown; it never
exceeded 166% of its 1,370% CPU. Current baseline:
[results/2026-08-15-remote-v2-baseline.md](results/2026-08-15-remote-v2-baseline.md);
how we got there:
[results/2026-08-14-remote-sandbox.md](results/2026-08-14-remote-sandbox.md).

Driven from an in-region load generator instead, the same cluster reached
**127,111 rows/s**. What scaling that to 1M rows/s would cost is modelled in
[results/2026-08-15-cost-model-1m-rows-per-second.md](results/2026-08-15-cost-model-1m-rows-per-second.md).
A 2026-08-16 re-sweep OOMKilled a buffer pod instead of producing a baseline
(the T-245 admission bug). The same run failed 45% of its compaction attempts
against the 1 GiB pin budget:
[results/2026-08-16-loadgen-t245-oomkill.md](results/2026-08-16-loadgen-t245-oomkill.md).
The fixes for both (PR #166, #167, #169) then deployed. The next sweep reached
113k rows/s and killed three pods:
[results/2026-08-16-post245-sweep.md](results/2026-08-16-post245-sweep.md).
`otel_logs_v3` then landed, and its first sweep found that every run in this
repo's history had sent all its load to one api pod:
[results/2026-08-16-v3-first-sweep.md](results/2026-08-16-v3-first-sweep.md).
**Every number measured before 2026-08-16 15:39 UTC is single-api-pod.**

Latest local numbers, smolquery 0.11.0 on 2026-08-17: **44,016 rows/s at 1 VU**
against ClickHouse's 33,324, and a tie at 64 VU (290,753 against 290,385). Both
arms lost 37–39% at 64 VU against the 2026-08-10 baseline, because the
`inserted_at` stamp roughly tripled k6's own CPU. Read the 64 VU rows as a
measurement of the laptop:
[results/2026-08-17-local-rebench-0-11-0.md](results/2026-08-17-local-rebench-0-11-0.md).

The full local baseline:
[results/2026-08-10-baseline.md](results/2026-08-10-baseline.md). ClickHouse runs
well above its reference here, because fsync costs ~3% on this hardware against
54% on the reference setup. The low-VU floor above is what smolquery
[PR #124](https://github.com/chasers/smolquery/pull/124) removes — see
[results/2026-08-11-pr124-adaptive-group-commit.md](results/2026-08-11-pr124-adaptive-group-commit.md).
Builds from 0.11.0 ship `commit_siblings: 5` by default, so the floor is gone
without a flag.
