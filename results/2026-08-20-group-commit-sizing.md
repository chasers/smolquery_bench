# 2026-08-20: sizing the group commit

Can the group-commit boundary reproduce what 20,000-row *requests* achieved?
Partly — and the calibration says which knob is actually in control, which is
not the one we changed.

**Read this first.** A GC loop ran against all three buffer pods throughout
(`:erlang.garbage_collect/1` every 20 s, ~70 ms per pass). That neutralises
T-330 so a memory failure could not masquerade as a batching failure. **These
numbers describe a cluster with T-330 fixed, not the current build.** Without
the loop, buffer RSS sat near 4,000 MB; with it, 464–1,366 MB across the whole
run.

Report: `results/loadgen-20260820T014911Z-cal-bigcommit.html`.
Metrics: `results/raw-loadgen/loadgen-20260820T014911Z-cal-bigcommit.metrics.sqlite3`.

## Why the Postgres model does not transfer

`commit_siblings` / `flush_idle_interval_ms` are modelled on Postgres's
`commit_delay` / `commit_siblings` (T-202). A Postgres group commit amortises
**one fsync** across concurrent transactions: the batched thing is WAL records
in a shared log, and nothing downstream ever processes "that batch" again.

A smolquery commit produces **a file** — a manifest entry, a replication round,
a seal that pulls it over HTTP and merges it, and eventually a compaction. The
per-commit cost is paid across the segment's whole lifetime.

So the objective differs. Postgres batches to cut **fsync count**; smolquery
must batch to cut **file count**, because file count decides whether sealing
keeps up, and when it does not the hot tier grows without bound and the tier
dies. That is the failure mode behind every collapse on 2026-08-19.

The 2026-08-20 1 VU result disproves the sibling heuristic directly: at 1 VU
there are no siblings, so the adaptive path chose the 5 ms window — and 1 VU
produced the largest commits and the only clean sustained hold measured. The
heuristic keys on the wrong variable.

## The change under test

Applied to the live StatefulSet with `kubectl set env`, bypassing the kustomize
overlay:

    SMOLQUERY_FLUSH_MAX_BYTES=48000000     # ~20,000 rows, the size that held
    SMOLQUERY_MAX_BUFFERED_BYTES=192000000 # ceiling above the new trigger
    SMOLQUERY_COMMIT_SIBLINGS=0            # disable the 5 ms idle window

`commit_siblings=0` matters as much as the byte cap: a window opening with
fewer than 5 in-flight inserts otherwise closes after **5 ms** and never gets a
chance to accumulate, however high the byte cap goes.

## Calibration: 2, 4, 8 VUs at 3,062 rows, 120 s each, on a clean v9

| VUs | rows/commit | commits/s | per node | seal:commit | rows/s | p50 |
|---|---|---|---|---|---|---|
| 2 | 3,411 | 1.6 | 0.5 | 1.28 | 5,473 | 1,113 ms |
| 4 | 5,298 | 2.3 | 0.8 | 1.12 | 10,878 | 1,124 ms |
| 8 | **8,174** | 3.0 | 1.0 | 1.08 | 21,133 | 1,158 ms |

Zero refusals and zero restarts at every step. `hotindex_seal_lag` oscillated
around zero throughout (+18, −45, −35, +130, +124, −35, −159, +90, −28, −122).

### Commits got 2.7x larger, and sealing kept pace

The baseline is **3,062 rows per commit**, not 850. With `flush_max_bytes` at
2 MB an arriving 7.2 MB insert exceeds the threshold on contact, so it flushes
whole: one insert, one commit. The 850-row figure is what the cap *would* give
if a payload could be split, and it cannot — an insert is atomic into the
accumulator.

At 8 VUs a commit is now **2.7 inserts**. `seal:commit` of 1.08 means sealing
retired slightly more segments than commits created, so the hot tier drew down
rather than grew — at every load tested.

For context, 8 VUs at 3,062 rows OOMed in ~110 seconds on 2026-08-19. It is now
healthy at 21,133 rows/s. **That comparison is confounded by the GC loop** and
should not be read as the batching change alone.

