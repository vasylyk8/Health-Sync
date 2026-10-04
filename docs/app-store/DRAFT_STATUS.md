# App Store Connect draft status

Verified through Apple's App Store Connect API on 2026-10-04.

- App: https://appstoreconnect.apple.com/apps/6817135913/distribution
- Version: 1.0 (`dde5aebf-f8c7-4ef9-95ed-32da0fe8b637`)
- State: `PREPARE_FOR_SUBMISSION`
- Release: manual
- Existing name: `KROK: Sync Apple Health to AI`
- Subtitle: `Your Health data for AI`
- Saved and read back: description, keywords, promotional text, support URL,
  marketing URL, subtitle and privacy policy URL.
- Bare `KROK` was rejected as already used by another account. Owner's proposed
  `KROK: Sync Apple Health with AI` has 31 characters, exceeding Apple's 30-character
  limit; replacement choice is pending.

No build was selected or uploaded by this draft operation. No submission was
created. Privacy declarations, pricing/territories, review contacts,
reviewer credentials, legal declarations and EU trader details were not changed.

The age-rating questionnaire was subsequently saved and verified, with
`ageRatingOverrideV2: SIXTEEN_PLUS`. Apple's legacy `appStoreAgeRating` reports
`SEVENTEEN_PLUS`; confirm the displayed rating in the current portal.
See QUESTIONNAIRE_ANSWERS.md for the saved answers and remaining privacy/export steps.

Draft operation: https://github.com/vasylyk8/Health-Sync/actions/runs/37206887677

This isolated branch contains only draft tooling and public listing payload:
https://github.com/vasylyk8/Health-Sync/tree/codex/app-store-draft-20261004

The workflow artifact `app-store-draft-readback` contains before/after public
listing metadata. Credentials are supplied by existing CI secrets and are not
included in artifacts or logs.

Latest checked main-branch iOS CI and TestFlight upload both succeeded for commit
`2922efabd7b78026b6ec0e8664ce4d88078fb4a0`. This does not establish that the final
release build is ready, or validate unpushed local release-readiness changes.

Before submission: finalize the build, provide screenshots and workable native
reviewer access, reconcile the privacy policy, confirm Firebase collection and
tracking settings, complete truthful privacy/age/encryption declarations, and
provide business review/trader contact details. A video and web reviewer account
can supplement review but do not ensure reviewers can exercise native features.
