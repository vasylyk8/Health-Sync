# Draft public upload source

`krok-health/` is a separate Agent Plugins 1.0 preparation copy pointing at the existing canonical MCP. It does not alter the installed private plugin or create another service. Build it with `python3 scripts/tasks/build-listing-package.py`. The ZIP contains only the manifest, remote MCP configuration and PR30 icon, with no credentials or private app bindings.

**Not ready to submit.** Terms and demo URLs are absent because they are not published/verified. Category and country allowlist await the target portal's supported values; unrestricted countries must not be substituted. Publisher identity is intended, not verified. Cases are drafted, not run in ChatGPT/Claude. See `docs/submission/README.md` for the complete readiness gaps.

Existing website/support/privacy URLs refer to the current Firebase site; inspect fetched live content before final handoff. This branch's new branding is not live until an approved deploy. Enter reviewer access only in secure dashboard fields. Claude uses its own connector portal and answers, not this ZIP.
