# KROK test and gate audit

Date: 2026-10-06. Branch: `claude/awesome-hopper-yisoso` (same as `main` at `a99e573`).

**Method.**
- Read all 21 workflow files, `scripts/tasks/*`, the Fastfile, `project.yml` and the server test/lint/TS config.
- Ran server `lint`, `typecheck`, `npm audit` and the unit tests locally, with a v8 coverage run.
- Pulled GitHub Actions history: the last 30 server-ci runs, all failed runs (216 in total), ios-ci runs on `main`, and logs for failed `evals`, `reviewer-provision` and `ios-ci` jobs.

**Not checked.**
- I did not run the Firebase emulator, Playwright or iOS suites. The emulator and Playwright need `firebase-tools` and Java, and iOS needs macOS. Their state comes from CI history only.
- I cannot see branch protection or required status checks (no tool for it). Several findings depend on that, and they are flagged below.
- `reviewer-provision` failed on `main` twice, but I could not retrieve the actual error text.

---

## 1. What exists today

| Layer | Checks | State |
|---|---|---|
| Server static | ESLint (`recommended`, not type-aware), `tsc --strict --noUncheckedIndexedAccess`, `npm audit --omit=dev` | Local run: lint and typecheck clean, 0 prod vulns |
| Server unit | 30 vitest files, 401 pass / 6 skipped, 13 s | Green. Local coverage: **85% lines, 78% branches**. CI does not measure coverage |
| Server integration | Firestore emulator (19 tests), rules and storage rules (4 tests) | Green in CI (not re-run here) |
| Server browser | Playwright consent, auth and public-pages (13 tests) | Green in CI |
| iOS unit | 21 XCTest files | Mostly green, red several times recently |
| iOS UI | `ios-ci` runs UI tests minus QA, bench and daily-check suites | Same |
| iOS release | `release-collector` job (Release-config subset), `daily-check` (Debug/Release × width 1/2/4 on simulator HealthKit, then server ingest of the batches) | `daily-check` red repeatedly on perf branches and once on `main` |
| Release gates | Entitlement check in the Fastfile (HealthKit, App Attest, Sign in with Apple), `preflight.sh`, `smoke.sh` (live MCP checks with synthetic user), `listing-package` schema validation, weekly `evals` | See findings |

Strengths worth keeping:
- The phone-to-server contract test (`daily-check` → `phone-batches.test.ts`) is unusually good.
- The shared `compact-fixtures.json` is consumed by both Swift and TS tests.
- `smoke.sh` runs known-answer checks against live data.
- The entitlement check refuses to upload an app that lost its HealthKit entitlement.
- A weekly real-LLM eval exists.

---

## 2. Findings, highest priority first

### P0. Release gates are not actually gates

1. **Deploy and TestFlight do not wait for CI.** `deploy.yml` and `testflight.yml` trigger on `push` to `main` independently of `server-ci` and `ios-ci`. `deploy.sh` runs no tests before `firebase deploy`. The only protection is the post-deploy `smoke.sh`, which is after production changed. Either run the tests inside the deploy workflow or put a `workflow_run`/required-check gate in front. I can't tell whether branch protection requires the checks to pass before merge. **Please confirm.**
2. **`main` has been red on iOS and merged anyway.** ios-ci on `main` failed on #101 (run 456) and #102 (run 465). Both merged. #101's `test` job failed in "Build and test", and `release-collector` passed. The TestFlight workflow would have uploaded from that commit. Same pattern on PR branches: `ios-ci` and `qa-ios` red on the diagnostics PR #104 at every recent head. `ios-ci` is flaky or broken enough that people stopped treating red as a stop.
3. **`reviewer-provision` failed on both of the last two `main` deploys (runs 50, 51).** Failing step: "Validate synthetic production dataset and reviewer access" (`FAIL: tool inventory`). *Cause found after the first draft:* `verify-reviewer.mjs` asserted exactly 16 tools, but an OAuth connection now sees 18 (17 health tools plus `get_account`) since the race tools landed on Oct 3-4. A stale assertion, not a production fault. Fixed (see section 5). Steps after the inventory check never ran, so they are still unverified.
4. **Weekly `evals` first run failed.** 19/22 passed. Failing case: ChatGPT answered 500 + 500 steps for a question expecting 1000. That looks like an over-strict grader (it should accept the sum), not a server bug, but the grader is the check and it's failing. Also `npm install` with `latest` for both SDKs took ~5 min and is unpinned and unlocked: the eval can break on any upstream release.

