import Foundation

public enum SessionCatalog {
    public static func list(rootDirectory: URL) throws -> [SessionSnapshot] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return []
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let snapshots = entries.compactMap { entry -> SessionSnapshot? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return try? SessionReader.loadSnapshot(directory: entry, validateIndex: false)
        }

        return snapshots.sorted { left, right in
            left.metadata.startedAt > right.metadata.startedAt
        }
    }
}
