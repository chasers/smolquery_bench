# PR #124, adaptive group commit: quick bench, 2026-08-11

[PR #124](https://github.com/chasers/smolquery/pull/124) closes an accumulation
window after `flush_idle_interval_ms` (5) instead of `flush_interval_ms` (1000)
when fewer than `commit_siblings` (5) inserts are in flight. **It removes the
low-VU ack-cadence floor: 18× the throughput at 1 VU, at 5% of the p50.**

Config A/B on one build, at `c51af98` on `adaptive-group-commit`. The `sib0` arm
sets `COMMIT_SIBLINGS=0`, which holds the adaptive wait off and reproduces the
old behavior. The `sib5` arm runs the PR defaults. Per run: cold table, 10 s
warm-up, 15 s pause, 30 s measured, same 3,062-row body, pool and encode 10/10,
`FLUSH_MAX_BYTES=48MiB`. ClickHouse ran `FSYNC=1` at the same VU levels.

## Results

12 runs, 0 refused, 0 crashes.

| run | rows/s | p50 ms | p95 ms | p99 ms | server cpu avg % | server rss peak MB |
|---|---|---|---|---|---|---|
| smolquery 1 VU, sib0 | 2,888 | 1,057 | 1,090 | 1,113 | 3 | 399 |
| smolquery 1 VU, **sib5** | **52,593** | **56** | 70 | 82 | 117 | 2,889 |
| smolquery 4 VU, sib0 | 10,878 | 1,120 | 1,152 | 1,203 | 8 | 604 |
| smolquery 4 VU, **sib5** | **106,610** | **113** | 130 | 170 | 127 | 3,584 |
| smolquery 8 VU, sib0 | 131,012 | 178 | 231 | 286 | 137 | 3,847 |
| smolquery 8 VU, sib5 | 135,206 | 177 | 216 | 279 | 145 | 3,582 |
| smolquery 64 VU, sib0 | 507,850 | 317 | 697 | 897 | 426 | 5,102 |
| smolquery 64 VU, sib5 | 551,637 | 302 | 697 | 826 | 438 | 5,121 |
| clickhouse 1 VU | 37,233 | 81 | 90 | 103 | 76 | 1,484 |
| clickhouse 4 VU | 249,557 | 46 | 63 | 87 | 371 | 2,643 |
| clickhouse 8 VU | 327,966 | 68 | 111 | 147 | 515 | 3,776 |
| clickhouse 64 VU | 446,944 | 413 | 704 | 864 | 586 | 9,234 |

The `sib0` rows track the published baseline within 2% at 1, 4 and 8 VU, so the
toggle is a fair stand-in for the old path.

## Findings

**The floor is gone below the sibling threshold.** 1 VU goes 2,888 → 52,593
rows/s (18.2×) and p50 goes 1,057 → 56 ms. 4 VU goes 10,878 → 106,610 (9.8×) and
p50 1,120 → 113 ms. Both levels previously waited out the 1,000 ms interval on
every request, exactly as the baseline predicted.

**No regression above the threshold.** 8 VU moves +3.2% (131,012 → 135,206),
inside the ±3–4% variance band, with p50 and p99 flat.

**64 VU gained 8.6%** (507,850 → 551,637, p99 897 → 826 ms), which sits above the
variance band. A window can still open with fewer than 5 inserts in flight under
heavy load, right after a flush drains the buffer, so the shorter wait plausibly
helps there too. **One run each — repeat before you claim this.**

**smolquery now leads ClickHouse at 1 VU**, 52,593 against 37,233 rows/s (+41%),
at a better p50 (56 ms against 81 ms). The baseline had ClickHouse 13× ahead
there. ClickHouse still leads mid-range by about 2.3–2.4× (4 and 8 VU), and
smolquery leads at 64 VU by 23%.

**The cost is CPU and memory at low VU**, which is the price of the extra work:
1 VU goes from 3% to 117% average CPU and from 399 MB to 2,889 MB peak RSS. At
8 and 64 VU both are flat.

## Caveats

- One 30 s run per configuration. Variance is ±3–4%, so read the 8 VU row as flat.
- A config A/B, not a branch A/B. It measures `commit_siblings`, not the whole diff.
- Background load was ~136% of 1000% (VS Code, Dropbox, WindowServer), noisier
  than the quiet machine of the 2026-08-10 baseline. It affects both arms alike.
- Durability is unchanged: both arms fsync before a 200, with the macOS
  `fsync(2)` caveat from the baseline.

Raw JSON: `results/raw-pr124/`. Regenerate the table with
`RESULTS=$PWD/results/raw-pr124 scripts/report.exs`.
