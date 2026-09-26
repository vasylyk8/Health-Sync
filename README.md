# Health Sync

An iPhone app that mirrors your Apple Health data to a private, EU-hosted server, so Claude or ChatGPT can answer questions about it through a remote MCP connector.

```
iPhone (HealthKit → durable outbox) → Storage incoming/ → ingestion → Parquet + manifest (Firestore)
                                                                      ↓
                                     Claude / ChatGPT ← MCP connector (Cloud Functions, /mcp/<secret>)
```

## For the owner
| Doc | What it's for |
|---|---|
| [docs/SETUP.md](docs/SETUP.md) | One-time setup: Apple, Google/Firebase, GitHub secrets |
| [docs/RELEASE_SOAK.md](docs/RELEASE_SOAK.md) | The 3–5 day real-phone test before submitting |
| [docs/APP_STORE.md](docs/APP_STORE.md) | Listing text, review notes, privacy answers |
| [docs/COSTS.md](docs/COSTS.md) | Measured running costs and cost levers |
| [docs/legal/](docs/legal) | Privacy policy, DPIA and HealthKit-sharing drafts (need legal review) |

## For engineers
| Path | Contents |
|---|---|
| `docs/DATA_CONTRACT.md` | Upload format, storage layout, correctness rules (the source of truth) |
| `docs/COVERAGE_MATRIX.md`, `shared/coverage.json` | Every HealthKit type synced, shared by app and server |
| `ios/` | SwiftUI app (XcodeGen `project.yml`, fastlane). `bundle exec fastlane test` runs everything on a simulator |
| `firebase/functions/` | TypeScript server. `npm test` (unit), `npm run test:emulator` (Firebase emulators), `npx tsx bench/bench.ts` |
| `scripts/tasks/` | `preflight`, `provision`, `deploy`, `smoke`, `monitoring`, `testflight` (run by GitHub Actions) |
| `scripts/synthetic/`, `scripts/evals/` | Synthetic monitoring user with known answers; weekly real-AI evals |

### Automation
- **server-ci**: lint, typecheck, unit tests and emulator integration tests on every change.
- **ios-ci**: builds the app and runs unit and UI tests on GitHub's macOS machines. It also saves App Store screenshots.
- **deploy**: provision (idempotent), deploy, seed the synthetic user, live smoke test, monitoring. Runs on `main` (and on the development branch until launch).
- **testflight**: signs (fastlane match, certificates stored in a private EU bucket) and uploads to TestFlight.
- **evals**: every week, real Claude and ChatGPT must answer fixed questions correctly through the live connector.
- **bootstrap** (on `main`): runs any `scripts/tasks/<task>.sh` on demand.

### Key design choices
- **Mirror, not live pull.** AI services can't reach a phone, and iOS locks HealthKit while the phone is locked.
- **Nothing lost, nothing silently wrong.** A HealthKit anchor only advances after the server has the data. Tools report coverage and completeness, and never return aggregates over truncated data.
- **Merged totals.** Apple's de-duplicated statistics are used for totals, so iPhone and Watch aren't double-counted.
- **Read-only, private links.** Only a hash of each 256-bit link is stored. Links are revoked instantly by Disconnect or Delete.
- **Deferred:** AI-written SQL (needs a sealed sandbox), Sign in with Apple, clinical records.
