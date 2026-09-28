import XCTest
@testable import SerialisCore

final class CLIInstallationTests: XCTestCase {
    func testLauncherPreservesQuotedPathsAndArgumentsAndCanBeUpdated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Serialis install '\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("Serialis")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let directory = root.appendingPathComponent("bin")
        let launcher = try CLIInstallation.install(executable: executable, directory: directory)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher.path))
        let process = Process()
        process.executableURL = launcher
        process.arguments = ["--match", "two words"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "--cli\n--match\ntwo words\n")
        XCTAssertEqual(try CLIInstallation.install(executable: executable, directory: directory), launcher)

        // Update launchers created by the original Save dialog as well.
        try "#!/bin/sh\nexec '/old/app/Serialis' --cli \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        _ = try CLIInstallation.install(executable: executable, directory: directory)
        XCTAssertTrue(try String(contentsOf: launcher).contains("# Installed by Serialis."))
    }

    func testUnrelatedExistingFileIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Serialis-install-conflict-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent("serialis")
        let contents = "An unrelated existing file"
        try contents.write(to: existing, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CLIInstallation.install(executable: URL(fileURLWithPath: "/example/Serialis"), directory: directory))
        XCTAssertEqual(try String(contentsOf: existing), contents)
    }
}
