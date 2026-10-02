# Preparation validation

Local checks on the PR30-based preparation branch:

- Lint, TypeScript check and bundled server/consent build passed.
- All 189 existing unit/HTTP tests passed.
- All 13 Chromium browser tests passed: seven existing Auth-emulator consent tests plus six public-page configurations. Each configuration checks home/support/privacy/instructions/404 at 320, 390 or 1440px, in light or dark mode, using production Hosting security headers. Assertions cover actual icon loading under CSP, no CSP violations, heading visibility, horizontal overflow and correct theme background. Consent still requires sign-in and exact-route consent remains opt-in.
- Mobile home screenshots in both themes were inspected. The PR30 1024px PNG is reused unchanged in the site and upload source; it remains legible on light/dark backgrounds. No native Swift source was changed.
- The actual preparation ZIP inventory and metadata passed local checks: contained icon, field lengths, five positive/three negative cases, canonical streamable-HTTP endpoint, no private app bindings or credentials. This is **not official portal schema validation or submission readiness**.
- Official policy and existing website/support/privacy content were fetched and inspected through read-only GitHub Actions. See `PLATFORM_REQUIREMENTS.md` for evidence.

Firebase integration and GitHub CI outcomes are recorded on the PR when complete. No production reviewer, native Apple login, actual ChatGPT/Claude cases or recordings are claimed by these automated checks. The new public-page styling is not deployed by this branch.
