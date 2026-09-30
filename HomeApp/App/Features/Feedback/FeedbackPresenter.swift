#if canImport(UIKit)
import UIKit
import SwiftUI
import HomeCore

extension Notification.Name {
    /// Posted when the user shakes the iPhone (any window). Opens the feedback form.
    static let homeDeviceDidShake = Notification.Name("app.fumble.home.deviceDidShake")
}

extension UIWindow {
    /// Shake gesture → `homeDeviceDidShake`. (UIKit delivers motion events to the key window's responder chain.)
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .homeDeviceDidShake, object: nil)
        }
    }
}

/// Shows the floating feedback button on every screen and presents the feedback form above whatever is showing.
///
/// The button lives in its own small `UIWindow` (one level above the app window) sized to the button, so it stays
/// visible over SwiftUI sheets without intercepting touches anywhere else. Drag it; it snaps to the nearest side
/// and remembers where it was. The form is presented with UIKit from the app window's topmost view controller,
/// so it also works while another sheet is open. Settings › "Show feedback button" hides the button; shaking the
/// iPhone still opens the form.
@MainActor
final class FeedbackPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = FeedbackPresenter()

    private static let sideKey = "feedback.buttonSide"        // "left" | "right"
    private static let yFractionKey = "feedback.buttonY"      // 0…1 of the usable height

    private weak var env: AppEnvironment?
    private var buttonWindow: UIWindow?
    private var presentedForm: UIViewController?   // strong while shown; cleared in formClosed()
    private var shakeObserver: NSObjectProtocol?
    private var wantsButton = true

    private let buttonSize: CGFloat = 44
    private let edgeMargin: CGFloat = 6

    // MARK: Setup

    /// Call once the scene has a window (RootView `.onAppear`). Safe to call again.
    func install(env: AppEnvironment) {
        self.env = env
        if shakeObserver == nil {
            shakeObserver = NotificationCenter.default.addObserver(forName: .homeDeviceDidShake, object: nil, queue: .main) { _ in
                Task { @MainActor in FeedbackPresenter.shared.present() }
            }
        }
        let show = UserDefaults.standard.object(forKey: FeedbackSettings.showButtonKey) as? Bool ?? true
        setButtonVisible(show)
    }

    /// Settings toggle.
    func setButtonVisible(_ visible: Bool) {
        wantsButton = visible
        if visible {
            if buttonWindow == nil { makeButtonWindow() }
            buttonWindow?.isHidden = presentedForm != nil
        } else {
            buttonWindow?.isHidden = true
        }
    }

    private var windowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// The app's own window (not the button window).
    private var appWindow: UIWindow? {
        let windows = windowScene?.windows.filter { $0 !== buttonWindow } ?? []
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private func makeButtonWindow() {
        guard let scene = windowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .clear
        let controller = FeedbackButtonController(
            onTap: { [weak self] in self?.present() },
            onDrag: { [weak self] phase, delta in self?.drag(phase, delta: delta) })
        window.rootViewController = controller
        buttonWindow = window     // set first so `appWindow` never picks this window
        window.frame = restingFrame()
        window.isHidden = false   // visible without becoming key (the app window keeps keyboard focus)
    }

    // MARK: Position

    private var usableBounds: CGRect {
        let bounds = windowScene?.coordinateSpace.bounds ?? UIScreen.main.bounds
        let insets = appWindow?.safeAreaInsets ?? .zero
        return bounds.inset(by: UIEdgeInsets(top: insets.top + 8, left: insets.left, bottom: insets.bottom + 8, right: insets.right))
    }

    private func restingFrame() -> CGRect {
        let defaults = UserDefaults.standard
        let side = defaults.string(forKey: Self.sideKey) ?? "left"
        let fraction = defaults.object(forKey: Self.yFractionKey) as? Double ?? 0.55
        let area = usableBounds
        let x = side == "right" ? area.maxX - buttonSize - edgeMargin : area.minX + edgeMargin
        let y = area.minY + CGFloat(min(max(fraction, 0), 1)) * max(0, area.height - buttonSize)
        return CGRect(x: x, y: y, width: buttonSize, height: buttonSize)
    }

    private var dragStartOrigin: CGPoint = .zero

    private func drag(_ phase: FeedbackButtonController.DragPhase, delta: CGPoint) {
        guard let window = buttonWindow else { return }
        switch phase {
        case .began:
            dragStartOrigin = window.frame.origin
        case .changed:
            let area = usableBounds
            var origin = CGPoint(x: dragStartOrigin.x + delta.x, y: dragStartOrigin.y + delta.y)
            origin.x = min(max(origin.x, area.minX), area.maxX - buttonSize)
            origin.y = min(max(origin.y, area.minY), area.maxY - buttonSize)
            window.frame.origin = origin
        case .ended:
            let area = usableBounds
            let side = window.frame.midX > area.midX ? "right" : "left"
            let travel = max(1, area.height - buttonSize)
            let fraction = Double(min(max((window.frame.minY - area.minY) / travel, 0), 1))
            UserDefaults.standard.set(side, forKey: Self.sideKey)
            UserDefaults.standard.set(fraction, forKey: Self.yFractionKey)
            let target = restingFrame()
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3,
                           options: [.allowUserInteraction], animations: { window.frame = target }, completion: nil)
        }
    }

    // MARK: Form

    /// Opens the feedback form for the frontmost page. Ignored while it's already open.
    func present() {
        // The form can disappear without a callback (e.g. the sheet it sat on was dismissed underneath it).
        if let form = presentedForm, form.presentingViewController == nil { formClosed() }
        guard presentedForm == nil, let env, let root = appWindow?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }

        let tracker = FeedbackPageTracker.shared
        let page = tracker.currentPage
        let context = tracker.currentContext
        let hostRef = WeakControllerRef()   // weak, so the sheet's closure doesn't retain its own controller
        let sheet = FeedbackSheet(env: env, initialPage: page, context: context, onClose: { [weak self] in
            guard let host = hostRef.controller else { self?.formClosed(); return }
            host.dismiss(animated: true) { self?.formClosed() }
        })
        let controller = UIHostingController(rootView: AnyView(sheet.environment(env)))
        hostRef.controller = controller
        controller.modalPresentationStyle = .pageSheet
        if let sheetController = controller.sheetPresentationController {
            sheetController.detents = [.medium(), .large()]
            sheetController.prefersGrabberVisible = true
            sheetController.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        controller.presentationController?.delegate = self
        presentedForm = controller
        buttonWindow?.isHidden = true
        top.present(controller, animated: true)
    }

    /// Scene became active: recover from a form that vanished without a callback and re-show the button.
    func sceneBecameActive() {
        if let form = presentedForm, form.presentingViewController == nil { formClosed() }
        if presentedForm == nil, env != nil { setButtonVisible(wantsButton) }
    }

    private func formClosed() {
        guard presentedForm != nil else { return }
        presentedForm = nil
        buttonWindow?.isHidden = !wantsButton
        Task { await env?.feedback.retryPending() }
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // Swipe-down dismiss (only possible while the message is empty).
        Task { @MainActor in self.formClosed() }
    }
}

