# Health Sync — Setup checklist (do this once, before the build)

Time needed: about 1–2 hours of clicking, plus waiting for Apple/Google where noted.
You don't need a Mac or any coding. When a step says "copy X", paste it into a note: you'll need it in step C.

Screens at Apple/Google change occasionally. If a button has moved, look for the same words nearby.

---

## A. Apple (needs the **Account Holder** or an **Admin** of your company's Apple Developer account)

1. **Accept agreements.** Go to https://appstoreconnect.apple.com → *Business* (or *Agreements, Tax, and Banking*). If anything says "Review" or "Accept", accept it. Nothing can be uploaded while an agreement is pending.

2. **Pick the app's ID.** Choose a bundle ID like `com.yourcompany.healthsync` (lowercase, no spaces). Write it down as **BUNDLE_ID**.

3. **Register the App ID with the right permissions.** Go to https://developer.apple.com/account/resources/identifiers → **+** → *App IDs* → *App* → Continue.
   - Description: `Health Sync`. Bundle ID: *Explicit*, and paste **BUNDLE_ID**.
   - In *Capabilities*, tick **HealthKit** (if it offers "Background Delivery", tick that too) and **App Attest**.
   - Continue → Register.

4. **Create the app in App Store Connect.** https://appstoreconnect.apple.com → *Apps* → **+** → *New App*.
   - Platform: iOS. Name: `Health Sync` (if it's taken, try `Health Sync for AI` or another name and tell me). Language: English (U.S.). Bundle ID: choose **BUNDLE_ID**. SKU: `healthsync`. Access: Full access.
   - Copy the **Apple ID** number shown under *App Information* as **ASC_APP_ID**.

5. **Create an API key for automation.** App Store Connect → *Users and Access* → *Integrations* → *App Store Connect API* → *Team Keys* → **+**.
   - Name: `Health Sync CI`. Access: **Admin** (needed for Apple's cloud-managed signing; the automation never creates, downloads or revokes certificates).
   - Download the `.p8` file (you can only download it **once**). Copy the **Key ID** and the **Issuer ID** (shown above the list).

6. **Certificates: nothing to do.** Release builds use Apple's cloud-managed signing, so no new certificate is created and existing ones (e.g. Sniped's) are never touched.

7. **Testers.** Make sure you and your second tester both appear in App Store Connect → *Users and Access* with any role (e.g. *Developer* or *Marketing*), and have accepted the invite email. Only people listed there can be internal TestFlight testers, and their access must include this app ("All apps" or KROK). Otherwise Apple answers "Tester(s) cannot be assigned". Copy both Apple ID emails.

8. **Team ID.** https://developer.apple.com/account → *Membership details* → copy the **Team ID** (10 characters).

9. **Store information** (I'll use this for the App Store listing). Reply to me with:
   - Company legal name and address as it should appear, a support email, and a support website (any page with a contact email is fine).
   - Are you a "trader" under the EU Digital Services Act? (If the company sells anything commercially, the answer is usually yes.)

## B. Google / Firebase

1. Go to https://console.firebase.google.com → **Create a project**. Name it `health-sync` (Google may add a suffix). Turn **off** Google Analytics for the project creation step if asked (we add the app's analytics later ourselves). Copy the **Project ID** (shown under the name, e.g. `health-sync-4f2a1`) as **PROJECT_ID**.
2. In the project, bottom-left → **Upgrade** → choose **Blaze (pay as you go)** and link a billing account/card.
3. **Budget alert:** https://console.cloud.google.com/billing → your billing account → *Budgets & alerts* → *Create budget*. Scope: the `health-sync` project. Amount: **$100** per month. Alert thresholds: **50%, 90%, 100%**. Email alerts to billing admins (you). Save.
4. **Run the setup script.** Open https://shell.cloud.google.com (a browser terminal, where you may need to click "Authorize"). Paste these two lines, replacing `PROJECT_ID`:
   ```
   curl -fsSLO https://raw.githubusercontent.com/vasylyk8/Health-Sync/claude/youthful-planck-k7ff0m/scripts/gcp-bootstrap.sh
   bash gcp-bootstrap.sh PROJECT_ID
   ```
   It takes about 5 minutes and ends with a box of 4 values. Copy them. If it prints **ERROR** or **WARNING**, send me the whole output.

## C. GitHub secrets

Go to https://github.com/vasylyk8/Health-Sync/settings/secrets/actions → **New repository secret**, once per row:

| Name | Value |
|---|---|
| `GCP_PROJECT_ID` | from B4 |
| `GCP_WIF_PROVIDER` | from B4 |
| `GCP_DEPLOY_SA` | from B4 |
| `GCP_RUNTIME_SA` | from B4 |
| `APPLE_TEAM_ID` | from A8 |
| `BUNDLE_ID` | from A2 |
| `ASC_APP_ID` | from A4 |
| `ASC_KEY_ID` | from A5 |
| `ASC_ISSUER_ID` | from A5 |
| `ASC_KEY_P8` | open the `.p8` file in TextEdit/Notepad and paste **everything**, including the `BEGIN`/`END` lines |
| `TESTER_EMAILS` | both Apple ID emails from A7, comma-separated |
| `ALERT_EMAIL` | where alerts should go |
| `ANTHROPIC_API_KEY` | https://console.anthropic.com → API Keys → Create. Under *Limits*, set a monthly spend limit of ~$10. |
| `OPENAI_API_KEY` | https://platform.openai.com/api-keys → Create. Under *Limits*, set a monthly budget of ~$10. |

Also check https://github.com/vasylyk8/Health-Sync/settings/actions shows **Allow all actions**.

## D. For the final test (later, not needed now)

- You: a Claude account (Free is fine) and a **ChatGPT Plus** account.
- Your second tester: an iPhone with a long Apple Watch history, plus TestFlight installed.

## E. Tell me "go"

Send me a message saying **go**, plus the store info from A9. I'll run an automatic check of everything above first. If anything is missing, I'll tell you exactly what before building further.
