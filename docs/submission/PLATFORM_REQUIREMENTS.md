# Platform requirements — checked 2 October 2026

Evidence: read-only GitHub Actions `listing-policy-research` saves the fetched final URLs, content, timestamp and HTTP status in its artifact. Requirements can change; re-fetch before submission. These notes are not an eligibility decision or legal advice.

## OpenAI

Sources: [plugin guidelines](https://developers.openai.com/plugins/plugin-guidelines) and [submission](https://developers.openai.com/plugins/deploy/submission). The old Apps SDK URLs redirect to these current plugin-directory documents.

The guidelines prohibit collecting, soliciting or processing **protected health information (PHI)**. They separately allow necessary sensitive/special-category personal data only with legally adequate consent and prominent disclosure. KROK reads consumer Apple Health data through HealthKit and may include glucose, medication names, mood, cycle and profile data. It does not read clinical records, diagnose or prescribe. Those facts do not establish that every input is outside PHI or otherwise allowed. The publisher must confirm applicable legal classification and seek eligibility clarification for ambiguous scope before attesting compliance. Do not silently remove features or claim health-category listings prove eligibility.

Suggested eligibility question, not sent: “2ndOp Inc operates KROK, a first-party iPhone app using HealthKit with user permission. Its read-only MCP provides user-selected consumer workouts and activity/sleep summaries; separately requested scopes can expose sensitive events/profile, and precise route endpoints require additional consent. It does not read clinical records, diagnose or prescribe. What consumer-health scope is eligible under your PHI and sensitive-data rules, and what evidence/disclosures are required?” Include the actual data inventory and consent screenshots when asking.

Submission requires a verified developer identity, organization permissions, a ZIP with listing and MCP metadata, all four public website/support/privacy/terms URLs, real demo, reviewer access, five positive/three negative cases, domain challenge, scans and owner legal attestations. Credentials belong only in secure reviewer fields. New digital subscription checkout/upsells are currently restricted; existing paid-account access is a separate case. KROK has no purchase flow in this release.

The public publisher name must match the verified identity. `author.name` is not business verification. Confirm the selected organization is 2ndOp Inc before upload. Start at [OpenAI Platform](https://platform.openai.com/) and follow the current organization verification and plugin submission instructions above; do not create a second private KROK installation to obtain a public listing.

The portal supplies an exact plain-text token for `/.well-known/openai-apps-challenge` on the challenge host. Wait for that token and selected host; do not deploy a placeholder or alter OAuth discovery. Existing Firebase Hosting can serve the public pages and challenge. A new website/domain is not automatically required, although portal acceptance of the selected origin must be confirmed. Submission for review and publishing an approved release are separate steps.

## Claude

Sources: [connector directory](https://claude.com/marketplace/connectors-plugins) and [connector submission](https://claude.com/docs/connectors/building/submission#submit-your-connector). This is the remote-MCP connector route, distinct from Claude's plugin-bundle submission path. Follow Claude's own requirements and form; the OpenAI ZIP is not a substitute.

The directory includes consumer-health and health/life-sciences categories. Categories are not evidence that KROK is eligible or approved. The submission flow explicitly asks whether the connector handles personal health data and whether the underlying API is first-party, authorized partner data or an uncontrolled third-party API. Answer health-data handling truthfully and explain that KROK owns its service and imports through authorized HealthKit access.

The current official route is [Claude directory management](https://claude.ai/directory/manage), available to eligible paid-plan users; organization/role rules are in the linked directory publishing guidance. It is a portal flow, not an assumed external application form. Listing fields differ from OpenAI: name up to 100 characters, one-liner up to 200, description up to 2,000, one to five categories, documentation and privacy URLs, support contact, icon and a permanent published slug. Authentication options include OAuth with dynamic client registration (implemented by KROK). The portal syncs tools and flags missing titles/annotations. Prepare security/privacy/data-ownership answers and the real Claude demo; verify the saved listing and its scopes before submission.

The [Anthropic Software Directory Policy](https://support.claude.com/en/articles/13145358-anthropic-software-directory-policy), fetched successfully on the same date, requires protecting user/third-party privacy, responsible handling of sensitive data and compliance with applicable law. It does not establish KROK's legal compliance. The submission page requires confirming every tool has been tested through MCP Inspector or the actual Claude custom connection, and seven owner policy acknowledgments. Do not substitute unit tests for that confirmation.

Research evidence: [Actions run 37003343010](https://github.com/vasylyk8/Health-Sync/actions/runs/37003343010), artifact `listing-policy-sources`. All fetched official pages and the three existing KROK listing URLs returned 200. Content inspection confirmed website purpose, support contact, publisher and public-OAuth privacy coverage. The website/support still use their prior styling until this preparation branch is deployed. Terms and recordings remain unverified/unpublished.

## Privacy reconciliation before owner approval

Compare `docs/legal/PRIVACY_POLICY.md`, live Firebase `/privacy`, and the GitHub Pages policy the owner identified. Keep a single approved source and ensure all linked copies cover Sign in with Apple, public OAuth, default-trimmed routes and separately consented precise endpoints, optional on-device groups versus assistant scopes, cloud retention/deletion and downstream assistant processing. Do not assert unpublished text is live. Preserve support contact and 2ndOp Inc identity.
