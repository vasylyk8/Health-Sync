# Real-phone test (3–5 days, about 5 minutes a day)

Automated tests can't reproduce real Apple Watch data or background syncing over days. This checklist can. You and your second tester each follow it on your own iPhone, using the TestFlight build.

Write down anything odd, with the time it happened, and send it to me. I'll fix it and send a new TestFlight build.

## Day 1: setup (about 20 minutes)
1. Install **TestFlight** from the App Store, open the invite email and install **KROK**.
2. Open the app and tap **Connect to Apple Health**. On Apple's screen tap **Turn On All**, then **Allow**.
3. ✅ The home screen shows "Syncing your history…" with a percentage.
4. Leave the app open (screen on) until the percentage reaches 100% or stops moving. Note how long it took: ______.
5. ✅ You see "Synced … ago" and "History synced back to <month year>". Does that month match when you started using your iPhone or Watch? ______
6. Tap **Claude**, tap **Continue**, then follow the three steps on claude.ai. When you finish, the app should show **✓ Set up** within a minute.
7. Tap **ChatGPT** and do the same on chatgpt.com (needs Plus). ✅ **✓ Set up**.
8. In Claude, ask each of these and compare with the Apple Health app:
   - "How many steps did I take yesterday?" (Health app → Steps → D)
   - "How did I sleep last night?" (Health app → Sleep)
   - "What was my average resting heart rate last month?" (Health app → Resting Heart Rate → M)
   - "List my workouts from last week."
   - "What's my step trend over the past 3 years, by month?"
   ✅ The numbers match (small differences on today's partial data are OK).
9. Ask the same three questions in ChatGPT. ✅ They match.

## Days 2–5: normal life (about 5 minutes a day)
- Use your phone normally. **Don't** open KROK unless a step says so.
- Each evening, ask Claude: "How many steps did I take today, and when was my data last synced?"
  ✅ The data is at most a few hours old (it syncs in the background when iOS allows).
- **Day 2:** in the Health app, add a manual weight entry, then delete another old manual entry (or add one and delete it). Next day, ask Claude about your weight. ✅ The new entry is there and the deleted one is gone.
- **Day 3:** turn on Airplane Mode for a few hours while walking. Turn it off. ✅ That evening the steps show up.
- **Day 3:** swipe KROK away in the app switcher (force-quit). Next day, ask Claude about today's steps. ✅ Claude says the data may be stale and suggests opening the app. Open the app → ✅ fresh again.
- **Day 4:** restart your iPhone. ✅ Syncing continues without opening the app.
- **Day 5:** in KROK, open **Claude → Disconnect**. Ask Claude a health question. ✅ It can no longer read your data. Reconnect it (a new link is created).

## Second tester (long Apple Watch history)
- Record how long the first sync took and roughly how many years of history there are: ______
- ✅ The phone didn't get hot or drain unusually (note the battery % before and after the first sync).

## Last step (only when everything above passed)
- In the app: **••• → Delete All My Data**. ✅ The app returns to the welcome screen, and Claude/ChatGPT can no longer read anything.
