# Firebase data disclosure inventory

Technical follow-up, October 3, 2026. Inspected the repository and official Apple/Firebase/Google documentation. Public-document extraction reported cached content. No customer tokens, keys or production data were read. No Firebase console settings were changed.

## Changes made

- App privacy manifest added at ios/HealthSync/Resources/PrivacyInfo.xcprivacy and explicitly included in XcodeGen resources. It declares KROK's direct account-linked Health, Fitness, Precise Location, Sensitive Info, User ID, Product Interaction and Performance Data, with functionality/analytics purposes and no tracking.
- UserDefaults reason CA92.1 covers app-only preferences (onboarding, consent, race goals, upload retries). SystemBootTime reason 35F9.1 covers elapsed sync timing and progress estimates. Only elapsed durations are sent; raw system uptime is not sent. Reasons must be revisited if API uses change.
- FirebaseAnalytics changed to FirebaseAnalyticsWithoutAdIdSupport. This product exists in Firebase's 11.0.0 Package.swift, the project's lower version bound. Swift imports remain FirebaseAnalytics. GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED and GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS are false.
- Product analytics and crash diagnostics remain active. Removing ad-ID support/vendor-ID collection does not remove app-instance or crash-installation identifiers, coarse location derived from IP, SDK events, or all provider-side advertising/data-sharing configuration. Console integrations/data sharing still need verification.
- Invalid Firebase configuration now produces a startup-unavailable screen before model creation, HealthKit observation or sync. Debug UI/benchmark arguments explicitly select synthetic sources; Release ignores them. UI-test Apple sign-in controls are compiled only in Debug.
- Health permission wording now explicitly distinguishes initial uploads to KROK from later authorized AI access, and states medications start off. Legal-page reconciliation remains open.
- TestFlight source manifest check and exported-app guard added. The guard validates bundled resources, identity/project, minimum SDK/Xcode, privacy flags and public URLs before upload. Existing entitlement checks remain.

These are local changes, not a built/uploaded/released binary. The current project allows Firebase 11.x from 11.0.0 and has no checked-in Package.resolved; exact SDK/transitive versions and archive privacy report remain final-build evidence. No blanket “all SDK manifests verified” claim is made. Google Analytics documentation says its SDK does not include a manifest; its collection must still be represented accurately in App Store privacy answers.

## Linked products and transitive collection

| Product | Repository use and documented collection | Disclosure implications |
| --- | --- | --- |
| FirebaseCore | Configure Firebase; docs report no direct data collection | Firebase user-agent information appears in other services; does not make the whole SDK stack data-free |
| FirebaseAuth | Anonymous UID and Sign in with Apple; identifiers always generated/stored; federated responses can contain email/contact claims | User ID collected/linked for functionality. Email is conditional: empty Apple requestedScopes does not prove Firebase receives no email |
| FirebaseAppCheck | App Attest in production; debug provider for debug/simulator; documented attestation/assertion objects and Firebase user agent | Describe security processing; inspect exact SDK/report to map identifiers or other diagnostic data. App does not use reCAPTCHA or DeviceCheck providers |
| FirebaseFunctions | Authenticated function calls including account/product events; documented function invocation metadata/IP | App functionality and account-linked events. Provider/network logging is separate from the app's custom no-health-value log contract |
| FirebaseStorage | Account-scoped uploads; documented Firebase user agent | KROK's uploaded health/location data is direct collection regardless of SDK user-agent linkage |
| FirebaseAnalyticsWithoutAdIdSupport | Custom events plus automatically measured lifecycle/screen/session events, app-instance ID and general location from masked IP | Product Interaction, Device ID/app-instance identifier, Coarse Location and applicable diagnostics. No automatic exemption because KROK has no ads; inspect console settings and current Apple taxonomy |
| FirebaseCrashlytics | Stack traces, app state, device/OS data, nonfatal domain/code; Analytics integration can supply breadcrumbs | Crash Data and identifiers/usage as actually collected. Do not classify all crashes as unlinked merely because setUserID is absent |
| FirebaseInstallations / FirebaseSessions / GoogleDataTransport / GoogleUtilities | Resolve the actual graph; docs describe installation-related data, session background timestamps/network/app metadata and SDK cache/dropped-event performance | Include actual transitive SDK collection. FirebasePerformance/Firestore/Messaging SDKs are not direct dependencies; do not automatically apply their full disclosures |

## Concrete App Privacy updates

Add Coarse Location to the worksheet because Google documents general-location derivation from masked IP. Keep Precise Location separately for raw workout routes. Treat app-instance/installation IDs as identifiers; determine linkage from the final SDK/report rather than assuming anonymous means unlinked. Retain account-linked product interactions and sync durations. Evaluate Other Diagnostic Data for device/OS/session/transport quality information.

Sensitive Info is declared for enabled profile fields such as wheelchair/disability information; health measurements/medications remain Health as appropriate to Apple's definitions. Race goals are fitness data. SDK-only categories are documented here and in the privacy worksheet; the app's manifest describes direct KROK collection, while SDKs supply their own required manifests where applicable. App Store labels must cover the complete combined practice even when an SDK omits a manifest.

## Required final checks

1. Save resolved SDK versions/dependency graph from the final build; inspect app and SDK manifests and generate Xcode's privacy report.
2. Verify bundled plist flags and no-ad-ID product, runtime collection and identifiers on a test device. App-instance identifiers and general IP-based location may remain.
3. Inspect Analytics Google signals, ads account links/key-event export and data-sharing settings. Verify actual provider terms and retention; this follow-up made no console changes.
4. Inspect federated identity claim handling safely to determine email collection; never log tokens or customer profiles.
5. Reconcile privacy policy with SDK collection, Analytics breadcrumbs/category-toggle event names and SDK-specific retention/geography. Existing 90-day server-log policy must not be presented as verified Firebase Analytics/Crashlytics retention.
6. Complete App Store privacy answers and publisher/legal sign-off. Run native tests and actual archive guard before submission.

## Validation

Local source manifest validation and eight exported-bundle tests passed, covering missing/malformed plists, wrong backend/app identity, old SDK/Xcode, advertising flags, missing API reasons and unlinked health declarations. Shell syntax and diff whitespace checks passed. Swift tests for launch policy were added; no Xcode/Swift toolchain is available in this Linux workspace, so native compilation, Swift tests and simulator/device checks were not run here. New read-only CI workflow runs manifest/validator tests when changes reach GitHub; it has not been dispatched by this task.

## Sources

- [Apple privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files), [required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [data-use declarations](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests).
- [Firebase Apple data collection](https://firebase.google.com/docs/ios/app-store-data-collection).
- [Google Analytics Apple disclosure](https://support.google.com/analytics/answer/10285841).
- [Analytics collection controls](https://firebase.google.com/docs/analytics/configure-data-collection).
- [Firebase 11.0.0 package products](https://github.com/firebase/firebase-ios-sdk/blob/11.0.0/Package.swift).

Apple's current rendered API-key pages were retrieved, but public text extraction omitted the per-value reason table. CA92.1/35F9.1 should be checked against the current Xcode/Apple reason list as part of final archive review. Apple's general requirement and the reason meanings were cross-checked with [Donny Wals' manifest guide](https://www.donnywals.com/how-to-add-a-privacy-manifest-file-to-your-app-for-required-reason-api-usage/) and public reason references; this does not replace Apple upload validation.
