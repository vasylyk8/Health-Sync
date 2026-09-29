# KROK: QA report

**Date:** 29 Sep 2026 · **Build under test:** TestFlight build (from `claude/youthful-planck-k7ff0m`, pre-`ae950da`), live backend `krok-1d60a`, owner's real Health data via the KROK connector · **Code at:** `ae950da`

## Verdict: not ready for external testers or App Store review

The architecture is sound: a durable outbox, anchored queries, merged statistics, hashed links and a clear data contract. The tests that already existed all pass. However, three problems hit the product's core promises: **correct numbers**, **fresh data** and **nothing lost**.

1. **Totals can be ~2× too high, with no warning.** The live overview reported **31,439 steps/day**; the true figure was about 17,300 (details in H2).
2. **Background sync is very likely broken after iOS kills the app** (reboot, force-quit, or memory pressure). HealthKit observers are only registered when the app comes to the foreground (H1).
3. **Several paths advance the HealthKit anchor without the data reaching the server.** Data lost this way never comes back. The worst of these will trigger on its own once App Check enforcement is turned on after the soak test (H3).

All three are fixable in days, not weeks.

## Fix status (branch `claude/krok-improvements-overnight-8tiym2`)

Verified by CI: server unit tests, and the iOS unit and UI tests on the newest iPhone. The QA UI suite ran on the smallest iPhone via `qa-ios`; the result of the last run is in the notes below.

| Finding | Status |
|---|---|
| H1 observers only registered when a scene is active | **Fixed**: registered at process launch (`HealthSyncApp.init`). Needs the phone-restart check (D-3) on a device. |
| H2 / S-1 merged totals lost after a later check | **Fixed**: merged totals are judged against their own window (up to 6 h behind the latest check). |
| H2 / S-2 overview hides the double-counting warning | **Fixed**: raw sums that may double count are reported as unavailable; sub-call notes are kept. |
| H3.1 upload `unauthorized` treated as success | **Fixed**: on `unauthorized` the phone asks a new server callable (`batchExists`) whether the batch is already there (processed or waiting in the incoming bucket). Only then does it count as uploaded; otherwise the sync fails visibly and retries. If the server can't be asked, it falls back to trusting an interrupted retry only. Deploy the server before shipping the build that uses it. |
| H3.3 missing batch file | **Fixed**: the entry is dropped without moving the anchor, so the data is read again. |
| H3.2 a bad record rejects a whole batch | **Open**. |
| H4 / S-3, S-4 deleted hours and reinstall ordering | **Open** (needs a Parquet schema or ordering change). Repro tests remain expected-fail. |
| H5 / I-3 delete during a sync leaves an anchor | **Fixed**: in-flight uploads from before a reset are ignored. |
| H6 `claude/**` branches deploy to production | **Fixed**: `deploy.yml` now deploys only from `main` and `claude/youthful-planck-k7ff0m`. Confirmed: a later server commit on this branch started no deploy. |
| H7 Connect stuck disabled after Delete | **Fixed**: `busy` is cleared before the screen changes. Confirmed by `testReonboardAfterDelete` on the small-device run. |
| I-4 one failing type aborts the sync | Already fixed by per-type isolation on the dev branch; the test is now an ordinary regression test. |
| M5 setup-sheet errors invisible | **Fixed**: shown inline in the sheet. |
| M6 link on the general pasteboard | **Fixed**: local-only, expires after 10 minutes. |
| M8 / I-6 stale `earliest` date | **Fixed**: refreshed on every full recompute. |
| M11 contrast, Dynamic Type clipping | **Mostly fixed**: no "contrast failed" items and no small hit areas left in the audit; welcome and consent text scroll with the button pinned below. The home "Synced … ago" line still clips at the largest sizes. |
| V-1, V-2, V-3, rounding, `dataAsOf` | **Fixed**. |
| S-5, S-6 sleep dating | **Fixed**: sleep is dated by the night it ends (before 18:00 counts for that day) in both `get_sleep` and `summarize`. |
| M2 first sync locks the screen | **Partly fixed**: the screen stays awake during the first sync. Speed and a background task are still open. |
| Privacy policy menu name | **Fixed** ("••• menu"). |
| M3(c), M4, M7, M9, M10, M12 | **Open**. M4 needs a reliable "no data" signal; M7 is a log-sink setting; M9 and M10 are larger changes. |

## What was tested, and how

