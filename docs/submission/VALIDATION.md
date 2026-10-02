# Preparation validation

Local checks on the PR30-based preparation branch:

- Lint, TypeScript check and bundled server/consent build passed.
- All 190 unit/HTTP tests passed, including real parser/query checks for the additional reviewer nutrition/profile fixtures.
- All 24 Firebase integration tests passed, including reseeding that preserves reviewer credentials and OAuth epochs and refusal to replace non-synthetic accounts.
- All 14 Chromium browser tests passed: eight Auth-emulator consent tests plus six public-page configurations. The new case verifies a real Firebase password user without a reviewer claim cannot authorize health access. Each public-page configuration checks home/support/privacy/instructions/404 at 320, 390 or 1440px, in light or dark mode, using production Hosting security headers. Assertions cover actual icon loading under CSP, no CSP violations, heading visibility, horizontal overflow and correct theme background. Consent still requires sign-in and exact-route consent remains opt-in.
- Mobile home screenshots in both themes were inspected. The PR30 1024px PNG is reused unchanged in the site and upload source; it remains legible on light/dark backgrounds. No native Swift source was changed.
- The actual preparation ZIP inventory and metadata passed local checks: contained icon, field lengths, five positive/three negative cases, canonical streamable-HTTP endpoint, no private app bindings or credentials. It also passed the official Agent Plugins portable JSON schemas and ISO country restriction checks. This is **not OpenAI extension/portal validation or submission readiness**.
- Official policy and existing website/support/privacy content were fetched and inspected through read-only GitHub Actions. See `PLATFORM_REQUIREMENTS.md` for evidence.

GitHub CI outcomes are recorded on the PR when complete. The reviewer account/Secret Manager credentials were created in production, but production login/tool rehearsal remains blocked by the disabled password provider. No native Apple login, actual ChatGPT/Claude cases or recordings are claimed by these automated checks. The new public-page styling is not deployed by this branch.
