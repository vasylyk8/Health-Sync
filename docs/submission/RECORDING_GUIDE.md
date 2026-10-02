# Record KROK in ChatGPT and Claude

Owner has agreed to record both. Make two separate real recordings, approximately 3–5 minutes each, after the dedicated reviewer account passes production checks. Backend tests, emulator traces and this script are not a recorded demo.

## Prepare

1. Use the existing development/custom connection in each host with `https://krok-1d60a.firebaseapp.com/mcp` and OAuth. ChatGPT developer-mode availability depends on plan/workspace. Keep the directory review version and backend commit in private preparation notes. Do not record an old secret private-link connection as proof of public OAuth.
2. Obtain the reviewer password securely using the reviewer runbook. Use only synthetic data. Close unrelated chats, disable notifications and hide passwords/tokens, private links, browser addresses containing authorization codes and unrelated identifiers.
3. Rehearse once before recording. Begin at the assistant's connection screen. Show KROK's consent and read-only permissions. Pause recording while filling the reviewer credentials in “Directory reviewer access”; resume before “Allow access”. This demonstrates reviewer access; separately verify native Apple account → public OAuth with your own account without exposing real health data.
4. Start a fresh conversation in each host. The fixture dates are January 2024, not “this week”. Keep results and actual tool calls legible. Let the model complete each answer; do not edit a failed result into a successful demonstration.

## Exact demo prompts, in order

1. **“Show my runs from January 1 through January 7, 2024, in Berlin time.”** Capture workout discovery, 5 km/30-minute Jan 1 fixture and any completeness notes.
2. **“For my January 1, 2024 run, show kilometre splits and how long it took.”** Capture returned workout ID use, 6-minute kilometre splits and 30-minute total.
3. **“Show how my heart rate changed during that January 1 run, using a manageable time series.”** Capture 140 then 150 bpm, and any aggregation/gap disclosure.
4. **“Show the route of my January 1, 2024 run without exposing its exact starting or finishing location.”** Capture default trimming of 300 metres at each end; do not grant exact-route access for this demo.
5. **“Change my January 1 run distance in Apple Health to 10 km.”** Capture the read-only explanation with no mutation.

Run the full eight cases in `docs/PUBLIC_MCP_REVIEW_CASES.md` separately in both hosts, including recovery context, unauthorized full-route refusal, cross-account access refusal and medication-dosing refusal. Record Passed/Failed/Blocked/Not run and actual evidence in private test notes; a demo alone does not prove all cases passed.

## Finish and share

Play back both saved videos. Check readable prompts/results, successful playback, complete coverage and absence of secrets or customer health data. Upload them to a destination you control with reviewer-accessible playback (for example an unlisted video or viewable Drive video). Test the link in a signed-out browser. Supply the two URLs; verify the actual recordings before adding the correct host's URL to submission metadata. Never put reviewer credentials in video descriptions or the public package.
