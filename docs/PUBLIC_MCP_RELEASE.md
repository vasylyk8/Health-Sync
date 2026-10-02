# Public MCP release — implementation and approval gates

Publisher: **2ndOp Inc**. Apple bundle: `com.vasylyk.krok`; team: `AAZHPDPD2B`.
Free at this release; subscriptions and billing are deliberately not implemented.
Target countries: all platform-supported countries except **RU** and **BY**.

## Architecture implemented in this PR

Keep the existing Firebase backend and Hosting site. No additional auth vendor or hosting account is required. Use `https://krok-1d60a.firebaseapp.com/mcp` as the canonical public OAuth resource, with authorization and same-origin Firebase auth helpers on that host. This new endpoint is **not deployed by this PR**.

Native Sign in with Apple links the current Firebase anonymous UID rather than creating a separate health-data owner. An already-used Apple account can be restored only before Health onboarding, with an empty local outbox and no uploaded dataset. An active account conflict leaves the current dataset unchanged. Existing private MCP links remain supported.

Public assistants use dynamic public-client registration, authorization-code/PKCE S256, resource binding, explicit browser consent, opaque hashed credentials, 15-minute access tokens, rotating refresh tokens, replay revocation and a 30-day absolute authorization lifetime. Cookie binding uses `__session`, the only cookie forwarded by Firebase Hosting rewrites. Disconnect invalidates all grants for that assistant; deletion invalidates access immediately and removes credentials outside the user's subtree.

All 17 health tools have explicit scope checks, structured outputs and read-only/non-destructive/closed-world annotations. The separate `get_account` tool returns only an opaque account ID, avoiding collision with the health `get_profile` tool. Sensitive events and profile permissions are excluded from default scopes. Precise route endpoints require a separate unchecked consent option and an explicit tool request. Phone category switches continue to apply independently of OAuth permission.

## Sequential approval and shipping checklist

1. Review and approve the PR, including privacy changes and the draft terms in `docs/legal/TERMS_OF_SERVICE.md`. Existing legal documents remain drafts for publisher/legal approval; no agent can make legal attestations for 2ndOp Inc.
2. Require green **server-ci**, **ios-ci**, **qa-ios** and **apple-auth-preflight** checks for the final commit. CI artifacts contain simulator screenshots, browser screenshots/traces and test results. QA findings that are recorded rather than asserted must be reviewed separately from the green status.
3. After explicit approval, merge and deploy through the existing Firebase workflow. Deployment is separate from TestFlight upload. This PR does not perform either action. Verify live `.well-known/oauth-authorization-server`, `.well-known/oauth-protected-resource/mcp`, `/register`, `/authorize`, `/token`, `/revoke`, `/connect`, and `/mcp` through Firebase Hosting, including forwarding of `__session`, no-store responses and the trusted proxy/IP behavior.
4. After deployment, approve a signed TestFlight build using the existing workflow. It now verifies the Sign in with Apple entitlement before upload. Test one real Apple account end to end: existing anonymous UID survives linking, web login matches that UID, assistant consent succeeds, disconnect stops access, and deletion revokes Apple authorization and removes data. Apple credentials and production callback behavior cannot be genuinely exercised by synthetic accounts or an undeployed branch.
5. Provision a **separate** synthetic reviewer account, not the monitoring account or a customer's account. It must have the administrator-set `krokReviewer` claim and a password login. Verify all review cases, then put credentials only in the platforms' secure review fields. Password login is rejected for ordinary accounts. Do not commit reviewer credentials or place them in a public ZIP.
   The guarded script is `firebase/functions/scripts/prepare-reviewer.mjs`. Supply `GCP_PROJECT_ID`, `KROK_REVIEWER_EMAIL`, and `KROK_REVIEWER_PASSWORD` (20+ characters) securely. Running it without `--apply` is a dry-run; `--apply` creates/rotates only the dedicated `krok-reviewer-directory` synthetic account and uploads fixtures. It refuses to overwrite customer or monitoring accounts. Production execution requires separate approval and credentials; it has not been run against production here.
6. Finalize and publish approved terms; verify the public website, support, privacy and terms URLs without login. The repository already contains a small Firebase Hosting website and support page, so no new website account is needed. The existing GitHub privacy page is not updated automatically by Firebase deployment; reconcile its text or choose the updated Hosting privacy URL explicitly.
7. Check current platform health-data policies and eligibility; complete business/developer and domain verification as required by each portal. Capture a **real** assistant walkthrough of the deployed version, host the recording for reviewers, and execute the five positive/three negative cases in `docs/PUBLIC_MCP_REVIEW_CASES.md`. Local protocol tests are not evidence of host/model behavior. No recording or saved directory draft is claimed here.
8. Only after those checks, prepare the platform-specific upload and submit separately to OpenAI and Anthropic. Select all supported countries except Russia/Belarus; disclose that KROK is free and that future subscriptions are not present. Directory review and approval are external decisions, not automatic effects of making `/mcp` public.

## Setup and reference URLs

- [Apple identifiers](https://developer.apple.com/account/resources/identifiers/list) and [keys](https://developer.apple.com/account/resources/authkeys/list)
- [Firebase authentication settings](https://console.firebase.google.com/project/krok-1d60a/authentication/providers)
- [GitHub PR and checks](https://github.com/vasylyk8/Health-Sync/pull/28)
- [GitHub workflows](https://github.com/vasylyk8/Health-Sync/actions)
- [OpenAI Apps SDK documentation](https://developers.openai.com/apps-sdk/) and [submission guidelines](https://developers.openai.com/apps-sdk/app-submission-guidelines)
- [Anthropic MCP documentation](https://docs.claude.com/en/docs/mcp)

Platform documentation could not be fetched from this restricted execution environment (OpenAI returned HTTP 403), so those links are references, not a claim of verified current submission requirements. Do not assume OpenAI and Claude use the same package format or review process.

## Verification boundaries

Two pre-existing ingestion regression tests were repaired, not suppressed: post-publication cleanup can be retried without double-publishing, and completeness is conservatively withheld while any of the account's accepted uploads remain in the incoming bucket. The latter uses one bounded (`maxResults=1`) lookup per tool; another account's uploads do not affect it. This is a snapshot of accepted server uploads, not a guarantee about records still only on the phone or future uploads.

Unit/HTTP tests exercise PKCE, code reuse, client/resource/callback binding, consent origins and cookies, reviewer restrictions, scopes, expiry, rotation, replay, account generation/deletion and revocation. Firestore emulator tests exercise actual transactions, TTL timestamps, concurrent refresh replay, disconnect/deletion cleanup and client rules. Browser tests use real Chromium, real Firebase SDK/password login and the local Auth emulator; they do not fake a successful Apple login. iOS tests use injected backends and system simulator UI; they do not automate a person's Apple account authorization.

The read-only preflight uses GitHub secrets within GitHub Actions, validates key format/integrity, confirms the supplied bundle/team IDs, and reads the enabled Firebase Apple provider and Services ID. It does not reveal secret values or prove that Apple's live redirect exchange will succeed. Tests cannot establish the absence of every bug.
