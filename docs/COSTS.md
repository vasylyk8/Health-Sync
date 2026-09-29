# Running costs (measured, not guessed)

Measured with `firebase/functions/bench/bench.ts` on the real ingestion and query code (local machine, so network and Firestore latency are not included). Prices are Google Cloud list prices for europe-west1 as I understand them in Sept 2026. Treat totals as estimates and verify them against the billing console after launch.

## Workouts with raw data
500 workouts of 90 minutes each, 7.1 million raw points in total (heart rate every 5 s, GPS at 1 Hz with 8 columns, running power at 1 Hz, speed, distance, steps and energy).

| Metric | Smooth synthetic data | With sensor-like noise (100 workouts) |
|---|---|---|
| Upload per workout (gzipped) | 117 KB | 351 KB |
| Stored (Parquet) per workout | 111 KB | **309 KB** |
| 500 workouts stored | 54 MB | ~150 MB |
| Ingest per workout (compute) | 115 ms | 155 ms |
| Any tool answer (list, series, route, zones, splits, best efforts) | 70–120 ms | 40–70 ms |

Real workouts are shorter on average than the benchmark (45–60 min), and noise is the realistic case, so plan on **~150–300 KB per workout**: even 3,000 workouts is about 1 GB, which costs a few cents a month to store.

Daily context is one small row per day (a few KB per year).

## Ongoing cost for one active user (estimate)
| Item | Estimate |
|---|---|
| Storage (~200 MB) | ~$0.005 / month |
| Ingestion: a workout is ~8 object writes and ~10 Firestore operations, once | < $0.001 per workout |
| Daily-context uploads (a small batch on each sync) | ~$0.02 / month |
| AI queries (a few dozen a month, each 40–120 ms compute) | < $0.01 |
| **Total** | **well under $0.10 per user per month** |

The previous design sent ~7,000 small uploads a month per Apple Watch user (about $0.15/user); this design sends one upload per workout plus one small daily upload per sync, so it is cheaper per user even though each workout carries far more data.

Fixed costs: ~$0–20/month (no always-on instance unless cold starts prove a problem), plus weekly evals (~$1–5/month).

## Cost levers (not implemented yet)
1. Send the daily context less often (e.g. once every few hours) to cut the small uploads.
2. Keep raw route/series data only for the last N years (a retention setting), if storage ever matters.
