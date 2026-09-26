# Running costs (measured, not guessed)

Measured with `firebase/functions/bench/` on the real ingestion and query code. Prices are Google Cloud list prices for europe-west1 as I understand them in Sept 2026. Treat the totals as estimates and verify them against the billing console after launch.

## Heavy user: 7 years of Apple Watch history
| Metric | Measured |
|---|---|
| Records (heart rate every 5 min + hourly steps + stats) | 858,480 |
| One-time upload | 23.8 MB gzipped |
| Stored (Parquet) | **23 MB per user** (real Watch data with workout heart rate is likely 2–3× this) |
| One-time ingestion compute | ~23 s |
| "Monthly heart-rate average over 7 years" | 2.2 s |
| "Weekly steps over 7 years" (merged totals) | 0.4 s |
| Peak memory | 260 MB |

## Ongoing cost per active Apple Watch user per month (estimate)
Background sync sends roughly 10 small uploads per hour while the user is awake (one per changed data type), which is about **7,000 small uploads a month**.

| Item | Estimate |
|---|---|
| Storage (~50 MB) | ~$0.001 |
| Ingestion compute (~0.4 s billed each, 4 per instance) | ~$0.02 |
| Firestore reads/writes (~6 per upload) | ~$0.05 |
| Cloud Storage operations (~3 per upload) | ~$0.07 |
| AI queries (a few dozen per month) | < $0.01 |
| **Total** | **≈ $0.15 per active user per month** |

Fixed costs: ~$0–20/month (no always-on instance unless cold starts prove a problem), plus weekly evals (~$1–5/month).

**What this means:** the $100/month budget covers roughly **500–600 active Apple Watch users**. iPhone-only users cost a fraction of that.

## Cost levers (not implemented yet; pick when needed)
1. **Sync less often in the background** (e.g. every 3 hours instead of hourly): cuts ongoing cost ~3×, and data stays within "a few hours" fresh.
2. **Combine all changed types into one upload per sync**: removes most per-upload Storage/Firestore overhead, ~2–3× cheaper. Needs a data-format version bump.
3. Buffer tiny updates and write Parquet less often: the most savings, and the most complex.
