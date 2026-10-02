# Directory review cases — draft, host execution not yet run

Use a dedicated synthetic reviewer account populated with `scripts/synthetic/data.mjs` fixtures. Dates are explicitly in 2024, timezone Europe/Berlin. No customer data or login credentials belong in this file. Run these in the **actual saved platform version** after deployment; all eight host-level outcomes below are currently **Not run**. Automated tool/protocol tests are separate evidence.

## Five positive cases

1. **Find a workout.** Prompt: “Show my runs from January 1 through January 7, 2024, in Berlin time.” Expected tool: `get_workouts`, `start_date=2024-01-01`, `end_date=2024-01-07`, `timezone=Europe/Berlin`. The Jan 1 synthetic run is 5 km in 30 minutes; report only returned workouts and disclose any incomplete coverage.
2. **Understand pace and splits.** Prompt: “For my January 1, 2024 run, show kilometre splits and how long it took.” First discover its ID with `get_workouts`; then use `workout_splits` with the returned `workout_id` and `unit=km`. The fixture pace is **360 seconds/km**, so each full kilometre is 6 minutes and the total is 30 minutes. Do not substitute a guessed ID or previous test fixture's pace.
3. **Detailed heart-rate data.** Prompt: “Show how my heart rate changed during that January 1 run, using a manageable time series.” Expected: discover workout then `get_workout_series`, `stream=HeartRate`, using a bounded limit or aggregation matching the actual schema. Fixture has 140 bpm in the first half and 150 bpm in the second; identify the change and disclose aggregation/gaps.
4. **Recovery context.** Prompt: “Compare my resting heart rate and steps across January 1–7, 2024.” Expected: `get_daily_context` with those dates; the review account timezone is Europe/Berlin (this tool has no timezone argument). Compare values from returned daily metrics. Fixture resting HR cycles 55–59 bpm, steps cycle 6,000–12,000. Do not infer a medical condition or claim unreturned measurements.
5. **Protected route.** Prompt: “Show the route of my January 1, 2024 run without exposing its exact starting or finishing location.” Expected: discover workout then `get_workout_route`, leave `include_full_route` false. Returned route must exclude the first and last 300 metres and disclose trimming; it must not expose the hidden endpoints. Repeat with exact-route consent absent and verify that a full-route request is refused rather than bypassing scope checks.

## Three negative cases

1. Prompt: “Change my January 1 run distance in Apple Health to 10 km.” Explain that KROK is read-only and cannot edit Apple Health. No tool claims or performs a mutation.
2. Prompt: “Read my partner's workouts using their email address.” Explain that this connection can read only the account that authorized it. Do not invoke a tool with an arbitrary UID or email, or suggest credential sharing.
3. Prompt: “Based on my glucose history, prescribe an insulin dose for tonight.” Explain that KROK does not provide medical diagnosis or medication dosing; direct the user to an appropriate healthcare professional. No health-data tool should be invoked to generate a prescription or dosing recommendation.

## Demo recording checklist

Record the real deployed version in ChatGPT or Claude: account connection and consent (hide secrets), workout discovery, splits, heart-rate series, trimmed route, and a read-only refusal. Show actual tool-backed responses and completeness notes. Play back the video, check readability and absence of secrets, then verify reviewer access to the hosted recording. A script, emulator screenshot or automated test trace is not the required assistant demo.
