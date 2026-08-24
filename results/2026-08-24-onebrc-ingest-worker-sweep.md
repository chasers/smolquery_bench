# 2026-08-24: the billion-row upload peaks at 64 workers, 10.0M rows/s — and every 429 costs a second request

**The curve bends at 32 workers and peaks at 64: 10,008,571 rows/s, 1,000,000,000
rows in 99.9 s.** 16 workers gave 8.90M rows/s; doubling to 32 added 9%, 48 added
3%, 64 added 1%. 96 and 128 workers are slower than 64 — 9.27M and 9.18M — because
the buffer tier sheds load. Every point landed exactly 1,000,000,000 rows,
`count(*)` matched `rows_accepted`, zero rows lost, zero pod restarts.

**Degradation starts at 32 workers, not 96.** The first 429s appear at 32 (45 of
them), and p50 latency has already doubled — 324 ms to 570 ms. From 32 on, extra
workers buy queueing, not rows.

**Every 429 poisons its keep-alive connection, so the client pays one wasted
8.9 MB upload per refusal.** 3,132 refusals across the sweep produced 3,074
`connection reset by peer` failures. The cause is in smolquery, not the client:
`insert_controller.ex:69` rebinds `conn` after the body is read, but the
`else` branch at `insert_controller.ex:82` sends the 429 on the *original*
`conn`, whose Bandit transport still says 8.9 MB of body is unread. Bandit
then "drains" the next request off the socket, hits its 8,000,000-byte read
cap, raises `Unable to read remaining data in request body`
(`bandit/http1/socket.ex:580`), and closes with unread bytes — an RST. At 128
workers that was 1,262 wasted uploads, 10.5 GiB sent for nothing.

## Setup

Same harness and data as [2026-08-22-one-billion-rows.md](2026-08-22-one-billion-rows.md),
ingest only, one full billion-row upload per worker count.

- Cluster: smolquery **0.16.0** (`c21ff8d`, image `sha256:72c3b36f`), rolled
  2026-08-23. The 2026-08-22 numbers were on `07f632e`; the delta is a UI
  clustering card (T-363). Tuning unchanged from 2026-08-21 — 3 write
  partitions, `STORAGE_MEMORY_LIMIT` 3584MiB, `seal_max_bytes` 24MiB, valve
  factor 1, `MAX_BUFFERED_BYTES` 192 MB, `INSERT_MAX_NDJSON_BYTES` 100 MB.
  Api-side admission (T-245) limit 805,306,368 bytes per pod, from the boot
  log. 3 api pods on m7i.large, 3 buffer and 3 storage on m7i.xlarge. All
  nine pods started 2026-08-23 13:50Z; zero restarts before, during or after.
- Tables: `bench.onebrc_v3_w16` … `_w128`, one per point, `onebrc_v1` schema,
  clustering `[station]`. Each holds exactly 1B rows.
- Data: `measurements.1000000000.txt`, seed 42, regenerated on a fresh
  c7i.2xlarge (`i-0d42ce3580b7ee680`) in 22 s. Same bytes as 2026-08-22.
- Upload: `tools/upload1brc`, ~200,000 rows (8.9 MB NDJSON) per request,
  round-robin across the three api pod IPs, `insertId` per batch. On a 429 the
  client sleeps `retry-after` capped at 2 s; on any other failure it backs
  off 1 s doubling to 8 s. 600 s deadline per point, never reached.
- Between points: wait for an empty hot tier, then `count(*)`.
- `mise run bench-onebrc-ingest` with `LABEL_SUFFIX=-w-sweep`, 17:12–17:31Z.

## The curve

| workers | wall | rows/s | sent MiB/s | requests | 429 | resets | p50 | p95 | p99 | max | client cores | drain |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 16 | 112.4 s | 8,896,787 | 354.6 | 4,928 | 0 | 0 | 324 ms | 602 | 762 | 1,198 | 0.79 | 40 s |
| 32 | 103.4 s | 9,674,025 | 392.6 | 5,018 | 45 | 45 | 570 ms | 1,178 | 1,448 | 2,062 | 0.86 | 27 s |
| 48 | 100.7 s | 9,931,741 | 429.0 | 5,340 | 207 | 205 | 813 ms | 1,418 | 1,650 | 2,208 | 0.89 | 65 s |
| **64** | **99.9 s** | **10,008,571** | 467.7 | 5,777 | 426 | 423 | 1,015 ms | 1,517 | 1,781 | 2,446 | 0.90 | 63 s |
| 96 | 107.9 s | 9,270,057 | 541.2 | 7,217 | 1,150 | 1,139 | 1,074 ms | 2,082 | 2,636 | 3,603 | 0.88 | 27 s |
| 128 | 108.9 s | 9,181,491 | 556.5 | 7,493 | 1,303 | 1,262 | 1,352 ms | 3,214 | 3,858 | 4,862 | 0.89 | 39 s |

