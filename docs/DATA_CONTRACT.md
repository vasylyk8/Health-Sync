# Data contract (schema version 2)

This is the single source of truth shared by the iOS app (`ios/`) and the server (`firebase/functions/`).
Any change bumps `schema` and must keep the server able to read older versions of what it still accepts.

KROK syncs **workouts** (with everything Apple attaches to them), **daily context**, **hourly series** and,
for the data categories the user switched on, **event/sample logs** (§7). Nothing else is accepted: the server
rejects every other batch type and record kind, and drops batches of a category the user has not enabled.

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
| `_daily` | `stats` | `day` | daily context rows (core category) |
| `_daily_nutrition`, `_daily_cycle`, `_daily_mind` | `stats` | `day` | daily rows of an optional category |
| `_hourly` | `stats` | `hs` | hourly heart rate, steps and HRV buckets |
| `_events_heart`, `_events_nutrition`, `_events_devices`, `_events_mind`, `_events_medications`, `_events_profile` | `anchored` | `ev`, `d` | event/sample logs of an optional category |
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
`ev` events `[{t,type,dur,md?}]` (`type` = HKWorkoutEventType: 1 pause, 2 resume, 3 lap, 4 marker, 5 motionPaused, 6 motionResumed, 7 segment; max 2000; `md` = Apple's details of a lap or segment, such as swim stroke style and lap length),
`plan` the plan the workout was run from, when it has one (`{id, kind, desc}`; kind = goal, pacer, custom or swimBikeRun; `desc` a short description of its steps),
`acts` sub-activities `[{s,e,act,actName}]` (multi-sport),
`stats` = Apple's statistics per quantity type recorded during the workout, e.g. `{"HeartRate":{"avg":145,"min":110,"max":162,"u":"count/min"},"ActiveEnergyBurned":{"sum":310.5,"u":"kcal"}}`,
`md` metadata (weather, indoor/outdoor, elevation ascended… scalar values; quantities as text; ≤ 8 KB).
Unknown fields are kept (stored in `extra`).

**`d` deletion tombstone**: `id` (HK UUID of a deleted workout). The server also deletes that workout's raw data.

**`ws` raw stream chunk** (in a `_wstream` batch): parallel arrays, one point per index.
`wid` (workout id), `st` stream name (`[A-Za-z0-9_]{1,60}`), `gen` (epoch ms of the phone-side read), `u` unit, `t` timestamps (ms), and value columns:
- quantity streams: `v`. Stream name = HealthKit type without prefix (`HeartRate`, `ActiveEnergyBurned`, `DistanceWalkingRunning`, `RunningSpeed`, `RunningPower`, `CyclingCadence`, `StepCount`, …). Discrete types are instantaneous readings stamped with the reading time; cumulative types (distance, energy, steps) are the amount added in an interval, stamped with the interval end. The full list is `workoutQuantityTypes` in `shared/coverage.json`.
- `route` (GPS): `lat`, `lon`, `alt` (m), `spd` (m/s), `ha` (horizontal accuracy, m). Values with invalid accuracy are `null`. Older uploads also carry `crs` (course) and `va` (vertical accuracy), which the server still accepts; the app no longer sends them.
- Types marked `"stream": false` in `shared/coverage.json` (active and basal energy, exercise time, physical effort, environmental and headphone audio exposure) are not sent as streams; Apple's statistics for them stay in the workout summary (`stats`).
At most 20,000 points per record; the phone sends ≤ 5,000. Arrays must have equal length; `null` = no value.
The phone sorts and de-duplicates by `t` before counting, so `expected` below is exactly what is stored.

**Compact `ws` chunk** (`enc: 1`, in a `_wstream` batch; plain chunks above are still accepted): the same record with `n` (number of points, 1–20,000) and every column (`t`, `v`, `lat`, …) an object instead of an array:
- `{"m": M, "o": 1|2, "d": [..n integers..], "x": [null positions]}`: the value at index *i* is `X[i] / M`, where `X` is rebuilt from `d` by cumulative sums. `o: 1`: `d[0]` is `X[0]`, `d[i]` is `X[i] - X[i-1]`. `o: 2`: `d[0]` is `X[0]`, `d[1]` is `X[1] - X[0]`, and for *i* ≥ 2 `d[i]` is the change of that step, so steady motion and regular timestamps become runs of zeros. `x` (optional, increasing) lists the indexes whose value is null; the running value carries over them (the phone repeats the previous value there). `M` is an integer 1–10¹⁵ and the division is IEEE division of two exact integers, so phone and server get the identical double.
- `{"r": [..n numbers or null..]}`: plain numbers for a column that is not a whole number of 1/M for any M ≤ 10⁶ (sent as is, so nothing is lost).
- `t` must be whole milliseconds (`M` = 1, no `x`) inside the usual range.
Precision (set on the phone, the server accepts any `M`): quantity streams (`v`) are rounded to 3 decimals (`M` = 1000, far below sensor precision; this removes floating-point noise such as 61.99999999999999 that would force plain numbers); the route is rounded to about a metre: `lat`/`lon` M = 10⁵ (1.1 m), `alt` M = 10, `spd` M = 10, `ha` M = 1. The route is thinned to one point per 5 s (the first and last points are always kept; the watch records about one per second), so `n` and the `wd` marker count the points sent. The server decodes to plain arrays before anything else, so Parquet files and tools see ordinary doubles. Test vectors shared with the iOS tests: `shared/compact-fixtures.json`. **The server must be deployed before an app that sends `enc: 1`**: an older server would skip the records and the phone would believe them stored.

**`wd` completeness marker** (last record of a workout's raw data): `wid`, `gen`, `expected` = `{stream: pointCount}`. The server sets `rawComplete` once every expected stream of that `gen` has arrived in full.
Re-reading a workout uses a new `gen`: a newer generation replaces older files of that stream, an older one is ignored, and streams absent from a newer marker are dropped.

**`day` daily context row** (in a `_daily` batch): `day` (local calendar date `YYYY-MM-DD`), `m` = metrics object (numbers, strings, booleans or null). Sent for every local day with at least one metric. Keys are listed in §2.

**`hs` hourly buckets** (in a `_hourly` batch): `st` series name, `u` unit, `enc: 1`, `n`, `t` (start of each local hour as epoch ms), `v` (average, or the sum for cumulative types), optional `lo` / `hi` (minimum / maximum). Columns use the compact encoding above (plain arrays are accepted too). Hours without readings are not sent. Series: `HeartRate` (avg/min/max), `StepCount` (sum), `HeartRateVariabilitySDNN` and `HeartRateVariabilityRMSSD` (avg).

**`ev` event / sample chunk** (in an `_events_<category>` batch): `ty` event type (names in `eventTypes` of `shared/coverage.json`), `u` unit, `src` / `bid` writing app, `enc: 1`, `n`, `s` start times, optional `e` end times, `v` / `v2` values (compact columns), `c` category value (integers), `ids` (HealthKit UUIDs) and `meta` (per-event metadata, scalar values). A chunk holds the samples of one type from one source. Dense series (blood glucose readings, blood pressure) are sent **without** `ids` and `meta` to stay small; their identity is `(type, start, source)`. The `Profile` event (`_events_profile`) is one entry with `meta` = `{dob, sex, wheelchair, moveMode}`. The `Medication` event lists the medications the user chose to share (names only, no dose history).

**`c` status entry**: `t` batch type, `at` time checked, `cu` = its full history is delivered.

## 2. Daily context metrics
Computed on the phone in the user's local calendar (`dailyMetrics` in `shared/coverage.json`). A missing key means "not recorded that day", never zero.
- Recovery and readiness: `restingHr`, `hrv`, `respiratoryRate`, `sleepingWristTempC`, `spo2Avg`, `spo2Min` (percent 0–100), `walkingHrAvg`, `sleepBreathingDisturbances`, and sleep per night (dated by the morning it ends; segments ending at or after 18:00 count for the next day): `sleepAsleepMin`, `sleepInBedMin`, `sleepCoreMin`, `sleepDeepMin`, `sleepRemMin`, `sleepAwakeMin`, `sleepBedtime`, `sleepWakeTime` (local `HH:mm`). One source per night is used for asleep time and stages (the one with the most staged sleep), so overlapping sources are never double counted.
- Activity and load: `steps`, `walkRunDistanceM`, `cyclingDistanceM`, `swimDistanceM`, `flightsClimbed`, `activeKcal`, `basalKcal`, `exerciseMin`, `standMin`, `daylightMin`, `physicalEffortAvg`, rings `ringMoveKcal`, `ringMoveGoalKcal`, `ringExerciseMin`, `ringExerciseGoalMin`, `ringStandHours`, `ringStandGoalHours`.
- Fitness trends: `vo2max`, `walkingSpeedMps`, `walkingStepLengthM`, `walkingAsymmetryPct`, `walkingDoubleSupportPct`, `walkingSteadinessPct`, `stairAscentSpeedMps`, `stairDescentSpeedMps`, `sixMinuteWalkM`.
- Body: `bodyMassKg`, `bodyFatPct`, `leanMassKg`, `bmi`, `heightM`, `waistM` (latest value of the day).
- Nutrition and hydration (only if logged): `dietaryKcal`, `proteinG`, `carbsG`, `fatG`, `sugarG`, `fiberG`, `sodiumG`, `waterL`, `caffeineG`.
- Mind and cycle (optional categories): `mindfulMin`, `moodValenceAvg`, `moodEntries`, `basalBodyTempC`, and menstrual-cycle category values as lists of HealthKit values (`cycleMenstrualFlow`, `cycleIntermenstrualBleeding`, `cycleOvulationTestResult`, `cycleCervicalMucusQuality`, `cycleInfrequentMenstrualCycles`, `cycleIrregularMenstrualCycles`, `cyclePersistentIntermenstrualBleeding`, `cycleProlongedMenstrualPeriods`). Sexual activity, contraceptive, pregnancy and lactation data are deliberately **not** read.
- Heart and body extras (core): `hrAvg`, `hrMin`, `hrMax`, `hrvMin`, `hrvMax`, `hrvRmssd`, `respiratoryMin`, `respiratoryMax`, `spo2Max`, `bodyTempC`, `perfusionIndexPct`, `uvExposure`, `moveMin`, `nikeFuel`, `timesFallen`, `pushCount`, `swimStrokes`, per-sport distances (`wheelchairDistanceM`, `snowDistanceM`, `xcSkiDistanceM`, `paddleDistanceM`, `rowingDistanceM`, `skatingDistanceM`), audio exposure (`envAudioAvg/Max`, `headphoneAudioAvg/Max`, `soundReductionAvg`, `envAudioEvents`, `headphoneAudioEvents` as counts). `restingHr`, HRV, respiratory, SpO₂, wrist temperature and VO₂ max use only Apple's own sources (Apple Watch, iPhone), so another app writing its own value does not blend in. `alcoholBeverages` is in the nutrition category.

## 3. What the phone sends, and when

1. **Recent** (`mode:recent`): workouts of the last 30 days, so the AI is useful within seconds.
2. **Daily context** (`_daily*`, `mode:stats`): the whole history the first time and once a week (so data added later is included), otherwise the last 3 days. One year per batch and category. A chunk whose content hash equals the last one sent is not uploaded again, and incremental reads happen at most every 15 minutes.
2b. **Hourly series** (`_hourly`, `mode:stats`): the whole history the first time (a year per batch, newest data included), then the last 3 days about once an hour. A chunk is recorded as done only when every series was read (a series that fails for a passing reason is retried; a series without permission is skipped); an app update that changes this (`hourlyVersion`) reads the whole history once more.
2c. **Event logs** (`_events_*`, `mode:anchored`): one anchored query per event type, only for categories the user switched on; pages of ≤ 5,000 samples, then change capture. Deletions are sent for non-dense types only.
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

- Workouts, daily rows, hourly buckets and events: Parquet (format V2, zstd), `data/{uid}/{type}/{yyyy-mm}/{batchId}.parquet`, partitioned by the **UTC month of the start**. One generic row shape (`k, id, s, e, v, v2, v3, c, u, agg, src, bid, dev, tz, extra, seq, batch, rid`); workout-specific fields are in the `extra` JSON. For `hs` rows `agg` = series name, `v` = avg/sum, `v2` = min, `v3` = max; for `ev` rows `agg` = event type. Rows without an `id` are identified by `(k, agg, s, src)`.
- Tombstones: `data/{uid}/{type}/_tombstones/{batchId}.parquet`.
- Raw streams: `data/{uid}/wstream/{workoutId}/{stream}/{gen}-{batchId}.parquet`, columns `t, v, lat, lon, alt, spd, crs, ha, va` (unused columns are NULL), zstd, sorted by time. Value columns are stored as scaled integers (`FileRef.scale` in the manifest, e.g. lat/lon × 10⁵, quantity values × 1000) with delta encoding, so a file is about the size of the upload; reads divide by the scale.
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

## First-sync performance notes (app behaviour, no format change)
- Raw workout data (`workoutdata` batches) may carry several workouts (the app sends up to 24 per upload, 4 when running under a background time limit). Each workout keeps its own `wd` marker; the server already publishes per workout id.
- The app records a group of workouts as done only after every batch of that upload was accepted, so an interrupted first sync resumes without losing or duplicating data.
- Header `perf` accepts only `readMs` and `uploadMs` (strict schema); on-device timing lives in `sync-timing.json`, not in batches.

## 7. Data categories and consent
Every batch type belongs to one category (`categories` and `types[].category` in `shared/coverage.json`). `core` (workouts, activity, sleep and recovery, hourly series) is always on. The others start on (`default` in `categories`; `medications` starts off because Apple asks for it on a separate per-medication sheet) and can be switched off in the app (**Your data**): `nutrition` (nutrition, alcohol), `heart` (heart alerts, lung function), `devices` (glucose, insulin, blood pressure), `mind` (state of mind, mindful minutes, symptoms), `cycle` (menstrual cycle), `medications` (medication list), `profile` (date of birth, sex, wheelchair use, move mode).
- The phone asks HealthKit for the types of the categories that are on; Apple's sheet lets the user deny single types.
- The `setCategories` callable stores the choice (`users/{uid}.categories`, `core` always included). The app calls it **before** it starts syncing a newly enabled category. Switching a category off deletes its Parquet files, manifests and coverage on the server and resets the phone's anchors for it, so switching it on again resends everything.
- The server drops (acknowledges but does not store) batches of a category that is not enabled, and tools never serve a disabled category.
- `getStatus` returns the enabled `categories`; a reinstalled app adopts them.
- Sensitive categories (`devices`, `mind`, `cycle`, `medications`, `profile`) never appear in logs or analytics, and tools that return them tell the AI to describe data and trends only, with no diagnosis and no medication or dosing advice.

## 8. Staying in sync after the first upload
- **App opens or comes to the foreground:** a full catch-up (workouts, recent daily rows, hourly series, event logs, profile and medications).
- **New workout saved** (background delivery, immediately): the workout, its raw data, and the daily rows.
- **New heart rate, steps or event readings** (glucose, nutrition, symptoms... of the groups that are on): HealthKit background delivery wakes the app, at most about once an hour per type (iOS decides); the wake sends events, the hourly series and the daily rows.
- **Periodic refresh:** the app asks iOS for a background refresh about hourly; iOS runs it when it sees fit (often a few times a day, less if the phone is unused or low on power).
- Background work only runs while the phone is unlocked (HealthKit data is encrypted when it locks) and is limited to about 20-25 s per wake; unfinished work resumes next time. Daily rows are re-read at most every 15 minutes and the last 3 days are always refreshed; the whole history is re-read weekly. Hourly series refresh at most hourly (last 3 days).
- **Workout zones:** on iOS 27 the workout summary carries Apple's own zone boundaries and time in each zone (`zones`).
- **Daily rows are all-or-nothing per chunk:** if a HealthKit query for a metric fails for a passing reason (Apple Health busy or locked), the chunk is not sent and is retried on the next run; only permanent failures (no permission for that type) leave a metric out. A newer app version can ask for a full re-read (`dailyVersion`).
