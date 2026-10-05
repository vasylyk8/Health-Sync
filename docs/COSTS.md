# Running costs (measured, not guessed)

Measured with `firebase/functions/bench/bench.ts` on the real ingestion and query code (local machine, so network and Firestore latency are not included). Prices are Google Cloud list prices for europe-west1 as I understand them in Sept 2026. Treat totals as estimates and verify them against the billing console after launch.

## Workouts with raw data
500 workouts of 90 minutes each, 7.1 million raw points in total (heart rate every 5 s, GPS at 1 Hz, running power at 1 Hz, speed, distance, steps and energy), with sensor-like noise (`NOISE=1`) and values rounded the way the app now rounds them before upload (`ROUND=1`: GPS 1 m, other values 4 decimals). The benchmark sends plain JSON; the app sends the compact integer-difference format, which is smaller still.

| Metric | Before (exact doubles, Parquet V1) | Now (scaled integers, Parquet V2 + zstd) |
|---|---|---|
| Upload per workout (gzipped, benchmark format) | 351 KB | 82 KB |
| Stored per workout | **309 KB** | **36 KB** |
| 500 workouts stored | ~150 MB | 17.5 MB |
| Ingest per workout (compute) | 155 ms | 130 ms |
| Any tool answer (list, series, route, zones, splits, best efforts) | 40–70 ms | 46–120 ms |

Stored size by stream (KB per workout): route 20.8, running power 5.9, running speed 2.8, distance 2.0, heart rate 1.9, steps 1.0, energy 1.0, summaries 0.4. (The benchmark still includes the energy stream the app no longer sends.)

The scaled-integer storage is the large saving: before it, the server stored every compact upload back as 64-bit doubles, which made the stored data several times larger than what was uploaded.

Real measurements from the owner's phone (3,337 workouts, upload size per the in-app speed test): 554 MB with the old format, 44 MB with compact chunks, and the planned further rounding, dropping of course/vertical accuracy and of the summary-only streams (active/basal energy, physical effort, exercise time, audio exposure) is estimated to bring this to about 22–28 MB. Re-run the speed test on the phone to confirm.

Routes are sent at one point per 5 s (about 35% of the previous route size, estimated 7–8 MB less over 3,337 workouts; confirm with the speed test row K).

## Other data (measured with the synthetic user, `bench/small-types.ts`)
| Data | Stored |
|---|---|
| Hourly heart rate (avg/min/max) and steps, one year | ~43 KB (about 20–25 KB per year uploaded in the compact format); 13 years ≈ 0.3–0.6 MB |
| Daily rows, one year (3 metrics in the test; the real rows have up to 87 keys) | ~32 KB test; real rows a few hundred KB per year at most |
| Nutrition entries | ~0.1 KB each |
Each monthly Parquet file costs about 2.7 KB of fixed overhead, which the 6-hourly compaction merges away.

## Ongoing cost for one active user (estimate)
| Item | Estimate |
|---|---|
| Storage (3,000 workouts ≈ 110 MB, plus a few MB of daily, hourly and event data) | ~$0.003 / month |
| Ingestion: a workout is ~8 object writes and ~10 Firestore operations, once | < $0.001 per workout |
| Daily-context uploads (a small batch on each sync) | ~$0.02 / month |
| AI queries (a few dozen a month, each 40–120 ms compute) | < $0.01 |
| Product analytics (hourly scan and ~90 aggregate writes, at launch volume) | Pennies per month; inspect before the 90-day access log grows past ~100,000 rows |
| **Total** | **well under $0.10 per user per month** |

The previous design sent ~7,000 small uploads a month per Apple Watch user (about $0.15/user); this design sends one upload per workout plus one small daily upload per sync, so it is cheaper per user even though each workout carries far more data.

Fixed costs: ~$0–20/month (no always-on instance unless cold starts prove a problem), plus weekly evals (~$1–5/month).

## Cost levers
1. Done: the daily context is sent only when its content changed and at most every 15 minutes; hourly series about once an hour.
2. Keep raw route/series data only for the last N years (a retention setting), if storage ever matters.
3. Launch analytics deliberately recomputes a bounded 90-day window hourly. Replace the scan with incremental daily counters before event volume makes its Firestore reads material; the MCP contract and rollup documents do not need to change.
