import Foundation

/// Build-time configuration read from the app's Info.plist (populated from xcconfig/build settings):
///
/// | Info.plist key   | Build setting        | Meaning |
/// |------------------|----------------------|---------|
/// | `HomeServerURL`  | `$(HOME_SERVER_URL)` | Base URL of the stateless Home server (Render). Empty → call Overpass directly. |
/// | `HomeAPIKey`     | `$(HOME_API_KEY)`    | Sent as `X-Home-Key` when non-empty. |
/// | `CFBundleIdentifier` | `$(HOME_BUNDLE_ID)` | Also determines the CloudKit container `iCloud.<bundle id>`. |
///
/// Server endpoints (v1): `GET /health`, `GET /v1/footprint?lat=&lon=` (Overpass proxy), `GET /v1/templates`.
public struct AppConfig: Hashable, Sendable {
    public var serverURL: URL?
    public var apiKey: String?
    public var bundleIdentifier: String
    public var appVersion: String
    public var buildNumber: String

    public static let defaultBundleIdentifier = "app.fumble.home"
    public static let apiKeyHeader = "X-Home-Key"
    public static let overpassURL = URL(string: "https://overpass-api.de/api/interpreter")!

    public init(serverURL: URL? = nil, apiKey: String? = nil, bundleIdentifier: String = AppConfig.defaultBundleIdentifier,
                appVersion: String = "0.0", buildNumber: String = "0") {
        self.serverURL = serverURL
        self.apiKey = (apiKey?.isEmpty ?? true) ? nil : apiKey
        self.bundleIdentifier = bundleIdentifier
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    /// Builds a config from an Info.plist dictionary. Unexpanded `$(VAR)` placeholders and empty strings count as unset.
    public init(infoDictionary info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let s = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, !s.hasPrefix("$(") else { return nil }
            return s
        }
        self.init(serverURL: value("HomeServerURL").flatMap(URL.init(string:)),
                  apiKey: value("HomeAPIKey"),
                  bundleIdentifier: value("CFBundleIdentifier") ?? AppConfig.defaultBundleIdentifier,
                  appVersion: value("CFBundleShortVersionString") ?? "0.0",
                  buildNumber: value("CFBundleVersion") ?? "0")
    }

    /// Reads `Bundle.main`. On non-Apple platforms (Linux tests) returns defaults.
    public static var main: AppConfig {
        #if canImport(Darwin)
        return AppConfig(infoDictionary: Bundle.main.infoDictionary ?? [:])
        #else
        return AppConfig()
        #endif
    }

    /// True when footprints should come from the Home server rather than Overpass directly.
    public var usesServer: Bool { serverURL != nil }

    /// CloudKit container identifier: `iCloud.<bundle id>` (entitlement is `iCloud.$(HOME_BUNDLE_ID)`).
    public var cloudKitContainerIdentifier: String { "iCloud." + bundleIdentifier }

    /// BGAppRefresh identifier (Info.plist `BGTaskSchedulerPermittedIdentifiers`).
    public static let refreshTaskIdentifier = "app.fumble.home.refresh"
    /// BGProcessing identifier for heavy maintenance (purge, FTS rebuild).
    public static let maintenanceTaskIdentifier = "app.fumble.home.maintenance"
    /// Deep-link scheme: `home://chore/<uuid>`.
    public static let urlScheme = "home"
    /// Request headers for the Home server (adds `X-Home-Key` when a key is configured).
    public var serverHeaders: [String: String] { apiKey.map { [AppConfig.apiKeyHeader: $0] } ?? [:] }
}
