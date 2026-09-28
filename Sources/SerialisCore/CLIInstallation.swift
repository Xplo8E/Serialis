import Foundation

public enum CLIInstallation {
    private static let marker = "#!/bin/sh\n# Installed by Serialis.\n"

    /// Install or update our launcher, preserving any unrelated file at this path.
    public static func install(executable: URL, directory: URL) throws -> URL {
        let manager = FileManager.default
        let destination = directory.appendingPathComponent("serialis")
        guard destination.standardizedFileURL != executable.standardizedFileURL else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8192,
                  let contents = try? String(contentsOf: destination, encoding: .utf8),
                  contents.hasPrefix(marker) || isPreviousLauncher(contents) else {
                throw CLIError("A different file already exists at \(destination.path). It was not changed.")
            }
        }
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let launcher = marker + "exec \(quoted) --cli \"$@\"\n"
        try launcher.write(to: destination, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    private static func isPreviousLauncher(_ contents: String) -> Bool {
        contents.hasPrefix("#!/bin/sh\nexec '") && contents.hasSuffix("/Serialis' --cli \"$@\"\n") &&
            contents.split(separator: "\n").count == 2
    }
}
