# KROK – instructions for AI coding agents (Codex, Claude Code)

KROK mirrors Apple Health to a private EU server so Claude/ChatGPT can answer questions about the owner's training. Repo: `Health-Sync`. Overview: `README.md`. Source of truth for data: `docs/DATA_CONTRACT.md` and `shared/coverage.json`.

**Protect above all:** the correct numbers get from Apple Health to the AI. None lost, none wrong.

## Working with the owner
- The owner is non-technical and cannot review code. Refer to them as they/them.
- Talk in short, plain language. Lead with the result. No code, file names or commit IDs unless asked. Put technical detail in the PR, not the chat.
- Do every technical step yourself (merge, deploy, run workflows, fix CI). Only ask the owner for things only they can do: portal logins, checks on their real iPhone, legal approvals. Give those as a short list of exact taps.
- Recommend one option; don't hand over a menu. Treat their goal as the instruction and their suggested method as a hypothesis. Push back if the evidence says so.
- Decide reversible things yourself. Ask only for a real product choice, an irreversible action, real cost, or an unresolved risk.
- If the owner is asking a question or discussing, answer and change nothing.
- Stay within the request. Don't fix unrelated things; mention them.
- If you can't do a step with your tools, say so plainly. Don't skip it or fake it.

## "Ship it"
When the owner says "ship it": open the PR if none exists, wait for green checks, merge it (merge commit), confirm the server deploy and its smoke test pass, confirm the TestFlight upload, then tell the owner it is out. No questions in between. Merging to `main` auto-deploys the server (`firebase/`, `shared/`, `scripts/`) and uploads the app to TestFlight (`ios/`, `shared/`). If checks stay red, fix them or report. Never ship red.
Without "ship it": do the work and push the branch.

## Environment and speed
- The cloud has no Swift/Xcode. GitHub Actions is the only place the app compiles and its tests run (`ios-ci`, about 15 min, costs real money). Batch iPhone changes into fewer pushes.
- Server: `cd firebase/functions && npm ci && npm run lint && npm run typecheck && npm test`. Run the relevant tests before pushing; CI runs the rest. Ask the server a question locally: `npx tsx scripts/local-probe.ts` (see `docs/SYNTHETIC_TESTING.md`).
- Known random UI-test failures (re-run once, don't investigate first): `testConnectClaudeShowsSetUpCheckmark`, `testLaunchPerformance`, `testChatGPTConsentCanBeCancelled`, `testHomeAccessibilityAndCapture`, `testWelcomeAccessibilityAndCapture`, and the `qa-ios` small-device light-mode run.
- `workflow_dispatch` only works for workflows that exist on `main`.

## Red lines
- Never delete or purge accounts or data: real users, the synthetic monitor, or the reviewer account (`krok-reviewer-directory`). Actions hold production access. Never run `purge-all` in run mode.
- No App Store or AI-directory submission (`appstore-submit` with `submit=true`, listing uploads) unless the owner names it.
- Never put health values, routes, tokens or secrets in logs, analytics, commits or public pages. Public contact is `support@2ndopinions.ai` only; no personal address or email.
- The Apple developer account is shared with another app (Sniped). Never touch its certificates, keys or Services ID.

## Debugging production
Read-only tools only: the `ingest-notes` workflow, the `diag` task (via `bootstrap`), and `mcp-probe`. Past dead ends are in `docs/HANDOFF_DAILY_DATA_BUG.md`; don't retry them.

## Being honest about checks
Say which of these applies: not tested / tested and failed / checked in CI or the simulator / checked in production. Simulator results never prove phone behavior or speed. Always say what was not verified.

## Data rules that have bitten before
- If the phone reads new or fixed data, bump `dailyVersion` / `hourlyVersion` (`ios/HealthSync/Sync/SyncEngine.swift`) so installed apps re-read history once.
- HealthKit statistics come back empty for older years. Fill from raw samples, never replace what statistics return.
- The Watch wins over the iPhone for steps, distance and energy. Never add readings from different sources together.

## This file
Don't edit `AGENTS.md`, `CLAUDE.md` or agent settings unless the owner asks. If docs and code disagree, the code and the latest merged PR win; fix the doc.
