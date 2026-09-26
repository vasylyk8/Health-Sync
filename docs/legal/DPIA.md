# Data Protection Impact Assessment (DRAFT – for the owner and legal review)

**Processing:** mirroring Apple Health data (special-category data, GDPR Art. 9) to a cloud store and exposing it, on the user's instruction, to a third-party AI assistant chosen by the user.

## Necessity and proportionality
- Purpose: users analyze their own health data with an AI assistant of their choice. Remote MCP connectors require an internet-reachable server, so a server copy is necessary (on-device access isn't technically possible).
- Minimization: read-only; no clinical records, routes or vision prescriptions; no identity data (anonymous accounts); logs exclude health values.
- Retention: deleted on request, or after 1 year of inactivity. Access logs are kept 90 days.

## Risks and mitigations
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Connector link leaked (e.g. shared screenshot) | Medium | High | 256-bit random links; the app shows the link only in setup; revoke via Disconnect; rate limits; the link is stored hashed server-side and excluded from request logs. **Residual:** without the phone, a user can't revoke (owner-accepted); the link dies after 1 year of inactivity. |
| Cross-user data exposure (bug) | Low | High | Server derives the user only from the verified token/auth; per-user storage paths; automated isolation tests; no arbitrary SQL in v1. |
| AI provider retains or reuses data | Medium | Medium | Per-provider explicit consent naming the company; privacy policy disclosure. **Residual:** outside our control. |
| Unauthorized uploads / abuse | Low | Medium | Firebase Auth, App Check (App Attest), storage rules (create-only, own folder, size limits). |
| Breach of cloud storage | Low | High | Google-managed encryption at rest, private buckets, least-privilege service accounts, no public access. |
| Stale or partial data misleads users | Medium | Low | Every answer carries completeness and freshness flags, and the AI is instructed to disclose partial data. |

## Transfers
Health data is stored in the EU. The anonymous ID is processed by Firebase Auth (US, SCCs). AI providers process data per their terms, at the user's direction.

## Open items for legal review
- Whether per-provider consent plus the privacy policy satisfy Art. 9(2)(a) in all launch countries, and age limits per country.
- Processor terms: Google Cloud DPA (accept in the console); controller relationship with Anthropic/OpenAI (the user's own accounts).
- Whether a DPO / EU representative is required at the expected scale.
- The Apple HealthKit third-party sharing assessment (see HEALTHKIT_SHARING.md).
