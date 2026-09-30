import SwiftUI
#if canImport(MessageUI) && canImport(UIKit)
import MessageUI
import UIKit
#endif

/// The system Messages composer (iMessage / SMS) with a prefilled body. The user picks the recipient and taps Send.
/// Check `MessageComposer.canSend` first; the simulator and iPads without Messages can't send.
struct MessageComposer: View {
    let text: String
    var recipients: [String] = []
    let onFinish: () -> Void

    static var canSend: Bool {
        #if canImport(MessageUI) && canImport(UIKit)
        return MFMessageComposeViewController.canSendText()
        #else
        return false
        #endif
    }

    var body: some View {
        #if canImport(MessageUI) && canImport(UIKit)
        ComposerRepresentable(messageBody: text, recipients: recipients, onFinish: onFinish)
            .ignoresSafeArea()
        #else
        Text(text)
        #endif
    }
}

#if canImport(MessageUI) && canImport(UIKit)
private struct ComposerRepresentable: UIViewControllerRepresentable {
    let messageBody: String
    let recipients: [String]
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.body = messageBody
        if !recipients.isEmpty { vc.recipients = recipients }
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
#endif
