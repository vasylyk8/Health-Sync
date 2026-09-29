# Data contract (schema version 1)

This is the single source of truth shared by the iOS app (`ios/`) and the server (`firebase/functions/`).
Any change bumps `schema` and must keep the server able to read older versions.

## 1. Upload batches (phone → server)

- Path: `incoming/{uid}/{batchId}.ndjson.gz` in the default Storage bucket. `batchId` is a UUIDv4 generated on the phone.
- Storage custom metadata: `schema`, `sha256` (hex SHA-256 of the gzipped bytes), `type` (HealthKit type identifier or a pseudo-type, see §3).
- Max 5 MB compressed and 200,000 records per batch. The phone splits larger results.
- Content: gzipped NDJSON. Line 1 is the **header**. Every following line is one **record**.
- Batches are immutable. Re-uploading the same `batchId` is a no-op, which makes retries safe.

### Header
```json
{"kind":"header","schema":1,"batchId":"…","type":"HKQuantityTypeIdentifierHeartRate",
 "seq":42,"device":"iPhone15,2","appVersion":"1.0 (7)","tz":"Europe/Kyiv","createdAt":1727337600000,
 "mode":"anchored|recent|stats|profile|reconcile|status",
 "window":{"start":…,"end":…},
 "caughtUp":false,
 "checkedAt":1727337600000,
 "perf":{"readMs":120,"uploadMs":850}}
```
- `seq`: per-(device, type) monotonic counter. The server uses it to order "latest wins" records.
- `mode`:
  - `recent`: the last 30 days via a sample query (fast first answers).
  - `anchored`: a page from the anchored query (the authoritative full history + change capture).
  - `stats`: merged statistics.
  - `profile`: characteristics.
  - `reconcile`: a full re-read after an anchor reset.
  - `status`: type `_status`. One batch reporting many types whose anchored query returned nothing new. Its records are `{"k":"c","t":"<type>","at":<checkedAt>,"cu":true}`. `cu` = that type's full history is delivered, which is the same as an empty `anchored` page with `caughtUp: true`. This replaces one upload per empty type (most of the ~170 types for a typical user).
- `window`: the time range this batch *fully covers*, if any. It's used for coverage and is absent for `anchored` pages, whose coverage comes from `caughtUp`.
- `caughtUp`: true when an anchored page returned fewer results than its limit, meaning the whole history of this type up to `checkedAt` has been sent.
- `checkedAt`: when the phone last successfully read this type from HealthKit, even if nothing was new. This drives freshness.
- `perf` (optional): how long the HealthKit read for this batch took, and how long the previous upload took. These are timings only, never health data. The server logs them so slow syncs can be diagnosed.

### Records (short keys keep batches small)
All times are **UTC epoch milliseconds**. `tz` is the sample's original timezone (`HKMetadataKeyTimeZone`) when present, otherwise null.

| `k` | Meaning | Fields |
|---|---|---|
| `s` | sample (quantity or category) | `id` (HK UUID), `s` start, `e` end, `v` numeric value in the canonical unit (quantity) or null, `c` category value (int) or null, `u` unit string, `src` source name, `bid` source bundle id, `dev` device model, `tz`, `md` small metadata object (string/number values only, ≤ 2 KB) |
| `w` | workout | `id`, `s`, `e`, `act` activity type (int) + `actName`, `dur` seconds, `en` active kcal, `dist` meters, `src`, `bid`, `dev`, `tz`, `ev` events `[{t,type}]` (pause/resume/lap/segment), `acts` sub-activities `[{s,e,act}]`, `md` |
| `x` | correlation (blood pressure, food) | `id`, `s`, `e`, `ct` correlation type, `items` `[{id,t,v,u}]`, `src`, `tz` |
| `ecg` | ECG | `id`, `s`, `e`, `cls` classification (int), `hr` avg bpm, `sym` symptoms status, `hz` sampling frequency, `volt` voltages in µV (array), `src` |
| `hb` | heartbeat series | `id`, `s`, `e`, `beats` `[{t,gap}]` (ms offset from `s`, "preceded by gap" flag), `src` |
| `a` | activity summary (rings) | `day` (YYYY-MM-DD, local), `ae` active kcal, `aeg` goal, `ex` exercise min, `exg`, `st` stand hours, `stg`, `mv` move min (if present) |
| `h` | merged statistic bucket | `t` type, `s` bucket start, `e` bucket end, `agg` `sum`/`avg`/`min`/`max`, `v`, `u`. Buckets are hourly. |
| `p` | profile/characteristics | `dob` (YYYY-MM-DD), `sex`, `blood`, `skin`, `wheelchair`, `activityMoveMode` (null when unavailable) |
| `d` | deletion tombstone | `id` (HK UUID of the deleted object) |

Unknown fields are kept (stored in `extra` JSON). Unknown category values are stored as numbers, never dropped.

**Series samples:** a quantity sample holding many readings (e.g. workout heart rate) is expanded into one `s` record per reading, with ids `<uuid>#<index>`. The parent itself is not sent. A tombstone for `<uuid>` removes all `<uuid>#…` readings.

## 2. What the phone sends, and when

