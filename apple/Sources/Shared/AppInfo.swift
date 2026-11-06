import Foundation

/// App name / version / build read from the bundle's Info.plist. The project
/// maps these to `PRODUCT_NAME` / `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
enum AppInfo {
    static var name: String {
        bundleString("CFBundleDisplayName") ?? bundleString("CFBundleName") ?? "Cockpit"
    }
    static var version: String { bundleString("CFBundleShortVersionString") ?? "—" }
    static var build: String { bundleString("CFBundleVersion") ?? "—" }

    private static func bundleString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
