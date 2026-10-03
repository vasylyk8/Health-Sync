# iPhone download link — launch requirement

Status: BLOCKED pending the owner-supplied public KROK App Store URL. The owner explicitly requested a placeholder until the listing is live. No public TestFlight or App Store URL was found or inferred.

Public home, authorization and connection-instructions pages show a disabled “App Store link coming soon” placeholder and explain iPhone setup, Health permissions/sync, Sign in with Apple and returning to the assistant. Existing users and synthetic reviewers can still authorize normally. This does not yet provide a working installation path for a new user.

Before public directory publication:
1. Obtain and verify KROK’s actual App Store URL, matching bundle ID com.vasylyk.krok and publisher 2ndOp Inc.
2. Replace all three data-krok-download="pending" placeholders in firebase/hosting/index.html, connect.html and mcp-docs.html with active download links. Preserve the existing PR30 action style.
3. Update scripts/tasks/verify-public-listing-pages.py and the consent browser assertion to require the active, correct destination instead of the placeholder. Verify mobile/desktop rendering and reviewer authentication.
4. Update OpenAI/Claude/Muse listing prerequisites and links through each platform’s appropriate draft/review update process; do not silently alter an in-review submission. State: “Requires the KROK iPhone app to sync your Apple Health data.”
5. Recheck that a new user can download, grant Health access, sign in with Apple, sync and return to their assistant. If their OAuth request expires during setup, restart from the assistant.

Do not mark this item complete until the link works. Do not use another app’s listing, a made-up Apple app ID or a fake download URL.
