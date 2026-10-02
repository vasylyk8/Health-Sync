# Asking KROK questions on synthetic data

Anything an AI can ask KROK about real Apple Health data can be asked of the synthetic user, without the phone.

| How | Where it runs | Speed | Use it for |
|---|---|---|---|
| `cd firebase/functions && npx tsx scripts/local-probe.ts '[{"tool":"get_daily_context","args":{"start_date":"2024-03-01","end_date":"2024-03-03"}}]'` | this machine: real ingest code + real MCP endpoint + MCP client, in-memory storage | ~5 s | trying a prompt's tool calls, debugging a tool |
| `npm test` (`test/unit/synthetic-mcp.test.ts`) | same stack | seconds | exact expected answers for every tool, in CI on every push |
| GitHub workflow `mcp-probe` (input `calls`: JSON array of `{tool, args}`) | the live deployment, synthetic user's connector link | ~1 min | checking what is actually deployed |
| Weekly `evals` workflow | live deployment, real Claude/ChatGPT | minutes | does a real AI pick the right tools |

`tools` as the argument of `local-probe.ts` lists the tools. `MAX_CHARS` limits printed output.

## The data
`scripts/synthetic/data.mjs` generates a year (2024) from simple formulas, so every answer is known exactly:
Monday runs with heart rate, distance and GPS, all 98 daily metrics the phone can send (`dailyValue(key, day)`),
hourly heart rate, steps and HRV, glucose in March, symptoms, nutrition entries, high-heart-rate alerts and a profile.
Glucose, symptoms and heart events are stored but the public v1 MCP does not offer tools for them (see PUBLIC_MCP_RELEASE.md); their direct query functions stay covered by `synthetic.test.ts`. Medications are off for this user, and the MCP test switches nutrition off to check that disabled categories stay hidden.
Bump `DATA_VERSION` when it changes: the deploy re-seeds the live synthetic user.

## Adding a tool or a metric
`synthetic-mcp.test.ts` fails if a tool exists that no test asks, and if any daily metric in `shared/coverage.json`
does not come back out of `get_daily_context`. Add a generator to `data.mjs` and an assertion to the test.

## Phone to server
The `daily-check` workflow seeds the iOS simulator's HealthKit with readings, runs the app's real daily pass, builds the
upload batches with the app's own batch writer and dumps them. A second job ingests those exact files with the real
server code and asks `get_daily_context` for them through the MCP endpoint (`test/unit/phone-batches.test.ts`), so a
metric the phone drops or the server mangles fails the run. Only the daily pass is chained so far (not workouts, hourly
series or events), and the seeded HealthKit has 12 data types.
