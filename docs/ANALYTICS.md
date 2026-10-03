# KROK product analytics

KROK's launch analytics is a private, aggregate-only MCP connector for the operator. There is no analytics dashboard and no additional product-analytics vendor. Claude calls five read-only tools over hourly Firestore rollups in the existing Firebase project.

## Metric contract

The source of truth is `firebase/functions/src/analytics/contract.ts`.

| Funnel step | Exact meaning |
|---|---|
| First opened | The authenticated app first reported an open. Offline opens appear after the next successful report. |
| Health connect started | The person tapped Connect to Apple Health. |
| Health connected | Health authorization and KROK device registration completed. HealthKit does not reveal which individual types were allowed. |
| Apple linked | Sign in with Apple completed. |
| First sync ready | The first Health batch became queryable by the assistant. |
| Assistant connected | A Claude or ChatGPT connection was first authorized or used. |
| Activated | The first successful non-setup KROK data-tool call—the observable proxy for a first AI question answered. |

W1 retention is a successful data-tool call 7–13 days after activation. W4 is days 28–34. Cohorts that have not lived through the complete window are excluded from the denominator.

## Collected fields

The app endpoint accepts only the event name, app version, sync outcome and coarse sync wall time. Unknown fields are rejected. The backend owns first-sync, assistant-connection, activation, MCP outcome and MCP duration milestones.

Never collected by product analytics: Health values, workout counts or metadata, GPS, Health dates, source names, tool arguments, free text, connector URLs/tokens, email, Apple identifiers, or individual analytics profiles.

One-time milestones live on `users/{uid}.analytics` and are deleted with the account. App events and MCP access logs expire after 90 days. `analyticsRollups/{UTC-date}` contains counts and duration sums only—no UID or event rows. The hourly job recomputes the last 90 days so W1/W4 cohorts mature correctly.

## Claude tools

- `usage_overview`: activation, active user-days, calls, success and provider mix.
- `activation_funnel`: first-open cohort conversion, optionally by app version.
- `retention`: mature W1/W4 cohorts.
- `reliability`: sync and MCP outcomes and mean duration.
- `metric_definition`: exact meaning and denominator.

All date ranges are UTC and limited to 90 days. Answers include freshness. `active_user_days` is intentionally named: a person active on two days counts twice; it must not be described as unique users over the whole period.

## Private operator link

Deployment creates a 256-bit token in Secret Manager (`krok-analytics-mcp-token`) and stores only its SHA-256 hash in Firestore. Request paths containing the token are excluded from Cloud Logging. Customer KROK links cannot call analytics tools.

In a trusted terminal, retrieve the Claude connector URL with:

```bash
scripts/tasks/analytics-link.sh
```

Treat it like a password. Rotate and immediately revoke the previous link with `scripts/tasks/analytics-token-rotate.sh`. Both tasks use the existing GitHub/GCP deployment identity; no analytics-vendor account or API key exists.

## Useful questions

- “Show the activation funnel for the last 14 complete days and identify the largest drop.”
- “What are W1 and W4 retention for September activation cohorts? Exclude immature cohorts.”
- “Compare Claude and ChatGPT usage over the last four weeks.”
- “Did sync or MCP reliability worsen in the last seven days?”
- “Define activation and explain what KROK cannot observe about the AI's final answer.”

## Verification and rollback

`scripts/tasks/deploy.sh` provisions the token, bootstraps rollups, and calls the live connector during smoke testing. Unit tests cover the strict event boundary, cohort math and MCP separation. Emulator tests cover transactions, deletion and server-only rules.

To stop access immediately, run the rotation task and do not install the replacement link. Removing the Hosting rewrite/function disables the connector without affecting customer health connectors or synced data.
