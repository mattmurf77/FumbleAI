import SwiftUI
import HomeCore
import HomeSchedule
#if canImport(UIKit)
import UIKit
#endif

@main
struct HomeApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    /// Screenshot runs (`-HomeDemo YES`) use the in-memory sample house; see `DemoLaunch`.
    @State private var env = DemoLaunch.current?.makeEnvironment() ?? AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .task {
                    #if canImport(UIKit)
                    // Notification actions (DONE / SNOOZE_1H) and body taps need the live services.
                    appDelegate.notificationHandler.configure(
                        actions: NotificationActions(chores: env.chores, reminders: env.reminders, clock: env.clock),
                        onOpen: { url in env.handle(url: url) })
                    #endif
                    await env.start()
                }
                .onOpenURL { url in env.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await env.sceneBecameActive() }   // also retries queued feedback
                #if canImport(UIKit)
                FeedbackPresenter.shared.sceneBecameActive()
                #endif
            }
        }
        .backgroundTask(.appRefresh(AppConfig.refreshTaskIdentifier)) { [env] in
            await env.runBackgroundRefresh()
        }
    }
}

#if canImport(UIKit)
/// A `UIResponder` so it ends every window's responder chain: unhandled motion events (shake) arrive here.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// UNUserNotificationCenter delegate; installed before launch completes so a "Done" tap that launched the app
    /// is delivered, configured with the live services from `HomeApp.body`.
    let notificationHandler = NotificationActionHandler()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CKSyncEngine relies on silent pushes (aps-environment entitlement + remote-notification background mode).
        application.registerForRemoteNotifications()
        notificationHandler.install()
        return true
    }

    /// Shake → feedback form (see `FeedbackPresenter`).
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .homeDeviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
#endif
