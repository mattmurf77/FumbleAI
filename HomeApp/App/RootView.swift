import SwiftUI
import HomeCore

/// Root switch: onboarding while the home has no property (or until onboarding finishes), else the tab bar.
/// Observes the current property so both a local commit and an iCloud restore switch screens automatically.
/// Also presents app-wide prompts: iCloud account changes (FR-SYN-32/33) and a one-time startup problem.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var property: Property?
    @State private var loaded = false
    @State private var showOnboarding = false
    @State private var bringRecords = false
    @State private var incomingFiles: [ProjectCSVFile] = []
    @State private var reviewingCSV: ProjectCSVFile?
    @State private var importError: String?
    @State private var accountError: String?
    @AppStorage(FeedbackSettings.showButtonKey) private var showFeedbackButton = true

    /// Feedback "Page" when the visible screen doesn't name itself with `.feedbackPage(_:)`.
    private var rootFeedbackPage: String {
        !loaded ? "Loading" : showOnboarding ? "Onboarding" : "Home"
    }

    var body: some View {
        @Bindable var env = env
        Group {
            if env.storageUnavailable {
                ContentUnavailableView {
                    Label("Your home could not be opened", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Unlock your iPhone, check its available storage, then reopen Home Blueprint to try again. Keep the app installed to preserve your local records.")
                }
            } else if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showOnboarding {
                OnboardingFlow(bringRecords: {
                    showOnboarding = false
                    bringRecords = true
                }, onFinished: { showOnboarding = false })
            } else {
                MainTabView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let file = incomingFiles.first, !showOnboarding, property != nil, reviewingCSV == nil {
                Button {
                    reviewingCSV = file
                } label: {
                    Label("Review spreadsheet: " + file.name, systemImage: "tablecells")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.background(.regularMaterial)
            }
        }
        .onOpenURL { url in
            guard OpenSpreadsheet.accepts(url) else { return }
            Task {
                do {
                    let incoming = try await Task.detached(priority: .userInitiated) { try OpenSpreadsheet.read(url) }.value
                    guard incomingFiles.count < 5 else {
                        importError = "Finish reviewing open spreadsheets, then open this file again."; return
                    }
                    incomingFiles.append(incoming)
                } catch { importError = error.localizedDescription }
            }
        }
        .sheet(isPresented: $bringRecords) {
            if let property {
                NavigationStack {
                    BringRecordsView(property: property)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { bringRecords = false } } }
                }
            } else { ProgressView("Opening your home…") }
        }
        .sheet(item: $reviewingCSV, onDismiss: {
            if !incomingFiles.isEmpty { incomingFiles.removeFirst() }
        }) { file in
            if let property {
                NavigationStack {
                    ProjectCSVImportView(property: property, initialFile: file)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { reviewingCSV = nil } } }
                }
            }
        }
        .alert("Couldn’t open spreadsheet", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .onChange(of: rootFeedbackPage, initial: true) { _, page in FeedbackPageTracker.shared.rootPage = page }
        #if canImport(UIKit)
        // Floating feedback button on every screen (own window, above sheets) + shake to send feedback.
        .onAppear { if !env.storageUnavailable { FeedbackPresenter.shared.install(env: env) } }
        .onChange(of: showFeedbackButton) { _, show in FeedbackPresenter.shared.setButtonVisible(show) }
        #endif
        .task {
            guard !env.storageUnavailable else { return }
            for await p in env.plan.observeCurrentProperty() {
                property = p
                if p == nil { showOnboarding = true }
                loaded = true
            }
        }
        .alert(item: $env.accountPrompt) { prompt in
            switch prompt {
            case .switchedAccounts:
                return Alert(title: Text("A different iCloud account is signed in"),
                             message: Text("Keep this iPhone’s data, or erase it and use the home stored in the new account? Export a CSV from Settings first if you want a copy."),
                             primaryButton: .destructive(Text("Erase and use new account")) {
                                 Task { await erase() }
                             },
                             secondaryButton: .cancel(Text("Keep my data")) { env.accountPrompt = nil })
            case .userDeletedZone(let zone):
                return Alert(title: Text("Your iCloud data for Home was deleted"),
                             message: Text("Upload this iPhone’s copy to iCloud again?"),
                             primaryButton: .default(Text("Upload again")) {
                                 Task { await reupload(zone) }
                             },
                             secondaryButton: .cancel(Text("Not now")) { env.accountPrompt = nil })
            }
        }
        .alert("Something needs attention", isPresented: Binding(get: { !env.storageUnavailable && env.startupError != nil }, set: { if !$0 { env.startupError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(env.startupError ?? "")
        }
        .alert("Couldn’t update iCloud", isPresented: Binding(get: { accountError != nil }, set: { if !$0 { accountError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(accountError ?? "")
        }
    }

    private func erase() async {
        do { try await env.eraseLocalDataForNewAccount() } catch { accountError = error.localizedDescription }
    }

    private func reupload(_ zone: String) async {
        do { try await env.confirmReupload(zoneName: zone) } catch { accountError = error.localizedDescription }
    }
}

#Preview("Sample house") {
    RootView().environment(AppEnvironment.preview())
}

#Preview("Empty") {
    RootView().environment(AppEnvironment.preview(sample: false))
}