private final class WeakControllerRef {
    weak var controller: UIViewController?
}

/// Root of the button window: a round translucent button with tap and drag.
final class FeedbackButtonController: UIViewController {
    enum DragPhase { case began, changed, ended }

    private let onTap: () -> Void
    private let onDrag: (DragPhase, CGPoint) -> Void
    private var startTouch: CGPoint = .zero

    init(onTap: @escaping () -> Void, onDrag: @escaping (DragPhase, CGPoint) -> Void) {
        self.onTap = onTap
        self.onDrag = onDrag
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .clear

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        blur.isUserInteractionEnabled = false
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "exclamationmark.bubble",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Send feedback"
        button.accessibilityHint = "Report a bug, suggest polish or share an idea. You can also shake your iPhone."
        button.addAction(UIAction { [weak self] _ in self?.onTap() }, for: .primaryActionTriggered)
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))

        container.addSubview(blur)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.18
        container.layer.shadowRadius = 6
        container.layer.shadowOffset = CGSize(width: 0, height: 2)
        container.alpha = 0.9
        view = container
        self.blur = blur
    }

    private weak var blur: UIVisualEffectView?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        blur?.layer.cornerRadius = min(view.bounds.width, view.bounds.height) / 2
    }

    /// Screen-space finger position (the window moves under the finger, so window coordinates would drift).
    private func screenPoint(_ g: UIGestureRecognizer) -> CGPoint {
        guard let window = view.window else { return g.location(in: nil) }
        let space = window.windowScene?.coordinateSpace ?? window.screen.coordinateSpace
        return window.convert(g.location(in: window), to: space)
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let p = screenPoint(g)
        switch g.state {
        case .began:
            startTouch = p
            onDrag(.began, .zero)
        case .changed:
            onDrag(.changed, CGPoint(x: p.x - startTouch.x, y: p.y - startTouch.y))
        case .ended, .cancelled, .failed:
            onDrag(.ended, .zero)
        default:
            break
        }
    }
}
#endif
