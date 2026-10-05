import SwiftUI
import HomeCore
#if canImport(UIKit)
import UIKit
#endif

/// The feedback form: Bug / Polish / Idea, a required message (typed or dictated with the mic — only the text is
/// sent, never audio), the page (auto-filled, editable) and Send.
/// Presented by `FeedbackPresenter` above whatever is on screen (including other sheets).
struct FeedbackSheet: View {
    let env: AppEnvironment
    let initialPage: String
    let context: [String: String]
    let onClose: () -> Void

    @State private var category: FeedbackCategory = .bug
    @State private var message = ""
    @State private var page = ""
    @State private var sending = false
    @State private var outcome: FeedbackReceipt.Status?
    @State private var errorText: String?
    @State private var dictation = SpeechDictation()
    @FocusState private var messageFocused: Bool

    private var trimmedCount: Int { message.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }
    private var canSend: Bool { !sending && outcome == nil && trimmedCount >= 1 && trimmedCount <= FeedbackSubmission.maxMessageLength }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $category) {
                        ForEach(FeedbackCategory.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        if message.isEmpty {
                            Label(category.prompt, systemImage: category.symbolName)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $message)
                            .focused($messageFocused)
                            .frame(minHeight: 140)
                            .accessibilityLabel("Message")
                    }
                    dictationRow
                } header: {
                    Text("Message")
                } footer: {
                    if trimmedCount > FeedbackSubmission.maxMessageLength - 500 {
                        Text("\(trimmedCount) of \(FeedbackSubmission.maxMessageLength) characters")
                            .foregroundStyle(trimmedCount > FeedbackSubmission.maxMessageLength ? Color.red : Color.secondary)
                    }
                }

                Section {
                    TextField("Page", text: $page)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Page")
                } footer: {
                    Text("Sends your message, this page name, the app and iOS version and your iPhone model. No screenshots, recordings, names or home data — dictation is sent as text only.")
                }
            }
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dictation.stop(); onClose() }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .bold()
                            .disabled(!canSend)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let outcome {
                    confirmation(outcome)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .alert("Couldn’t send feedback", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
        .interactiveDismissDisabled(sending || !message.isEmpty)
        .onAppear {
            page = initialPage
            messageFocused = true
        }
        .onDisappear { dictation.stop() }
        .onChange(of: dictation.transcript) { _, words in
            if dictation.isRecording { message = words }
        }
    }

    /// Mic: dictates into the message (appended to what is already typed).
    private var dictationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { Task { await toggleDictation() } } label: {
                    Label(dictation.isRecording ? "Stop" : "Dictate",
                          systemImage: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.bordered)
                .tint(dictation.isRecording ? .red : .accentColor)
                .disabled(sending || outcome != nil)
                .accessibilityLabel(dictation.isRecording ? "Stop dictating" : "Dictate your message")
                if dictation.isRecording {
                    Label("Listening…", systemImage: "waveform")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
                Spacer(minLength: 0)
            }
            if let err = dictation.errorText {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func toggleDictation() async {
        if dictation.isRecording {
            stopDictation()
        } else {
            messageFocused = false
            await dictation.start(prefix: message)
        }
    }

    /// Stops listening and keeps what was heard.
    private func stopDictation() {
        guard dictation.isRecording else { return }
        let words = dictation.transcript
        dictation.stop()
        message = words
    }

    private func confirmation(_ status: FeedbackReceipt.Status) -> some View {
        Label(status == .sent ? "Thanks! Feedback sent." : "Saved — will send when online.",
              systemImage: status == .sent ? "checkmark.circle.fill" : "tray.and.arrow.up.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
            .accessibilityAddTraits(.isStaticText)
    }

    private func send() async {
        stopDictation()
        guard canSend else { return }
        sending = true
        messageFocused = false
        let pageName = page.trimmingCharacters(in: .whitespacesAndNewlines)
        let submission = FeedbackDeviceInfo.submission(
            category: category, message: message, page: pageName.isEmpty ? initialPage : pageName,
            context: context, config: env.config)
        do {
            let receipt = try await env.feedback.submit(submission)
            sending = false
            withAnimation { outcome = receipt.status }
            #if canImport(UIKit)
            UIAccessibility.post(notification: .announcement,
                                 argument: receipt.status == .sent ? "Feedback sent" : "Feedback saved, will send when online")
            #endif
            try? await Task.sleep(nanoseconds: receipt.status == .sent ? 1_000_000_000 : 1_600_000_000)
            onClose()
        } catch {
            sending = false
            errorText = error.localizedDescription
        }
    }
}

#Preview("Feedback") {
    FeedbackSheet(env: .preview(), initialPage: "Plan · Ground floor", context: ["lens": "plan"], onClose: {})
}