### P1. Coverage gaps in what matters for a health-data product

5. **Zero unit coverage on `index.ts`, `store/firestore.ts`, `auth/tokens.ts`, `auth/oauth-store.ts`; 17% on `account.ts`.** This is the auth, token, account-deletion and Firestore layer. The emulator suite touches some of it, but nothing measures how much. Add coverage to the integration run so this is visible.
6. **No test asserts App Check behavior.** `ENFORCE_APP_CHECK` defaults to `false` and `deploy.sh` also defaults it to `false`. The app ships the App Attest entitlement, so the intent looks like enforcement. Either enforce it and test it, or document why not. **Question for you:** is App Check meant to be off at launch?
7. **Firestore and Storage rules have 4 tests total.** Rules are the last line of defense for health data. Add negative tests for each collection (cross-user read/write, unauthenticated, field-level writes, listing).
8. **Account deletion.** *Correction to the first draft:* I called this thinly tested because `account.test.ts` is short. That was wrong: the emulator suite already covers tokens, OAuth credentials and grants, access log, product events, blobs, the user subtree and the auth user, and confirms other users' data survives. The remaining gap was a catch-all that fails if a *new* collection is added without a purge. Added (section 5). Two collections (`orphanBatches`, `rateLimits`) keep user-id-keyed tombstones for up to 30 days via TTL, by design.
9. **No static analysis beyond ESLint-recommended and tsc.** No type-aware lint (`no-floating-promises`, `no-misused-promises`), which matters for an async Firestore/Express server. No SwiftLint/SwiftFormat. No secret scanning, CodeQL, dependabot/renovate, `shellcheck` (16 shell scripts), `ruff` (11 Python scripts that handle ASC and Firebase credentials), or `actionlint`. None of these are present in the repo.
10. **The 6 skipped unit tests** are all `phone-batches.test.ts`, skipped unless `PHONE_BATCH_DIR` is set. By design they run in `daily-check` only. That check does not run on PRs to `main` unless the paths match, and it is hard-coded to a list of branches. A change to `server/ingest` on an unlisted branch skips the contract test silently.
11. **iOS coverage is collected (`gatherCoverageData`) but never read or thresholded.**

### P2. CI efficiency and hygiene

12. **server-ci runs twice per commit.** It triggers on both `push` and `pull_request` (e.g. runs 300 and 301 on the same SHA). It has no `concurrency` group. Same for `ios-ci`, though that one has `cancel-in-progress`. On macOS runners (billed at a 10× multiplier) the duplicate is the expensive part. Fix: `push` only on `main`, `pull_request` for everything else.
13. **macOS cost is concentrated in non-gating jobs.** `daily-check` is 6 macOS jobs × up to 40 min per push, with a branch list of 9 branches (most of them already merged). Combined with `qa-ios`, `healthkit-bench`, `shared-read-bench`, `phone-comparison-bench` and `daily-concurrency-bench`, one push to a perf branch can start several full macOS runs. Make benches `workflow_dispatch`-only, and run `daily-check` as 2 jobs (Debug and Release at the shipping width) on PRs, the full matrix nightly or on dispatch.
14. **Dead and stale workflows.**
    - `qa-audit`, `qa-testflight-source`, `listing-policy-research` and `reviewer-provision` (push trigger) are tied to one-off `codex/*` branches.
    - `deploy.yml` lists `claude/youthful-planck-k7ff0m`.
    - `healthkit-bench` is tied to `claude/laughing-knuth-5lkgy7`.
    - GitHub lists **33 registered workflows** against 21 files on `main`. The 12 ghosts (`purge-all`, `public-mcp-live-smoke`, `history-*`, `hourly-*`, `initial-options-*`, `diagnostic-suite-bench`, `app-store-draft`, `daily-storage-trace`) exist only on other branches or are leftovers. Delete the files and the obsolete registrations.
15. **Missing `timeout-minutes`** on `server-ci`, `deploy`, `evals`, `bootstrap`, `apple-auth-preflight`. In `ios-ci`, jobs were cancelled at 26 and 30 minutes (run 465), which looks like timeout or hang behavior, so check iOS job duration trends.
16. **Actions are tagged (`@v4`), not pinned to SHAs.** This includes the ones that hold GCP federation and App Store keys (`google-github-actions/auth`). Node 20 deprecation warnings appear in every log.
17. **`bootstrap.yml` runs any `scripts/tasks/*.sh` from any ref with every secret** (ASC key, Anthropic, OpenAI, GCP deploy SA). Anyone with write access can push a branch containing a modified script and dispatch it. Put the secrets behind a GitHub Environment with required reviewers, and restrict `ref` to `main` unless approved.
18. **Dev-dependency audit.** `npm audit` (all deps) reports 6 issues (4 high, 2 moderate). I did not identify the packages. CI only audits `--omit=dev`, which is the right blocking gate; add a non-blocking weekly full audit.
19. **A 1.4 MB Python wheel (`brotli-…whl`) is committed in `firebase/functions/`** with no reference anywhere in the repo. Likely a leftover.
20. **Repo root has `QA_REPORT.md` and `QA_REPORT_2.md`** (28 KB of point-in-time findings). The findings that are still open should be tests or issues, not prose.

