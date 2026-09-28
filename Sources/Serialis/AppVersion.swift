import Foundation

enum AppVersion {
    // Both interfaces execute inside the same app bundle and read the GUI version.
    static var string: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
