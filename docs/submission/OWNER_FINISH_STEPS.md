# Owner steps remaining after technical preparation

This file records real dependencies, not a submitted/approved listing. No messages have been sent to either platform.

## Reviewer sign-in

The production account is created and its credentials are stored in [KROK Secret Manager](https://console.cloud.google.com/security/secret-manager?project=krok-1d60a), secret `krok-directory-reviewer-credentials`. Do not paste them into chat, the repository, videos or listing text. Production browser sign-in, OAuth/PKCE and all 18 MCP tools passed after the owner approved enabling the password provider.

The approved change set `signIn.email.enabled=true` and `signIn.email.passwordRequired=true` in project `krok-1d60a`. Apple login remains supported; health OAuth still requires Apple or an administrator-marked password reviewer. Unit and real Auth-emulator browser tests confirm ordinary password users are refused. Normal production verification never changes provider settings.

Both walkthroughs were recorded and visually sampled on October 2, 2026; see the platform demo review files. Run any remaining acceptance cases using `RECORDING_GUIDE.md`. Use the email/password from the secret in “Directory reviewer access” on the OAuth page after starting connection in each host. The real host cases and recording URLs remain required; synthetic protocol checks cannot replace them.

## Terms and eligibility

The publisher approved `docs/legal/TERMS_OF_SERVICE.md` on October 2, 2026 after requesting removal of the street address and email. The approved page is staged at `firebase/hosting/terms.html`; verify `/terms` after deployment. This approval covers the terms wording and publication, not directory policy attestations.

OpenAI's PHI prohibition and sensitive-data requirements need a publisher compliance determination for the actual Apple Health inventory. Use the documented eligibility question if clarification is needed. Consent and “not medical advice” do not establish acceptance by themselves.

## Organization, portal and domain

1. The publisher reports that **2ndOp Inc verification is approved** as of October 2, 2026. This was not independently inspected in the portal. Sign in at [OpenAI Platform](https://platform.openai.com/login). Select/create the organization for **2ndOp Inc**, then complete business verification in [organization settings](https://platform.openai.com/settings/organization/general). Keep selected organization/project and verified public identity consistent with the package.
2. Once approved legal URLs and real recordings are incorporated, build and validate the final ZIP. Confirm a supported category, the country allowlist excluding RU/BY, and real case evidence. Open [OpenAI plugin submissions](https://platform.openai.com/plugins) and upload the final draft using the organization owner or Apps Management Write role. Inspect the saved fields; an upload is not a submission.
3. Supply the exact domain challenge token and the portal-selected host. `prepare-domain-challenge.py` stages the token at `/.well-known/openai-apps-challenge` and refuses replacing a different token. Deploy, check exact plain-text response on that origin, and confirm domain verification. Static files take precedence over Firebase rewrites; do not change the OAuth discovery handler to carry a placeholder token.
4. Complete actual saved-version OAuth and all eight host cases, secure reviewer fields and scans. The authorized owner completes current legal/policy attestations. Submit for review only with complete evidence. Publication follows approval as a separate step.
5. For Claude, use [directory management](https://claude.ai/directory/manage) on an eligible paid plan. Follow `CLAUDE_SUBMISSION_DRAFT.md`, connect the canonical public endpoint, disclose personal health data, confirm every tool through MCP Inspector or actual Claude, and supply secure reviewer fields. Verify permanent slug/category/region controls, complete owner compliance acknowledgments, then submit. Do not upload the OpenAI ZIP as a substitute for Claude's connector flow.

The current tools cannot control the owner's logged-in OpenAI/Claude dashboards or make business verification and owner attestations. They can prepare, validate and repair the technical artifacts and incorporate supplied challenge/recording evidence.
