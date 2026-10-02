# Dedicated synthetic reviewer — preparation runbook

The dedicated production account and fixtures were created by Actions run 37005037317. Credentials are in `krok-directory-reviewer-credentials` in the KROK project's Secret Manager. Production login is blocked by the disabled password provider; no global provider setting was changed. Keep the email/password and exact login instructions only in secure reviewer fields and private secret storage, not in the public package.

## Provision and verify

1. Use the confirmed `krok-1d60a` project and an authorized admin identity. Verify Firebase email/password sign-in is enabled for the review flow; do not assume Admin SDK user creation enables the provider. Ordinary password users do not receive access through this path: it requires the dedicated `krokReviewer` claim.
2. `scripts/tasks/provision-directory-reviewer.py --apply` reuses credentials from Secret Manager, completes fixtures, then runs the production verifier. It never changes provider settings. `prepare-reviewer.mjs --apply --reuse --reseed` refreshes synthetic fixtures while preserving passwords and grants. Omitting `--reuse` deliberately rotates credentials and invalidates previous grants. Passwords stay in subprocess environments; never command arguments, logs, artifacts or the package. Cloud writes are limited to the named secret and dedicated synthetic account/fixtures. The script refuses customer/monitor replacement and accounts undergoing deletion.
3. Wait for all fixture ingestion. Verify workout discovery, 360-second/km splits, heart-rate series, daily context and trimmed routes against `scripts/synthetic/data.mjs`. Missing data is a failure, not permission to invent expected values.
4. In a clean browser, begin real OAuth from each host, open “Directory reviewer access”, sign in and approve ordinary read-only scopes. Confirm no MFA/mailbox/phone/private-network dependency. Check wrong password refusal, no cross-account access, exact-route refusal without consent, cancellation, disconnect/revocation and password rotation invalidating previous grants.
5. Enter the tested credentials and exact host sign-in instructions only in secure reviewer fields. Keep the account available throughout review. Rotation revokes prior grants; update secure review fields and rerun cases before rotating during review.

Owner secret access: [Google Secret Manager for KROK](https://console.cloud.google.com/security/secret-manager?project=krok-1d60a). A secret existing does not prove the login/provider or dataset works. Do not mark reviewer access complete until the clean-browser and real-host checks pass.

The verifier captures its synthetic callback locally instead of sending it to an assistant. It tests production browser login, PKCE, default-scope refusals, every tool, refresh rotation and revocation, and saves only check names/status. This is a production protocol rehearsal; actual saved-version ChatGPT/Claude host cases remain separate.
