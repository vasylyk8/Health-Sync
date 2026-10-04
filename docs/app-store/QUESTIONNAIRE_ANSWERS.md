# Questionnaire answers

Owner confirmed the policies and authorized completing questionnaires on October
4, 2026. This authorizes entering supported answers; it does not supply missing
business contacts or establish unobserved SDK settings.

## Age rating

**Saved and read back in App Store Connect.** Verification run:
https://github.com/vasylyk8/Health-Sync/actions/runs/37207454594

Apple returned `ageRatingOverrideV2: SIXTEEN_PLUS`. Its legacy
`appStoreAgeRating` field returned `SEVENTEEN_PLUS`; check the current portal's
displayed rating before release rather than assuming those fields are equivalent.

The exact saved payload is in `scratch-app-store/questionnaires.json`.

- Health/wellness topics: **Yes**.
- Medical/treatment information: **Infrequent or mild**. KROK exposes the user's
  health measurements, symptoms and optional medication names; it does not diagnose
  or give treatment/dosing instructions.
- Alcohol/tobacco/drug references: **Infrequent or mild**, because optional health
  records include alcoholic drinks and blood alcohol data.
- Advertising, parental controls, age assurance: **No**. An age-16 policy is not an
  implemented age-verification control.
- Unrestricted browsing, public user-generated content, messaging/chat and social
  media: **No**. KROK's private goal/health inputs are not a public content feed;
  assistant conversations happen in separate services.
- Contests, simulated gambling, real gambling, loot boxes: **None/No**. Race data
  and a personal goal are not an in-app contest with prizes.
- Violence, weapons, horror, profanity, mature/suggestive themes and sexual
  content/nudity: **None**. Menstrual health records are health information.
- Kids age band: **Not applicable**.
- Age override: **16+**, matching the approved age-16 terms.

No regional override or classification number is invented.

## App Privacy

**Prepared, not saved.** The available API returned HTTP 404/PATH_ERROR for the
privacy relationship: `The relationship 'dataUsages' does not exist`. This
connection has API credentials but no authenticated interactive portal session.
Enter the finalized answers under App Store Connect > KROK > App Privacy.

The owner-supplied disclosure sheet proposes these rows. App Privacy labels remain
separate from the binary's privacy manifest. Final SDK/console checks remain
technical validation even though the policy is approved.

For each confirmed collected row below: **linked to user Yes**, **tracking No**,
subject to final verification that Analytics configuration does not enable tracking
under Apple's definition.

| Data type | Purpose |
| --- | --- |
| Health | App Functionality |
| Fitness, including private race goals | App Functionality |
| Precise Location: workout routes | App Functionality |
| Coarse Location: Analytics IP-derived region | Analytics |
| Sensitive Info: health profile, including wheelchair use | App Functionality |
| User ID | App Functionality, Analytics |
| Device ID: app-instance/installation identifiers | App Functionality, Analytics |
| Product Interaction | Analytics |
| Crash Data | App Functionality |
| Performance Data | Analytics |
| Other Diagnostic Data | App Functionality, Analytics |

Email remains a factual check: Firebase may receive an email in federated token
claims despite Apple sign-in requesting no email scope. If it does, select
**Email Address / linked / App Functionality / no tracking**. Do not assert no
collection based only on the absence of requested scopes. See SDK_DISCLOSURES.md
for the inspection that avoids exposing tokens or personal information.

No separate Other User Content row is needed solely for a structured race finish
goal already classified as Fitness. Revisit if the final app adds free-form content.

No Contacts, Photos/Videos, Browsing History, Search History, Purchases, Financial
Info, Audio Data, or other contact information is documented as collected.

## Encryption/export compliance

**Prepared; final build association pending.** No encryption declaration or build
record was modified in this questionnaire operation.

Based on the documented standard HTTPS and Apple/OS encryption implementation:

- Uses encryption: **Yes**.
- Proprietary/nonstandard encryption: **No**.
- Standard encryption implemented instead of, or in addition to, Apple OS
  encryption: **No**, for the documented OS-provided TLS implementation.
- `ITSAppUsesNonExemptEncryption`: **false**.
- Additional exemption/upload documentation: **not expected for the documented
  implementation**. Recheck the final binary and SDK inventory before associating
  a build; no custom-encryption declaration is created unnecessarily.

Export compliance is associated with the actual build. The approved answers do not
select a build, upload an archive or submit the app.

## Business fields

EU trader classification, public business address/phone, review contact and account
agreements need the owner's actual account/business facts. No placeholder or
personal contact information is entered. Policy approval does not supply these
details or authorize accepting future account agreements.
