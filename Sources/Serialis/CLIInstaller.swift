import AppKit

/// The launcher uses the app's executable, so CLI and GUI always share a version.
enum CLIInstaller {
    static func install() {
        do {
            guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let panel = NSSavePanel()
            panel.title = "Install Serialis Command-Line Tool"
            panel.message = "Choose a folder on your PATH. Keep Serialis.app at its current location after installing."
            panel.nameFieldStringValue = "serialis"
            panel.directoryURL = directory
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            guard destination.standardizedFileURL != executable.standardizedFileURL else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let launcher = "#!/bin/sh\nexec \(quoted) --cli \"$@\"\n"
            try launcher.write(to: destination, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            let alert = NSAlert()
            alert.messageText = "Command-Line Tool Installed"
            alert.informativeText = "Run serialis --help in Terminal. If the command is not found, add \(destination.deletingLastPathComponent().path) to your shell’s PATH."
            alert.runModal()
        } catch { NSAlert(error: error).runModal() }
    }
}
