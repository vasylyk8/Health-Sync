# KROK App Store materials

Prepared October 3, 2026. Draft for the first public iPhone release; the final build is not ready. No Apple metadata was saved by this preparation. See the [release plan](app-store/RELEASE_PLAN.md), [privacy audit](app-store/PRIVACY_READINESS.md) and [Apple reviewer runbook](app-store/REVIEWER_RUNBOOK.md).

## Listing fields

| Field | Proposed value | Status |
| --- | --- | --- |
| Name | KROK | Confirm saved record/name in Apple |
| Subtitle | Your Health data for AI | Draft, within 30 characters |
| Category | Health & Fitness | Proposed; optional secondary Productivity |
| Price | Free | Existing release intent; confirm saved price schedule |
| Availability | All supported storefronts except Russia and Belarus | Existing intent; enumerate Apple's actual territories before saving |
| Age rating | Complete the current questionnaire and reconcile age-16 eligibility | Do not reuse the old blanket “None” answers |
| Support URL | https://krok-1d60a.web.app/support | Public text retrieved; fresh check required before submission |
| Privacy Policy URL | https://krok-1d60a.web.app/privacy | Public text retrieved; reconciliation open |
| Marketing URL | https://krok-1d60a.web.app/ | Optional; verify final launch content |
| Copyright | 2026 2ndOp Inc | Confirm publishing entity |
| Support email | support@2ndopinions.ai | Matches current public pages |

Seller name comes from Apple's account. Publisher must confirm the legal entity, agreements and EU DSA trader status/contact information in Apple's secure fields. Do not reuse former personal contact details in public marketing copy.

## Promotional text

Ask Claude or ChatGPT about your workouts, heart rate, routes, sleep and recovery using the Apple Health data you choose to share.

## Description

KROK connects your Apple Health data to Claude or ChatGPT so you can ask questions about your training and recovery.

Ask questions such as:
• What were the kilometre splits in my latest run?
• How much time did I spend in each heart rate zone?
• How did I sleep before my longest workout?
• How has my training load changed over six weeks?

WORKOUTS AND RECOVERY
Read Apple's recorded workout summaries and available measurements such as heart rate, speed, power and cadence. Explore GPS routes, sleep, activity and recovery summaries. Available detail depends on what your devices and apps recorded and what you allow KROK to read. Incomplete data is identified in tool results.

HOW IT WORKS
1. Connect Apple Health and choose the data types KROK may read.
2. Sign in with Apple and let your data sync to KROK.
3. Connect your assistant and approve its read-only access.
4. Ask questions in Claude or ChatGPT.

YOUR DATA, YOUR CHOICES
KROK never changes your Apple Health records. Apple Health lets you allow or deny individual types. You can change those choices any time in Settings › Health › Data Access & Devices › KROK. KROK has no separate in-app switch per group; Delete All My Data removes everything already on KROK's servers.

KROK stores the data you allow on its servers before you connect an assistant. Public OAuth routes hide their first and last 300 metres by default; exact endpoints require separate permission and an explicit request. Existing private-link connections use a different authorization model.

Disconnect an assistant or delete your KROK account and server data from the app. Deletion does not change Apple Health or remove information an assistant already received. Your health data is not sold or used for advertising.

REQUIREMENTS
An iPhone running iOS 17 or later and an Apple Account are required. Claude or ChatGPT is a separate service with its own account, availability, terms and plan requirements. Custom ChatGPT connections require developer mode on an eligible plan. Check KROK's connection instructions for the supported setup.

KROK is free at this release. It is not a medical device and does not provide diagnosis, treatment or medical advice. Consult a qualified healthcare professional before making medical decisions.

## Keywords

apple health,claude,chatgpt,workout,running,heart rate,gps,fitness,sleep,recovery,export,mcp

## Screenshots and icon

Use PR30 branding and the existing 1024-pixel app icon. Capture the final release candidate using synthetic data and current native screens:

1. Welcome: “Your Apple Health, meet your AI.”
2. Synced home: workouts and recovery ready for your assistant.
3. Apple-linked assistant setup: approve read-only access.
4. Connect Claude or ChatGPT: the four-step setup.
5. Account/privacy controls: disconnect or delete.

UI tests already capture Welcome, Account, Home, medal screens and Apple OAuth setup. They also capture legacy private-link screens: do not use these to represent new-user OAuth onboarding. Simulator selection is dynamic; inspect actual image sizes against Apple's current requirements. The old fixed 6.9-inch claim was not verified. No real health records, private links or unsupported medical claims.

## Draft App Review notes

KROK is an iPhone health and fitness data app. It reads the Apple Health types a user permits and syncs them to KROK's backend so assistants explicitly connected by that user can answer questions about workouts and recovery. It does not write to HealthKit. Its health outbox is excluded from backup. It is not a medical device and provides no diagnosis or treatment.

New-user flow: Connect to Apple Health → Sign in with Apple → upload/home → select Claude or ChatGPT → add the public MCP endpoint using OAuth → approve read-only permissions. Sync starts after Health permission is granted, while the Apple account page is shown. The assistant must authorize the same Apple-linked KROK account.

Core data includes workouts, recorded measurements, routes and daily/hourly activity and recovery summaries. Additional groups are nutrition/alcohol, heart alerts/lung function, glucose/insulin/blood pressure, mood/symptoms, menstrual cycle and profile. Apple Health controls permission per type, and KROK has no separate in-app group switch. [VERIFY before pasting: whether medications are requested at all in the final build; shared/coverage.json defaults them to off, but the in-app switch that enabled them was removed.] Clinical records, pregnancy/contraception data, clinical questionnaires and ECG waveforms are not requested.

The authorization page identifies the assistant and its requested permissions. Allow access is explicit. Public OAuth exact route endpoints require a separate unchecked consent option and an explicit tool request. Disconnect revokes assistant access. More → Delete All My Data initiates account deletion, revokes Apple authorization for linked accounts, cuts connector access and queues server erasure. Apple Health records are unchanged. Legacy private links remain available to existing accounts and have different scope restrictions.

Before pasting: add the successfully rehearsed native review route, secure access details if applicable and review contact from the [reviewer runbook](app-store/REVIEWER_RUNBOOK.md). These notes alone are insufficient to submit. Directory credentials do not sign into the native app.

## Privacy, age rating and export compliance

Finalize App Privacy answers using [PRIVACY_READINESS.md](app-store/PRIVACY_READINESS.md), the [Firebase inventory](app-store/SDK_DISCLOSURES.md), and the exact release archive/SDK configuration. The old claims that crash data is unlinked and no contact data is collected are not established. Privacy labels and privacy manifests are separate requirements.

Complete the current rating questionnaire honestly, including health/wellness/medical content where applicable. Resolve the terms' age-16 eligibility through Apple's supported rating/override options; do not invent a rating before inspecting the current portal.

ITSAppUsesNonExemptEncryption = false is configured. Publisher must verify qualifying exempt encryption and complete Apple's export questions; the setting alone is not a legal determination.
