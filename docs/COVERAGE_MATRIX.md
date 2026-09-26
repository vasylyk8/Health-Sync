# HealthKit coverage matrix

The machine-readable source is **`shared/coverage.json`** (197 entries). It's bundled into the iOS app and imported by the server, so both sides always agree on types, units and aggregation.

The app creates each type from its identifier at runtime and **skips types that the running iOS version doesn't have**. No per-version code is needed, and newer types just start syncing on newer phones.

| Kind | Examples | How the phone reads it | Record | Background delivery |
|---|---|---|---|---|
| quantity, cumulative | steps, distances, energy, nutrition, exercise minutes | `HKAnchoredObjectQuery` (raw) + `HKStatisticsCollectionQuery` hourly, `.cumulativeSum` (merged totals) | `s` + `h` | yes (hourly max) |
| quantity, discrete | heart rate, HRV, SpO2, weight, BP components, VO2max | `HKAnchoredObjectQuery`. Series samples with `count > 1` are expanded with `HKQuantitySeriesSampleQuery` (every reading). Hourly `h` buckets use avg/min/max. | `s` + `h` | yes |
| category | sleep stages, mindful minutes, cycle tracking, symptoms, heart events | `HKAnchoredObjectQuery`. The value is stored as an int, and unknown values are kept. | `s` | yes |
| workout | all activity types | `HKAnchoredObjectQuery` on `HKWorkoutType`, plus events and `workoutActivities` | `w` | yes |
| ECG | Apple Watch ECG | anchored query + `HKElectrocardiogramQuery` for voltages | `ecg` | yes |
| heartbeat series | beat-to-beat (AFib/HRV) | anchored query + `HKHeartbeatSeriesQuery` | `hb` | yes |
| activity summary | rings (move/exercise/stand + goals) | `HKActivitySummaryQuery`, re-read for the last 7 days on each sync (it has no anchors) | `a` | no (foreground/observer on energy) |
| correlation | blood pressure, food | `HKSampleQuery` on the correlation type | `x` | no (correlations don't support it; the component types trigger a re-read) |
| state of mind (iOS 18+) | moods/emotions | anchored query | `s` (+ `md`) | yes |
| audiogram | hearing tests | anchored query, with sensitivity points in `md` | `s` | yes |
| characteristics | date of birth, sex, blood type, skin type, wheelchair use, move mode | `HKHealthStore` characteristic getters | `p` | n/a (read each sync) |

## Excluded in v1 (by decision)
- Workout **routes** (GPS): size and location privacy.
- **Clinical records** (FHIR): owner decision.
- **Vision prescriptions** and **medications** (iOS 26): these need Apple's per-object authorization flow.
- **Scored assessments** (GAD-7, PHQ-9): not read in v1.

## Rules
- **Unavailable ≠ zero.** A type with no samples is reported as "no data", never 0. If the phone never managed to read a type, it has no coverage, and tools say so.
- **Read denials** are invisible to apps. Apple returns empty results. The app shows "No readable Health data found" (with help) only when *every* type is empty.
- **Limited history:** if the user grants limited history (newer iOS), the earliest readable date becomes the coverage start. The AI is told history starts there.
- **Units:** values are stored in the unit column of `coverage.json`, and the app verifies `isCompatible` at runtime. An incompatible type is skipped and reported via analytics (type id only).
