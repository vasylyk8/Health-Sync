# Data contract (schema version 2)

This is the single source of truth shared by the iOS app (`ios/`) and the server (`firebase/functions/`).
Any change bumps `schema` and must keep the server able to read older versions of what it still accepts.

KROK syncs **workouts** (with everything Apple attaches to them) and **daily context**. Nothing else is
accepted: the server rejects every other batch type and record kind.

## 1. Upload batches (phone → server)

- Path: `incoming/{uid}/{batchId}.ndjson.gz` in the default Storage bucket. `batchId` is a UUIDv4 generated on the phone.
- Storage custom metadata: `schema` (always `1`: the version of this upload envelope, checked by the Storage rules), `sha256` (hex SHA-256 of the gzipped bytes).
- Max 5 MB compressed and 200,000 records per batch. The phone splits larger results.
- Content: gzipped NDJSON. Line 1 is the **header**. Every following line is one **record**.
- Batches are immutable. Re-uploading the same `batchId` is a no-op, which makes retries safe.

### Header
```json
{"kind":"header","schema":2,"batchId":"…","type":"HKWorkoutTypeIdentifier",
 "seq":42,"device":"iPhone","appVersion":"1.0","tz":"Europe/Kyiv","createdAt":1727337600000,
 "mode":"anchored|recent|stats|reconcile|status|workoutdata",
 "window":{"start":…,"end":…}, "caughtUp":false, "checkedAt":1727337600000,
 "reconcileId":"…","reconcileDone":false, "perf":{"readMs":120,"uploadMs":850}}
```
- `schema`: 2 (1 is still parsed for workout batches). `_wstream` and `_daily` batches need 2.
- `type` is one of:

| type | mode | records | meaning |
|---|---|---|---|
| `HKWorkoutTypeIdentifier` | `recent`, `anchored`, `reconcile` | `w`, `d` | workout summaries and deletions |
| `_wstream` | `workoutdata` | `ws`, `wd` | raw data of workouts (streams, GPS route) |
| `_daily` | `stats` | `day` | daily context rows |
| `_status` | `status` | `c` | "checked, nothing new" for the types above |

- `seq`: per-type monotonic counter; the server keeps the highest `seq` per record id ("latest wins"). The app keeps its counters across upgrades.
- `window`: the time range this batch fully covers (used for coverage). For `_daily` it goes to the statistics coverage.
- `caughtUp`: true when an anchored page returned fewer results than its limit, meaning the whole history up to `checkedAt` has been sent.
- `perf`: timings only, never health data.

### Records
All times are **UTC epoch milliseconds**.

