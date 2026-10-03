# KROK Privacy Policy (DRAFT – needs legal review before launch)

_Last updated: 3 October 2026. Controller: 2ndOp Inc · support@2ndopinions.ai._

## What KROK does
KROK copies your **workouts** from Apple Health, with their detailed measurements and GPS routes, plus **daily and hourly summaries** (sleep, heart rate, steps and similar), to our servers, so that the AI assistants **you** connect (Anthropic's Claude and/or OpenAI's ChatGPT) can answer questions about your training and recovery. If you choose, KROK can also share further groups of Apple Health data (see "Additional data groups").

## What we collect
- **Workouts** you allow in Apple Health: type, time, duration, energy, distance, heart rate and the other measurements recorded during the workout (for example speed, power, cadence), how they changed over the workout, and the plan the workout was run from, if any.
- **Location:** the **GPS route** of outdoor workouts (latitude, longitude, altitude, speed). Routes can reveal where you live or work. By default, the tools your AI assistant uses hide the first and last 300 metres of each route; exact routes are only returned if you ask your assistant for them.
- **Daily and hourly summaries**: sleep, resting heart rate, heart rate variability, hourly heart rate and steps, activity totals, fitness trends, body measurements, and similar. All of your available history is copied.
- **Account identifiers:** an anonymous Firebase account ID is created on your phone. When you choose Sign in with Apple, Firebase links an Apple account identifier to that same account so you can authorize assistants and restore access. KROK does not request your name or email from Apple; Apple and Firebase may process identity-token claims under their own policies. Dedicated directory-review accounts use an email/password and synthetic data, not customer health data.
- **Technical and product-usage data:** crash reports; app version; whether onboarding steps, a sync and an assistant connection succeeded; coarse sync and tool-call duration; which assistant and KROK tool were used; and when those events occurred. These events are linked to the pseudonymous KROK account so we can measure the activation funnel and retention. They never contain Health values, workout counts or metadata, GPS routes, Health dates, tool arguments, free text, connector links, your email or your Apple identifier.

## Additional data groups (on by default, you choose)
These groups are read when you connect Apple Health, if you track them. Apple Health shows each type and lets you allow or deny it. In the app, **••• menu → Your data**, you can switch a group off at any time, which **deletes its data from our servers**.
- **Nutrition and alcohol:** logged food and drink with the nutrients and times, alcoholic drinks, blood alcohol content.
- **Heart alerts and lung function:** high/low heart rate and irregular rhythm notifications, atrial fibrillation burden, lung function measurements, inhaler use.
- **Glucose, insulin and blood pressure:** readings recorded in Apple Health (for example by a continuous glucose monitor).
- **Mood and symptoms:** state of mind entries, mindful minutes and symptoms you log (such as headache, fever, fatigue).
- **Menstrual cycle:** cycle tracking entries.
- **Medications:** the list of medications you choose to share (names only, no dose history).
- **Profile:** date of birth, sex, wheelchair use and activity mode, used to interpret your numbers.
This is health data of a particularly sensitive kind. KROK describes it back to you through your assistant; it does not diagnose, and neither KROK nor the assistant gives medical advice.

We do **not** read clinical records or documents, reproductive and sexual-health data such as pregnancy or contraception, or ECG recordings.

## Why we use it (legal bases)
- To provide the service you asked for: storing your data so your connected assistants can read it (GDPR Art. 6(1)(b)).
- Health data is special-category data. We process it only with your **explicit consent** (GDPR Art. 9(2)(a)), given when you connect Apple Health (including the types you allow on Apple's permission sheet), and again, per assistant, when you connect Claude or ChatGPT. You can withdraw consent at any time by switching a group off in KROK or in Apple Health, disconnecting, or deleting your data.
- Crash and usage diagnostics: our legitimate interest in understanding and improving whether the service works (Art. 6(1)(f)). These never contain health data and are not used for advertising or tracking across apps or websites.

## Who receives it
- **Google Cloud / Firebase** (our processor) stores your health data **in the EU (Belgium)**. Your account identifiers are processed by Firebase Authentication, which may process them in the United States (EU Standard Contractual Clauses).
- **The AI assistant you connect** (Anthropic or OpenAI) receives the parts of your data it requests when you ask it a question. Once received, that data is handled under **their** terms and privacy policies, which you accepted with them. We don't control their processing, storage location or retention.
- We never sell your data, use it for advertising, or share it with anyone else.

## How long we keep it
Until you delete it (••• menu → Delete All My Data, completed within 24 hours), or automatically **one year after your last sync**. Data of an additional group is deleted as soon as you switch that group off. Product events and access logs (which tool was used and when, no health values or arguments) are kept for 90 days. One-time funnel milestones are deleted with the account. Daily analytics rollups contain aggregate counts and durations without account identifiers.

## Your rights
You can access, correct, export or delete your data, withdraw consent, and complain to your data protection authority. The easiest way to delete your server data is in the app. For anything else, email support@2ndopinions.ai.

## Security
Encryption in transit and at rest, per-assistant private links that can be revoked, strict access controls, and no health data or locations in logs. Anyone who has your private link can read your data through it, so treat it like a password and disconnect the assistant if it is exposed.

## Public assistant connections
Public MCP connections use Sign in with Apple and a read-only authorization page identifying the assistant and requested permissions. Access credentials expire after 15 minutes; rotating refresh credentials keep an approved connection working for up to 30 days before you authorize it again. We store hashes of these credentials and the associated permission grant. Disconnecting an assistant invalidates its OAuth grants immediately. Deleting your account removes its grants and credentials as well as its health data.

Detailed sensitive health events and personal profile details require separate requested permissions in addition to the data groups you enabled in KROK. Exact route endpoints require a separate, unchecked-by-default consent option as well as an explicit tool request. Existing private-link connections remain supported; they do not gain the scope restrictions of OAuth, so disconnect them if you no longer use them. Deleting your server data does not delete copies already received by an assistant.

## Children
KROK is not intended for children under 16.

## Changes
We'll notify you in the app of material changes.
