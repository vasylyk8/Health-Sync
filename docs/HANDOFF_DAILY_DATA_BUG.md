# Handoff: Apple Health daily/hourly history is not reaching the user's AI tools

Written 2026-10-03 (~13:30 UTC) from the full working session of the previous AI (Claude Code, cloud session). Everything below is
taken from that session's transcript, CI logs and server diagnostics. Where something is a guess, it says so. Where I was wrong, it
says that too (section 9). Dates/times are UTC unless stated; the user is in Toronto (UTC-4).

## 0. TL;DR

- **Product:** KROK = iOS app that mirrors Apple Health to a private EU server (Firebase/Cloud Run + GCS + DuckDB/Parquet), exposed to
  Claude/ChatGPT through an MCP connector (`get_daily_context`, `get_hourly_series`, `get_recovery`, `get_workouts`, ...). Repo
  `vasylyk8/Health-Sync`, `main` deploys the server and builds TestFlight.
- **Bug:** on the owner's real iPhone (iPhone18,1, iOS 27.0 build 24A437, 3,338 workouts, 13.2 years of Health data) the server only
  ever has **full daily metrics for 2026-07-14 .. today (~82-122 days)**. Every earlier year has only **sleep + activity rings**
  (+ sometimes walking HR or HRV), and **no steps / HR / HRV / active kcal / resting HR**. `restingHr` is missing **everywhere**
  (even for recent days). Hourly HR/steps/HRV history also starts around 2026-07-14 (it varied between uploads). Workouts are fine.
- **What is established (high confidence):**
  1. The old data exists in Apple Health and is readable by the app: first samples steps 2017-06-16, HR/RHR/HRV 2019-12-27 (sample
     queries work); the user confirms steps exist every day incl. March 2024; the permission is "All Recorded Data".
  2. The failure is **on the phone, in the HealthKit statistics read** (`HKStatisticsCollectionQuery`), not on the server and not in
     upload/merge: the phone's own per-chunk diagnostic notes say `data=2/65 ... empty=63 failed=none` for old years - the queries
     return **empty collections with no error**.
  3. It does **not** reproduce in the CI iOS simulator (Debug or Release), and it is **not** caused by load from concurrent workout
     reads (speed-test rows G3/G4: same empties when reading alone).
  4. The only lead with real signal: for one chunk (2016-07-14..2017-07-14, steps) the probe printed
     `n=0 a=28` = plain statistics query **0 days**, same query restricted to **Apple sources only 28 days** (exactly the days
     from the first sample 2017-06-16). So **the plain statistics query (no source predicate) returns nothing for older data while a
     query that names the sources returns it.** Only this one chunk was readable (server log truncates notes to 200 chars).
- **Not yet understood:** why `restingHr` is empty even with the Apple-source predicate; why a second query variant returned data in
  one upload (walking HR full 2020-2025) and not in the next; why on the real phone 64 of 65 metric results are "lost" in the
  parallel collection (rescued by a sequential retry) but never in the simulator.
- **State right now:** PR #55 (diagnostic probe, experiment) is merged; PR #57 (restore parallel daily/hourly order) is open, CI
  running; the owner said **do nothing else to the app until told** (section 8). No fix for the data gap has been shipped.

## 1. System background (only what matters for this bug)

### 1.1 Data path
1. App (`ios/HealthSync`) reads HealthKit, builds compact batches (gz NDJSON), uploads to a Cloud Run ingest service.
2. Server stores batches in GCS as Parquet per type, merges at read time, serves MCP tools (`firebase/functions/src/query/*`,
   `src/mcp/server.ts`).