**`w` workout summary** (one per HealthKit workout, id = HKWorkout UUID):
`id`, `s` start, `e` end, `act` activity type (int) + `actName`, `dur` seconds (Apple's duration, excluding pauses),
`en` active kcal, `dist` metres, `hrAvg`, `hrMax`, `src`, `bid`, `dev`, `tz`, `srcVersion`,
`ev` events `[{t,type,dur}]` (`type` = HKWorkoutEventType: 1 pause, 2 resume, 3 lap, 4 marker, 5 motionPaused, 6 motionResumed, 7 segment; max 2000),
`acts` sub-activities `[{s,e,act,actName}]` (multi-sport),
`stats` = Apple's statistics per quantity type recorded during the workout, e.g. `{"HeartRate":{"avg":145,"min":110,"max":162,"u":"count/min"},"ActiveEnergyBurned":{"sum":310.5,"u":"kcal"}}`,
`md` metadata (weather, indoor/outdoor, elevation ascended… scalar values; quantities as text; ≤ 8 KB).
Unknown fields are kept (stored in `extra`).

**`d` deletion tombstone**: `id` (HK UUID of a deleted workout). The server also deletes that workout's raw data.

**`ws` raw stream chunk** (in a `_wstream` batch): parallel arrays, one point per index.
`wid` (workout id), `st` stream name (`[A-Za-z0-9_]{1,60}`), `gen` (epoch ms of the phone-side read), `u` unit, `t` timestamps (ms), and value columns:
- quantity streams: `v`. Stream name = HealthKit type without prefix (`HeartRate`, `ActiveEnergyBurned`, `DistanceWalkingRunning`, `RunningSpeed`, `RunningPower`, `CyclingCadence`, `StepCount`, …). Discrete types are instantaneous readings stamped with the reading time; cumulative types (distance, energy, steps) are the amount added in an interval, stamped with the interval end. The full list is `workoutQuantityTypes` in `shared/coverage.json`.
- `route` (GPS): `lat`, `lon`, `alt` (m), `spd` (m/s), `crs` (degrees), `ha`, `va` (horizontal/vertical accuracy, m). Values with invalid accuracy are `null`.
At most 20,000 points per record; the phone sends ≤ 5,000. Arrays must have equal length; `null` = no value.
The phone sorts and de-duplicates by `t` before counting, so `expected` below is exactly what is stored.

**`wd` completeness marker** (last record of a workout's raw data): `wid`, `gen`, `expected` = `{stream: pointCount}`. The server sets `rawComplete` once every expected stream of that `gen` has arrived in full.
Re-reading a workout uses a new `gen`: a newer generation replaces older files of that stream, an older one is ignored, and streams absent from a newer marker are dropped.

**`day` daily context row** (in a `_daily` batch): `day` (local calendar date `YYYY-MM-DD`), `m` = metrics object (numbers, strings, booleans or null). Sent for every local day with at least one metric. Keys are listed in §2.

**`c` status entry**: `t` batch type, `at` time checked, `cu` = its full history is delivered.

## 2. Daily context metrics
Computed on the phone in the user's local calendar (`dailyMetrics` in `shared/coverage.json`). A missing key means "not recorded that day", never zero.
- Recovery and readiness: `restingHr`, `hrv`, `respiratoryRate`, `sleepingWristTempC`, `spo2Avg`, `spo2Min` (percent 0–100), `walkingHrAvg`, `sleepBreathingDisturbances`, and sleep per night (dated by the morning it ends; segments ending at or after 18:00 count for the next day): `sleepAsleepMin`, `sleepInBedMin`, `sleepCoreMin`, `sleepDeepMin`, `sleepRemMin`, `sleepAwakeMin`, `sleepBedtime`, `sleepWakeTime` (local `HH:mm`). One source per night is used for asleep time and stages (the one with the most staged sleep), so overlapping sources are never double counted.
- Activity and load: `steps`, `walkRunDistanceM`, `cyclingDistanceM`, `swimDistanceM`, `flightsClimbed`, `activeKcal`, `basalKcal`, `exerciseMin`, `standMin`, `daylightMin`, `physicalEffortAvg`, rings `ringMoveKcal`, `ringMoveGoalKcal`, `ringExerciseMin`, `ringExerciseGoalMin`, `ringStandHours`, `ringStandGoalHours`.
- Fitness trends: `vo2max`, `walkingSpeedMps`, `walkingStepLengthM`, `walkingAsymmetryPct`, `walkingDoubleSupportPct`, `walkingSteadinessPct`, `stairAscentSpeedMps`, `stairDescentSpeedMps`, `sixMinuteWalkM`.
- Body: `bodyMassKg`, `bodyFatPct`, `leanMassKg`, `bmi`, `heightM`, `waistM` (latest value of the day).
- Nutrition and hydration (only if logged): `dietaryKcal`, `proteinG`, `carbsG`, `fatG`, `sugarG`, `fiberG`, `sodiumG`, `waterL`, `caffeineG`.
- Mind and cycle: `mindfulMin`, `moodValenceAvg`, `moodEntries`, `basalBodyTempC`, and menstrual-cycle category values as lists of HealthKit values (`cycleMenstrualFlow`, `cycleIntermenstrualBleeding`, `cycleOvulationTestResult`, `cycleCervicalMucusQuality`, `cycleInfrequentMenstrualCycles`, `cycleIrregularMenstrualCycles`, `cyclePersistentIntermenstrualBleeding`, `cycleProlongedMenstrualPeriods`). Sexual activity, contraceptive, pregnancy and lactation data are deliberately **not** read.

## 3. What the phone sends, and when

1. **Recent** (`mode:recent`): workouts of the last 30 days, so the AI is useful within seconds.
2. **Daily context** (`_daily`, `mode:stats`): the whole history the first time and once a week (so data added later is included), otherwise the last 3 days on every sync. One year per batch.
3. **Workout history** (`mode:anchored`): pages of ≤ 200 workouts from `HKAnchoredObjectQuery` (nil anchor first). The same query continues forever as change capture (adds + deletions).
4. **Workout raw data** (`_wstream`): for every workout without raw data on the server, newest first, one upload per workout (split if large): every recorded quantity stream, the GPS route, then the `wd` marker. Read from HealthKit: samples associated with the workout (for heart rate also the same source's samples during the workout, for workouts imported from other apps).
5. **Status** (`_status`): reports the workout type as fully synced when the anchored pass found nothing new (at most once an hour).
A HealthKit background observer wakes the app when a workout is added; it runs an incremental sync (summary, raw data, recent daily rows) within ~20 s and continues in the foreground or a background processing task.

### The outbox rule (no data loss)
The results of one anchored page and its `newAnchor` are written together to a local outbox file **before** upload. The anchor is advanced **only after** the server acknowledges the batch. After a crash, unacked batches are re-sent (same `batchId`). Raw data of a workout is marked "done" locally only after all its batches are acknowledged.

### Upgrade from schema 1
The outbox state records its schema. On first launch of the new app the old state is replaced: anchors reset (every workout is re-read with full detail), queued old-format batches are dropped, and sequence numbers are kept (the server keeps the highest `seq` per record).

### Reconciliation
After 30+ days without a sync (deletion records expire in HealthKit): a full `reconcile` pass of workout summaries. The server treats it as adds, then tombstones workouts it holds that were not re-sent (and deletes their raw data).

## 4. Server storage

- Workouts and daily rows: Parquet, `data/{uid}/{type}/{yyyy-mm}/{batchId}.parquet`, partitioned by the **UTC month of the start**. One generic row shape (`k, id, s, e, v, c, u, agg, src, bid, dev, tz, extra, seq, batch, rid`); workout-specific fields are in the `extra` JSON.
- Tombstones: `data/{uid}/{type}/_tombstones/{batchId}.parquet`.
- Raw streams: `data/{uid}/wstream/{workoutId}/{stream}/{gen}-{batchId}.parquet`, columns `t, v, lat, lon, alt, spd, crs, ha, va` (unused columns are NULL), zstd, sorted by time.
- Compaction (every 6 h): merges partitions with more than 8 files, keeping the latest version of each record and dropping tombstoned ones. Raw stream files are already one per stream and read together.

### Manifest and index (Firestore, server-owned)
- `users/{uid}/types/{type}`: manifest of Parquet files and coverage (`intervals`, `statsIntervals`, `caughtUp`, `earliest`, `latest`, `checkedAt`, `visibleAt`) for `HKWorkoutTypeIdentifier` and `_daily`.
- `users/{uid}/workouts/{workoutId}`: raw-data index `{ streams: {name: {gen, files, points, unit, cols}}, expected, expectedGen, rawComplete, updatedAt }`.
- `users/{uid}`: `{ generation, deleting, lastVisibleAt, connections, links, tz }`.
Publishing a batch is one Firestore transaction that checks the user's `generation` (so a deletion that started meanwhile wins).

### Visible vs accepted
The phone's upload ack only means **accepted**. "Synced" in the app and every tool's coverage come from `visibleAt`/coverage, set only when the manifest is published.

## 5. Correctness rules used by the tools
- **Apple's numbers first.** `get_workouts` / `get_workout` return Apple's own summary (duration excludes pauses, energy, distance, average and max heart rate, statistics, metadata).
- **Raw data is never silently partial.** `raw_data` is `complete` only when `rawComplete`; tools say when raw data is still uploading. Series tools state how many points exist and how many are shown; downsampling averages per time bucket (mean/min/max); paging (`cursor`) returns every point exactly once.
- **Calculations** (`workout_*`) run on the full raw data and use moving time (pauses from workout events removed): heart rate zones (gaps over 30 s are "unmeasured"), splits per km/mile, heart rate drift and decoupling, best efforts (sliding window), elevation (smoothed, 2 m threshold). Distance comes from Apple's distance stream when present, otherwise from the GPS route.
- **Privacy default:** the first and last 300 m of a route are hidden unless `include_full_route` is set; routes too short to trim are refused without it.
- **Timezone:** local dates use the `timezone` argument (default: the phone's timezone from the latest header).
- **Completeness:** every response carries `coverage`, `complete` and `dataAsOf`; results larger than ~60 KB are refused with advice to narrow the request. Data older than 24 h adds a note asking the user to open KROK.

## 6. Deletion ("Delete all my data")
1. The callable sets `users/{uid}.deleting=true`, bumps `generation` and deletes all token hashes (connectors stop immediately).
2. It enqueues a Cloud Tasks job (retried until success) that deletes `incoming/{uid}/`, `data/{uid}/` (including raw streams), all Firestore docs under `users/{uid}` (manifests, workout indexes), access-log entries, and finally the Auth user.
3. Ingestion checks `deleting`/`generation` inside its publish transaction and discards late work.
4. Storage soft-delete is disabled on the bucket, so deleted objects are gone. The privacy policy states deletion completes within 24 h.
5. One-off migration: `scripts/tasks/cleanup-legacy` removes the data types of the previous app version (after backing them up for 14 days).
