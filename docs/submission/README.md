# KROK public listing preparation

Publisher: **2ndOp Inc**. OpenAI organization registration and business verification have not started. KROK is currently free; future subscriptions are outside this release. Intended availability: every country supported by the target platform except Russia (RU) and Belarus (BY). PR30 is the design source for all new public-facing work.

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
- `docs/legal/TERMS_OF_SERVICE.md` is proposed text, not a published agreement. No terms URL is declared complete.
- The dedicated reviewer is not yet provisioned or tested in production. Never commit or include credentials in listing packages.
- All eight real-host cases in `docs/PUBLIC_MCP_REVIEW_CASES.md` remain **Not run** in both hosts. Automated tests do not change this status.
- Both real recordings are pending. The owner has agreed to record them. No demo URL is invented.
- Country targeting must be an explicit target-platform supported-country list excluding RU/BY. Do not use an empty list (unrestricted targeting) or infer enforcement from this document.
- No organization verified, portal draft uploaded, legal attestation made, directory review submitted or listing published by this preparation batch.

Use [platform requirements](PLATFORM_REQUIREMENTS.md), [recording guide](RECORDING_GUIDE.md) and [reviewer runbook](REVIEWER_RUNBOOK.md) to close these gaps in order.
