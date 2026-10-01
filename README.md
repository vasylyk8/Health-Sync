# KROK

An iPhone app that mirrors your Apple Health **workouts** (with every heart rate reading, other sensor stream and GPS route Apple recorded) plus a daily recovery/activity summary to a private, EU-hosted server, so Claude or ChatGPT can answer questions about your training through a remote MCP connector: Apple's own summary first, exact calculations and raw data on request.

```
iPhone (workouts + raw streams + daily rows → durable outbox) → Storage incoming/ → ingestion → Parquet + manifest/index (Firestore)
                                                                      ↓
                                     Claude / ChatGPT ← MCP connector (Cloud Functions, /mcp/<secret>)
```

## For the owner
| Doc | What it's for |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | One-time setup: Apple, Google/Firebase, GitHub secrets |
| [docs/WORKOUTS_RELEASE.md](docs/WORKOUTS_RELEASE.md) | Releasing the workouts-only version: order of steps, cleanup of old data, real-phone checklist |
| [docs/RELEASE_SOAK.md](docs/RELEASE_SOAK.md) | The 3–5 day real-phone test before submitting |
| [docs/APP_STORE.md](docs/APP_STORE.md) | Listing text, review notes, privacy answers |
| [docs/COSTS.md](docs/COSTS.md) | Measured running costs and cost levers |
| [docs/legal/](docs/legal) | Privacy policy, DPIA and HealthKit-sharing drafts (need legal review) |

## For engineers
| Path | Contents |
|---|---|
| `docs/DATA_CONTRACT.md` | Upload format, storage layout, correctness rules (the source of truth) |
| `docs/COVERAGE_MATRIX.md`, `shared/coverage.json` | What is read from HealthKit (workout streams, daily metrics), shared by app and server |
| `ios/` | SwiftUI app (XcodeGen `project.yml`, fastlane). `bundle exec fastlane test` runs everything on a simulator |
| `firebase/functions/` | TypeScript server. `npm test` (unit), `npm run test:emulator` (Firebase emulators), `npx tsx bench/bench.ts` |
| `scripts/tasks/` | `preflight`, `provision`, `deploy`, `smoke`, `monitoring`, `testflight`, `testers`, `evals`, `diag` (read-only diagnostics), `cleanup-legacy-plan` (read-only) and `cleanup-legacy` (one-off removal of the old data types). Run by GitHub Actions |
| `scripts/synthetic/`, `scripts/evals/` | Synthetic monitoring user with known answers; weekly real-AI evals |

### Automation
- **server-ci**: lint, typecheck, unit tests and emulator integration tests on every change.
- **ios-ci**: builds the app and runs unit and UI tests on GitHub's macOS machines. It also saves App Store screenshots.
- **deploy**: provision (idempotent), deploy, seed the synthetic user, live smoke test, monitoring. Runs on `main` (and on the development branch until launch).
- **testflight**: builds the app unsigned, signs it ad-hoc with its entitlements, then exports through Apple's cloud-managed signing (no certificates created or stored), verifies the HealthKit/App Attest entitlements, uploads to TestFlight and adds testers (`testers`).
- **evals**: every week, real Claude and ChatGPT must answer fixed questions correctly through the live connector.
- **bootstrap** (on `main`): runs any `scripts/tasks/<task>.sh` on demand, e.g. `diag` (ingestion logs, bucket contents, uptime-check results) or `smoke`.
- Live endpoints: `https://<project>.web.app/health` (health check; `/healthz` is reserved by Google's front end) and `/mcp/<link>`.

### Key design choices
- **Mirror, not live pull.** AI services can't reach a phone, and iOS locks HealthKit while the phone is locked.
- **Summary first, raw on request.** Tools return Apple's summary; raw streams and the route are downsampled or paged (and say so); exact calculations (zones, splits, drift, best efforts, elevation) run on the server over the full raw data.
- **Privacy by default.** Workouts, activity, sleep and recovery are read by default; nutrition, heart alerts, glucose/insulin/blood pressure, symptoms and mood, cycle, medications and profile are separate switches, off until the user enables them (switching one off deletes its data). Route start/end (300 m) are hidden unless the user explicitly asks for the exact route.
- **Nothing lost, nothing silently wrong.** A HealthKit anchor only advances after the server has the data. A workout's raw data is "complete" only when every promised point arrived; tools report coverage and completeness, and never return aggregates over truncated data.
- **Apple's numbers.** Apple's own workout statistics are shown as recorded; sleep merges overlapping sources by picking one per night.
- **Read-only, private links.** Only a hash of each 256-bit link is stored. Links are revoked instantly by Disconnect or Delete.
- **Deferred:** AI-written SQL (needs a sealed sandbox), Sign in with Apple, clinical records.
