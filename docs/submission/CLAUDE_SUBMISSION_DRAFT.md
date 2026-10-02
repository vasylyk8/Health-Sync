# Claude connector answers — draft

Use [directory management](https://claude.ai/directory/manage) after prerequisite tests and eligibility review. Do not submit or check policy acknowledgments from this document alone.

- **Connection:** one remote URL, `https://krok-1d60a.firebaseapp.com/mcp`; public OAuth, not per-user secret links.
- **Name:** KROK.
- **One-liner:** Your Apple Health, explained.
- **Description:** KROK connects the Apple Health data you choose to Claude. Explore synced workouts, kilometre splits, heart-rate series, sleep and daily activity. Sign in with Apple and authorize Claude separately. Access is read-only. Routes hide their first and last 300 metres by default; exact endpoints require additional consent and an explicit request. Timed nutrition and profile details require additional permissions. Data can be incomplete or delayed. KROK describes data and trends; it does not diagnose, prescribe or provide medical advice.
- **Documentation:** https://krok-1d60a.firebaseapp.com/mcp-docs
- **Terms:** https://krok-1d60a.firebaseapp.com/terms (verify after deployment).
- **Demo:** https://drive.google.com/file/d/1bHNkx5rvJSU8aMhlTKbo36jjviG2N6l6/view?usp=sharing
- **Privacy:** https://krok-1d60a.firebaseapp.com/privacy
- **Support contact:** vasylyk@outlook.com (existing public support address).
- **Icon:** PR30's actual `submission/krok-health/assets/icon.png`.
- **Categories:** choose applicable supported consumer-health/fitness categories in the portal; verify current options.
- **Slug:** proposed `krok`, subject to availability and owner approval; permanent after publication.
- **Use cases:** inspect workouts and pace, compare activity/sleep, explain returned health trends without diagnosis. Requires KROK on iPhone, permissioned HealthKit sync, native Sign in with Apple linking the synced account, and OAuth consent. Reads data only. Current release has no paid plan requirement.
- **Company:** 2ndOp Inc. Product website https://krok-1d60a.firebaseapp.com/ identifies publisher. Confirm portal accepts a product website for the company field; do not invent a separate corporate website. Primary contact: owner confirms use of the existing support address for review updates.
- **Authentication:** OAuth 2.0, dynamic client registration, public client with PKCE S256; no client secret required. Dedicated synthetic password reviewer path is restricted by claim and provides review access without a mailbox or phone.
- **Data handling:** KROK owns the backend API and imports through user-authorized Apple HealthKit. **Yes, handles personal health data.** No sponsored content or advertising. Explain separately consented scopes, trimmed routes, downstream Claude processing, deletion and retention using the approved privacy policy. Do not characterize Apple Health as a company-owned API or claim PHI eligibility is established.
- **Test & launch:** secure account fields only after provisioning and clean-browser checks. All tools must be tested through MCP Inspector or the actual Claude connection before confirming this requirement; automated unit tests alone are insufficient. The demo was recorded and visually sampled on October 2, 2026; remaining real-host acceptance cases still require evidence. See `KROK_CLAUDE_DEMO_REVIEW_2026-10-02.md`.
- **Compliance:** owner must review all seven required acknowledgments against actual behavior and current directory terms. No acknowledgments have been made here.
- **Countries:** all target-platform supported countries except RU/BY; verify available targeting controls and enforcement before publication. Do not assume the prose imposes a geographic block.
