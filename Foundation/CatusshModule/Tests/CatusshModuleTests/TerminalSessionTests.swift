//
//  TerminalSessionTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

@MainActor
final class TerminalShutdownTests: XCTestCase {
    /// A session that ends turns the modes a program may have left on off
    /// before it says so, and keeps nothing typed for the next one.
    func testAnEndingSessionResetsTerminalModes() async throws {
        CatusshStore.shared.openInterfaceAutomatically = false
        let surface = RecordingSurface()
        // Nothing listens on port 1: the session ends at once.
        let context = TerminalContext(machine: RDMachine(remoteAddress: "127.0.0.1", remotePort: "1", name: "closed"), surface: surface)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !surface.text.contains("Connection Closed") {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let text = surface.text
        let reset = try XCTUnwrap(text.range(of: TerminalContext.modeReset), text)
        let closed = try XCTUnwrap(text.range(of: "Connection Closed"))
        XCTAssertLessThan(reset.lowerBound, closed.lowerBound)
        context.insertBuffer("stale")
        XCTAssertEqual(context.getBuffer(), "")
    }
}
