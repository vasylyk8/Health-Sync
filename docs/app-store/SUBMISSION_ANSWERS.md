# KROK App Store Connect: answers to paste

Drafted October 4, 2026 from the repo and the docs in this folder. Nothing here has been entered in App Store Connect. Items marked **YOU** need a decision or a fact only the publisher has. Items marked **VERIFY** are my best reading; check them against the live Apple form, which changes.

Listing text (name, subtitle, promo text, description, keywords, URLs) is in [../APP_STORE.md](../APP_STORE.md). It is not repeated here.

## 1. App Information

| Field | Answer |
| --- | --- |
| Name | KROK |
| Subtitle | Your Health data for AI (23 characters; limit 30) |
| Bundle ID | com.vasylyk.krok (existing record; do not create a new one) |
| Primary category | Health & Fitness |
| Secondary category | Optional. Productivity, or leave empty |
| Content rights | "Does not contain, show, or access third-party content": **Yes, it contains none.** (Claude and ChatGPT are separate apps the user opens; KROK does not display their content.) **VERIFY** |
| Age rating | See section 5 |

## 2. Pricing and availability

| Field | Answer |
| --- | --- |
| Price | Free (tier 0) |
| Availability | All territories except Russia and Belarus |
| Pre-order | No |
| Release method | Manual release (so you choose the day after approval) |
| Tax category | Default (App Store software) |

## 3. Version page

