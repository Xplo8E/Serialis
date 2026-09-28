import Foundation

enum SessionLocation {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["SERIALIS_SESSIONS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Serialis/Sessions", isDirectory: true)
    }
}
