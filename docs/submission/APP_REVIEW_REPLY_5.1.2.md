# Reply to App Review: 5.1.2(i) tracking, 5.1.1(i)/5.1.2(i) AI data sharing, 5.2.5 (iOS 1.0, build 78 rejected 13 Nov 2026)

Paste in App Store Connect (App Review → the submission → Reply) after the new build is attached. Replace `<BUILD>` and `<VIDEO LINK>`.

```
Hello, thank you for the detailed review. We have addressed all three issues in build <BUILD>.

1. Guideline 5.1.2(i) – App Tracking Transparency
KROK does not track users. The App Privacy information was filled in incorrectly; we have corrected it. Email Address and Name were removed (KROK does not collect them; Sign in with Apple requests neither), and no data type is marked as used for tracking or for advertising. KROK has no advertising, no data brokers and no advertising identifier, so it does not need App Tracking Transparency.

2. Guidelines 5.1.1(i) and 5.1.2(i) – Sharing data with a third-party AI service
KROK now asks for permission inside the app before any data can be shared with an AI service. When the user taps Claude or ChatGPT on Home, a consent screen opens first, in every case (including the App Review sign-in). It:
- names who receives the data: Anthropic (Claude) or OpenAI (ChatGPT);
- lists what the assistant can read: workouts and their measurements, GPS routes (first and last 300 m hidden), daily and hourly summaries of sleep, heart rate, steps and activity, nutrition, cycle tracking and profile if allowed in Apple Health, and race goals;
- links to that company's privacy policy and to KROK's;
- has "Allow" and "Don't Allow" buttons. Nothing is shared and no setup steps are shown until the user taps Allow. Disconnecting withdraws the permission, and it is asked again before any new connection.
The privacy policy (https://krok-1d60a.web.app/privacy, section "Who receives it") now states what data is shared with each AI company, that it is shared only after this consent, and that both companies protect it under their privacy policies with protections equal to KROK's.
To see it: sign in with the test account ("App Review sign-in" on the first screen), then tap Claude on Home. Recording: <VIDEO LINK>

3. Guideline 5.2.5 – Apple trademarks
We removed "Apple Health" from the app name (now "KROK: Fitness MCP for AI") and from the keywords, and rewrote the description so it refers to Apple Health only to say the app works with it.

Thank you.
```
