# 2026-08-20: the first sustained hold, and why every earlier one failed

Two results, and the second explains the first.

**A 10-minute hold held.** 1 VU at 20,000 rows per insert sustained 38,610
rows/s against a fresh `bench.otel_logs_v9` with zero restarts, zero 5xx, and
sealing at parity with ingest. Every previous attempt at sustained load on this
cluster collapsed inside three minutes.

**The buffer tier's memory is ~98% garbage.** One `:erlang.garbage_collect/1`
pass over a pod sitting at its 4 GiB ceiling took 70 ms and freed 2,394 MB.
`TableBuffer` heaps are never fullswept, so the high-water mark of every payload
stays resident until the cgroup kills the pod.

Reports: `results/loadgen-20260820T005916Z-v9-1vu-20k.html` (the hold) and
`results/loadgen-20260819T214029Z-post-t316-soak.html` (the 16 VU failure it is
measured against).

## The hold

| | |
|---|---|
| load | 1 VU, 20,000 rows per insert, 44.85 MiB per request |
| duration | 600 s measured, on a fresh table |
| rows/s | **38,610** |
| rows accepted | 23,180,000 |
| requests | 1,159, **0 refused** |
| p50 / p95 / p99 | 488 / 590 / 641 ms |
| max latency | 697 ms |
| data sent | 50.8 GiB |
| restarts | **0 across all nine pods** |

Nothing degraded across the window:

| bucket | rows/s | write ms | commit ms | 5xx | seal lag | buffer RSS |
|---|---|---|---|---|---|---|
| 01:03 | 38,947 | 387 | 295 | – | +88 | 3,552 |
| 01:05 | 38,333 | 386 | 295 | – | −47 | 3,999 |
| 01:07 | 38,596 | 390 | 302 | – | −8 | 4,030 |
| 01:09 | 38,246 | 398 | 308 | – | −12 | 4,092 |
| 01:11 | 38,644 | 389 | 299 | – | −1 | 3,924 |

Compare the 16 VU soak, where the write phase ran 220 → 795 ms before the tier
died.

### Why it held: sealing reached parity

`hotindex_seal_lag` — entries added to the hot manifest minus entries retired —
oscillated around zero all run: +88, −1, −47, −3, −8, −10, −12, +49, −1, −68.

Every earlier run had sealing at **4–69%** of the commit rate, so the hot tier
only ever grew. That backlog is what broke the tier in every failure recorded on
2026-08-19: it made each seal attempt more expensive, which slowed commits,
which OOMed the pod, which failed the seal, which grew the backlog.

One insert becomes one commit becomes one segment — measured at 109 inserts,
109 commits and ~114 sealed segments per minute. So 20,000-row inserts produce
**6.5x fewer files per row** than the 3,062-row bodies every earlier run used,
and that alone moved sealing from "never keeps up" to "keeps up".

### The reservation

Buffer RSS parked at **4,030–4,092 MB against the 4,096 MB limit** for the last
six minutes. Flat, not climbing, and it survived — but with no headroom at all.
That is a pass on the letter of "RSS flat or falling" and uncomfortable in
spirit. The next section says why, and why the fix should make it comfortable.

## The root cause: `TableBuffer` heaps are never fullswept

On a buffer pod at the ceiling under live ingest, one GC pass over 905
processes took **70 ms**:

    before: total=2716.7  processes=1892.1  binary=736.1   (MB)
    after:  total=322.7   processes=34.7    binary=202.6
    freed:  total=2394.0  processes=1857.4  binary=533.5
    biggest process: 687.9 MB -> 0.3 MB

The kernel agreed. cgroup `memory.current` on the collected pod fell to
2,274 MB while its two untouched peers, under identical load at the same
moment, stayed at 3,981 and 3,904 MB.

### It is the decoded rows, not the request bodies

Largest `TableBuffer` on an untouched pod:

