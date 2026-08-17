# SIGBUS crash evidence, 2026-08-17

The raw macOS `.ips` reports are **not in git** — they carry host paths, hardware
identifiers and a crash-reporter key, and `results/crashes-*/` is gitignored.
This file keeps the fields the analysis rests on.

macOS writes the reports to `~/Library/Logs/DiagnosticReports/`, then moves them
to the `Retired/` subdirectory and eventually deletes them. Collect them with:

```sh
find ~/Library/Logs/DiagnosticReports -name 'beam.smp-*.ips'
```

## The crash

BEAM JIT code reads 8 bytes starting **one byte before a heap buffer**.

```
LDUR X7, [X9, #-1]     ; load 8 bytes at (X9 - 1)
LSR  X7, X7, #8        ; shift off the low byte
```

`X9` holds a heap allocation's base address. The pair is the BEAM's idiom for an
unaligned multi-byte read, and it runs off the front of the buffer.

Every report agrees on four things:

- The faulting thread is `erts_sched_N` — a **normal** scheduler, never a dirty one.
- The ESR reads `(Data Abort) byte read Translation fault` — a read.
- `sp` is a healthy thread stack, far from the fault address. **Not a stack overflow.**
- The PC lies in JIT-allocated memory, in **no loaded image** — not `beam.smp`,
  not `adbc_nif.so`, not the DuckDB driver. **Not a DuckDB crash.**

## The eight crashes

`far + 1` is the exact start of a malloc region in 8 of 8.

| crash | thread | far | far+1 | next region | sp | far+1 == region start |
|---|---|---|---|---|---|---|
| 2026-08-17-090238 | `erts_sched_3` | `0xb9fffffff` | `0xba0000000` | `0xba0000000` (MALLOC_SMALL) | `0x16b98edc0` | yes |
| 2026-08-17-095118 | `erts_sched_2` | `0x79e3fffff` | `0x79e400000` | `0x79e400000` (MALLOC_SMALL) | `0x16bbb6dc0` | yes |
| 2026-08-17-100302 | `erts_sched_2` | `0xb6f7fffff` | `0xb6f800000` | `0xb6f800000` (MALLOC_SMALL) | `0x16fc2edc0` | yes |
| 2026-08-17-103427 | `erts_sched_1` | `0xa79bfffff` | `0xa79c00000` | `0xa79c00000` (MALLOC_SMALL) | `0x16b6b6dc0` | yes |
| 2026-08-17-104037 | `erts_sched_3` | `0xad8bfffff` | `0xad8c00000` | `0xad8c00000` (MALLOC_SMALL) | `0x1701dedc0` | yes |
| 2026-08-17-104441 | `erts_sched_1` | `0x8dbbfffff` | `0x8dbc00000` | `0x8dbc00000` (MALLOC_SMALL) | `0x16bd1edc0` | yes |
| 2026-08-17-104652 | `erts_sched_3` | `0xc86ffffff` | `0xc87000000` | `0xc87000000` (MALLOC_SMALL) | `0x16d8fadc0` | yes |
| 2026-08-17-113957 | `erts_sched_10` | `0x6397fffff` | `0x639800000` | `0x639800000` (MALLOC_SMALL) | `0x16c65edc0` | yes |

## Why it is intermittent

The read is **always** out of bounds. It only faults when the allocator places
the buffer at the very start of a VM region, so the preceding page is unmapped.
Every other run performs the same read and silently gets adjacent heap.

**A 33% crash rate is a 100% bug rate with a 33% chance of hitting unmapped
memory.** Treat this as memory safety, not flakiness.

## Environment

Erlang/OTP 29.0.2, Elixir 1.20.2, macOS 26.6.1 on an Apple M1 Max. smolquery
`072a26a`, local `mix run --no-halt` dev build.

Fourteen reports from 2026-08-10 carry the same signature, so the bug predates
every change made on 2026-08-17.

Tracked as T-286.
