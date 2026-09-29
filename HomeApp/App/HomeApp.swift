import SwiftUI
import HomeCore
#if canImport(UIKit)
import UIKit
#endif

@main
struct HomeApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var env = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .task { await env.start() }
                .onOpenURL { url in env.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await env.sceneBecameActive() } }
        }
        .backgroundTask(.appRefresh(AppConfig.refreshTaskIdentifier)) { [env] in
            await env.runBackgroundRefresh()
        }
    }
}

#if canImport(UIKit)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CKSyncEngine relies on silent pushes (aps-environment entitlement + remote-notification background mode).
        application.registerForRemoteNotifications()
        // INTEGRATION: HomeSchedule — set UNUserNotificationCenter.current().delegate to the notification action
        // handler and register the CHORE_DUE category (actions DONE, SNOOZE_1H) here, before launch completes.
        return true
    }
}
#endif