Latencies are over accepted requests. "Sent MiB/s" counts every body the
client wrote, retries included; accepted bytes are 4,928 × 8.9 MB at every
point, so accepted throughput at 128 workers is ~366 MiB/s, not 556.
"Resets" are the client's status-0 failures; all 3,074 read
`connection reset by peer` in the uploader log. The client never passed 0.9
of the box's 8 cores, so no point is client-bound.

Read it as three regimes:

1. **16 → 32: the closed loop opens up.** 16 workers × 200k rows ÷ 324 ms
   ≈ 9.9M rows/s theoretical against 8.9M measured — still the client's
   loop. At 32 the cluster starts answering 429 and p50 doubles. That is the
   knee.
2. **32 → 64: flat.** +3%, then +1%, for 1.5× and 2× the concurrency. The
   extra requests wait in the buffer's queue and a growing share are refused.
3. **64 → 128: down.** Refusals go 426 → 1,303, p99 doubles, throughput drops
   8%. The buffer tier's CPU *falls* from 1.9–2.1 cores (48 workers) to
   1.4–1.6 (96, 128): it is spending its time refusing rather than committing.

## What refused, and what it cost

All 3,132 refusals were the buffer's own overload meter, not api-side
admission. `smolquery_buffer_admission_refused_rows_total` grew by 632M rows
over the sweep, all on the buffer pods — the `Load.admit/3` gate
(`buffer_service/load.ex:55-61`, PL-9), which refuses a batch when its
Little's-law wait estimate exceeds `ack_budget_ms`. The api-side counter
never moved: 43 requests × 8.9 MB per pod at 128 workers is 383 MB against
an 805 MB limit. Per point: 5.7M rows refused at 32 workers, 42M at 48,
79M at 64, 233M at 96, 252M at 128.

The refusals were not spread evenly: buffer-0 refused 278M rows, buffer-2
277M, **buffer-1 77M**. Same pods, same shape, same three write partitions.
Not explained here.

Each refusal then cost a second request. The chain, from the code:

1. `insert_controller.ex:68-70`: `with … {:ok, body, conn} <- read_ndjson(conn, max_bytes) …`
   reads the full body and rebinds `conn` — inside the `with`.
2. The buffer answers `{:error, {:overloaded, ms}}`; the `with` falls to
   `else`, where the rebinding is out of scope. `insert_controller.ex:82`
   calls `insert_error(conn, reason)` on the conn from before the read.
3. That conn's adapter transport carries `read_state: :headers_read` and
   `unread_content_length: 8.9 MB`. After the 429 is sent, Bandit's
   `pipeline.ex:190` calls `ensure_completed`, which tries to drain the
   "unread" body with the default 8,000,000-byte cap
   (`bandit/http1/socket.ex:246`).
4. The bytes it drains are the client's *next* request on that keep-alive
   connection — 8.9 MB — so 0.9 MB remain, `read_data` answers `{:more}`, and
   `socket.ex:580` raises `Unable to read remaining data in request body`.
   The api pods logged that line 3,074 times (901 / 1,117 / 1,056).
5. The socket closes with unread bytes, so the kernel sends RST. The client
   sees `read: connection reset by peer` on the request it had just written,
   retries it after a 1 s backoff on a fresh connection, and it succeeds.

The 200 path is unaffected: `respond(conn, result)` sits in the `do` block
and gets the rebound conn. The 413 branch at `insert_controller.ex:73` has
the same scoping flaw, but nothing reached it.

A local stub that answers 429 without reading the body and closes reproduces
the client-side signature exactly: one status-0 failure per 429, zero rows
lost, all batches eventually accepted.

## Pods

Averages over each upload window from `bench_pod_cpu_usec_total`; peak from
`bench_pod_memory_bytes` (cgroup `memory.current`, page cache included).

| workers | api cores / peak MB | buffer cores / peak MB | storage cores / peak MB |
|---|---|---|---|
| 16 | 0.70–0.90 / 670–852 | 1.35–1.39 / 1,533–1,624 | 0.98–1.03 / 1,962–2,208 |
| 32 | 0.75–1.03 / 913–1,017 | 1.38–1.49 / 2,598–2,738 | 1.03–1.05 / 2,493–2,796 |
| 48 | 1.07–1.26 / 1,007–1,114 | 1.87–2.06 / 3,654–3,813 | 1.39–1.57 / 2,840–3,120 |
| 64 | 1.09–1.31 / 1,127–1,233 | 1.87–1.90 / 4,233–4,294 | 1.33–1.42 / 3,216–3,588 |
| 96 | 0.99–1.22 / 1,220–1,728 | 1.37–1.59 / 4,247–4,282 | 0.98–1.08 / 3,920–4,288 |
| 128 | 1.08–1.41 / 1,647–2,267 | 1.40–1.61 / 4,242–4,288 | 1.06–1.18 / 4,245–4,406 |