| | |
|---|---|
| total_heap_size (heap terms) | **825.5 MB** |
| refc binaries held | 8,703 refs, 147.8 MB |
| live GenServer state (`:erts_debug.size`) | **0.0 MB** |
| message queue | 0 |

Raw NDJSON bodies are refc binaries — 147.8 MB there. The dominant 825.5 MB is
heap terms: the body decoded into Elixir maps. `ndjson_passthrough` is true, so
the api forwards raw bytes and the buffer decodes; 20,000 rows x 63 columns is an
enormous number of small terms on one process heap, all garbage the moment the
encode finishes.

### The proximate cause

    fullsweep_after: 65535    minor_gcs: 1

The OTP default, against a single minor GC. The old heap is fullswept only after
65,535 minor collections, so on a long-lived `TableBuffer` it never happens.

### What it explains

- Memory climbing with zero curvature — 8 VUs went 1,900 MB to the 4,096
  ceiling in 75 s with no plateau.
- Growth proportional to load.
- Pods OOMing during a drain with **no ingest at all** — recovery, claim
  healing and replication grow heaps the same way.
- Why raising the container limit only postpones it.

## The VU search that could not converge

The original question was which VU count is sustainable. It could not be
answered, and the reason is itself a finding.

| VUs | start backlog | result |
|---|---|---|
| 16 | 1 hot file | fail — OOM ~2.4 min |
| 8 | 26 hot files | **fail — OOM ~110 s, clean start** |
| 4 | **1,736 hot files** | invalid — contaminated start |

Starting backlogs ran 1 → 26 → 54 → 1,736. Each failed run left a backlog the
next one inherited, because the tier could not drain what a failure left behind.
Runs stopped being independent. `bench.otel_logs_v9` had to be created to get a
clean table at all.

The 8 VU result is solid on its own: clean baseline, RSS straight from ~1,900 MB
into the ceiling in 75 s, no plateau.

## Corrections

Three hypotheses this session raised and the evidence then killed. They are
recorded because each cost time and each looked convincing:

- **The write pool reserves 2 GB.** `write_pool_size × write_engine_memory_limit`
  is 4 × 512 MB, and cold idle RSS measured 1,855–2,281 MB, which matched almost
  exactly. It was coincidence: DuckDB's `memory_limit` is a cap, not a
  reservation, and idle RSS an hour later was 1,204–1,325 MB on two of three
  pods. The BEAM's own processes held the memory.
- **The hot manifest ETS is the memory hog.** It is 10.4 MB across 755 rows.
  Total ETS on a loaded pod is 13.2 MB.
- **The seal stall is a permanent deadlock.** It self-heals. On this cluster it
  took ~28 minutes and two partial-claim heals (61 entries, then 1) to clear
  3,674 files. A 45-second observation window was too short to see it, and
  concluding "stuck" from two samples was wrong.

## Filed

| task | priority | what |
|---|---|---|
| T-330 | urgent | `TableBuffer` heaps never fullswept — the root cause above |
| T-331 | high | Move the batching win into the group-commit boundary: commits close at ~850 rows, sealing needs ~20,000 |
| T-327 | high | A follower's stale claim stalls the seal pipeline for tens of minutes |
| T-328 | high | The query planner still fetches the whole hot manifest, with stats, per partition |

T-331 is the generalisation of this result. `flush_max_bytes: 2_000_000` at
2,351 bytes per row closes a group-commit window at **~850 rows** — about 23x
smaller than the commit that held here. An insert is atomic into the
accumulator, so a large request lands whole; that is the entire difference
between the request boundary and the group-commit boundary.

## Next

1. Land T-330, then re-measure. The same workload should sit near 1 GB rather
   than 4 GB, turning a marginal pass into a comfortable one.
2. Re-run the 2 / 3 / 4 VU ladder afterwards. Today it would only measure how
   fast garbage fills 4 GiB.
3. T-331, so ordinary small inserts get this win without 45 MiB request bodies.