| Area | Method | Result |
|---|---|---|
| Existing automated tests | Server lint, typecheck, 41 unit tests and 16 emulator integration tests; iOS unit and UI tests on CI | All pass |
| Live MCP tools, on real data | ~30 calls: consistency between tools, source filters, edge dates and timezones, bad input, limits | 3 correctness bugs, 4 validation gaps |
| Server logic | Full code review, plus 9 new repro tests (`firebase/functions/test/unit/qa-findings.test.ts`) | 9 of 9 bugs reproduced |
| iOS sync engine | Full code review, plus 3 new repro tests (`ios/HealthSyncTests/QAFindingsTests.swift`) | See CI results below |
| UI, design, accessibility | New `QAUITests`: Apple's automated accessibility audit on every screen, largest Dynamic Type, dark mode, launch time, flow edge cases; smallest iPhone via `qa-ios.yml` | See CI results below |
| Performance | Live first-sync timeline, plus the benchmark re-run at your real heart-rate density | See P-1 and P-2 |
| Security and privacy | Rules, tokens, logs, pasteboard, privacy policy against the code, App Store answers | See section 4 |

**Not testable from here:** a physical device, background delivery over days, Apple Watch, battery and heat, the real claude.ai and chatgpt.com connector screens, VoiceOver by hand, and the live web pages (outbound HTTP to the site is blocked in this sandbox). Section 6 is a device checklist that covers these.

---

## 1. High severity

### H1: Background sync doesn't survive the app being terminated
`HealthSyncApp` has no app delegate. `observeChanges` (which runs `HKObserverQuery` and `enableBackgroundDelivery`) is only called from `AppModel.start()`, and `start()` only runs when `scenePhase == .active`. When HealthKit relaunches a terminated app in the background, the scene never becomes active. No observer query is running, so nothing syncs, and the completion handler HealthKit expects is never called. Apple requires observer queries to be set up in `application(_:didFinishLaunchingWithOptions:)`.
- **Effect:** after a reboot, a force-quit, or iOS evicting the app, data stops updating until the user opens KROK. Soak-test days 3 and 4 will likely fail.
- **Related:** `Info.plist` declares `fetch` and `processing` background modes and the task identifier `app.healthsync.sync`, but no `BGTaskScheduler` code exists. App Review may ask about this.
- **Fix:** add a `UIApplicationDelegateAdaptor` that registers observers for every synced type on every launch, and register a `BGProcessingTask` for the long first sync.
- **Confidence:** high from the code. Confirm on a device (section 6, D-3).

### H2: Totals double-counted (iPhone + Watch); the overview hides the warning. *Confirmed live.*
- **Live evidence, 29 Sep ~02:40 UTC:** `get_health_overview` reported steps as **31,439/day**. For 21–28 Sep, the raw sum across all sources was 31,593 on the first day; Watch alone was 16,159 and iPhone alone 15,434. After the stats phase reached StepCount (~03:12), the same queries returned the merged value: **16,252**.
- **Cause 1:** `isComplete(..., stats=true)` checks the stats intervals only up to `min(end, checkedAt)`. But any later anchored or empty-check batch moves `checkedAt` forward. The engine's `run()` sends stats before the anchored pass, so after every foreground sync, "today" and "this week" totals fall back to the raw sum. Repro test S-1.
- **Cause 2:** `getOverview` keeps `metrics` and `coverage` from each sub-call but throws away `notes`. The "may double count" warning never reaches the AI. Repro test S-2.
- **Fix:** track a separate `statsCheckedAt`, or compare stats coverage against the stats window rather than `checkedAt`. In the overview, never add up `raw_may_double_count` rows; fall back to the Watch-preferred source, or return "unavailable". Keep the notes.

### H3: Silent, permanent data loss paths ("nothing lost" violated)
The outbox design is good, but three paths commit the anchor anyway:
1. **`FirebaseBackend.upload` treats Storage `unauthorized` as success.** It assumes the object already exists. Any other rules or App Check rejection is also reported as `unauthorized`, so the anchor moves forward and that page of history is gone. **This becomes live the day App Check enforcement is turned on** (`provision.sh` keeps it off "until the soak test passes"). Fix: on `unauthorized`, confirm the object exists (for example with a callable `batchStatus(batchId)`) before acknowledging.
2. **Server-side rejection after the phone's acknowledgement.** A single record failing validation rejects the whole batch (up to 5,000 records) permanently. The phone already moved the anchor, and nothing tells it. Fix: reject only the bad line, or expose rejected batches in `getStatus` so the phone can reset that type's anchor.
3. **A missing batch file is treated as uploaded** (`SyncEngine.flush`). This one is documented. Better to reset that type's anchor and re-read.