1. **Profile** (`p`) once and on change.
2. **Merged statistics** (`h`) for every cumulative quantity type over the full history. This is cheap and gives exact all-history totals within minutes. It's recomputed on every sync for affected days (days of added samples + the last 2 days), plus a **full recompute weekly** so that deletions of old samples show up in totals within 7 days. (HealthKit deletion records carry no date, so there's no cheaper exact way.)
3. **Recent** (`s`/`w`/…, `mode:recent`): the last 30 days per type, newest first. The AI becomes useful fast.
4. **Anchored full history** (`mode:anchored`): pages of ≤ 20,000 objects (≤ 2,000 for workouts, ECGs and heartbeat series) per type from `HKAnchoredObjectQuery` (nil anchor first). Pages are split into ≤ 5 MB uploads. Up to 4 types sync at the same time, with each type's batches kept in order, and the most-asked types (steps, sleep, heart rate, workouts…) go first. A type with nothing new is reported in the shared `status` batch. This re-sends recent items too, and the server dedupes by UUID. The same query then continues forever as change capture (adds + deletions).

### The outbox rule (no data loss)
The results of one anchored page and its `newAnchor` are written together to a local outbox file **before** upload. The anchor used for the next query is advanced **only after** the server acknowledges the batch (upload finished + metadata verified). After a crash, unacked batches are re-sent (same `batchId`). The anchor never moves past un-acknowledged data.

### Reconciliation
If the anchor is lost/invalid, after a permission change, or after 30+ days without a sync: run a full `reconcile` pass (nil anchor). The server treats it as a set of adds, and dedupes by UUID. Deletions missed while offline can't be recovered from HealthKit (Apple expires deletion records). A reconcile therefore also sends, per type and month, the **list of UUIDs that currently exist**, and the server tombstones anything it holds that isn't in the list.

## 3. Server storage

- Raw Parquet (append-only): `data/{uid}/{type}/{yyyy-mm}/{batchId}.parquet`, partitioned by the **UTC month of the start time**.
- Tombstones: `data/{uid}/{type}/_tombstones/{batchId}.parquet` (column `id`). Deletions come per type from the anchored query, so no cross-type index is needed.
- Merged stats: `data/{uid}/{type}/_stats/{yyyy}/{batchId}.parquet`. The latest `seq` per bucket wins.
- Compaction (daily job): merge small files per month, apply tombstones, keep the latest per UUID. It writes a new file first, then swaps the manifest, then deletes the old files.

### Manifest (Firestore, server-owned)
`users/{uid}/types/{type}`:
```
{ version, files: { "2024-03": ["…parquet", …], "_stats/2024": […], "_tombstones": […] },
  coverage: { intervals: [[start,end],…] (stored in Firestore as [{s,e},…], which forbids nested arrays), statsIntervals, caughtUp: bool, earliest, latest, checkedAt, visibleAt },
  counts: { records } }
```
`users/{uid}`: `{ generation, deleting: bool, lastVisibleAt, connections{…}, rate{…} }`.
Publishing a batch = one Firestore transaction that appends the new file(s), merges coverage and bumps `version`, and checks that `generation` still matches (so a deletion that started meanwhile wins).

### Visible vs accepted
The phone's upload ack only means **accepted**. "Synced" in the app and every tool's coverage come from `visibleAt`/coverage, which are set only when the manifest is published.

## 4. Correctness rules used by the tools

- **Totals** of cumulative types (steps, distance, energy, flights, …) without a source filter use merged hourly stats. They're labelled `merged` and are exact on hour boundaries in the requested timezone. Requests with finer boundaries are rejected with an explanation.
- **Raw calculations** (averages/min/max of discrete types, anything with a source/device filter) run on deduped raw samples minus tombstones. When sources overlap, sums over raw data are labelled `raw_may_double_count`.
- **Timezone:** grouping uses the `tz` argument (default: the phone's current timezone from the latest header). Buckets follow local days across DST. Travel: each sample is bucketed in the requested tz, not its original tz. The original is returned on raw rows.
- **Sleep:** a night is attributed to the local date on which it **ends**. Stage durations are merged per stage, and overlapping samples from different sources aren't double-counted (the preferred source is the one with stages, i.e. Watch over phone).
- **Workouts:** duration excludes pauses (from events). Multi-sport workouts list their sub-activities.
- **Units:** canonical storage units are listed in `COVERAGE_MATRIX.md`. Tools return the unit on every value.
- **Completeness:** every tool response carries:
  `coverage` (per type: synced intervals, caughtUp, earliest, latest, checkedAt, stale),
  `complete` (true only if the requested range is fully inside the coverage intervals for all types used), and `dataAsOf`.
  If a result would exceed its row cap (cap+1 check) or ~60 KB, the tool returns an error explaining how to narrow the request. It **never** returns an aggregate over partial rows.
  If the data is more than 24 h old: `note: "Data last synced …; ask the user to open KROK to refresh."`

## 5. Deletion ("Delete all my data")

1. The callable sets `users/{uid}.deleting=true`, bumps `generation` and deletes all token hashes (connectors stop immediately).
2. It enqueues a Cloud Tasks job (retried until success) that deletes `incoming/{uid}/`, `data/{uid}/`, all Firestore docs under `users/{uid}`, access-log entries, and finally the Auth user.
3. Ingestion checks `deleting`/`generation` inside its publish transaction and discards late work.
4. Storage soft-delete is disabled on the bucket, so deleted objects are gone. There are no Firestore backups in v1. The privacy policy states deletion completes within 24 h.
