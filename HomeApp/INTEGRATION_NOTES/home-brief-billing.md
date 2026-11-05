# Home Brief purchase

Home Blueprint keeps its existing tasks, projects, inventory, budgets and CSV export free. Home Brief adds an optional, one-time purchase for preparing a PDF of selected completed work. Settings and the brief builder show the App Store price and offer Restore Purchase. StoreKit grants access from verified current entitlements and handles pending approvals and revoked purchases through its transaction listener.

## App Store Connect

Use the existing **Home Blueprint** app record, Apple ID **6817578211**. In App Information, confirm the bundle ID used by the existing TestFlight build and append `.homebrief` to form the product ID. The default local build uses `app.fumble.home.homebrief`. The app derives the ID from its installed bundle at runtime, including when the existing signing workflow overrides `HOME_BUNDLE_ID`.

Create a **non-consumable** called **Home Brief**. The proposed US storefront price is **$14.99**, which is also the local fixture price. Configure availability, the production price, localizations and the review screenshot in App Store Connect. The publisher’s Paid Apps Agreement, tax and banking details must be active. Submit the first purchase with the app version.

## Verification

- The Home scheme uses the local StoreKit configuration when run from Xcode. The fixture is included in HomeTests and excluded from the app archive. Keep the default bundle ID when running these simulator tests. Demo screenshots and SwiftUI purchase previews do not contact the App Store.
- Generate the project using the existing XcodeGen workflow and run the Home scheme’s **Test** action on an iPhone simulator. The app-hosted StoreKit cases cover purchase, restore after relaunch, a refund, a failed payment and Ask to Buy approval. Billing-state tests also cover cancellation, verification failure, unavailable products and duplicate taps.
- Use the signed TestFlight build and the production product record to verify localized pricing, purchase, an independent restore and access after a refund. Confirm the PDF grants access only after Apple verifies the purchase and that existing free workflows continue to work.

Reviewers can find the purchase in Settings and in the Home Brief builder. A homeowner chooses which completed work to include, previews the PDF and chooses a sharing destination. Apple handles payment and restoration for the purchasing Apple Account.

[Apple’s sandbox setup for review](https://developer.apple.com/help/app-review/before-submitting-for-review/configure-in-app-purchases) · [StoreKit testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)
