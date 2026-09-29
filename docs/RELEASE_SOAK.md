# Real-phone test (3–5 days, about 5 minutes a day)

Automated tests can't reproduce real Apple Watch data or background syncing over days. This checklist can. You and your second tester each follow it on your own iPhone, using the TestFlight build.

Write down anything odd, with the time it happened, and send it to me. I'll fix it and send a new TestFlight build.

## Day 1: setup (about 20 minutes)
1. Install **TestFlight** from the App Store, open the invite email and install **KROK**.
2. Open the app and tap **Connect to Apple Health**. On Apple's screen tap **Turn On All**, then **Allow**. ✅ The list includes **Workouts** and **Workout Routes**.
3. ✅ The home screen shows "Step 1 of 4 …" moving to "Step 4 of 4: workout details (n of m)" with a percentage.
4. Leave the app open (screen on) until the percentage reaches 100% or stops moving. Note how long it took: ______.
5. ✅ You see "Synced … ago" and "History synced back to <month year>". Does that month match your first recorded workout? ______
6. Tap **Claude**, tap **Continue**, then follow the three steps on claude.ai. When you finish, the app should show **✓ Set up** within a minute.
7. Tap **ChatGPT** and do the same on chatgpt.com (needs Plus). ✅ **✓ Set up**.
8. In Claude, ask each of these and compare with the Apple Fitness app (Workouts):
   - "What was my last workout? Give duration, active calories, distance and average heart rate."
   - "List my workouts from last week."
   - "For my last run, how much time did I spend in each heart rate zone? My max heart rate is <your value>."
   - "Show me the pace for each kilometre of my last run."
   - "Did my heart rate drift between the first and second half of my longest workout?"
   - "Show my route for my last outdoor workout." ✅ The first and last 300 m are hidden. Then ask for "the full route including where it starts" ✅ now they appear.
   - "How did I sleep and what was my resting heart rate the night before my last workout?"
   ✅ Apple's numbers (duration, energy, distance, average heart rate) match the Fitness app; the calculated ones look sensible.
9. Ask the first three questions in ChatGPT. ✅ They match.

## Days 2–5: normal life (about 5 minutes a day)
- Use your phone normally. **Don't** open KROK unless a step says so.
- **Day 2:** do a real workout with your Watch (a 20+ minute walk or run is fine). Within an hour or two, ask Claude: "What was my last workout, and was its detailed data fully uploaded?" ✅ It appears without opening KROK (or after opening the app once), and Claude says the detailed data is complete (or still uploading, then complete later).
- **Day 2:** in the Health app, delete an old test workout you don't need. Next day ask Claude to list that week's workouts. ✅ It is gone.
- **Day 3:** turn on Airplane Mode, do a workout, turn it off afterwards. ✅ That evening the workout shows up (open the app and pull down if needed).
- **Day 3:** swipe KROK away in the app switcher (force-quit). Next day, ask Claude about today's workouts. ✅ Claude says the data may be stale and suggests opening the app. Open the app → ✅ fresh again.
- **Day 4:** restart your iPhone. ✅ Syncing continues without opening the app.
- **Day 5:** in KROK, open **Claude → Disconnect**. Ask Claude a health question. ✅ It can no longer read your data. Reconnect it (a new link is created).

## Second tester (long Apple Watch history)
- Record how long the first sync took, how many workouts there are, and how many had their detailed data (heart rate, route) uploaded: ______
- ✅ The phone didn't get hot or drain unusually (note the battery % before and after the first sync).

## Last step (only when everything above passed)
- In the app: **••• → Delete All My Data**. ✅ The app returns to the welcome screen, and Claude/ChatGPT can no longer read anything.
