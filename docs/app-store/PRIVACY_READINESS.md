# KROK privacy and submission readiness audit

October 3, 2026. Source-based preparation; no final archive or final-build real-phone test was inspected. Baseline and newer-main comparison are in [RELEASE_PLAN.md](RELEASE_PLAN.md). Technical follow-up added the manifest and production startup/upload checks. Native compilation and final archive verification remain pending; see [SDK disclosures](SDK_DISCLOSURES.md).

## Findings

| Finding | Evidence | Required resolution |
| --- | --- | --- |
| App privacy manifest added; archive verification pending | PrivacyInfo.xcprivacy declares app data, CA92.1 app-only defaults and 35F9.1 elapsed timing; explicit resources entry and upload guard added | Verify actual archived inclusion and combined SDK report. SDK declarations do not cover app code |
| SDK inventory prepared; final linkage/console settings pending | [SDK_DISCLOSURES.md](SDK_DISCLOSURES.md) records official collection; Analytics now without ad-ID support, IDFV and ad-personalization disabled | Inspect resolved versions, automatic events/IDs/retention and provider console settings. Do not claim crash data is unlinked |
| Medication default misstated | coverage.json medications.default=false; medication request follows enablement | Correct policy/HealthKit assessment's general “on by default” heading with explicit medication exception |
| Upload precedes AI connection; permission wording corrected | Sync starts after Health permission while account screen appears; revised purpose string explicitly states server upload before assistant authorization and medications off | Verify final Health permission sheet and reconcile onboarding/legal pages with the same distinction |
| Third-party AI protections unresolved | Named assistant, displayed permissions and explicit Allow access; policy defers provider retention/processing to own terms | Verify actual provider terms/settings for health-data training/data mining and equal protection under 5.1.1(i). Consent alone does not establish compliance |
| Broad groups mostly enabled | coverage categories include nutrition/alcohol, heart, devices, mood/symptoms, cycle and profile | Justify each type's concrete health/fitness purpose; test denial/off behavior; do not change launch scope silently |
| OAuth differs from private links | SetupSheet branches by Apple account; consent has unchecked full-route option | Verify public exact route consent plus explicit request and legacy link limits; do not imply scopes apply to every link |
| Account deletion exists in source | AppModel Apple reauth/revocation; beginDeletion cuts access; purgeUserData removes records/credentials/Firebase Auth user | Test real-device cancellation/fail/retry, Apple revocation and production purge. “Delete All My Data” deletes the account, not only health rows |
| Outbox excluded from backup | Outbox sets isExcludedFromBackup=true | Check actual device paths and other health caches before making blanket no-iCloud claim |
| Age-16 eligibility conflicts with old rating advice | Terms 16+; policy not intended under 16; old draft blanket None | Complete current questionnaire and resolve Apple's supported age/rating options; Health date of birth is not an implemented eligibility gate |
| Retention/region promises need evidence | Policy promises 24-hour erasure, one-year inactivity purge, 90-day events/logs and EU health storage | Verify deployed schedules/regions/processors/backups/retries/SDK retention; distinguish recipient copies already sent |
| Native reviewer route missing | Native Apple sign-in only; password reviewer access is on web OAuth | Prove native route with usable data; directory credentials are insufficient |
| Production fake fallback removed; native verification pending | Invalid config prevents model/HealthKit sync startup; Debug-only synthetic modes; exported-app identity/config gate | Run native launch tests and validate the actual exported binary |

These are gates/reconciliation findings, not an Apple rejection. HealthKit sharing with general AI assistants needs compliant handling and a health-management justification. Medical disclaimers alone do not settle it.

## App Privacy worksheet

Linked includes account/device/pseudonymous IDs. Proposed No tracking depends on verifying all SDK/provider practices. Select all actual purposes; App Privacy labels and app/SDK privacy manifests are distinct.

