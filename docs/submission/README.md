# KROK public listing preparation

Publisher: **2ndOp Inc**. The publisher reports OpenAI organization verification is approved as of October 2, 2026; the portal was not independently inspected. KROK is currently free; future subscriptions are outside this release. Intended availability: every country supported by the target platform except Russia (RU) and Belarus (BY). PR30 is the design source for all new public-facing work.

## Coverage and sequence

| Step | Autonomous work | Owner/platform dependency |
| --- | --- | --- |
| 1. Eligibility | Inspect actual data scopes, fetch current official requirements, document differences and draft eligibility questions | Confirm legal classification of data and obtain platform clarification where needed; acceptance is not guaranteed |
| 2. Listing and pages | Draft truthful copy, reuse PR30 icon/tokens, prepare terms and privacy reconciliation | Approve terms/legal commitments before publication |
| 3. Reviewer access | Prepare guarded provisioning, synthetic fixtures, secure password storage and account/OAuth/tool checks | Cloud permissions/provider setup if unavailable; access remains incomplete until verified |
| 4. Host cases and demo | Prepare five positive/three negative cases, rehearse backend/browser flow, provide exact recording instructions | Owner records ChatGPT and Claude; real host outcomes and video access must be verified |
| 5. Platform submissions | Prepare separate OpenAI package and Claude submission answers; validate archives and public links | Complete platform-specific eligibility gates and secure reviewer fields |
| 6. Verification and submission | Prepare challenge-file implementation after the portal supplies its exact token; check saved metadata/scans where accessible | Owner verifies 2ndOp Inc, makes legal attestations and approves submit/publish |

Batch A: requirements, listing copy, shared branding, cases and recording guide. Batch B: reviewer provisioning and end-to-end checks. Batch C: incorporate recordings and approved legal pages, enumerate countries supported by each portal, finalize packages. Final setup: organization/domain verification, saved-version host tests, legal attestations, submission. Approval and publication are separate actions.

## Current gaps

- OpenAI health-data eligibility needs careful review; consumer-health consent does not override the PHI prohibition.
- `docs/legal/TERMS_OF_SERVICE.md` was approved by the publisher on October 2, 2026, with street address and email removed. `/terms` is staged for publication; verify its live content after deployment.
- The dedicated reviewer is provisioned and its credentials stored in Secret Manager. After explicit owner approval, the password provider was enabled. Production browser sign-in, PKCE, all 18 MCP tools, scope refusals, refresh rotation and revocation passed. The callbacks were captured by the verifier; actual saved-version ChatGPT/Claude sessions and recordings remain separate. Never commit or include credentials in listing packages.
- The demo recordings support a subset of real-host behavior. Completion of all eight cases in `docs/PUBLIC_MCP_REVIEW_CASES.md` remains unverified; do not mark the entire suite passed from the demos or automated tests.
- Both real recordings were supplied and visually sampled. See `KROK_CHATGPT_DEMO_REVIEW_2026-10-02.md` and `KROK_CLAUDE_DEMO_REVIEW_2026-10-02.md` for the links, observed behavior and review limits.
- The OpenAI package now has an explicit ISO allowlist excluding RU/BY, subject to the host's own supported regions. Validate portal acceptance and Claude targeting controls before publication; see `COUNTRY_TARGETING.md`.
- Organization verification is owner-reported approved. No portal draft upload, directory policy attestation, directory submission or listing publication has been performed by this preparation batch.

Use [platform requirements](PLATFORM_REQUIREMENTS.md), [recording guide](RECORDING_GUIDE.md) and [reviewer runbook](REVIEWER_RUNBOOK.md) to close these gaps in order.