3. Daily rows: record `{k:"day", day:"YYYY-MM-DD", m:{metricKey: value,...}}` per consent category (`core`, `nutrition`, `mind`, ...).
   Server merges all uploads of a day **metric by metric** (PR #38; `dailyMaps` in `query/health.ts`, `keepVersions: true`).
4. 66 `core` daily metrics are defined in `shared/coverage.json` (`dailyMetrics`, 87 total with other categories). 15 are flagged
   `"source": "apple"` (app reads them only from Apple's own sources): restingHr, hrv, respiratoryRate, sleepingWristTempC, spo2Avg,
   spo2Min, walkingHrAvg, sleepBreathingDisturbances, vo2max, hrvMin, hrvMax, hrvRmssd, respiratoryMin, respiratoryMax, spo2Max.
   Steps, hrAvg, activeKcal etc. are **not** source-filtered. Sleep (category samples via `HKSampleQuery`) and activity rings
   (`HKActivitySummaryQuery`) use different query types.
5. Hourly series (HR avg/min/max, steps, HRV) use `HKStatisticsCollectionQuery` with 1-hour intervals (`hourlyBuckets`).

### 1.2 Sync engine (iOS)
- `SyncEngine.run`: recent workouts, then **in parallel**: daily history, workout raw-data upload (the long step), hourly history,
  events. Parallelism of daily/hourly with the workout upload was an explicit product decision to keep the first sync short
  (a first sync of this account is ~4+ minutes for workouts alone).
- `SyncEngine.dailyContext`: full pass = yearly chunks, oldest first, starting at the earliest sample date; each chunk calls
  `HealthKitSource.dailyContextBatches` -> per category `dailyRecords` (TaskGroup, 8 concurrent per-metric queries through a shared
  `queryGate` of 24, then sequential retry of anything missing, then rows). Version constants `dailyVersion` / `hourlyVersion`
  (currently 7 / 4) force a one-time full re-read when bumped. `dailyHashes` skip re-sending unchanged chunks; incremental = last 3 days,
  full = every 7 days.
- `HealthKitSource.dailyStatistics`: `HKStatisticsCollectionQuery(quantityType:, quantitySamplePredicate:, options:, anchorDate: from,
  intervalComponents: day 1)`; predicate = `HKQuery.predicateForSamples(withStart:end:options: [])`, plus, only for `source:"apple"`
  metrics, `appleSourcesPredicate` (HKSourceQuery for the type, keep sources whose bundle id has prefix `com.apple.health`,
  `HKQuery.predicateForObjects(from:)`).
- Speed test (in-app menu, rows A..K, G, G2, now G3/G4) runs the same code on the device and prints to the screen; the owner pastes it.

### 1.3 Owner's device facts
- iPhone18,1, iOS 27.0 (24A437), 6 cores, 11 GB. Account has Apple (3,042 workouts), Hevy, Strong, Strava, Fitness sources.
- Resting HR: owner says Apple Watch writes it daily incl. today; Athlytic was a source but was disabled ~2026-10-02.
- Health -> Privacy -> KROK: **All Recorded Data**.
- **Unknown:** whether 2026-07-14 is the date this phone was set up/restored (see questions, section 10).

## 2. Symptoms as seen through the AI (the user-visible bug)

First report 2026-10-02 16:36: the user's Claude said "There is no sleep, resting HR, daily HRV, steps or activity rings. Hourly heart
rate, hourly steps, hourly HRV and workouts all sync fine."

The previous AI had the **KROK connector in its own session** (the owner's claude.ai account) and queried the owner's real data
directly (`get_daily_context`, `get_hourly_series`, `get_recovery`, ...). That connector needs re-auth after every account/purge event
and was unavailable much of the time afterwards (use the diag workflow below instead).

## 3. Evidence catalogue (chronological; numbers are as observed)

### 3.1 First observation (2026-10-02 ~16:40) - via connector
Daily rows carried one metric for recent days, only sleep for 2021, nothing for 2025. Hourly HR had whole years missing. `get_recovery`
empty. Workouts, splits, zones, routes, profile, heart events, nutrition all fine.

### 3.2 After PR #35 (retry failed reads) - 17:45
No change. Daily last two weeks: only audio exposure + alcohol. Mid-2026 days: only `hrvMax`. Sleep present for March 2024. Hourly steps
now covered 2025 (had been missing), hourly HRV last week.

### 3.3 After a fresh install (counters restart) - 18:00
Days with an old server row stayed thin; days with no old row (back to Oct 2017) got sleep rows. -> hypothesis "high `seq` of old rows
beats new rows" -> PR #36 (counter starts at current time) + the owner purged the server.

### 3.4 Server-side diag after the purge (admin workflow, read-only) - 20:00..20:07
- 3,428 batches stored, **0 rejected**. Workouts 3,387 records, complete.
- **0 daily core records** at that moment (daily history was still uploading newest first; had reached July 2022, 1,539 days);
  hourly records: 8, back to Sept 2023. Nutrition 17, mind 106 arrived.
- Rows were thin even on a clean account: sleep + audio only, e.g. 1-4 March 2024 and 1-4 June 2025 only sleep.

### 3.5 Speed-test G2 lines (the app's own report of the last daily pass)
- After #38/#39 build (2026-10-02 21:14): `1/65 metrics with data. Empty: none. Failed: none` -> impossible unless 64 results never reported.
- After #41 (2026-10-03 00:57): `50/65 metrics with data (restingHr, hrv, respiratoryRate, sleepingWristTempC, spo2Avg, spo2Min,
  walkingHrAvg, sleepBreathingDisturbances, sleep, steps, walkRunDistanceM, cyclingDistanceM), 65 of 65 reported, 64 retried.
  Empty: heightM, hrvRmssd, uvExposure, moveMin, nikeFuel, wheelchair/snow/xcSki/paddle/rowing/skating distance, pushCount,
  perfusionIndexPct, bodyTempC, headphoneAudioEvents. Failed: none`. This is for the **last 365 days** (`dailyContext(now-365d, now)`)
  run alone in the speed test. Same G2 line again on 2026-10-03 11:46 and 12:46 (identical).
  Note it includes `restingHr` **with data** - yet the server never has restingHr.

### 3.6 Server contents per year (merged daily rows, `purge-all` diag; columns steps/restingHr/hrv/sleepAsleepMin/walkingHrAvg/activeKcal/ringMoveKcal = days having the metric)
After the #41 build, update in place (2026-10-03 ~00:06, via connector): every day from 2026-07-14 has ~50 metrics; March 2024 only rings+sleep;
hourly starts 2026-07-14; recovery works (HRV 63 vs 76.9 baseline); training load works.

Diag after fresh install #1 (2026-10-03 02:45, build from PR #51):
```
2017:  40 days; 2.0 metrics/day; 0/0/0/0/0/0/0
2018:  64 days; 2.8; 0/0/0/26/0/0/0
2019: 167 days; 2.2; 0/0/0/0/5/0/6
2020: 366 days; 10.9; 0/0/0/345/365/0/366
2021: 365; 11.1; 0/0/0/353/365/0/365
2022: 365; 12.0; 0/0/0/348/365/0/365
2023: 365; 14.6; 0/0/0/343/363/0/365
2024: 366; 14.6; 0/0/0/349/366/0/366
2025: 365; 15.0; 0/0/0/364/364/0/365
2026: 275; 24.2; 81/0/81/273/274/81/275     (hrv/steps/activeKcal 81 days = since 2026-07-14)
```
Diag after fresh install #2 (2026-10-03 11:36, build from PR #52):
```
2020-2023: steps/rhr/hrv/walkingHr/activeKcal all 0 (sleep ~345, rings 365)      <- walkingHr from install #1 (365/yr) is GONE
2024: 366 days; 15.3; 0/0/171/349/0/0/366    (hrv 171 days = from the chunk start 2024-07-14)
2025: 365; 17.6; 0/0/365/364/0/0/365
2026: 276; 26.9; 122/0/276/274/80/122/276    (steps/activeKcal 122 days, hrv 276, walkingHr 80, restingHr 0)
```
-> **Which metrics return old data differs between uploads.** (How "fresh install" interacts with server data is not known - the
owner may or may not have used Delete All My Data; see section 10.)

### 3.7 Per-chunk phone notes (server log of the batch header `perf.note`)
Build from PR #52, fresh install #2 (11:27..11:31). Per yearly chunk (starting 2013-07-14) `core: daily from=.. to=.. data=X/65 got=65
lost=64(hrv,respiratoryRate,sleepingWristTempC) empty=.. failed=none`:
```
2013..2017-07-14: data 0/65 (empty 65)     2017-07..2018-07: 1/65     2018-07..2019-07: 1/65
2019-07..2020-07: 2/65   2020-07..2021-07: 2/65   2021-07..2022-07: 2/65   2022-07..2023-07: 2/65 (earlier build: 3)
2023-07..2024-07: 3/65   2024-07..2025-07: 7/65 (that chunk took 96 s)   2025-07..2026-07: 13/65   2026-07-14..now: 45/65
```
- `failed=none` everywhere; **no HealthKit error for any metric**.
- `got=65 lost=64` for **every chunk** even after the "return values from the TaskGroup" rewrite (PR #52): all 65 results arrive in the
  group, but 64 are nil after collection -> then rescued by the sequential retry loop. The same note on the nutrition category
  (earlier build) showed `got=10 lost=9`. This is device-only; never in the simulator (Debug or Release).
- First-sample dates reported by the phone (HKSampleQuery ascending, limit 1): steps 2017-06-16, HR 2019-12-27, RHR 2019-12-27,
  HRV 2019-12-27.

### 3.8 Speed test G3/G4 (build from PR #55, reading daily alone, per yearly chunk) - 2026-10-03 12:46
```
phone: protected data available, app state active
2013-07-14..2017-07-14: 0/65 metrics; steps/hrAvg/restingHr/hrv/activeKcal/sleep 0 days
2017-07..2018-07: 1/65  sleep 26d | 2018-07..2019-07: 1/65 | 2019-07..2020-07: 2/65 sleep 181d
2020-07..2021-07: 3/65 sleep 351d | 2021-07..2022-07: 5/65 | 2022-07..2023-07: 5/65 | 2023-07..2024-07: 6/65
2024-07..2025-07: 6/65 | 2025-07..2026-07: 5/65  (all: steps 0d, hrAvg 0d, restingHr 0d, hrv 0d, activeKcal 0d)
2026-07-14..2026-10-03: 45/65  steps 82d hrAvg 82d hrv 82d activeKcal 82d sleep 82d restingHr 0d
G4 (same years while 48 workouts are read in a loop): 2021-07..2022-07 and 2025-07..2026-07 -> identical to "alone".
```
-> **Load is not the cause.** Also: this run (alone) returned **hrv 0 days for 2024-2025**, while the previous upload (daily
running in parallel with workouts) had hrv for 2024-2025 -> **non-deterministic**.
Also in the same output: `G2` for the last-365-days window says restingHr has data, but G3 for 2026-07-14..now says restingHr 0d.
(The two windows overlap only in 2025-10-03..2026-10-03; restingHr data would have to lie in 2025-10-03..2026-07-14 only. Not understood.)

### 3.9 Probe (in the sync's core note; PR #55 build, 12:26..12:29)
Per chunk the note ends with `|| probe steps:s=<first sample in range>,n=<plain statistics days>,a=<Apple-sources-only days>,m=<month-by-month
plain days>,src=<apple sources>/<all sources>` for steps, restingHr, hrAvg, hrv, activeKcal. **The server log truncates strings to 200
characters (`firebase/functions/src/log.ts`, `slice(0, 200)`), so almost every probe was cut off.** The only fully readable part:
chunk 2016-07-14..2017-07-14: `steps:s=2017-06-16,n=0,a=28,m=2...` (m truncated). `suspect=` lists (samples exist but statistics empty):
`steps,activeKcal` for 2017-2019, `restingHr,hrv,steps,activeKcal,hrAvg` for 2019-2022, `hrv,steps,activeKcal,hrAvg` for 2022-2024.
Last readable fragment of another line: `src=16/16` for steps in the 2015-07..2016-07 chunk (16 Apple sources of 16 total).

## 4. History of what was done (in order), with result

| # | PR / change | Hypothesis | Result |
|---|---|---|---|
| 1 | #35 `fix/daily-context-and-refresh`: failed daily/hourly queries retried once; transient failure fails the chunk instead of recording it complete; hourly same; versions bumped | queries dropped silently when HealthKit busy/locked | **No change** in server data |
| 2 | #36 `fix/seq-fresh-install`: batch `seq` counters start at current time after a reinstall | old rows with higher `seq` beat new rows | real bug (fixed) but **not the cause**; led to a server purge of the owner's accounts |
| 3 | #37 `fix/account-switch`: app detects account change, re-registers; server registers missing account on link creation | purge deleted the login, app silently made a new account ("Register the device first") | real bug (fixed); caused by the purge itself |
| 4 | #38 `fix/daily-merge-and-gate`: server merges a day's uploads metric by metric; daily queries use the shared read gate; speed-test row G2 | sparse later upload could erase metrics; load from 8 concurrent stat queries next to workout reads | **Server merge fix is real and stays.** Data still thin; G2 added |
| 5 | #39 `fix/daily-version-3` | previous builds did not re-read history for already-synced installs | made the update re-read; data still thin |
| 6 | #41 `fix/daily-results-accounting` (dailyVersion 4): collect results as `Result` values, retry any metric that did not report, richer G2 | G2 said `1/65, Empty none, Failed none` => 64 results never reported | **Recent 81 days became complete** (50 metrics/day). Older years unchanged. `64 retried` stayed on the phone |
| 7 | #43 `mcp-probe` workflow, #44 full synthetic dataset (98 daily metrics, hourly, nutrition...), #46 test fix, #47 phone->server chain test (`daily-check.yml`: simulator seeds Health data, runs the real daily pass, dumps batches, server job ingests them and asks through MCP) | owner demanded the AI be able to reproduce any pull itself | built; all green; **cannot reproduce the bug** (simulator returns everything) |
| 8 | (investigation, no code shipped) iOS 27 limited-history authorization (`earliestAuthorizedSampleDate(for:)`) | "Past 30 Days" grant hides old samples | **Refuted**: Settings shows "All Recorded Data" |
| 9 | #51 `fix/daily-chain-diag`: never upload a chunk with metrics missing; per-chunk diagnostic note (`BatchHeader.note` -> `perf.note`, logged by ingest); multi-year engine test; `ingest-notes` workflow | need to see what each yearly chunk returns on the device | notes showed `empty=63 failed=none` for old years; sample dates exist back to 2017/2019 |
| 10 | #52 `fix/daily-release-build`: Debug+Release matrix in `daily-check`; collect results as the TaskGroup return value; per-category notes; dailyVersion 5, hourlyVersion 3 | optimized Release build miscompiles/loses results (device shows lost=64) | **Release simulator also lost=0**; on device `lost=64 got=65` persisted -> cause not the collection style |
| 11 | #55 `fix/daily-probe`: probe (s/n/a/m/src), sequential daily-first order (experiment), retry-with-3s-sleep for empty key metrics + `incomplete` flag (re-read in 6 h), speed-test rows G3/G4, versions 7/4 | system load from workout reads makes statistics silently empty | **Refuted** by G3/G4 (alone == loaded). Made first sync much longer. Probe produced the `a=28 vs n=0` lead |
| 12 | #57 `fix/sync-order-parallel` (open, CI running) | owner: restore parallel order, change nothing else | pending merge + TestFlight |

Test/CI infrastructure that came out of this (all on `main`): `mcp-probe` workflow (call any MCP tool against the live synthetic user),
`scripts/local-probe.ts` (real ingest+MCP in memory, ~5 s), `test/unit/synthetic-mcp.test.ts`, `phone-batches.test.ts`, `daily-check.yml`
(Debug and Release simulator job + server job), `ingest-notes.yml` (read per-chunk notes from the ingest log), branch `ops/purge-all`
(`purge-all.yml`, push = read-only diag). See `docs/SYNTHETIC_TESTING.md`.

## 5. Things I would *not* retry (already refuted)

- iOS 27 limited-history authorization (setting is All Recorded Data).
- Server overwrite / merge order / `seq` counters (fixed; server stores what the phone sends; 0 rejected batches).
- "Load from concurrent workout reads empties the statistics" (G3/G4).
- "Release-build miscompile of the TaskGroup collection" (CI Release is clean; rewrite did not change device `lost=64`).
- Retrying empty results after a pause (3 s x 2: retries=2, still empty).
- Hypothesis that restingHr is dropped by third-party sources (owner says Watch writes it daily) - not proven false, but the same
  Apple-only predicate lets HRV and walking HR through in some uploads.

## 6. Current best hypotheses (ordered), with how to test each

1. **Plain statistics collection returns nothing for samples recorded before ~2026-07-14, but returns them when sources are
   named.** Evidence: `n=0 a=28` (steps, 2017). Consistent with: sleep/rings fine (other query types), sample queries fine, recent
   82 days fine, HRV/walking HR (Apple-only flagged) appearing in some uploads while steps/HR/kcal (not flagged) never do.
   Possible mechanism (unverified): data from older devices/sources (iCloud-synced, e.g. previous iPhone/Watch) is invisible to
   a source-less statistics query on this phone/iOS build (maybe related to "preferred source order"/source priorities in Data Sources
   & Access, or an iOS 27 behavior). **Test:** per chunk and per metric record n (plain), a (Apple sources), `all` (predicate from
   *all* sources via HKSourceQuery), `sep` (`.separateBySource` collection summed), `m` (month windows), single `HKStatisticsQuery`
   per day; read the full probe (raise log limit, see 7.1). If a/all/sep give data, make that the fallback when plain is empty and
   samples exist.
2. **Raw-sample fallback.** Sample queries work for old data (workouts raw streams, sleep, first-sample dates). If no statistics
   variant works, aggregate daily values from `HKSampleQuery` per metric per month and dedupe overlapping sources
   (Apple Watch + iPhone double counting for steps/energy needs a rule, e.g. per-day max per source family or prefer Watch).
3. **restingHr** is separate: it is Apple-only-flagged and empty even for recent days and even though G2 (365-day window) shows it with
   data. Compare `hasSamples` with/without the Apple predicate over the last 90 days; list sources (`HKSourceQuery`) and their bundle
   ids for `restingHeartRate`; check `HKStatisticsCollectionQuery` options (`.discreteAverage` vs `.mostRecent`) - the metric may
   be defined with an aggregation that returns nil for the Watch's daily sample type.
4. **Nondeterminism between uploads** (walking HR full in install #1, absent in install #2; HRV 2024-25 present with parallel order,
   absent with alone order): suggests HealthKit-side state (statistics cache building for the new phone/iCloud sync still in progress,
   or source-ordering state) rather than app logic. **Test:** run the same chunk twice minutes apart and across a day; log
   `HKHealthStore` sync/restore status if any; ask the owner when the phone was set up (section 10).
5. **`lost=64 got=65` on device only** is a second, possibly unrelated defect in `dailyRecords`' collection. It is harmless today
   (sequential retry covers it) but unexplained. Cheap experiment: drop the TaskGroup and read sequentially for one build and compare
   the notes; or return a small `Sendable` struct (key + cells) from each child instead of `(Int, Result)`.

## 7. Practical how-to

### 7.1 Read what the phone sent / what the server holds (no GCP access needed in the sandbox; only GitHub Actions with WIF)
- Per-chunk notes: dispatch **`ingest-notes`** (`workflow_dispatch` works only from `main`): inputs `hours`, `limit`; prints
  `timestamp uid type result note`. The note is cut at 200 chars by `src/log.ts` (change `v.slice(0, 200)` for the `note` key, or store
  `perf.note` on the batch doc, to see the whole probe - **this is server-only and was the first thing I wanted to do next**).
- Merged daily rows per year: push a comment-only change to branch **`ops/purge-all`** (workflow `purge-all.yml`, default mode `diag`,
  read-only) and read the job log tail (print `merged daily rows per year ...`). Mode `run` deletes accounts; needs confirmation text; do not run.
- Owner's KROK connector in the AI session: needs the owner to (re)authorize in claude.ai connector settings; sign in with Apple, same
  Apple ID as the phone (a reviewer/synthetic account gives synthetic data: Europe/Berlin timezone, steps exactly 10000/11000/12000).
- Real device timing/queries: only the owner's phone. The in-app speed test (menu) prints rows incl. G2/G3/G4; the owner pastes text.
  The auto-uploaded notes are the best channel because they need no owner action beyond opening the app after an update.

### 7.2 CI facts
- No Swift toolchain in the sandbox; **CI is the only compiler**. `ios-ci` ~12-15 min, `server-ci` ~2 min, deploy ~4 min, TestFlight
  upload ~10 min + Apple processing 5-15 min before the owner can install.
- Known UI flakes (re-run once): `testConnectClaudeShowsSetUpCheckmark`, `testLaunchPerformance`, `testChatGPTConsentCanBeCancelled`,
  `qa-ios small-device` (light-mode run), simulator "Authorization session timed out" (daily-check retries once).
- `workflow_dispatch` only runs workflows that exist on `main`. `daily-check` triggers on push to `main` and some branches.
- Two sessions edit this repo concurrently (e.g. PR #54 analytics, #56 Home screen were merged by another session). Always pull `main`.
- GitHub access is via MCP tools only (no `gh`). Commit footer / PR footer conventions come from the session system prompt.

### 7.3 Code map
- `ios/HealthSync/Health/HealthKitSource.swift`: `dailyContextBatches`, `dailyRecords`, `dailyCells`, `dailyStatistics`, `dailyCategory`,
  `sleepSegments`, `activityRings`, `appleSourcesPredicate`, `hourlySeries`, `hourlyBuckets`, `dailyProbe`, `dailyDiagnosis` (speed test
  G3/G4), `earliestDailyDate`, `earliestSampleNote`, `benchmark` (speed test).
- `ios/HealthSync/Sync/SyncEngine.swift`: `run`, `dailyContext`, `hourlyHistory`, `dailyVersion`, `hourlyVersion`, `Config.dailyFullEvery`.
- `ios/HealthSync/Sync/Records.swift`: `BatchHeader.note` / `cleanNote` (700 chars, restricted alphabet).
- `ios/HealthSync/Health/HealthDailyCheck.swift` + `ios/HealthSyncUITests/DailyCheckUITests.swift`: DEBUG harness that seeds the simulator.
- `shared/coverage.json`: daily metric definitions (`source: "apple"` flag).
- Server: `firebase/functions/src/ingest/{batch,ingest}.ts` (note accepted/logged), `src/query/health.ts` (`dailyMaps` merge),
  `src/mcp/server.ts`, `src/log.ts` (200-char truncation), tests under `firebase/functions/test/unit/`.

## 8. Constraints and the owner's preferences (follow these)

- **Latest explicit instruction (2026-10-03 12:49 and 12:53): "Revert the way the sync worked before only, don't change anything else
  w the app" and "only do what I asked first - revert the way upload worked before and ship that."** After that ships, the owner wants to
  continue the bug with a new AI; **get explicit approval before changing app behavior.** A proposed fix (fallback to Apple-sources predicate
  when plain statistics are empty and samples exist; drop the 3 s retry; raise server note log limit to 700) was described to the owner and
  declined for now.
- First sync duration matters a lot (daily/hourly in parallel with workouts was a deliberate decision). Do not serialize it again.
- The owner dislikes being sent back to test repeatedly; wants the AI to reproduce things itself. For this bug that is impossible in CI,
  so use auto-uploaded notes.
- Earlier standing rule: ship without asking *within the requested scope*; report plainly; state uncertainty; short answers, no flattery.
- Never purge the synthetic monitor / reviewer accounts. Server purge deletes the owner's login and triggers account-switch side effects.
- Pronouns: use they/them for the owner unless stated otherwise.

## 9. Mistakes / wrong turns of the previous AI (so the next one does not repeat them)

- Declared the daily path "tested" on simulator data; the simulator never reproduces the device behavior (overclaim, owner called it out).
- Blamed iOS 27 limited authorization without checking the setting first (wrong).
- Blamed server overwrite/seq (partly real bugs, not the cause) and system load (refuted) - each cost the owner a reinstall/upload cycle.
- Attached the *last category's* diagnostic note to the core batch (nutrition), misleading the first reads (fixed in #52).
- Merged #44 after #45 without re-checking `main` CI (tests referenced removed tools; fixed by #46).
- Queried via the owner's connector which sometimes pointed at the synthetic account.

## 10. Open questions for the owner (answers change the diagnosis)

1. Is **2026-07-14** the day this iPhone was set up / restored from a backup / paired with the current Apple Watch? Which devices were used
   before (old iPhone/Watch models)? Older data coming from other devices via iCloud is the leading explanation for hypothesis 1.
2. When the owner did a "fresh install" (several times), did they also use **Delete All My Data** / was the server data wiped? (The merged
   server rows lost walking HR for 2020-2025 between install #1 and #2, which should be impossible with additive merge.)
3. Health app -> Browse -> Data Sources & Access: which sources and devices appear for **Steps**, **Resting Heart Rate**, **Heart Rate
   Variability**? Any source order / "turned off" sources? Is there an old iPhone/Watch listed?
4. Health -> Steps -> Show All Data: does a day in 2022 show a source name, and which (iPhone/Watch/other)?
5. Is the owner willing to run one more speed-test build that prints, for a handful of metrics and years, the full variant matrix (section 6.1)?

## 11. Suggested next steps (not done; owner approval needed)

1. Server-only: raise the `note` log limit from 200 to 700 chars (or store `perf.note` with the batch) so the existing probe becomes readable.
   Then re-upload once (bump `dailyVersion`) and read the full `s/n/a/m/src` matrix per year.
2. In the speed test (no sync behavior change), add rows that run the variant matrix (6.1) for steps/hr/hrv/restingHr/activeKcal for
   one old year, with source lists (names, bundle ids, counts). The owner can paste once.
3. Based on the matrix: implement the fallback chain in `dailyStatistics` (plain -> Apple sources -> all sources -> raw samples) only when
   the first result is empty and samples exist; keep existing results untouched; verify via the notes and `purge-all` diag per year; add the
   same fallback to `hourlyBuckets`.
4. Add a CI/simulator test that models "plain query empty, source-named query returns data" (e.g. samples from a second source/device in
   HealthKit simulator) so the failure is reproducible without the phone.
