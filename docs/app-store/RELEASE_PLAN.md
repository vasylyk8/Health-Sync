# KROK App Store release plan and readiness

Prepared October 3, 2026, America/Toronto. User approved preparation steps 1–5 and stated the final build is not ready. Testing, submission and release remain later gates. This work initiated no remote workflow, provisioning change, Apple write or deployment. Subsequent technical work is recorded below.

## Evidence

Workspace source: commit 19a19e124c5fa16efb9965baa937c0b493c2f310. Remote main observed: e8cebd7a17804821cc1c97f614f9026e5cb0d7be. Read-only comparison changes only HealthKitSource.swift, SyncEngine.swift and BatchTests.swift; audited consent/account/metadata/SDK/workflow files are unchanged between these commits. Re-audit the final release commit.

| Evidence | Observation | Limit |
| --- | --- | --- |
| [TestFlight 37150222240](https://github.com/vasylyk8/Health-Sync/actions/runs/37150222240) | Upload actually ran; missing-secrets branch skipped; logs report Xcode 26.6 and successful App Store Connect upload | Existing build; final build and processed details/testers not verified |
| [Apple preflight 37149031253](https://github.com/vasylyk8/Health-Sync/actions/runs/37149031253) | Apple provider/key checks passed; native App ID and Sign in with Apple capability verified | Does not exercise real Apple login, establish membership expiry/agreements or seller identity |
| [iOS CI 37150222279](https://github.com/vasylyk8/Health-Sync/actions/runs/37150222279) | GitHub reports success for observed main | Does not replace final real-phone tests |
| Owner-confirmed identity in preflight | com.vasylyk.krok; team AAZHPDPD2B | Numeric Apple app ID/saved listing not retrieved |
| Public privacy/support/instructions | Readable text retrieved October 3 | Extractor reports cached results; no fresh HTTP/header/device/mailbox check claimed |

Environment has no Apple secrets or outbound account identity. Tool discovery found no connected App Store Connect management tool. Upload evidence supports an existing record and working CI access: do not create a duplicate or replacement bundle ID. Direct portal verification and saved metadata remain pending.

## Approved sequence

1. Apple setup: evidence collected; direct checks pending. Confirm existing record's numeric Apple ID, bundle/team, seller, membership, agreements, roles and EU trader verification. Confirm free pricing and territories excluding RU/BY against actual Apple storefronts. Do not request signing keys in chat or create replacement credentials because this environment lacks them.
2. Readiness audit: completed for inspected source; unresolved gates in [PRIVACY_READINESS.md](PRIVACY_READINESS.md). This is not final-build certification.
3. Listing: draft prepared in [APP_STORE.md](../APP_STORE.md), correcting outdated onboarding, medication-default, age-rating and contact wording. Final screenshots wait for stable UI.
4. Privacy/legal: reconciliation worksheet prepared; SDK/provider facts and legal attestations remain open. Update approved legal sources and deployed pages consistently, then verify. Published text alone does not prove legal approval.
5. Apple review: runbook prepared in [REVIEWER_RUNBOOK.md](REVIEWER_RUNBOOK.md); native review route and rehearsal remain open. No review account was provisioned and no customer data changed.
6. Final build: waiting. Record exact SHA/version/build/backend revision. Run required iOS/server checks and Apple preflight. Archive with Xcode 26+/iOS 26+ SDK (recheck requirements), inspect manifests/config/entitlements and upload via existing TestFlight automation. Confirm processing/export answers and testers. External testing may require Beta App Review.
7. Real-iPhone testing: waiting. Update [RELEASE_SOAK.md](../RELEASE_SOAK.md) to current Apple-linked OAuth/defaults. Two testers run 3–5 days: long history, denied permissions/empty data, background/offline/retry, restoration, both assistants, named consent, route hiding/separate exact-route permission, sensitive scopes, disconnect and deletion/Apple revocation. Record Pass/Fail/Blocked and fix/retest affected cases.
8. App Review: waiting for readiness and launch approval. Freeze copy/screenshots; choose exact tested build; verify reviewer access, live URLs/backend, accurate labels, rating/export forms, legal/account fields and territories. Present a concrete submission summary. With authorization select manual release and submit; handle review questions/rejections and retest changed binaries.
9. Release: waiting for Apple approval and launch authorization. Release manually and verify listing/install/onboarding/sign-in/sync/assistant access, crashes and server errors. Prepare then replace public “App Store link coming soon” controls with verified Apple URL; avoid a circular install path during review. Do not assume phased release is available for an initial version.

## Submission blockers

| ID | Blocker | Closure evidence |
| --- | --- | --- |
| B1 | Final build not ready | Release candidate identified; checks and real-phone results pass |
| B2 | Manifest added locally; archive/report verification pending | Run final macOS build, inspect bundled app/SDK manifests and privacy report |
| B3 | SDK inventory drafted; final SDK/console and AI handling unresolved | [SDK inventory](SDK_DISCLOSURES.md), actual SDK linkage/provider protections, finalized labels/policy |
| B4 | Native reviewer route untested | Full app access with usable data; Apple-approved demo alternative if applicable |
| B5 | Legal text diverges from implementation | Medication-off exception, upload/sharing, routes, age and deletion reconciled |
| B6 | Account/portal attestations not inspected directly | Existing record, seller, membership, agreements, DSA, contact, price/territories verified |
| B7 | Final listing/screenshots/forms absent | Accurate final metadata, accepted image sizes, no placeholders |

## Apple requirements checked

Public text retrieved October 3, reported cached; recheck before upload/submission:

- [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/): Xcode 26+/iOS 26+ SDK uploads since April 28, 2026; updated rating questionnaire since January 31, 2026; EU trader requirements; approved reasons for designated APIs. SDK minimum does not require raising iOS 17 deployment target.
- [Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): 2.1 final completeness/reviewer access; 2.3 truthful metadata; 5.1.1 policy, permissions, minimization, deletion and equal third-party protections; 5.1.2(i) explicit third-party AI disclosure/permission; 5.1.3 health-data restrictions including advertising/data mining and iCloud.
- [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/): include SDK practices; route trimming does not undo precise-location collection; pseudonymous account IDs still link data.

## Owner inputs pending

Confirm existing App Store Connect record's Apple ID/URL, publishing entity and membership/account status through non-secret information or supported access. Existing record is supported by upload evidence. Final-build timing remains open. Publisher completes legal declarations and eventual launch authorization.

## Technical follow-up authorized by “Go”

Added app privacy manifest and explicit resources configuration; removed missing-Firebase synthetic fallback and restricted synthetic launch modes/UI sign-in controls to Debug. Selected Analytics without ad-ID support, disabled IDFV and ad-personalization signals, and prepared [SDK_DISCLOSURES.md](SDK_DISCLOSURES.md). Added source/exported-app validation before TestFlight upload plus a read-only CI workflow. Eight validator tests pass locally; native launch tests were added but require macOS CI. No final archive, native test outcome, upload, portal edit or deployment is claimed. Legal/account/reviewer/final-build gates remain open.
