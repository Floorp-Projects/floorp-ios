# Floorp iOS App Privacy declaration

- Owner: Floorp release manager
- Applies to: `app.floorp.Floorp`
- Last source audit: 2026-09-04
- Canonical machine-readable declaration: `docs/app-store-connect-metadata.json`

This is the release checklist for the App Store Privacy Nutrition Label and the public
Floorp privacy policy. It intentionally makes a conservative disclosure for optional,
account-associated Firefox Sync data even though Sync encrypts record content end to end
before upload and Mozilla cannot decrypt that content.

Apple defines collection as off-device transmission that lets the developer or a third-party
partner access data for longer than a real-time request. Apple also says ongoing collection
after an initial opt-in must be disclosed, app-level answers should be comprehensive, and
third-party partners must be included. See [App privacy details][apple-privacy-details] and
[Manage app privacy][apple-manage-privacy].

## App Store Connect answers

Set tracking to **No**. Configure every row below as collected, linked to the user's identity,
not used for tracking, and with the listed purposes.

| Category | Data type | Purposes | Shipping-build basis |
| --- | --- | --- | --- |
| Contact Info | Name | App Functionality | Optional Mozilla Account display name; names in Sync address/payment records |
| Contact Info | Email Address | App Functionality | Mozilla Account email; email in Sync address records |
| Contact Info | Phone Number | App Functionality | Telephone number in region-eligible Sync address records |
| Contact Info | Physical Address | App Functionality | Street/locality/region/postal-code/country in Sync address records |
| Financial Info | Payment Info | App Functionality | Optional credit/debit-card autofill Sync records |
| Location | Coarse Location | App Functionality; Analytics | Country/city/region inferred by Mozilla Account services from the connection IP |
| User Content | Photos or Videos | App Functionality | Optional Mozilla Account profile image managed in the account web flow |
| User Content | Other User Content | App Functionality | Floorp notes, account/authentication data, saved website usernames/passwords, and bookmark metadata |
| Browsing History | Browsing History | App Functionality | Optional Sync history, bookmark URLs, and open-tab URLs |
| Search History | Search History | App Functionality | Searches represented in Sync history; this is also conservative coverage for search-suggestion requests |
| Identifiers | User ID | App Functionality; Analytics | Mozilla Account UID used for authentication and Sync |
| Identifiers | Device ID | App Functionality; Analytics | Account-bound device and Sync-client identifiers |
| Usage Data | Product Interaction | App Functionality; Analytics | Mozilla Account connected-service use, settings interactions, and last-sync activity |
| Diagnostics | Crash Data | App Functionality; Analytics | Mozilla Account connected-service failures handled by its third-party error service |
| Diagnostics | Performance Data | App Functionality; Analytics | Account/Sync operational timestamps, success/failure, and performance data |
| Diagnostics | Other Diagnostic Data | App Functionality; Analytics | Account/Sync error messages, device information, and service state |
| Other Data | Other Data Types | App Functionality; Analytics | Account eligibility age, authorization, language, settings, and technical service data |

Apple has no password-specific data type. Use **Other User Content**, not **Sensitive Info**;
Apple reserves Sensitive Info for characteristics such as racial or ethnic data, beliefs,
political opinions, disability, biometrics, and similar categories.

All listed types are linked because the applicable retained path is a Mozilla Account or Sync
record. Account/Sync operational data is used for both App Functionality and Analytics; the other
types are used only for App Functionality. None is used for tracking.

## Source evidence

- `SyncContentSettingsViewController.generateSettings()` defaults bookmarks, history, tabs,
  passwords, credit cards, addresses where region-enabled, and Floorp notes to on after sign-in.
- `MozillaAppServices.Address` contains name, organization, street, locality/region,
  postal code, country, telephone, and email fields.
- `MozillaAppServices.CreditCard` contains cardholder name, encrypted card number, last four
  digits, expiration, and card type.
- `MozillaAppServices.Profile` contains Mozilla Account UID, email, display name, and avatar URL.
- `MozillaAppServices.AttachedClient` and the device-constellation UI expose account-bound
  client/device identifiers and device names.
- Mozilla's account notice says the service processes account/contact/authorization data,
  IP-derived location, settings, interaction, technical, performance, and error data; it also
  describes a third-party error service for connected-service failures. See
  [Mozilla Accounts Privacy Notice][mozilla-account-privacy].
- Mozilla documents that Sync stores bookmarks, history, open tabs, passwords, addresses, and
  payment methods on a remote server and encrypts the content end to end before it leaves the
  browser. See [Sync Firefox data][mozilla-sync] and
  [Choose what information to sync][mozilla-sync-types].

Floorp sets `FloorpFlags.isTelemetryDisabled` before launch services initialize, forces the
Glean, daily-usage, studies, rollouts, and crash-reporting preferences to false, prevents Glean
initialization and MetricKit submission, and leaves Floorp's Sentry path inert. Floorp also
disables sponsored-content reporting and advertising attribution. The Usage Data and Diagnostics
rows above are therefore limited to Mozilla Account service processing; they do not represent
Floorp Glean, MetricKit, or Sentry uploads. Re-enabling any Floorp-owned upload path requires
updating this declaration first.

The default search-suggestion client sends typed terms to the configured search provider using
an ephemeral session. Floorp does not retain that request off-device. Provider processing is
governed by the provider selected by the user; the conservative Search History row remains in
the declaration. Ordinary traffic to websites selected by the user is open-web navigation,
which Apple explicitly distinguishes from app data collection.

## Public privacy-policy release gate

As of the audit date, `https://floorp.app/privacy` is not sufficient for this iOS release. It
mentions Sync only generally and does not enumerate the data types above, identify Mozilla as
the retained account/Sync service partner, or explain concrete retention/deletion and consent
revocation behavior. It also says telemetry and crash reports are opt-in even though this
shipping Floorp configuration disables them.

Before marking the App Privacy confirmation in a release workflow, publish a policy update that:

1. identifies every account, operational, and Sync category in the table;
2. identifies Mozilla Account and Mozilla Sync as service providers and explains that Sync
   content is stored only as account-associated end-to-end-encrypted ciphertext;
3. states that Floorp telemetry, crash reporting, sponsored reporting, and ad attribution are
   disabled in this build;
4. explains retention and deletion, including engine disablement, Mozilla Account disconnection,
   deletion of server-side Sync data, and account deletion;
5. explains how users revoke ongoing Sync consent and where they can exercise deletion/privacy
   rights; and
6. states that none of the declared data is used for tracking.

Apple's [App Review Guidelines, section 5.1.1][apple-review-guidelines] require the public policy
to identify collection and use, third-party access/protection, retention/deletion, and consent
revocation. Do not attest that the live policy matches the metadata until those points are public.

[apple-privacy-details]: https://developer.apple.com/app-store/app-privacy-details/
[apple-manage-privacy]: https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/
[apple-review-guidelines]: https://developer.apple.com/app-store/review/guidelines/#privacy
[mozilla-sync]: https://support.mozilla.org/kb/sync
[mozilla-sync-types]: https://support.mozilla.org/kb/how-do-i-choose-what-information-sync-firefox
[mozilla-account-privacy]: https://www.mozilla.org/privacy/mozilla-accounts/