### H4: Merged totals can't go down, and freeze after a reinstall. *Repro tests S-3 and S-4.*
- **Deletions:** HealthKit returns no statistic for an hour that is now empty, so the phone sends no bucket for it. The server keeps the old bucket because it keeps the latest upload per hour. Example: a user deletes a bogus 50,000-step entry; the total stays at 50,300 forever, and the weekly full recompute doesn't fix it. Fix: treat a stats batch's window as authoritative and replace every bucket inside it. Alternatively, have the phone send zeros for empty buckets.
- **Reinstall:** the Firebase anonymous user survives in the Keychain, but the outbox (and with it `seq`) starts from 1 again. Old buckets with a higher `seq` win forever. The same happens to profile changes. Fix: order by `(createdAt, seq)` or add a per-install epoch, and delete Keychain state on first launch after install if a fresh account is wanted.

### H5: "Delete All My Data" during a sync leaves stale state behind (I-3)
`deleteAllData` calls `outbox.reset()` while the engine may be mid-upload. When that upload finishes, `Outbox.complete` writes the anchor into the freshly reset `state.json`. After the user onboards again with a new anonymous account, that type starts from the old anchor and **its history before the anchor never reaches the new account**. The observer queries also stay registered (`observing` is never reset). Fix: cancel and await the engine before resetting, and give the outbox a generation token so stale completions are ignored.

### H6: Any `claude/**` branch push deploys to production
`deploy.yml` runs on `branches: [main, 'claude/**']` with `firebase/**` paths. This happened during this QA session: my test-only commit started a production deploy. **I cancelled it before any job ran, so nothing was deployed.** Your TestFlight testers use this same backend. Restrict deploys to `main`, or to one named release branch.

### H7: After "Delete All My Data" the user can't reconnect without force-quitting
Reproduced in the simulator (`QAUITests.testReonboardAfterDelete`, iPhone 17e, in-memory fakes). The welcome screen comes back with **Connect to Apple Health greyed out and spinning**. It is still disabled after 20 s, and tapping does nothing. Only terminating and relaunching the app recovers; onboarding then works. The spinner and the disabled state are both driven by `AppModel.busy`, so something leaves `busy == true` after deletion. From the code, `deleteAllData`'s `defer` should clear it, so the root cause isn't pinned down. Look at the ordering of `withAnimation { phase = .welcome }` against the `defer`, and at any other writer of `busy` during the transition. **Confirm on a device (D-12).**

---

## 2. Medium severity