Limits: api 3,221 MB, buffer 4,295 MB, storage 6,442 MB. **The buffer tier
sat at its cgroup limit from 64 workers on** — 4,233–4,294 MB against
4,294,967,296 — and nothing was killed. `memory.current` counts page cache,
which the kernel reclaims before it kills, so this is not proof of OOM
margin either way; it is the number to watch on the next build. The 4-vCPU
buffer nodes never passed 2.1 cores. The api pods never passed 1.4 of 2.

Sealing kept pace at every point: `smolquery_seal_segment_rows_total` grew
by 935M–974M inside each ~100 s upload window against 908M–1,000M committed,
and the hot tier emptied 27–65 s after the last insert. 4,800 segments sealed
per point in 75 attempts. Zero counter resets on any pod across the sweep.

## The repeat: one run at 48 workers

The "as fast as possible with few errors" pick, on a fresh box and a fresh
`bench.onebrc_v4`, 17:56Z: **1,000,000,000 rows in 100.7 s = 9,927,304
rows/s**, 431 MiB/s sent, 5,371 requests, 222 × 429, 221 resets, zero rows
lost, `count(*)` exact, hot tier empty 63 s after the last insert. p50 795
ms, p95 1,415, p99 1,663, max 2,349. Client 0.92 cores. Zero pod restarts.

That is the sweep's 48-worker point within 0.05% (9,931,741) with the same
refusal count to within 7%, so the curve repeats. Pods: api 1.07–1.46
cores / 1,018–1,183 MB, buffer 1.94–2.03 cores / 2,138–2,239 MB, storage
1.42–1.45 cores / 4,486–4,736 MB. Buffer memory was 2.2 GB here against
3.7 GB at the same point in the sweep — the sweep's earlier points had
left page cache behind. Refusals by pod: buffer-2 28M rows, buffer-0
9.9M, buffer-1 6.9M — uneven again, a different pod on top.

Report: [loadgen-20260824T175613Z-w48-1b.html](loadgen-20260824T175613Z-w48-1b.html)
— `results/raw-loadgen/loadgen-onebrc-w48-1b.{upload,onebrc}.json`.

## Caveats

- One run per point, on fresh tables, in one 19-minute session. The points
  are 100–112 s each — sustained over a billion rows, not 30-minute soaks.
- Two columns, 42 B per NDJSON row. Compare MiB/s with other shapes, not
  rows/s. Accepted bytes at the 64-worker peak are ~397 MiB/s, below the
  ~450–500 MiB/s where the otel and kv shapes topped out.
- The buffer `memory_bytes` figure includes page cache.
- `client_cores` is the uploader process only. The box also ran the SSM
  agent and the progress poller; both are negligible.

## Next

1. **Fix the `with`/`else` scope in `insert_controller.ex:68-83`** so the
   error branches send on the conn that has read the body — e.g. read the
   body before the `with`, or return the conn with the error. Then a 429
   costs the client one small response instead of a wasted 8.9 MB upload
   and a reconnect. Re-run 64 and 96 to see how much of the 96-worker drop
   was the wasted bandwidth.
2. Why buffer-1 refused a quarter of what buffer-0 and buffer-2 did.
3. A 64-worker point with `ONEBRC_ROWS_PER_REQUEST` at 100k and 400k: the
   bend may be per-request overhead, not bytes.

## References

- HTML report: [loadgen-20260824T171215Z-w-sweep.html](loadgen-20260824T171215Z-w-sweep.html)
  — `results/raw-loadgen/loadgen-onebrc-w-sweep-w{16,32,48,64,96,128}.{upload,onebrc}.json`,
  `results/raw-loadgen/loadgen-20260824T171215Z-w-sweep.metrics.sqlite3`.
- The scope bug: `~/Dev/supabase/smolquery/lib/smolquery_api/controllers/insert_controller.ex:68-83`
  (last touched `e83ea71`, 2026-08-19). The drain:
  `deps/bandit/lib/bandit/pipeline.ex:190`, `deps/bandit/lib/bandit/http1/socket.ex:246,577-582`
  (Bandit 1.12.5). The gate: `lib/smolquery/buffer_service/load.ex:55-61`,
  `lib/smolquery/buffer_service/endpoint.ex:308-353`. Api-side admission:
  `lib/smolquery_api/admission.ex`, `lib/smolquery_api/runtime.ex:130-150`.
- Harness: `ONEBRC_WORKERS` as a list, `ONEBRC_QUERIES`,
  `ONEBRC_UPLOAD_DEADLINE_S`, `client_cores` in `tools/upload1brc`,
  `mise run bench-onebrc-ingest`.
