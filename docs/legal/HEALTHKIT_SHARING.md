# Apple HealthKit sharing assessment (DRAFT)

Apple's rules (App Store Review Guideline 5.1.3 and the HealthKit privacy documentation) allow HealthKit data to be used to provide health/fitness services to the user, and shared with third parties only with the user's permission, for health or fitness purposes. It may never be used for advertising or data mining, or sold.

**How KROK is designed to fit:**
- The **service** is health and fitness management. Users ask questions about their own workouts (pace, heart rate zones, routes, training load and recovery), and get answers based on their own data. The app, its screens, its listing and the review notes all describe exactly this.
- **The third party is chosen by the user**, named on a consent screen ("Anthropic processes this data under its own terms"), and only receives data when the user asks it a question.
- **No advertising, selling or data mining.** Server-side analytics never include health data.
- **Read-only.** Nothing is written to HealthKit. HealthKit data is not stored in iCloud.
- **Scoped and opt-in.** Workouts (with routes and measurements) and daily/hourly fitness and recovery metrics are read by default. Additional groups (nutrition, heart alerts, glucose/insulin/blood pressure, mood and symptoms, cycle, medications, profile) are separate switches that start on; Apple Health's permission sheet lists each type and the user can deny any, and each group can be switched off in the app. Each type is read only because a feature uses it (for example glucose around workouts, nutrition and recovery). Clinical records, reproductive/sexual-health data and questionnaires are not requested.
- **Controls:** disconnect per assistant; delete all data; automatic deletion after a year of inactivity.

- **Sensitive data:** assistants are instructed to describe the data and trends only, never to diagnose or to advise on medication or dosing, and KROK states it is not a medical device.

**Residual risk (owner-accepted):** App Review may consider a general-purpose AI assistant not to be a "health or fitness service". If rejected, the likely remedies are to (a) emphasize the health-coaching use case in the app, (b) add in-app explanations of example health questions, or (c) request a call with App Review. Only review can settle this.
