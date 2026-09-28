import AppKit
import SerialisCore

/// The launcher uses the app's executable, so CLI and GUI always share a version.
enum CLIInstaller {
    static func install() {
        do {
            guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
            let destination = try CLIInstallation.install(executable: executable, directory: directory)
            // Verify the installed launcher itself before reporting success.
            let process = Process()
            process.executableURL = destination
            process.arguments = ["--version"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "Serialis \(AppVersion.string)" else {
                throw CLIError("The command-line tool was written, but its version check failed.")
            }
            let alert = NSAlert()
            alert.messageText = "CLI installed successfully"
            alert.informativeText = "Installed to ~/.local/bin/serialis.\nRun serialis --help in Terminal."
            alert.runModal()
        } catch { NSAlert(error: error).runModal() }
    }
}
