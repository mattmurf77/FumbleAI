# Home Brief purchase

Home Blueprint keeps its existing tasks, projects, inventory, budgets and CSV export free. Home Brief adds an optional, one-time purchase for preparing a PDF of selected completed work. Settings and the brief builder show the App Store price and offer Restore Purchase. StoreKit grants access from verified current entitlements and handles pending approvals and revoked purchases through its transaction listener.

## App Store Connect

Use the existing **Home Blueprint** app record, Apple ID **6817578211**. In App Information, confirm the bundle ID used by the existing TestFlight build and append `.homebrief` to form the product ID. The default local build uses `app.fumble.home.homebrief`. The app derives the ID from its installed bundle at runtime, including when the existing signing workflow overrides `HOME_BUNDLE_ID`.

Create a **non-consumable** called **Home Brief**. The proposed US storefront price is **$14.99**, which is also the local fixture price. Configure availability, the production price, localizations and the review screenshot in App Store Connect. The publisher’s Paid Apps Agreement, tax and banking details must be active. Submit the first purchase with the app version.

## Read the catalog or create a draft

From the repository root, the existing `bundle exec fastlane ios status` lane also checks Home Brief. It derives the SKU from the bundle returned by Apple for app 6817578211. It reports absence or product type, state, locales, US price periods and availability, subject to the key’s permissions. The status client accepts GET requests only. A permission error is reported as an incomplete check.

The separate, manual `bundle exec fastlane ios prepare_home_brief` lane uses the same Fastlane authentication and `HOME_BUNDLE_ID`. Use it only for intentional draft setup. For an absent SKU, it creates the non-consumable and en-US localization, selects the exact $14.99 US price point Apple returns for that IAP, and requests availability in the USA only, with automatic availability in future territories turned off. The catalog read at the end reports Apple’s resulting configuration. The English description is “Export selected home projects as a PDF.”

An existing SKU is read back and preserved. If Apple interrupts setup after creating the new product, keep its logged Apple product resource ID. Read the status, then use `bundle exec fastlane ios prepare_home_brief resume_id:APPLE_RESOURCE_ID` to fill missing configuration for that exact MISSING_METADATA draft. Any existing localization, price schedule or availability is preserved. If an existing setting needs a change, review it directly in App Store Connect. Coordinate with other App Store Connect editors during manual setup.

The helper can post only to Apple’s product, localization, price-schedule and availability endpoints. Review screenshots, submission, agreements, tax/banking and release remain separate publisher steps. No automatic workflow triggers the draft helper.

[Apple product API and pricing examples](https://developer.apple.com/documentation/appstoreconnectapi/managing-in-app-purchases) · [Apple availability request](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-inapppurchaseavailabilities) · [Apple product metadata limits](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/)

## Verification

- The Home scheme uses the local StoreKit configuration when run from Xcode. The fixture is included in HomeTests and excluded from the app archive. Keep the default bundle ID when running these simulator tests. Demo screenshots and SwiftUI purchase previews do not contact the App Store.
- Generate the project using the existing XcodeGen workflow and run the Home scheme’s **Test** action on an iPhone simulator. The app-hosted StoreKit cases cover purchase, restore after relaunch, a refund, a failed payment and Ask to Buy approval. Billing-state tests also cover cancellation, verification failure, unavailable products and duplicate taps.
- Use the signed TestFlight build and the production product record to verify localized pricing, purchase, an independent restore and access after a refund. Confirm the PDF grants access only after Apple verifies the purchase and that existing free workflows continue to work.

Reviewers can find the purchase in Settings and in the Home Brief builder. A homeowner chooses which completed work to include, previews the PDF and chooses a sharing destination. Apple handles payment and restoration for the purchasing Apple Account.

[Apple’s sandbox setup for review](https://developer.apple.com/help/app-review/before-submitting-for-review/configure-in-app-purchases) · [StoreKit testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)
