//
//  GhosttyTerminfoTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

final class GhosttyTerminfoTests: XCTestCase {
    private func run(_ command: String, home: URL, terminfo: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        if let terminfo { environment["TERMINFO"] = terminfo.path }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// The command a server runs, run here with this Mac's sh and tic.
    func testTheInstallCommandInstallsThenFindsTheEntry() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try run(GhosttyTerminfo.installCommand, home: home)
        XCTAssertEqual(GhosttyTerminfo.outcome(of: first), .installed, first)
        let second = try run(GhosttyTerminfo.installCommand, home: home, terminfo: home.appendingPathComponent(".terminfo"))
        XCTAssertEqual(GhosttyTerminfo.outcome(of: second), .present, second)
    }

    func testTheAnswerIsFoundAfterABannerAndMissingOtherwise() {
        XCTAssertEqual(GhosttyTerminfo.outcome(of: "Welcome to box\r\ncatussh-terminfo:installed\r\n"), .installed)
        XCTAssertEqual(GhosttyTerminfo.outcome(of: "'sh' is not recognized as an internal or external command"), .failed)
    }

    func testTheBundledEntryIsGhostty() {
        XCTAssertTrue(GhosttyTerminfo.source.hasPrefix("xterm-ghostty|ghostty|Ghostty,"))
        XCTAssertFalse(GhosttyTerminfo.source.contains("'"))
    }
}
