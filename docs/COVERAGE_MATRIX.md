# What KROK reads from Apple Health

The machine-readable source is **`shared/coverage.json`**. It's bundled into the iOS app and imported by the server, so both sides always agree. Read-only: nothing is written to HealthKit.

## Workouts (everything Apple attaches)
| What | How the phone reads it |
|---|---|
| Summary: activity, start/end, duration, active energy, distance, average/max heart rate, source and device | `HKAnchoredObjectQuery` on `HKWorkoutType` (history + change capture + deletions) |
| Apple's statistics for every quantity recorded during the workout | `HKWorkout.allStatistics` |
| Metadata (weather, indoor/outdoor, elevation ascended, …) | `HKWorkout.metadata` |
| Events (pause/resume/lap/segment) and sub-activities (multi-sport) | `workoutEvents`, `workoutActivities` |
| **Raw streams**: heart rate, active energy, distance (walking/running, cycling, swimming, rowing, paddling, skating, skiing…), steps, running speed/power/stride/ground contact/vertical oscillation, cycling power/speed/cadence, swimming strokes, effort scores, SpO2, respiratory rate, audio exposure (`workoutQuantityTypes`) | `HKSampleQuery` for samples associated with the workout; series samples expanded with `HKQuantitySeriesSampleQuery` (every reading) |
| **GPS route** | `HKWorkoutRouteQuery` (lat, lon, altitude, speed, course, accuracy) |

## Daily context (one row per local day)
Recovery and readiness, sleep by night, activity and load, fitness trends, body measurements, nutrition and hydration, mindfulness and mood, menstrual-cycle context: see DATA_CONTRACT.md §2 for every key. Quantities use `HKStatisticsCollectionQuery` with day buckets (sum, average, min, max or latest); sleep, rings, categories and mood use their own queries.

## Not read (by decision)
- Everything else in Apple Health: the other ~170 types the previous version synced (blood pressure, glucose, ECG, heartbeat series, audiograms, symptoms, medications, clinical records…) are no longer requested.
- Sexual activity, contraceptive, pregnancy, lactation and related cycle data: not needed for workout analysis.
- Profile (date of birth, sex, blood type…): not read; ask the user for their maximum heart rate or zone boundaries instead.

## Rules
- **Unavailable ≠ zero.** A metric with no data is omitted from the row; a workout without a route or heart rate simply has no such stream. Tools list which streams exist.
- **Read denials** are invisible to apps. If the user denies a type, it reads as empty.
- **Types missing on the running iOS version** are skipped, so newer types start syncing on newer phones without code changes.
- **Units** are set in `shared/coverage.json` and verified with `isCompatible` at runtime.
