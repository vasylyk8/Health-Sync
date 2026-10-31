# Reply to App Review: Guideline 2.1 Information Needed (iOS 1.0)

Apple did not find a bug. It asked for six pieces of information plus a screen recording. Paste the reply below in App Store Connect (App Review → the submission → Reply), attach the recording or include its link, and paste the same text into **App Review Information → Notes**. The Notes field takes at most 4,000 characters, and this text fits.

Replace `<VIDEO LINK>` before sending. Test credentials stay in the Sign-in fields, not in this text.

---

## Text to paste

```
Hello, here is the requested information.

1. SCREEN RECORDING
<VIDEO LINK>
The video was recorded on a physical iPhone running the latest iOS. It starts with launching KROK and shows: connecting Apple Health (the Health permission sheet), Sign in with Apple (account creation and login), the first upload, connecting Claude and asking a question about a workout, and account deletion (••• menu → Delete All My Data → confirm). Deletion removes the account and its server data and revokes Sign in with Apple. KROK has no user-generated content, no paid content and no in-app purchases.

2. PURPOSE AND AUDIENCE
KROK is for people who record workouts with Apple Watch or iPhone (runners, cyclists and other athletes) and want to ask an AI assistant about their own training. Apple Health has the data, but people cannot ask questions about it in plain language, such as "How long was I in heart rate zone 4 on yesterday's run?" or "What was my fastest 5K this year?". KROK copies the user's workouts and daily recovery summaries from Apple Health, read-only, to a private EU server. The user then connects Claude or ChatGPT, which can answer those questions with exact calculations on the real data. KROK is free, has no ads, and never sells data or uses it for advertising.

3. HOW TO ACCESS THE MAIN FEATURES
No Apple Account or Apple Health data is needed. Use the test account in the Sign-in Information fields.
a) On the first screen, tap "App Review sign-in" (below the Connect button).
b) Enter the test email and password. Home opens with the sample account's data. Apple Health is not read in this mode and nothing is uploaded.
c) To see the AI connection, tap Claude on Home and follow the steps. On the KROK web page that opens, use the test account at the bottom of the page (not Sign in with Apple) and tap Allow access. Then add the connector on claude.ai (a free account works) and ask, for example: "Show my runs from January 1 through January 7, 2024." The sample data is from January 2024.
Regular users tap Connect to Apple Health, allow access, and Sign in with Apple. Review mode replaces only those two steps. In review mode the ••• menu shows "Exit review mode" instead of deletion, so the shared test account stays intact. The recording shows deletion with a regular account.

4. EXTERNAL SERVICES
- Apple HealthKit: the source of the data (read-only; KROK never writes to Health).
- Sign in with Apple: authentication.
- Google Firebase / Google Cloud (region europe-west1, Belgium): Authentication, Cloud Functions, Firestore, Cloud Storage, App Check with App Attest, Crashlytics (crash reports) and Analytics (product usage, never health values).
- Anthropic Claude and OpenAI ChatGPT: the AI assistants. The user connects them explicitly through OAuth, using the open Model Context Protocol (MCP), after a consent screen that names the recipient. KROK does not send data to any AI service on its own. The assistant reads data only when the user asks a question, and access stops as soon as the user disconnects.
- No payment processors: the app is free with no purchases.

5. REGIONAL DIFFERENCES
The app works the same in all regions. Claude and ChatGPT are available only in the countries their providers support, and ChatGPT custom connectors need a paid ChatGPT plan with Developer Mode. Those limits come from the AI providers, not from KROK.

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
KROK is a general fitness and wellness app, not a medical device. It does not diagnose, treat or give medical advice, and the assistants are told to describe data and trends only. It uses no protected third-party content. Health data is used only to provide the service, is stored encrypted in the EU (not in iCloud), and is deleted on request or after one year of inactivity. Privacy policy: https://krok-1d60a.web.app/privacy

Thank you.
```

---

## Recording checklist (owner, before replying)

Apple rejects recordings from a simulator or ones that don't start at launch. Use a **physical iPhone on the latest iOS release** and the **App Store review build (1.0)** installed through TestFlight.

1. Turn on Do Not Disturb and start Screen Recording from Control Center while on the Home Screen.
2. Tap the KROK icon (a fresh install, so the Welcome screen shows).
3. Tap **Connect to Apple Health** → the Health sheet → Allow.
4. **Sign in with Apple** on the account page (this is registration and login).
5. Let the upload screen run for a few seconds, then go to Home.
6. Tap **Claude** → go through the consent and connect steps → show Claude answering one workout question (for example, splits for a recent run).
7. Back in KROK: **••• → Delete All My Data → confirm** → Sign in with Apple re-authentication → the app returns to the Welcome screen.
8. Optional, about 20 s: on Welcome, tap **App Review sign-in**, sign in with the test account, and show Home.

Privacy: use an Apple ID and iPhone with little or no real health data, or a test Apple ID. Don't show the test password, private links or authorization codes in the address bar. Keep the video under about 3 minutes. Attach the file to the reply, or upload it unlisted (YouTube unlisted, or a Drive link open to "anyone with the link") and test the link in a signed-out browser.

## Before you press Submit
- Run the `reviewer-provision` workflow so the test account and sample data are current.
- Check that the Sign-in Information fields hold the current test email and password, with "Sign-in required" ticked.
- Do not rotate the reviewer password while the review is open.