### The byte cap never bound. The interval did.

At 8 VUs a commit is 8,174 rows x 2,351 bytes = **19.2 MB**, against a 48 MB
cap. The cap was never reached at any load tested.

p50 latency was **1,113 / 1,124 / 1,158 ms** — pinned at `flush_interval_ms:
1000` regardless of load. Every window closed on the timer.

So raising `flush_max_bytes` from 2 MB to 48 MB did almost nothing on its own.
What produced the larger commits was `commit_siblings=0`, which stopped windows
closing after 5 ms and let them run to the 1 s timer. **`flush_interval_ms` is
the binding lever at every load we can reach on this cluster.**

### A prediction that was wrong, recorded

Before the run: 5,600 / 11,000 / 23,000 rows per commit at 2 / 4 / 8 VUs.
Measured: 3,411 / 5,298 / 8,174 — 1.6x to 2.8x too high at every point.

The model extrapolated arrival rate from the 16 VU soak and missed a feedback
loop. `commit_siblings=0` adds ~900 ms of latency, which in a closed loop
throttles each VU to under one request per second, so fewer inserts arrive to
batch, which keeps commits small. The batching change suppresses its own input.

## What this says about the control law

Sublinear scaling — commits grew 1.55x per doubling of load — means a fixed
byte target cannot reach a fixed commit size. Commit size is set by arrival
rate times the window, and the window is a constant.

The invariant worth governing is **commits per second per node**, not commit
size. Sealing absorbs some number of segments per second; commit size should
float to whatever keeps commits/s under it:

  * low volume — commits/s naturally low, no reason to wait, keep the latency
  * high volume — widen the window to hold commits/s down, size grows with it,
    bounded by `ack_budget_ms` (5,000)

That is self-tuning at both ends, which a fixed `flush_max_bytes` cannot be:
small kills high volume, large taxes low volume. Mechanically it is closer to a
minimum inter-commit interval per `TableBuffer` than to a byte threshold — still
`commit_delay` in spirit, but keyed on time since the last commit rather than on
sibling count.

The ceiling is not yet located. Sealing kept up at **0.6 commits/s per node**
(1 VU, 20,000-row inserts), kept up at **1.0** here, and did not at **11–15**
(8–16 VUs on the old settings). It is unlikely to be a constant: seal cost
scales as roughly `segments^1.21`, so larger commits are individually more
expensive to seal.

## The cost, which is real

`commit_siblings=0` charges every commit the full 1 s window. At 2 VUs that is
~1,113 ms p50 against ~229 ms on the old settings, for 1.1 inserts of batching.
A terrible trade at the low end, and exactly why the fix has to be adaptive
rather than a new constant.

## Follow-ups

| task | what |
|---|---|
| T-330 | `TableBuffer` heaps never fullswept — the GC loop stood in for this |
| T-331 | Group commit is tuned on Postgres's model; target commit rate, not bytes |
| T-333 | No commit size distribution, no bytes counter, no flush-trigger reason |

T-333 is the immediate blocker for doing this properly. Establishing "the timer
closed every window" needed a before/after latency comparison; a
`flush_trigger_total{reason}` counter would have said it outright.

## Next

1. Re-run 8 VUs **without** the GC loop, to separate the batching effect from
   the memory effect. Everything above is measured with T-330 stood down.
2. Sweep `flush_interval_ms` (1 s -> 3 s -> 5 s) rather than `flush_max_bytes`.
   It is the lever actually in control, and `ack_budget_ms` is 5,000.
3. Land T-333 first if possible, so the sweep reads the trigger reason directly.

## Cluster left as

The buffer StatefulSet still carries the `kubectl set env` overrides above.
They bypass the kustomize overlay, so the next deploy from smolquery-deploy
reverts them. Revert sooner with:

    kubectl set env statefulset/smolquery-buffer -n smolquery \
      SMOLQUERY_FLUSH_MAX_BYTES- SMOLQUERY_MAX_BUFFERED_BYTES- SMOLQUERY_COMMIT_SIBLINGS-
