# Data Protection Impact Assessment (DRAFT – for the owner and legal review)

**Processing:** mirroring Apple Health **workouts** (with second-by-second measurements and GPS routes), daily and hourly summaries and, **only for groups the user switches on**, event and sample logs (nutrition and alcohol, menstrual cycle, profile) (special-category data, GDPR Art. 9, plus location data) to a cloud store and exposing it, on the user's instruction, to a third-party AI assistant chosen by the user.

## Necessity and proportionality
- Purpose: users analyze their own health data with an AI assistant of their choice. Remote MCP connectors require an internet-reachable server, so a server copy is necessary (on-device access isn't technically possible).
- Minimization: read-only; a type is read only when a tool or feature uses it (selection rule, docs/COVERAGE_MATRIX.md). Workouts, activity, sleep and recovery are always on; **every other group is a separate switch, on by default (owner decision), with its own Apple Health permission request per type**, and switching it off deletes its server data.
 Not read at all: clinical records and documents, sexual activity, contraceptive, pregnancy and lactation data, reproductive/urogenital symptoms, GAD-7/PHQ-9 questionnaires, ECG, audiograms, glucose, insulin, blood pressure, heart alerts, lung function, symptoms, State of Mind and medications (removed in October 2026; data already stored is deleted by a scheduled job); no identity data (anonymous accounts); logs exclude health values and locations. Location is limited to the routes of the user's own workouts; the AI tools hide the first and last 300 m by default.
- Retention: deleted on request, or after 1 year of inactivity. Product events and access logs are kept 90 days; linked funnel milestones are deleted with the account; identifier-free daily rollups retain only aggregate counts and durations. The one-off removal of the earlier data types keeps a backup for 14 days (auto-expiring) as a safety net.

## Risks and mitigations
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Connector link leaked (e.g. shared screenshot) | Medium | High | 256-bit random links; the app shows the link only in setup; revoke via Disconnect; rate limits; the link is stored hashed server-side and excluded from request logs. **Residual:** without the phone, a user can't revoke (owner-accepted); the link dies after 1 year of inactivity. |
| GPS routes reveal home/work and routines | Medium | High | Routes are only read for workouts; the AI tools trim the first/last 300 m by default and return exact routes only when explicitly requested; refused for very short routes; nothing location-related in logs. **Residual (owner-accepted):** the private link has no expiry or scope, so anyone with it can request full routes, and the AI provider receives whatever route points the user asks it for. Consider OAuth with scopes before a second user. |
| Cross-user data exposure (bug) | Low | High | Server derives the user only from the verified token/auth; per-user storage paths; automated isolation tests; no arbitrary SQL in v1. |
| Operator analytics link leaked | Low | Medium | Separate 256-bit secret URL stored hashed, excluded from request logs, rate-limited and immediately rotatable; tools read UID-free rollups only and cannot return raw events or individual journeys. |
| AI provider retains or reuses data | Medium | Medium | Per-provider explicit consent naming the company; privacy policy disclosure. **Residual:** outside our control. |
| Unauthorized uploads / abuse | Low | Medium | Firebase Auth, App Check (App Attest), storage rules (create-only, own folder, size limits). |
| Breach of cloud storage | Low | High | Google-managed encryption at rest, private buckets, least-privilege service accounts, no public access. |
| Stale or partial data misleads users | Medium | Low | Every answer carries completeness and freshness flags, and the AI is instructed to disclose partial data. |
| The AI gives medical advice on cycle or other health data | Medium | High | Tools for these groups return an instruction to describe data and trends only: no diagnosis, no dosing or medication advice, suggest a clinician when appropriate. The app and listing state that KROK is not a medical device. **Residual:** the assistant's own behaviour is outside our control. |
| Sensitive categories collected without a real choice | Medium | High | Per-category switches (default on, owner decision: review before launch), Apple Health's per-type permission sheet (the user can deny any type), server-side enforcement (batches of a disabled category are dropped and never served), deletion on switch-off, no sensitive values in logs or analytics. |
| Sensitive data breach has high impact (cycle) | Low | High | Same technical safeguards as other data; sensitive groups are opt-in so most users never store them. Review whether additional encryption or shorter retention is warranted before launch. |

## Transfers
Health and location data is stored in the EU. The anonymous ID is processed by Firebase Auth (US, SCCs). AI providers process data per their terms, at the user's direction.

## Open items for legal review
- Whether per-provider consent plus the privacy policy satisfy Art. 9(2)(a) in all launch countries, and age limits per country.
- Processor terms: Google Cloud DPA (accept in the console); controller relationship with Anthropic/OpenAI (the user's own accounts).
- Whether a DPO / EU representative is required at the expected scale.
- The Apple HealthKit third-party sharing assessment (see HEALTHKIT_SHARING.md).
- Whether the optional groups (cycle) need extra measures in launch countries (for example Washington My Health My Data Act authorization, Canadian provincial health-information rules), and whether any group should be hidden in the first App Store release (each can be hidden without removing code).
- Whether default-on collection of sensitive groups (cycle) is acceptable or whether those should be off by default at launch.
- Retention for sensitive groups (currently the same as other data: deleted on request, on switch-off, or after 1 year of inactivity).

_This document is a draft prepared by the developer and is not legal advice._
