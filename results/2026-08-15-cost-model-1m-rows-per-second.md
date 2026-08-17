# What 1M rows/s would cost, 2026-08-15

A cost model for sustaining **1,000,000 rows/s** of ingest in `eu-central-1`,
extrapolated from the measured 127,111 rows/s in
[2026-08-15-remote-v2-baseline.md](2026-08-15-remote-v2-baseline.md).

**Roughly $139,000/month — and compute is 3% of it.** The bill is network and
storage. Two line items, neither of them servers, are 86% of the total.

| line | $/month | share |
|---|---|---|
| Cross-AZ data transfer | **90,600** | 65% |
| Network Load Balancer | **37,100** | 27% |
| S3 storage (first month) | 7,200 | 5% |
| EC2 compute | 4,100 | 3% |
| RDS catalog, EBS, S3 requests | ~450 | <1% |
| **Total** | **~139,400** | |

Read the two big lines as a design finding, not a quote. Both are avoidable,
and the levers section says how.

## Prices

All fetched from the AWS Pricing API for EU (Frankfurt) on 2026-08-15, except
the two marked *list*.

| item | price |
|---|---|
| m7i.large | $0.12075 /hr |
| m7i.xlarge | $0.24150 /hr |
| m7i.2xlarge | $0.48300 /hr |
| S3 Standard | $0.0245 /GB-mo first 50 TB, $0.0235 next 450 TB |
| NLB | $0.027 /hr + $0.006 /NLCU-hr |
| Cross-AZ transfer | $0.01 /GB each direction (*list*) |
| RDS db.m7g.xlarge | ~$0.35 /hr (*list*, unverified) |

## What the measurement gives us

At the 127,111 rows/s peak the cluster used **715% of a core**:

| tier | CPU | scaled ×7.87 to 1M |
|---|---|---|
| 3 buffers | 459% | 36.1 cores |
| 2 storage | 216% | 17.0 cores |
| 1 api | 40% | 3.1 cores |
| **total** | **715%** | **56.3 cores** |

Row size is **2,351 bytes** raw, measured from the body
(7,198,917 bytes / 3,062 rows). So 1M rows/s is **2.35 GB/s** of raw ingest.

## Compute — the small part

56.3 cores plus 30% headroom is ~73. Sized as tiers, with the buffer tier
spread wide enough for 24 partitions:

| tier | nodes | vCPU | $/hr |
|---|---|---|---|
| buffer | 10× m7i.xlarge | 40 | 2.415 |
| storage | 5× m7i.xlarge | 20 | 1.208 |
| api | 4× m7i.2xlarge | 32 | 1.932 |
| | | **92** | **5.55** |

**$4,055/month.** The api tier is sized by network, not CPU — it only needs
3 cores but has to move 2.35 GB/s in and the same out.

## Cross-AZ transfer — the biggest line, and the most avoidable

Three hops carry data, and only one of them is cheap.

| hop | volume | cross-AZ share | $/hr | $/month |
|---|---|---|---|---|
| client → api | 2.35 GB/s | **free if clients are outside AWS** | 0 | 0 |
| api → buffer | 2.35 GB/s raw | ~2/3 | 112.80 | **82,344** |
| buffer → replica | 235 MB/s compressed | ~2/3 | 11.28 | 8,234 |
| buffer/storage → S3 | 235 MB/s | same-region, free | 0 | 0 |
| | | | | **90,578** |

Two things make this shape:

**The api → buffer hop moves raw NDJSON.** The deployment runs
`ndjson_passthrough=true`, so the api forwards the body uncompressed. That hop
carries ten times what the replication hop carries.

**Replication is cheap, because it ships segments not rows.**
`Replicator.SegmentShipping` "ships the encoded segment bytes and the manifest
entry to its followers" — so replication factor 2 costs one compressed copy,
not one raw copy. Worth knowing: this was the single largest uncertainty in the
model, and it resolved in smolquery's favour.

The 2/3 factor is placement, not physics. The ring deals partitions by hash
with no AZ awareness, so with three AZs about two thirds of hops leave their
zone.

## NLB — $37,100/month to forward bytes

An NLCU covers **1 GB per hour** of processed bytes. At 2.35 GB/s that is
8,460 GB/hr, so 8,460 NLCUs:

    8,460 × $0.006 = $50.76/hr = $37,055/month

The load balancer would cost **9× the compute** it balances.

## S3 — depends entirely on compression, and our number is a lie

Measured on the sandbox: 138 objects totalling 132.5 MiB. Against the rows
sealed so far that is roughly **10 bytes/row**, a ~200× ratio.

**Do not plan with that.** The body is synthetic — 1,000 project IDs and
repeated categorical values — which parquet dictionary-encodes and zstd
compresses far better than real logs. This model assumes a realistic **10×**,
so 235 bytes/row and **235 MB/s** sealed.

- **20.3 TB/day**, 609 TB/month added
- First month, average ~305 TB stored: **$7,218**
- Thereafter roughly **$14,500/month** more, until retention caps it

S3 requests are negligible. At the 64 MiB `seal_max_bytes` default that is
~3.5 sealed files/s; even doubling for compaction rewrites it is under
$100/month.

## Confidence

This is one measured point extrapolated **7.9×**. Treat the shape as sound and
the magnitude as ±50%.

What would move it most, in order:

1. **Compression ratio.** Scales S3 storage and the replication hop directly. A
   real corpus at 5× rather than 10× doubles both.
2. **Whether scaling stays linear past 3 buffers.** We proved 1 → 3 partitions
   spread evenly. 24 is an extrapolation, and coordination, replication
   fan-out and catalog contention all grow with node count.
3. **AZ placement.** The 2/3 cross-AZ assumption is worth $90k/month on its own.

Unverified: the RDS instance class (db.t4g.medium will not survive this seal
rate, but the right size is a guess), and EBS sizing for buffer PVCs.

## The levers, in order of money

1. **Make api → buffer AZ-local.** The single biggest line at $82k/month, and
   it is a routing decision, not a physics limit. An AZ-aware ring — prefer a
   buffer in the caller's zone — removes most of it.
2. **Get the NLB out of the data path.** $37k/month to forward bytes.
   Client-side load balancing, or DNS to per-AZ endpoints, avoids per-GB
   processing entirely.
3. **Compress the api → buffer hop.** If AZ-local routing is not available,
   compressing the passthrough cuts that line ~10× on its own.
4. **Set retention.** S3 grows 609 TB/month unbounded otherwise.

Do 1 and 2 and the bill drops from ~$139k to **~$20k/month** for the same
throughput. That is the finding: at this scale smolquery's cost is dominated
by where its bytes travel, not by how hard it works.

## Prerequisites this assumes away

Two open items must land first, or 1M rows/s is not reachable at any price:

- **T-244** — bound segments per seal batch. At 127k rows/s the seal path
  livelocked with 10,400 unsealed files. PR #149 is up.
- **T-245** — bound ingest admission before the body is read. Four pods were
  OOMKilled at 128 VUs. More api replicas without this is the same failure in
  more places.
