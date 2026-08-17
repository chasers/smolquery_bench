# The mid-range dip is the flush trigger's dead band, 2026-08-17

smolquery's throughput against ClickHouse is U-shaped. It wins at 1 VU, falls to
about half of ClickHouse at 4–8 VU, then returns to parity at 64 VU. ClickHouse
shows no such shape, so the dip belongs to smolquery.

**The cause is the gap between the two flush triggers.** At 8 VU, cutting
`FLUSH_MAX_BYTES` from 48 MiB to 8 MiB raises throughput **68%**, from 123,219 to
207,405 rows/s.

## The mechanism

`Smolquery.BufferService.TableBuffer` closes an accumulation window on the first
of two triggers.

**A timer, set once.** `schedule/1` returns the state unchanged when a timer
already exists, so `flush_after/1` reads `in_flight_inserts` at the single
instant the window opens:

```elixir
defp schedule(%__MODULE__{timer: nil} = state) do
  timer = Process.send_after(self(), {:flush, tag}, flush_after(state))
  %{state | timer: {timer, tag}}
end

defp schedule(state), do: state

defp flush_after(state) do
  if state.in_flight_inserts < state.runtime.commit_siblings,
    do: state.runtime.flush_idle_interval_ms,
    else: state.runtime.flush_interval_ms
end
```

**A byte threshold,** checked on every insert in `handoff_when_full/1`, at
`flush_max_bytes`.

The two leave a band uncovered:

| load | what closes the window | cost |
|---|---|---|
| below ~5 VU | the 5 ms idle timer | one short window |
| **5 to ~32 VU** | **48 MiB only** | **wait for ~7 bodies to arrive** |
| above ~32 VU | 48 MiB, reached at once | none |

Below `commit_siblings` (5) a window closes after `flush_idle_interval_ms` (5 ms).
At or above it, the window gets `flush_interval_ms` (1000 ms), so in practice only
the 48 MiB threshold ends it — about 7 bodies at 6.87 MiB each.

That predicts a latency floor of `48 MiB / arrival rate`. At 8 VU the measured
rate is 38.5 req/s, so the floor is ~182 ms. Measured p50 is **163 ms**.

## Evidence

8 VU, 30 s measured, 10 s warm-up, cold table per arm, one run each.

| arm | rows/s | vs control | p50 ms | p95 ms | p99 ms |
|---|---|---|---|---|---|
| `ctl48`, the 48 MiB default | 123,219 | — | 166 | 335 | 361 |
| `fmb24`, 24 MiB | 191,102 | +55% | 120 | 180 | 200 |
| `fmb16`, 16 MiB | 163,643 | +33% | 114 | 233 | 295 |
| `fmb8`, 8 MiB | **207,405** | **+68%** | 115 | 177 | 207 |
| `sib16`, `COMMIT_SIBLINGS=16` | 167,647 | +36% | 154 | 212 | 316 |

The control reproduces the morning's dip — 123,219 against 117,949 rows/s, p50
166 against 163 ms — so the arms compare against a real reproduction.

**Both predictions hold.** Shrinking the byte trigger helps. Raising
`commit_siblings` above the VU count helps too, by restoring the 5 ms window at
the same load. The two knobs reach the same mechanism from opposite sides, which
is what makes the diagnosis a mechanism rather than a correlation.

At 8 VU this closes most of the gap to ClickHouse: 0.46 of its throughput at the
default, 0.80 at 8 MiB.

## Why the default is 48 MiB, and why lowering it is not the fix

The 2026-08-10 tuning chose it **at 64 VU**, where it was the best of six values.
At that load the threshold fills the moment it is set, so a larger batch is pure
gain.

The same A/B at 64 VU prices the trade-off:

| arm at 64 VU | rows/s | vs control | p50 ms | refused |
|---|---|---|---|---|
| `v64ctl48`, 48 MiB | **341,021** | — | 282 | 810 |
| `v64fmb8`, 8 MiB | 210,421 | **−38%** | 516 | 828 |

**8 MiB wins 68% at 8 VU and loses 38% at 64 VU.** The default is not
miscalibrated. One constant is serving two regimes, and it can only suit one.
Any fix has to make the trigger respond to load, not pick a better number.

The control also shows what the k6 byte-patch stamp bought at high VU: 341,021
rows/s against 290,753 for the same configuration this morning, +17%.

## What a fix looks like

The trigger is static; the arrival rate is not. Three options, for smolquery to
weigh:

- **Re-evaluate the timer** when `in_flight_inserts` falls below
  `commit_siblings`, rather than only when the window opens. The cheapest change,
  and it targets the dead band directly.
- **Scale the byte target to the observed arrival rate**, so the window closes on
  time rather than on a fixed size.
- **Add a deadline** independent of rows and bytes, so no caller waits longer
  than X for a window it did not fill.

## Caveats

- **Every number in this file is a 30 s run. Do not compare them with the 60 s
  runs elsewhere in this repo.** A 30 s window reads consistently high, because it
  captures more of the fast phase before refusals build. At 64 VU the same
  configuration measured 383,680 rows/s over 30 s and 327,068 over 60 s — a 17%
  gap from run length alone. The A/B arms compare with each other and with
  nothing else.
- One 30 s run per arm. That carries more variance than the ±3–4% of a 60 s run.
  `fmb16` landing below `fmb24` is out of order and shows it. Read the table as
  "every arm beats the control by 33–68%", not as a ranking.
- Measured on Erlang/OTP 29.0.2, which on 2026-08-17 measured 6.2% slower than
  OTP 27 at 1 VU. That affects every arm alike, so the comparison holds.
- The ClickHouse comparison uses this morning's 258,249 rows/s at 8 VU, measured
  with the slower k6 stamp. It is a reference point, not a matched control.
- These runs use the byte-patch k6 stamp landed the same day, so they do not
  compare with any run before 2026-08-17.

Raw JSON: `results/raw-dip/`.