---

## 3. What I would add / remove / change

### Add
| # | Item | Why | Cost |
|---|---|---|---|
| A1 | Required-check gate: deploy/TestFlight only after `server-ci`/`ios-ci` green on that SHA (`needs` via reusable workflow, or branch protection with required checks) | P0-1, P0-2 | Small |
| A2 | Coverage in server-ci (`@vitest/coverage-v8`) with floors per area (e.g. ingest, query, readiness ≥ 90% lines; `auth/`, `account.ts`, `store/` measured from unit + emulator runs) | P1-5 | Small |
| A3 | Rules tests per collection and bucket path, including negative cases | P1-7 | Medium |
| A4 | Deletion end-to-end emulator test | P1-8 | Medium |
| A5 | App Check enforcement test (or an explicit decision) | P1-6 | Small |
| A6 | `typescript-eslint` type-checked config (`recommendedTypeChecked`, at least `no-floating-promises`) | P1-9 | Small, may need fixes |
| A7 | `actionlint`, `shellcheck`, `ruff` job on `scripts/` and `.github/` (one fast Linux job) | P1-9 | Small |
| A8 | Secret scanning (gitleaks) and CodeQL (JS/TS, Swift is optional), plus dependabot for npm, Actions and Gemfile | P1-9, P2-16 | Small |
| A9 | SwiftLint (warnings only at first) | P1-9 | Small |
| A10 | Lockfile for `scripts/evals` and pinned SDK versions; make the grader accept equivalent answers (sum of hourly values) | P0-4 | Small |
| A11 | Nightly `smoke.sh` against production (not only after deploy), alerting on failure | catches drift between deploys | Small |
| A12 | Doc-drift check: `docs/COVERAGE_MATRIX.md` and `shared/coverage.json` generated from or tested against each other | prevents contract drift | Medium |

### Change
| # | Item | Notes |
|---|---|---|
| C1 | `server-ci` and `ios-ci` triggers: `pull_request` + `push` to `main` only; add `concurrency` with cancel-in-progress | halves runs |
| C2 | `daily-check`: PR subset (2 jobs) and nightly full matrix; trigger on path, not on a hand-maintained branch list | P2-13 |
| C3 | Benches (`*-bench`, `phone-comparison`, `healthkit-bench`) to `workflow_dispatch` only | P2-13 |
| C4 | Add `timeout-minutes` everywhere; pin third-party actions to SHAs; move to Node 24 versions | P2-15, 16 |
| C5 | `bootstrap.yml` behind an Environment with required reviewers | P2-17 |
| C6 | Investigate `ios-ci` build failures on `main` and either fix the flake or split the job so a compile error and a UI flake aren't the same red | P0-2 |
| C7 | Read and fix the `reviewer-provision` failure before submission | P0-3 |
| C8 | Move open items from `QA_REPORT*.md` into tests or issues | P2-20 |

### Remove
| # | Item |
|---|---|
| R1 | Workflows tied to merged or one-off branches: `qa-audit`, `qa-testflight-source`, `listing-policy-research`, `healthkit-bench` (or convert to dispatch-only), plus the 12 ghost registrations |
| R2 | Stale branch names in `deploy.yml` and `daily-check.yml` triggers |
| R3 | The committed `brotli-*.whl` (confirm it is unused first) |
| R4 | `mcp-probe` and `ingest-notes` are manual debugging tools, not checks. Keep them, but move them out of the "CI" mental model (a `tools/` folder or a README section) |

---

## 4. Open questions for you

1. ~~Is branch protection on `main` enabled?~~ **No**: the GitHub API reports `main` as `protected: false`. Turn it on (section 6).
2. Should App Check be enforced at launch? (P1-6.)
3. ~~What did `reviewer-provision` fail on?~~ Answered: stale tool count (section 5).
4. Is `brotli-*.whl` used by anything outside this repo (e.g. a Cloud Functions Python step)?
5. Is the weekly eval meant to be a hard gate (blocks release) or an advisory signal?