| Apple data type | Proposed collection/linkage | Purpose/evidence | Verification needed |
| --- | --- | --- | --- |
| Health | Yes; linked | App Functionality; recovery/health measurements/events under UID | Enabled types and recipient handling; health records are not automatically all Sensitive Info |
| Fitness | Yes; linked | App Functionality; workouts/activity/measurements | Derived fields and goals |
| Precise Location | Yes; linked | App Functionality; stored raw workout routes | Output trimming does not remove collection |
| User ID | Yes; linked | Functionality; Firebase UID/Apple identifier; analytics linkage | Include Analytics where identifiers serve measurement |
| Product Interaction | Yes; linked | Analytics; account-scoped events and FirebaseAnalytics | SDK automatic events/identifiers |
| Performance Data | Candidate | Sync/tool timing and SDK diagnostics; purposes depend on use | Map event timing versus diagnostic duration accurately |
| Crash Data | Yes; linkage unresolved | App Functionality; Crashlytics/nonfatal errors | Installation/device identifiers and retention |
| Device ID | SDK app-instance/installation identifiers collected; final linkage to confirm | Analytics/Crashlytics/security as used | Check combined report and actual SDK behavior; disabling ad-ID/IDFV does not remove these IDs |
| Coarse Location | Yes via Analytics; final linkage to confirm | Analytics derives general location from masked IP | Include separately from workout Precise Location; verify actual settings/report |
| Other Diagnostic Data | Candidate | SDK device/OS/session/transport quality information | Map resolved SDK payloads to current Apple taxonomy |
| Email Address | Unresolved | Apple requestedScopes empty; Firebase/token claims may still be processed | No-request does not prove no-collection; inspect safely without logging tokens |
| Sensitive Info | Candidate; scope-dependent | Profile includes wheelchair use/sex and sensitive groups | Apply Apple's exact definitions (e.g. disability); do not blanket-classify health |
| Other User Content / applicable fitness type | Candidate | Optional race finish goal/name/date stored per account | Map to current taxonomy and actual uses |
| Customer Support | Evaluate | Public email may receive identifiers/user-supplied data | Apply Apple's optional-disclosure criteria to actual support practices |

No ads, purchases, contacts, photo/audio or browsing collection was observed in app source; this is not a negative attestation for all SDKs. Synthetic directory-review email does not mean ordinary customers use password login.

## Legal reconciliation

- State medications off by default; other groups depend on Apple per-type grants and app settings.
- Explain initial uploads to KROK and later explicit per-assistant disclosure.
- Reconcile OAuth exact-route consent and legacy private-link restrictions throughout policy.
- Describe account deletion, immediate access cutoff, asynchronous purge and existing AI copies.
- Cover Firebase SDK collection, uses, regions and retention; do not imply every processor/type stays only in Belgium.
- Verify third-party AI protections, model-training/data-mining behavior and Apple health-data restrictions.
- Align age-16 terms/app eligibility/rating.
- Validate erasure/inactivity/log commitments and backups.
- Record publisher/legal resolution and deploy approved source/page changes together. Published documents do not establish sign-off.

## Final archive and device checks

Record SHA/build and resolved SDK versions. Inspect generated privacy report and bundled app/SDK manifests. Verify GoogleService-Info.plist, production endpoint, App Attest, HealthKit/background delivery, Apple sign-in and backup exclusion. Exercise consent/disconnect/account deletion on the exact proposed binary.

Sources: [Apple privacy details](https://developer.apple.com/app-store/app-privacy-details/), [Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [requirements](https://developer.apple.com/news/upcoming-requirements/). Retrieved text reported cached. Repository evidence: ios/project.yml; AppModel.swift; HealthSyncApp.swift; FirebaseBackend.swift; FirebaseTelemetry.swift; AppleSignIn.swift; Consent.swift; Outbox.swift; shared/coverage.json; firebase/functions/src/account.ts; firebase/hosting/connect.html.

Technical verification details and remaining SDK/console checks: [SDK_DISCLOSURES.md](SDK_DISCLOSURES.md).