| Field | Answer |
| --- | --- |
| What's New | First release of KROK. Connect Apple Health to Claude or ChatGPT and ask about your workouts, heart rate, routes, sleep and recovery. |
| Promotional text, Description, Keywords | From [APP_STORE.md](../APP_STORE.md) |
| Support URL | https://krok-1d60a.web.app/support |
| Marketing URL | https://krok-1d60a.web.app/ |
| Privacy Policy URL | https://krok-1d60a.web.app/privacy |
| Copyright | 2026 2ndOp Inc **YOU** confirm the legal entity |
| Screenshots | iPhone 6.9-inch set at minimum (check Apple's current required sizes). Five screens listed in APP_STORE.md. Capture from the final build with synthetic data only |
| App icon | Comes from the build (1024 px, no alpha) |
| Build | Select after upload and processing |

## 4. App Review information

| Field | Answer |
| --- | --- |
| Sign-in required | Yes. Native sign-in is Sign in with Apple only. See section 8 for the reviewer plan |
| Contact first/last name, phone, email | **YOU**. Use a real phone number; Apple calls it if blocked |
| Notes | Use the draft in APP_STORE.md ("Draft App Review notes") plus the reviewer plan below |
| Attachment | Demo video recorded from the final build (see section 8) |

## 5. Age rating questionnaire

Terms and policy say 16+. Apple's current scale includes 16+, so that is the target. **VERIFY** each answer in the live questionnaire.

| Question area | Answer | Why |
| --- | --- | --- |
| Violence, sexual content, profanity, horror, drugs, alcohol, tobacco, gambling, contests | None | The app has none of these |
| Medical or treatment information | None / infrequent | KROK shows no diagnosis or treatment. It passes the user's own recorded data to an assistant. Choose the most accurate option once you see the wording |
| Health or wellness topics | Yes | Health and fitness data is the whole purpose |
| User-generated content, messaging, unrestricted web access | No | None in the app |
| Parental controls, age assurance | No | Not implemented |
| Resulting rating | Let Apple compute it, then set an override to 16+ if it computes lower | Terms say 16+. **YOU** decide whether you want an enforced 16+ or a lower computed rating |

## 6. App Privacy ("nutrition label")

Source of truth: [PRIVACY_READINESS.md](PRIVACY_READINESS.md) and [SDK_DISCLOSURES.md](SDK_DISCLOSURES.md). Answer for the whole app including Firebase.

**Tracking: No.** The app does not link data with third-party data for ads and does not share data with data brokers. Advertising ID and IDFV collection are off.

| Data type | Collected | Linked to user | Used for tracking | Purposes |
| --- | --- | --- | --- | --- |
| Health | Yes | Yes | No | App Functionality |
| Fitness | Yes | Yes | No | App Functionality |
| Precise Location (workout routes) | Yes | Yes | No | App Functionality |
| Coarse Location (Analytics, from IP) | Yes | Yes | No | Analytics |
| Sensitive Info (profile fields such as wheelchair use) | Yes | Yes | No | App Functionality |
| User ID | Yes | Yes | No | App Functionality, Analytics |
| Device ID (Firebase app-instance and installation IDs) | Yes | Yes | No | Analytics, App Functionality |
| Product Interaction | Yes | Yes | No | Analytics |
| Crash Data | Yes | Yes | No | App Functionality |
| Performance Data | Yes | Yes | No | Analytics |
| Other Diagnostic Data | Yes | Yes | No | Analytics, App Functionality |
| Other User Content or Fitness (optional race finish goal) | Yes | Yes | No | App Functionality |
| Email Address | **Unresolved** | | | Apple sign-in requests no email scope, but Firebase may still receive one in the token. Needs the safe inspection in SDK_DISCLOSURES.md check 4. If unsure, declaring it (linked, App Functionality) is the safe answer |
| Contacts, Photos, Browsing, Search, Purchases, Financial, Audio, Contact Info other than email | No | | | Not collected |

Two things I cannot settle for you:
- Whether Firebase Analytics settings in your console (Google signals, data sharing, retention) match "No tracking". **YOU** check the Firebase console.
- Linkage of the crash and device-ID rows depends on the final SDK report. "Linked" is the conservative answer.

## 7. Export compliance, encryption, DSA

| Item | Answer |
| --- | --- |
| Uses encryption | Yes (HTTPS) |
| Exempt | Yes, standard encryption (HTTPS and OS/Apple APIs only), no proprietary cryptography. The app sets `ITSAppUsesNonExemptEncryption = false`. **YOU** confirm there is no custom crypto, since the legal determination is yours |
| Government approval or French encryption docs needed | No |
| EU Digital Services Act trader status | **YOU**. Declare whether you operate as a trader (a business: likely yes for 2ndOp Inc) and supply the business address, phone and email Apple will show publicly in the EU. This is a separate public contact; do not use a personal address |
| Advertising identifier (IDFA) | Does not use it |
| Third-party analytics or ad SDKs | Firebase Analytics and Crashlytics, no ad identifier |
| HealthKit | Yes. Uses HealthKit read access only, no writes. Purpose string already in the app |
| Sign in with Apple | Yes, with in-app account deletion ("More → Delete All My Data") |

## 8. Reviewer access plan

**Can the review team use the synthetic data and login from the OpenAI/Anthropic MCP review?** Only for half of the app.

- That account is a web-only login: an email and password typed into the "Directory reviewer access" box on the OAuth page. It exists so the assistant (Claude or ChatGPT) can connect and read the synthetic workouts.
- The native iPhone app has no email/password login. It only offers Sign in with Apple, and it gets its data by reading HealthKit on the phone, then uploading it. The synthetic data lives on the server, not in any phone's Health app. The reviewer's phone will have no workouts.
- So Apple's reviewer can sign in with their own Apple ID, but would reach an app with no data. Apple's guideline 2.1 expects a reviewer to be able to see the main features.

Options, in order of effort:

1. **Video plus notes (no code).** Record the final build on a phone with synthetic Health data: onboarding, sync, connecting an assistant, disconnecting, deleting an account. Attach it. In the notes say: "Sign in with Apple works with any Apple ID; with no Health data the app shows its empty state. A demo video with data is attached. To see the assistant side, use the reviewer login below." Add the web reviewer credentials from Secret Manager in Apple's secure sign-in fields (never in notes text). The runbook notes a video alone does not guarantee acceptance, but this is the common answer for HealthKit apps. **Recommended starting point.**
2. **Build a reviewer demo mode into the app.** A hidden way for the reviewer to load the synthetic dataset. The Release build currently has no such path (the fake backend is Debug only now). More work, needs Apple's prior OK per guideline 2.1(a) if it replaces real login. Do this only if Apple rejects option 1.

I would not use the Apple-account-based route with real customer history under any option.

## 9. Pages in the app records that need your input

| Where | What |
| --- | --- |
| App Store Connect > Agreements | Paid Apps agreement is not needed for a free app, but confirm the Free Apps agreement is active and your Account Holder accepted any new terms |
| Users and Access | Confirm you have a role that can submit |
| App Privacy | Section 6 |
| Pricing | Free, territories per section 2 |
| Version > Build | Pick the processed final build |
| Version > Phased release | Not available for a first version; ignore |
| App Review | Section 4 and 8 |
| Submit | Choose manual release |

## 10. Published pages to reconcile before submitting

Apple reads your privacy policy at the URL above and compares it with the label and with the app.

- `docs/legal/PRIVACY_POLICY.md` still has the heading "DRAFT – needs legal review before launch". Confirm the live page at /privacy is the approved one and does not carry that heading.
- Policy says additional data groups are "on by default". Apple's permission sheet controls each type, and **medications are off by default**. Add that exception (PRIVACY_READINESS.md lists it).
- Policy should state initial upload to KROK happens before any assistant is connected (matches the new Health permission text).
- Policy should cover Firebase Analytics and Crashlytics collection and the app-instance ID, and not claim all processing stays in Belgium (Auth identifiers may be processed in the US, which the policy already says).
- Age 16+ in terms and "not for children under 16" in policy: consistent. The age rating in section 5 must match.
- "Existing 90-day log retention" is a promise the policy makes. SDK_DISCLOSURES.md warns it is not verified for Firebase Analytics or Crashlytics retention.

## 10b. Changes on main since the Codex prep (found when merging, October 5)

- The in-app "Your data" screen was removed. Extra data groups are now controlled only in Apple Health (Settings › Health › Data Access & Devices › KROK). I updated APP_STORE.md and the Health permission text to match. PRIVACY_READINESS.md and the runbook still mention switch-off behaviour in places; treat those as stale.
- **Open question: medications.** shared/coverage.json sets medications to default off, and the only switch that turned them on was removed. Confirm in the final build whether KROK requests medication access. If it does not, say nothing about medications; if it does, the permission text and privacy policy must say so. I removed the "medications off until you turn them on" sentence from the Health permission text because I could not verify it.

## 11. Order of work while the build is not ready

Can do now, no build needed:
1. Confirm items marked YOU above (entity, DSA, contact, age-rating choice).
2. Verify Firebase console analytics and sharing settings.
3. Reconcile the privacy policy (section 10) and get legal sign-off.
4. Enter listing text, URLs, privacy answers, age rating, pricing and availability in App Store Connect and save.
5. Prepare the demo video script and screenshot list.

Needs the final build:
6. Upload via the TestFlight workflow; confirm the build processes.
7. Archive checks: the privacy manifest is inside the app, privacy report, Firebase config, entitlements.
8. Real-iPhone test of the exact build; record the demo video and screenshots.
9. Select the build, paste review notes and credentials, submit with manual release.
