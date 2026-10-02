# Dedicated synthetic reviewer — preparation runbook

Production access is not yet provisioned or verified. The default UID is reserved for the reviewer and separate from the production monitor. Choose a reserved-domain synthetic email identifier; it must not require a real inbox or delivery. Keep email/password and login instructions only in the secure platform reviewer fields and private secret storage, not in the public package.

## Provision and verify

1. Use the confirmed `krok-1d60a` project and an authorized admin identity. Verify Firebase email/password sign-in is enabled for the review flow; do not assume Admin SDK user creation enables the provider. Ordinary password users do not receive access through this path: it requires the dedicated `krokReviewer` claim.
2. Generate a random password of at least 20 characters and store it in Google Secret Manager, with access limited to the publisher/admin. Pass it to `firebase/functions/scripts/prepare-reviewer.mjs` via `KROK_REVIEWER_PASSWORD`; never pass it as a command-line argument or print it. Use `GCP_PROJECT_ID`, `KROK_REVIEWER_EMAIL` and `KROK_REVIEWER_UID` through the environment. Dry-run is the default; `--apply` writes only the dedicated account and synthetic fixtures. The script refuses to replace customer accounts or the monitor and rejects an account undergoing deletion.
3. Wait for all fixture ingestion. Verify workout discovery, 360-second/km splits, heart-rate series, daily context and trimmed routes against `scripts/synthetic/data.mjs`. Missing data is a failure, not permission to invent expected values.
4. In a clean browser, begin real OAuth from each host, open “Directory reviewer access”, sign in and approve ordinary read-only scopes. Confirm no MFA/mailbox/phone/private-network dependency. Check wrong password refusal, no cross-account access, exact-route refusal without consent, cancellation, disconnect/revocation and password rotation invalidating previous grants.
5. Enter the tested credentials and exact host sign-in instructions only in secure reviewer fields. Keep the account available throughout review. Rotation revokes prior grants; update secure review fields and rerun cases before rotating during review.

Owner secret access: [Google Secret Manager for KROK](https://console.cloud.google.com/security/secret-manager?project=krok-1d60a). A secret existing does not prove the login/provider or dataset works. Do not mark reviewer access complete until the clean-browser and real-host checks pass.