---

## 5. Changes made (branch `claude/awesome-hopper-yisoso`, not yet merged)

| Change | Files |
|---|---|
| **Deploy waits for server tests.** `deploy.yml` calls `server-ci` first; a manual run has a `skip_ci` box for emergencies. | `deploy.yml`, `server-ci.yml` |
| **TestFlight waits for `ios-ci` on that commit.** Triggered by `workflow_run` of a successful `ios-ci` push on `main`; the manual button is the override. The old `push` trigger is gone. | `testflight.yml` |
| **No more double runs.** `server-ci`, `ios-ci`, `daily-check` run on pull requests and pushes to `main` only. Older runs on the same PR are cancelled. | `server-ci.yml`, `ios-ci.yml`, `daily-check.yml` |
| **Smaller macOS bill.** `daily-check` runs 2 jobs (Debug, Release at width 2, the shipping width) on PRs and `main`; the full 6 only on manual dispatch. Four bench workflows are dispatch-only, as their own header comments already said. | `daily-check.yml`, `healthkit-bench.yml`, `phone-comparison-bench.yml`, `shared-read-bench.yml`, `diagnostic-suite-bench.yml` |
| **Timeouts** added to `server-ci` (20 min), `deploy` (60), `evals` (20), `bootstrap` (60), `apple-auth-preflight` (10). | those files |
| **Secret scan** (pinned, checksum-verified gitleaks 8.28.0) on PRs and `main`. Run locally over the full history first: no leaks found. | `secret-scan.yml` |
| **Dependabot**, weekly and grouped: `firebase/functions` npm and GitHub Actions. | `.github/dependabot.yml` |
| **Coverage floors** in `server-ci` (`@vitest/coverage-v8`): overall 83% lines / 75% branches, 90%+ on `query`, `readiness`, `ingest`. Set just under today's numbers, so it blocks regressions rather than demanding new tests. | `vitest.config.ts`, `package.json`, `package-lock.json`, `.gitignore` |
| **Rules tests** 4 -> 13 tests: list and collection-group queries, updates and deletes, every server-owned path, unknown collections, anonymous callers; Storage size, empty, schema, checksum shape, upper-case id, delete, list, nesting. | `test/integration/rules.test.ts` |
| **Catch-all deletion test**: scans every Firestore collection and subcollection after a purge for the user's id (passes today, so nothing leaks). | `test/integration/firestore.test.ts` |
| **`reviewer-provision` fix**: expected tool count 16 -> 18. | `scripts/verify-reviewer.mjs` |

**Checked here:** lint, typecheck, build clean; 407 unit tests pass with the coverage floors (and a deliberately high floor fails as it should); 37 emulator tests pass (was 28); `actionlint` clean on every workflow; `gitleaks` clean.

**Not checkable here (needs a real run on GitHub):**
- The deploy gate and the TestFlight `workflow_run` gate only take effect once merged to `main`, because both workflows run from the default branch.
- `daily-check` and `ios-ci` need macOS. The matrix expression is syntax-checked, not executed.
- Playwright was not run; `verify-reviewer.mjs` was syntax-checked only (it needs production credentials).
- **Storage overwrite protection is unverified.** `storage.rules` says uploads are never overwritten, but the emulator accepts a second upload to the same path, so no test can confirm it. Cloud Storage should treat `allow create` as new-object-only; confirm once against a real project. Impact if wrong is small (a user replacing their own unprocessed batch).

**Behavior changes to know about:**
- Pushing a branch with no open PR no longer starts CI. Open a PR, or use "Run workflow".
- A change that only touches `.github/workflows/ios-ci.yml` also triggers a TestFlight upload after it passes (previously the path filter excluded it).
- `deploy.yml` still allows the `claude/youthful-planck-k7ff0m` branch; I left that alone because the branch still exists and may be in use.

## 6. Still needs you (repo settings I can't change)

1. **Turn on branch protection for `main`** with required checks `server-ci / test`, `ios-ci / test`, `ios-ci / release-collector`, `secret-scan / gitleaks`. Without it, the gates above only protect deploys, not merges. (Caveat: path-filtered workflows don't report on PRs that don't touch their paths, which makes required checks hang. Either remove the path filters on those two or use a ruleset that tolerates missing checks.)
2. Enable **secret scanning and push protection** and **Dependabot alerts** under Settings > Code security.
3. Decide on **App Check** enforcement (open question 2).
