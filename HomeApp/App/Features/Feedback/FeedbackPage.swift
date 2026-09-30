import SwiftUI
import Observation

/// Device-local feedback preferences.
enum FeedbackSettings {
    /// UserDefaults Bool (default true) behind Settings › "Show feedback button".
    static let showButtonKey = "feedback.showButton"
}

/// Which screen the user is looking at, for the feedback form's "Page" field.
///
/// Screens mark themselves with `.feedbackPage("Plan · Ground floor")`. Each marked view pushes an entry when it
/// appears and removes it when it disappears, so the newest visible entry is the frontmost screen, including
/// screens inside sheets and pushed navigation views (their presenters' preferences can't see them, which is why
/// this is a shared tracker rather than a preference key). `RootView` sets `rootPage` as the fallback for screens
/// that don't mark themselves (e.g. "Onboarding").
@MainActor
@Observable
final class FeedbackPageTracker {
    static let shared = FeedbackPageTracker()

    struct Entry: Equatable {
        let token: UUID
        var name: String
        var context: [String: String]
    }

    /// Fallback page when no marked screen is visible.
    var rootPage = "Home"
    private(set) var entries: [Entry] = []

    /// Frontmost marked screen, else `rootPage`.
    var currentPage: String { entries.last?.name ?? rootPage }
    /// Small non-personal details the frontmost screen attached (e.g. lens).
    var currentContext: [String: String] { entries.last?.context ?? [:] }

    func push(_ token: UUID, name: String, context: [String: String]) {
        entries.removeAll { $0.token == token }
        entries.append(Entry(token: token, name: name, context: context))
    }

    /// Renames in place (e.g. the floor changed) without changing which screen is frontmost.
    func update(_ token: UUID, name: String, context: [String: String]) {
        guard let i = entries.firstIndex(where: { $0.token == token }) else { return }
        entries[i].name = name
        entries[i].context = context
    }

    func remove(_ token: UUID) {
        entries.removeAll { $0.token == token }
    }
}

private struct FeedbackPageModifier: ViewModifier {
    let name: String
    let context: [String: String]
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { FeedbackPageTracker.shared.push(token, name: name, context: context) }
            .onDisappear { FeedbackPageTracker.shared.remove(token) }
            .onChange(of: name) { _, newName in FeedbackPageTracker.shared.update(token, name: newName, context: context) }
            .onChange(of: context) { _, newContext in FeedbackPageTracker.shared.update(token, name: name, context: newContext) }
    }
}

extension View {
    /// Names this screen in feedback ("Plan · Ground floor", "Chores", "Settings"). Put it on a screen's top-level
    /// view. `context` holds small non-personal details (lens, tab); never user content.
    func feedbackPage(_ name: String, context: [String: String] = [:]) -> some View {
        modifier(FeedbackPageModifier(name: name, context: context))
    }
}
