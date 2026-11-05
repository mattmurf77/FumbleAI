import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Available inside either the existing Settings form or the gated brief builder.
struct HomeBriefPurchaseView: View {
    var body: some View {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            HomeBriefPurchaseSection().environmentObject(BlueprintBilling(isDemo: true))
        } else {
            HomeBriefPurchaseSection()
        }
    }
}

private struct HomeBriefPurchaseSection: View {
    @EnvironmentObject private var store: BlueprintBilling
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            if store.isDemo {
                Text("Open your own home to buy or restore Home Brief.")
            } else if store.unlocked {
                Label("Home Brief unlocked", systemImage: "checkmark.seal.fill")
                    .accessibilityIdentifier("billing.unlocked")
            } else {
                Text("Create a PDF of the home improvements you choose to share with an agent or buyer.")
                if let price = store.price {
                    Button {
                        Task { await store.purchase() }
                    } label: {
                        Text("Unlock for \(price) · Pay once")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy || store.loadingProduct)
                    .accessibilityIdentifier("billing.buy")
                } else if store.loadingProduct {
                    ProgressView("Checking App Store price…")
                } else {
                    Text("The App Store price is currently unavailable.")
                        .foregroundStyle(.secondary)
                    Button("Check Price Again") { Task { await store.loadProduct() } }
                        .accessibilityIdentifier("billing.retry")
                }
            }
            Button("Restore Purchase") { Task { await store.restore() } }
                .disabled(store.busy || store.isDemo)
                .accessibilityIdentifier("billing.restore")
            if store.busy { ProgressView("Connecting to the App Store…") }
            if let message = store.message {
                Text(message).font(.callout)
                    .accessibilityIdentifier("billing.status")
            }
        } header: {
            Text("Home Brief")
        } footer: {
            Text("The one-time purchase unlocks Home Brief PDFs. You can continue to manage tasks, projects and inventory for free.")
        }
        .task(id: store.unlocked) { if !store.unlocked { await store.loadProduct(refresh: true) } }
        .onChange(of: store.message) { _, message in
            #if canImport(UIKit)
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await store.refreshEntitlements()
                    if !store.unlocked { await store.loadProduct(refresh: true) }
                }
            }
        }
    }
}
