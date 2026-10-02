# Repair the Apple web sign-in identity

The October 2 production screenshot shows Apple's **Sniped** name and icon. Apple's primary app association supplies this branding. The production read-only check confirms Firebase's Services ID, team, key ID and private key match GitHub configuration, and KROK's native App ID has Sign in with Apple enabled. This does not prove the Services ID/key are associated with the right primary app or that Apple's live code exchange succeeds.

## Confirmed callback policy defect

The owner changed the Services ID primary app to KROK, and Apple's screen now displays KROK. A separate Chromium reproduction with the real Firebase SDK found Hosting's `script-src 'self'` blocks Google's required redirect helper from `https://apis.google.com`. PR34 permits that origin, preserves unrelated script restrictions and keeps failed callbacks recoverable. The before/after test uses a mocked helper response and does not complete an Apple login. After deployment, first retest a fresh real Apple connection before deciding whether a key change is necessary. Postdeployment verification checks the live script policy too.

## Inspect before changing

1. Open [Firebase Apple authentication](https://console.firebase.google.com/project/krok-1d60a/authentication/providers). Open **Apple** and note the **Services ID**, **Apple Team ID**, and **Key ID**. Do not copy the private key into chat. Team must be `AAZHPDPD2B`.
2. Open [Apple Developer identifiers](https://developer.apple.com/account/resources/identifiers/list/serviceId). Select **Services IDs** and open the exact Services ID shown in Firebase. Under **Sign in with Apple**, choose **Configure**. Check **Primary App ID**.
3. It must be the KROK app with identifier `com.vasylyk.krok`, rather than Sniped. Check [App IDs](https://developer.apple.com/account/resources/identifiers/list/bundleId): KROK must have Sign in with Apple configured as a primary App ID. If it is grouped with Sniped, inspect the implications for existing Apple users before changing that group; changing groups can change Apple identity mapping and require migration. Do not modify Sniped's existing primary app, key or shared Services ID as a shortcut.
4. For the canonical public MCP flow, the Services ID website configuration must include domain `krok-1d60a.firebaseapp.com` and exact return URL `https://krok-1d60a.firebaseapp.com/__/auth/handler`. If sign-in is supported from `krok-1d60a.web.app`, also register that domain and `https://krok-1d60a.web.app/__/auth/handler`. Save/Continue/Register to persist changes.
5. Open [Apple Developer keys](https://developer.apple.com/account/resources/authkeys/list). Inspect the **Key ID** from Firebase: its Sign in with Apple configuration must support the KROK primary App ID. A key can parse and match Firebase while belonging to the wrong primary app.

If the Services ID or key belongs to Sniped, create a dedicated KROK Services ID/key under KROK's primary app, preserving Sniped. Update Firebase Apple settings and GitHub `APPLE_SIGN_IN_SERVICE_ID`, `APPLE_SIGN_IN_KEY_ID`, and `APPLE_SIGN_IN_KEY_P8` through their secure consoles. Store the downloaded `.p8` securely; Apple allows downloading it only once. Never send it in chat.

## Verify the repair

Restart the connection from the assistant to obtain a fresh OAuth request. Confirm Apple's screen shows KROK, then complete real Apple login using the same Apple Account linked in the iPhone app. Check KROK consent appears, authorize and request a known workout. Confirm this links to the existing account/data rather than creating an unrelated identity.

Run the read-only Apple preflight after any configuration update. If `auth/internal-error` persists despite correct primary app/key/return URL, capture the failure time and inspect the sanitized Firebase Auth exchange error; do not share callback URLs, authorization codes, tokens or health data. The branding mismatch and generic Firebase error may have different causes.

These Apple portal checks require the owner's authenticated developer session. No Apple configuration or existing user identity has been changed by the diagnostic PR.
