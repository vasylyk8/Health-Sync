# Reviewer instructions (paste into each portal's credentials / notes field)

Credentials live only in Secret Manager (`krok-directory-reviewer-credentials`, project `krok-1d60a`). Paste them into the portal's private fields below; never commit them. Replace `<EMAIL>` and `<PASSWORD>` when pasting.

Rules every portal checks: the login works first try, has no MFA, confirmation code, Apple Account or private-network step, and the account is already populated. Do not rotate the password during a review (rotation revokes the reviewers' sessions).

## Why earlier submissions were rejected
The credentials fields held nothing (or only an Apple ID note), the reviewer form was collapsed on the connect page, and the iOS app required an Apple Account and Apple Health data. All three are fixed in code; see the checklist at the bottom.

## OpenAI plugin directory / Claude connector directory / Muse (same text)
```
KROK is a read-only connector for a user's own Apple Health workout data. A test account with sample data is ready; no iPhone, Apple Account or verification code is needed.

Test account
  Email:    <EMAIL>
  Password: <PASSWORD>

Steps
1. Add KROK (https://krok-1d60a.firebaseapp.com/mcp) and start the connection. A KROK page opens.
2. On that page, ignore "Sign in with Apple". Under "Reviewing KROK? Use the test account", enter the email and password above and press "Sign in with test account".
3. Press "Allow access". You return to the assistant, connected.

Sample data covers January 2024 (timezone Europe/Berlin). Ask about dates in that range, for example:
- "Show my runs from January 1 through January 7, 2024."
- "For my January 1, 2024 run, show kilometre splits."
- "Compare my resting heart rate and steps across January 1-7, 2024."
Questions about "this week" or "today" return nothing because the sample data is from 2024.

The account is shared by reviewers and stays connected for the whole review. All tools are read-only.
```

## App Store Connect: App Review Information
Sign-in required: Yes. User name `<EMAIL>`, Password `<PASSWORD>`. Notes (see `docs/APP_STORE.md` for the full text):
```
No Apple Account or Apple Health data is needed to review KROK.
1. On the first screen, tap "App Review sign-in" (below the Connect button).
2. Enter the test email and password above. The app opens Home with the sample account's data; Apple Health is not read in this mode.
3. To see the connector, tap Claude or ChatGPT on Home and follow the steps. On the KROK web page that opens, use the test account at the bottom (not Apple) and tap Allow access.
Normal users connect Apple Health and sign in with Apple; the review mode only replaces those two steps.
```

## Before submitting (owner checklist)
- Run the `reviewer-provision` workflow (manual dispatch, reuse mode) so the account, claim, data and `lastVisibleAt` are current; it also runs verify after each deploy on main.
- Clean browser: start a connection from claude.ai and ChatGPT, confirm the test account form is visible without expanding anything, and the 3-step flow above works exactly as written.
- Fresh iPhone or simulator with no Apple Account signed in: "App Review sign-in" reaches Home.
- Paste the blocks above into the portals' private credential fields.
- Open items that can still cause rejection: OpenAI's health-data eligibility, the App Store URL placeholder, and the Apple web sign-in branding (see `PLATFORM_REQUIREMENTS.md`).
