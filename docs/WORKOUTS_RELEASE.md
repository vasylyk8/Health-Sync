# Releasing the workouts-only version (owner runbook)

Plain-language steps. Nothing here happens automatically: **no step below runs until you say so.**

## What changed
- The app now sends only your **workouts** (Apple's summary, every sensor reading recorded during the workout, the GPS route) and one **daily summary** row per day (sleep, resting heart rate, HRV, steps, rings, VO2 max, body measurements, nutrition if you log it, mindfulness/mood, menstrual-cycle context).
- Claude and ChatGPT get new tools: list workouts, one workout in full, raw readings and route (paged/downsampled), exact calculations (heart rate zones, km splits, heart rate drift, best efforts, elevation), daily context.
- The other Health data types are no longer read, and are removed from the server (see step 4).

## Order of steps (the order matters)
1. **Review the pull request** and confirm the automatic checks are green (server tests, iPhone app build and tests).
2. **Deploy the server first** (the `deploy` automation, from the branch you choose). From this moment the server accepts only workouts, daily rows and raw workout data, and the AI connectors get the new tools. Until the new app is installed, the AI will only see data that was already there.
3. **Install the new app build** (TestFlight). On first launch it detects the old version's sync state, keeps only its counters, and re-reads every workout with full detail, newest first. Keep the app open and the phone unlocked for the first sync (the screen stays on). The AI can already answer about recent workouts after a few seconds.
4. **Remove the old data from the server:**
   - Run the **`cleanup-legacy-plan`** task (read-only). It lists what would be removed and changes nothing.
   - Run **`cleanup-legacy`**. It copies the old data to a private backup bucket that **deletes itself after 14 days**, checks every copy, then deletes the old files and their index entries. It never touches workouts, daily rows, raw workout data, connector links or your account.
   - Because you chose to delete in the same release, run this right after step 3 is confirmed working (step 5). If anything looks wrong in step 5, do not run it: the old data is harmless meanwhile (the AI tools no longer show it).
5. **Check on your real iPhone** (things a simulator cannot test):
   - [ ] On first launch, iOS asks for Health access: **Workouts and Workout Routes** must appear in the list; allow all.
   - [ ] The sync screen moves through "Step 1 of 4 … Step 4 of 4: workout details (n of m)" and ends with "Synced …".
   - [ ] Finish a real workout with your Watch. Within a few minutes (open the app and pull down if needed) it appears in the AI: ask *"What was my last workout? Include average heart rate."*
   - [ ] Compare with the Apple Fitness app: duration, active energy, distance and average heart rate match what the AI says.
   - [ ] Ask *"How much time was I in heart rate zone 2 on my last run? My max heart rate is …"* and *"Show me the pace per kilometre."* (exact calculations).
   - [ ] Ask for the route. By default the first and last 300 m must be hidden. Ask explicitly for the full route to see it.
   - [ ] Ask about last night's sleep ("get my daily context for yesterday").
   - [ ] Restart the phone, do a workout without opening KROK, and check the workout arrives later (background delivery).
   - [ ] Settings → Health → Data Access → KROK shows only workout- and daily-summary categories.
6. **Update the App Store text and privacy answers** from `docs/APP_STORE.md` (adds *Precise Location* for GPS routes) and have `docs/legal/*` reviewed: they now describe location data.

## If something goes wrong
- **Server deployed but app not yet installed:** nothing is lost. The phone keeps its queue and sends everything once updated.
- **Old data cleanup:** the 14-day backup (`gs://<project>-legacy-backup/legacy/`) can be copied back by an engineer. After 14 days it is gone by design.
- **Raw data still "partial" for a workout:** the AI says so. Open KROK, pull down, wait; if it stays partial, the run summary in the app's sync issue line tells why.
- **Stop the AI seeing routes:** disconnect the assistant in KROK (its link stops working immediately) or delete all data.

## Known limits (be aware)
- Real HealthKit reads of routes and per-workout data cannot be tested without a phone; the automated tests use realistic fake workouts, so step 5 is essential.
- iOS only lets apps read Health data while the phone is unlocked, so the first full sync needs the app open. Background uploads continue only when iOS allows.
- The private connector link has no expiry and grants access to all synced data, including exact routes if requested. Consider OAuth before adding other users.
- Workouts imported from other apps often have no Apple-recorded statistics; heart rate is looked up from all authorized samples in the workout's time window, while other streams may still be missing.