| ID | Finding | Evidence / fix |
|---|---|---|
| M1 (I-4) | **One failing data type aborts the whole sync.** The task group rethrows, so later types never sync. The progress bar then sticks below 100%, and because that branch is checked first, "Synced … ago" never appears. | iOS repro test. Fix: catch per type, record the error, carry on, and retry later. |
| M2 (P-1) | **First sync is slow, and the screen lock stops it.** Live: the "last 30 days" pass alone took **38.5 min** (01:56→02:35 UTC). After 75 min, most types still had no full history. The app says "Keep the app open", but the idle timer isn't disabled, so the phone auto-locks, HealthKit becomes unreadable and iOS suspends the app. | Commit `ae950da` (4 types in parallel, skip empty uploads) is **not in the TestFlight build**; ship it. Also set `isIdleTimerDisabled` during the first sync and add a `BGProcessingTask`. Heart-rate series expansion runs one query per series sample, so profile it on a device. |
| M3 (S-5, S-6) | **Sleep dating.** (a) Sleep that ends after 12:00 is dated to the next day and merged with the following night; this affects late sleepers and shift workers. (b) `summarize(SleepAnalysis)` groups by the local date a segment *starts*, while `get_sleep` uses the wake-up date, so deep sleep for "the 21st" was 18 min in one tool and 37 min in the other. (c) `duration_min` adds up overlapping sources (Watch + AutoSleep) with no warning. | Repro tests. Fix: split nights at the longest gap in the data rather than at noon; route the tool description's sleep example to `get_sleep`; apply the same one-source-per-night rule in `summarize`. |
| M4 | **"No readable Health data found" can never appear.** Empty anchored pages are still uploaded and published, which sets `lastVisibleAt`. A user who denied every permission sees "Synced just now", and the assistant finds nothing. | Base the check on `typesWithData == 0 && historyComplete`, independent of `lastVisibleAt`. |
| M5 | **Errors inside the setup sheet are probably invisible.** The alert is attached to `RootView`, underneath the presented sheet. "Continue" shows no progress and isn't disabled, because `link(for:)` never sets `busy`. If link creation fails (offline), nothing visible happens. | Attach the alert to the sheet and set `busy` in `link(for:)`. Verify with device check D-6. |
| M6 | **The private link is copied to the general pasteboard.** Universal Clipboard syncs it to the user's Mac and other apps can read it, yet it is a bearer credential for all their health data. | Use `UIPasteboard.general.setItems(_, options: [.localOnly: true, .expirationDate: …])`. |
| M7 | **Link tokens end up in request logs.** The token sits in the URL path (`/mcp/<token>`), and Cloud Run/Hosting request logs record full URLs, kept for 30 days by default. That conflicts with "only a hash of each link is stored". | Exclude the path from logs (log sink exclusion), or accept the token in a header. |
| M8 (I-6) | **Merged totals miss older edits.** The incremental stats window is 3 days (the contract says "days of added samples + the last 2"), so edits to older days wait up to 7 days. Worse, `earliest` is cached forever, so history imported later (e.g. old Fitbit data) never gets merged totals. | iOS repro test. Refresh `earliest` during each full recompute; include the dates of newly added samples in the incremental stats. |
| M9 | **Correlations (blood pressure, food) aren't anchored.** Deletions and edits older than 7 days never propagate, and there are no tombstones. | Use an anchored query for correlation types. |
| M10 (P-2) | **Long-range query performance at real data density.** Your Watch records ~2,660 heart-rate readings/day, versus the benchmark's 288. Re-running the benchmark at 30 s intervals: 3 years = 3.2M records, 88 MB Parquet, **8.3 s** for "monthly HR average" locally (the stock benchmark: 1.7 s for 7 years). On a shared 1-vCPU function reading from GCS, 7–10-year users will approach the 45 s deadline and the 400 MB scan cap. | Store hourly min/avg/max for discrete types too (the phone already computes them), and use that path for avg/min/max. |
| M11 | **Colour contrast.** The green "Set up" label is 2.2:1 and the accent-colour "Privacy Policy" footnote link is 3.5:1; small text needs 4.5:1. White on the Claude and ChatGPT tints is 3.1–3.2:1, borderline even for bold text. | Use darker variants in light mode. The automated audit results are below. |
| M12 | The "Open claude.ai" and "Open chatgpt.com" buttons may open the native apps through universal links. Custom connectors are added on the web (and ChatGPT's Developer mode is web-only), so users could land somewhere they can't finish setup. | Check on a device (D-7). Consider opening an in-app Safari view. |

## 3. Low severity / polish

- **V-1/V-2:** an impossible date (`2026-02-30`) or an offset timezone (`+05:30`) returns `internal: "Try a smaller request"`, which is misleading. Validate these up front.
- **V-3:** `summarize(HeartRate, stat=sum)` returns 283,519 "count/min". Refuse sum for discrete types.
- `"Steps"` returns not_found with no suggestion. Add common aliases or a "did you mean StepCount" hint.
- Merged step totals come back unrounded (`16252.49`). Round count types.
- `get_health_overview` always has `dataAsOf: null`. Its `dailyAverage` divides by every day in the window, including today (partial) and days before the history starts.
- `get_workouts.segments` returns a JSON *string* of raw epoch-ms intervals; one run had 45 identical "Running" segments. That wastes tokens and is unreadable for the AI. Return local times, and collapse segments that are all the same activity.
- `in_bed_min` is always 0 when the Watch is the chosen source, because the iPhone's "in bed" samples are dropped.
- The header sends `UIDevice.model` ("iPhone") where the contract says a model identifier ("iPhone15,2"). Storage metadata omits the contract's `type` field.
- Metadata: NSNumber values of 0 or 1 match `as Bool` first, so they become booleans. The ~2 KB size check ignores the length of values.
- Once an assistant is set up, the user can't view or copy the link again; they have to disconnect and reconnect.
- Callable (Firebase Functions) errors all show "Something went wrong"; add offline, rate-limit and account-being-deleted messages.
- Copy: the privacy policy says "Settings menu → Delete All My Data", but the app uses the ••• menu. ChatGPT's row says "Requires ChatGPT Plus" while the tip says "Plus, Pro or Business".

## 4. Security, privacy and App Store

- ✅ Links are 256-bit random tokens; only a SHA-256 hash is stored in Firestore; disconnecting revokes access immediately. Bad tokens are rate-limited per IP. Storage rules only allow new uploads (no overwrites) to the user's own folder. Firestore allows no client writes. SQL injection through `source` was tried and is safe.
- ⚠️ M6 (pasteboard), M7 (tokens in logs), H3.1 (App Check).
- ⚠️ **Privacy policy vs reality:** it says data is stored in "Belgium", but Firestore uses `eur3` (Belgium + Netherlands), and user and manifest documents hold health-derived coverage metadata. It says "not intended for under 16", but there's no age gate and the planned age rating is "None".
- ⚠️ **App Privacy label:** Firebase Analytics collects an app-instance ID, and the answers mark usage data "not linked". Check against Firebase's published App Store disclosure guidance before submitting.
- ✅ Guideline 5.1.2(i) (sharing data with third-party AI needs explicit consent): the per-assistant consent screen names the company. Keep it, and mention it in the review notes.

## 5. Simulator results (iPhone 17e, the smallest current model, and the newest iPhone)
- **iOS unit tests: all 15 pass**, including the 3 QA repro tests. `XCTExpectFailure` is strict, so a pass means each expected failure actually happened: **I-3, I-4 and I-6 are confirmed.** The 3 existing onboarding UI tests pass.
- **Launch time:** average 1.58 s across 5 cold launches on the simulator (in-memory fakes). Fine.
- **Largest text size, welcome screen:** the tagline shrinks to "Apple Healt…", the privacy disclosure to "Your Health data…" and the button to "Connect t…", and the screen can't scroll. The consent text can't be read. **Fix:** a `ScrollView` plus `ViewThatFits`.
- **Home:** provider names, chevrons and subtitles take the pink accent (the list button tint). "Requires ChatGPT Plus" fails contrast; at the largest size "ChatGPT" wraps as "ChatG-PT".
- **Accessibility audit:** "Privacy Policy" hit area is under 44 pt; VoiceOver reads the consent icon as "lock.shield.fill"; the white step numbers 1–3 on the Claude orange fail contrast; the sheets' "Close" and the sync status text don't fully scale with Dynamic Type. Several other items were flagged "contrast nearly passed".
- **Dark mode:** the welcome screen renders correctly.
- **Re-onboarding after Delete All My Data:** fails. The Connect button stays disabled until the app is relaunched (H7). This also blocked the remaining flow tests (disconnect, reopening setup, double-tap Continue), so those are not verified.
- **Test harness:** the `-uiTesting` build still uses the real Keychain, so a link created in one test leaks into the next and the sheet skips consent. The QA suite resets state with Delete All My Data first.

## 6. Device checklist (what only you can check, ~15 min + background days)
Use together with `docs/RELEASE_SOAK.md`.
- **D-1** First sync: note the start time and when it reaches 100%. Does the screen auto-lock mid-sync, and does the percentage then stop moving? (M2)
- **D-2** In Claude, ask "How many steps did I take today?" during and after the first sync, and compare with the Health app. (H2)
- **D-3** Restart the phone and don't open KROK. Walk 1,000 steps and wait 2–3 h. Ask Claude "when was my data last synced?". Expected with the current build: stale. (H1)
- **D-4** Add a fake 20,000-step entry in the Health app for yesterday, wait for a sync, check Claude, then delete the entry and check again after a sync. Expected with the current build: the total stays inflated. (H4)
- **D-5** In Settings → Health → Data Access → KROK, turn everything off, then reinstall KROK and onboard. Does it say "No readable Health data found"? (M4)
- **D-6** Airplane Mode on → open Claude setup → tap Continue. Do you see an error? (M5)
- **D-7** With the Claude and ChatGPT apps installed, tap "Open claude.ai" and "Open chatgpt.com". Where do you land, and can you add a connector there? (M12)
- **D-8** Copy the link, then paste on your Mac. If it pastes, Universal Clipboard exposure is confirmed. (M6)
- **D-9** Turn on VoiceOver and go through onboarding and the Claude setup. Note anything unlabeled or read out of order.
- **D-10** Largest text size (Settings → Accessibility → Larger Text): go through every screen and look for clipping.
- **D-12** Tap ••• → Delete All My Data. Can you tap "Connect to Apple Health" straight away, or is it greyed out with a spinner until you force-quit? (H7)
- **D-11** Start a sync, then tap ••• → Delete All My Data straight away, onboard again, and let it finish. Compare "History synced back to" with the first run. (H5)

## Repro tests added (report only; no app code changed)
- `firebase/functions/test/unit/qa-findings.test.ts`: 9 `it.fails` tests (S-1 to S-6, V-1 to V-3). They pass today *because* the bugs exist. Once a bug is fixed its test shows as "unexpectedly passing"; then change `it.fails` to `it`.
- `ios/HealthSyncTests/QAFindingsTests.swift`: 3 `XCTExpectFailure` tests (I-3, I-4, I-6).
- `ios/HealthSyncUITests/QAUITests.swift` and `.github/workflows/qa-ios.yml`: accessibility audit, Dynamic Type, dark mode, launch time and flow tests, run on the smallest iPhone simulator.
