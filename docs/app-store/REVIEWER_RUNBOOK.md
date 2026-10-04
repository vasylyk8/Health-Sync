# KROK Apple reviewer preparation

October 3, 2026. Draft route/tests only; native reviewer access was not provisioned or executed. Directory reviewer fixtures validate web OAuth/MCP. Those credentials do not sign into the native app.

## Resolve native review access

Apple Guideline 2.1 requires complete app access. Native KROK needs Sign in with Apple and reads the phone's HealthKit data. A web password review account does not bypass this. Do not share personal Apple Accounts or customer history.

Resolve with the final build: a documented review experience with synthetic workouts/recovery so Apple can inspect native screens, sync states, data controls and assistant access. If using built-in demo mode instead of a demo account due to legal/security obligations, obtain Apple's prior approval per 2.1(a); disclose it and expose all relevant functionality. UI-test launch arguments are not an approved production demo.

Alternatively, prove a real sign-in path works on a fresh phone/account with no existing Health history and allows full review. A supplementary video does not automatically replace usable app access. Implementation of review access remains future work.

## Packet status

| Item | Status |
| --- | --- |
| Final version/build/SHA | Waiting for final build |
| Apple numeric app ID | Not retrieved |
| Native route with usable synthetic data | Unimplemented/untested |
| Secure access details if needed | Not supplied; secure Apple fields only |
| Review contact name/email/phone | Publisher to provide privately |
| Final-build native-app video | Not recorded |
| Assistant setup/plan eligibility | Must be rehearsed; do not assume directories are live |
| Backend/public URLs | Prior evidence exists; fresh final checks pending |

## Rehearsal

Record Pass/Fail/Blocked/Not run, build/SHA, device/iOS, time and non-secret evidence. All cases are Not run for the final Apple release.

1. Fresh install: initial server-upload disclosure, workout-only permission, denied additional types and empty Health data.
2. Apple sign-in: new account, cancellation/network failure, account restoration and browser-account mismatch.
3. Sync: summary/detail completeness, long history, offline retry and real-phone background behavior.
4. Claude: supported public OAuth with same Apple Account; named recipient/scopes, Cancel/Allow access; known-fixture workout and split questions.
5. ChatGPT: independent actual-host test on eligible account/plan with developer mode if custom setup needs it.
6. Routes: default endpoint hiding; request alone cannot grant exact permission; separate consent plus request; legacy links tested separately.
7. Extra groups: actual defaults including medications off; denied Health permissions; switch-off server erasure and scope restrictions; explain fitness purpose.
8. Read-only/health limits: mutation, diagnosis and medication-dosing requests; KROK tools must not mutate or give medical recommendations. External host responses have their own behavior/terms.
9. Disconnect: each assistant revoked independently; subsequent data calls refused; reconnect needs approval.
10. Delete account: More → Delete All My Data, Apple reauth/revocation, immediate cutoff, server/Firebase account purge, local reset and reinstall. Test cancellation/offline/retry on disposable synthetic/test account only.

Actual iPhone/assistant-host execution is required. Callback interception and simulator fakes are engineering evidence, not completion of these cases.

## Final review notes

Start with [APP_STORE.md](../APP_STORE.md), then add the exact rehearsed native route, synthetic-data instructions, assistant setup and review contact. Enter credentials only in dedicated secure fields. Describe external-account/plan requirements truthfully; do not require reviewer personal Health history.

Do not paste unfinished placeholders, private links/passwords or circular “install from the coming-soon App Store link” instructions. Supplementary video uses final build and synthetic data without tokens/private links.

Keep backend/reviewer access working throughout review. If access details change, update secure fields and repeat rehearsal. Submit only after final-build gates and concrete release approval.
