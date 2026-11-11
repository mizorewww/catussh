import GhosttyTerminal
import XCTest
#if canImport(UIKit)
    import UIKit
#endif
@testable import CatusshTerminal

final class NativeTerminalTests: XCTestCase {
    @MainActor
    func testUserClipboardActionsWorkButRemoteClipboardWriteIsDenied() async throws {
        let saved = TestPasteboard.save()
        defer { TestPasteboard.restore(saved) }
        let terminal = CatusshTerminalView()
        let native = terminal.session.platformView()
        let window = TestHost(native)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        terminal.write("catussh copy marker")
        XCTAssertTrue(terminal.session.backend.waitForPendingOutput())
        XCTAssertTrue(native.performBindingAction("select_all"))
        #if os(macOS)
            XCTAssertTrue(native.copySelectedTextToPasteboard())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(TestPasteboard.string?.contains("catussh copy marker") == true)

            TestPasteboard.string = "catussh paste 中文"
            let pasted = expectation(description: "system pasteboard input")
            terminal.setupBufferChain { text in
                if text.contains("catussh paste 中文") { pasted.fulfill() }
            }
            XCTAssertTrue(native.performBindingAction("paste_from_clipboard"))
            await fulfillment(of: [pasted], timeout: 5)

            let remote = Data("remote replacement".utf8).base64EncodedString()
            terminal.write("\u{1B}]52;c;\(remote)\u{07}")
            XCTAssertTrue(terminal.session.backend.waitForPendingOutput())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(TestPasteboard.string, "catussh paste 中文")
        #else
            // Reading the pasteboard's contents on iOS waits on the paste-consent
            // prompt, which a test cannot answer; the change count and the
            // presence of text are readable without it.
            let beforeCopy = UIPasteboard.general.changeCount
            XCTAssertTrue(native.copySelectedTextToPasteboard())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertGreaterThan(UIPasteboard.general.changeCount, beforeCopy, "Copy writes the pasteboard")
            XCTAssertTrue(UIPasteboard.general.hasStrings)

            let afterCopy = UIPasteboard.general.changeCount
            let remote = Data("remote replacement".utf8).base64EncodedString()
            terminal.write("\u{1B}]52;c;\(remote)\u{07}")
            XCTAssertTrue(terminal.session.backend.waitForPendingOutput())
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(UIPasteboard.general.changeCount, afterCopy, "A remote program cannot write the pasteboard")
        #endif
    }

    #if os(macOS)
        @MainActor
        func testCopyOnSelectCopiesAMouseSelectionOnlyWhileOn() async throws {
            let saved = TestPasteboard.save()
            defer {
                CatusshTerminalView.setCopyOnSelect(true)
                TestPasteboard.restore(saved)
            }
            let terminal = CatusshTerminalView()
            let native = terminal.session.platformView()
            let window = TestHost(native)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            terminal.write("catussh select marker")
            XCTAssertTrue(terminal.session.backend.waitForPendingOutput())
            func drag() async throws {
                func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                    let point = native.convert(NSPoint(x: x, y: native.bounds.height - 8), to: nil)
                    return NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: native.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                    )!
                }
                native.mouseDown(with: event(.leftMouseDown, 4))
                for x in stride(from: 10, through: 160, by: 10) { native.mouseDragged(with: event(.leftMouseDragged, CGFloat(x))) }
                native.mouseUp(with: event(.leftMouseUp, 160))
                try await Task.sleep(for: .milliseconds(200))
            }

            CatusshTerminalView.setCopyOnSelect(false)
            TestPasteboard.string = "untouched"
            try await drag()
            XCTAssertEqual(TestPasteboard.string, "untouched")

            CatusshTerminalView.setCopyOnSelect(true)
            try await drag()
            XCTAssertTrue(TestPasteboard.string?.contains("catussh select marker") == true)
        }
    #endif

    @MainActor
    func testRealSurfaceInputOutputResizeFontAndWindowTransfer() async throws {
        TestHost.prepare()
        let terminal = CatusshTerminalView()
        let title = expectation(description: "OSC title")
        let bell = expectation(description: "bell")
        let input = expectation(description: "keyboard Enter")
        terminal.setupTitleChain { value in
            if value == "catussh Ghostty Test" { title.fulfill() }
        }
        terminal.setupBellChain { bell.fulfill() }
        terminal.setupBufferChain { value in
            if value.contains("\r") { input.fulfill() }
        }
        // Output arriving before SwiftUI/AppKit presentation must survive.
        terminal.write("before attach\r\n")
        terminal.setTerminalFontSize(with: 16)
        let native = terminal.session.platformView()
        XCTAssertTrue(native === terminal.session.platformView())
        let window = TestHost(native)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        terminal.write("\u{1B}[31m中文 👻\u{1B}[0m\r\n\u{1B}]2;catussh Ghostty Test\u{07}\u{07}")
        XCTAssertTrue(terminal.session.backend.waitForPendingOutput())
        XCTAssertTrue(terminal.session.backend.readViewportText()?.contains("before attach") == true)
        XCTAssertTrue(terminal.session.backend.readViewportText()?.contains("中文 👻") == true)
        XCTAssertTrue(native.sendKey(.enter))
        await fulfillment(of: [title, bell, input], timeout: 5)
        XCTAssertEqual(native.fontSize, 16)

        let originalSize = terminal.requestTerminalSize()
        window.resize(CGSize(width: 900, height: 600))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(terminal.requestTerminalSize().width, originalSize.width)
        terminal.setTerminalFontSize(with: 20)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(native.fontSize, 20)
        XCTAssertTrue(terminal.session.backend.readViewportText()?.contains("before attach") == true)

        // Push the original banner into scrollback before transferring the view.
        terminal.write((0..<100).map { "history \($0)\r\n" }.joined())
        XCTAssertTrue(terminal.session.backend.waitForPendingOutput())

        let secondWindow = TestHost(size: CGSize(width: 900, height: 600))
        native.removeFromSuperview()
        secondWindow.show(terminal.session.platformView())
        defer { secondWindow.close() }
        try await Task.sleep(for: .milliseconds(150))
        terminal.write("after move\r\n")
        XCTAssertTrue(terminal.session.backend.waitForPendingOutput())
        XCTAssertTrue(terminal.session.backend.readViewportText()?.contains("after move") == true)
        XCTAssertTrue(native.scrollToRow(0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(terminal.session.backend.readViewportText()?.contains("before attach") == true)
    }

    @MainActor
    func testLastSessionReferenceMayBeReleasedBySSHWorker() async throws {
        let owner = SessionOwner()
        let window = TestHost()
        weak var native: PlatformTerminalView?
        autoreleasepool {
            let view = owner.session!.platformView()
            native = view
            window.show(view)
        }
        try await Task.sleep(for: .milliseconds(100))
        owner.session!.output.write(Data("live teardown surface".utf8))
        XCTAssertTrue(owner.session!.backend.waitForPendingOutput())
        XCTAssertTrue(owner.session!.backend.readViewportText()?.contains("live teardown surface") == true)
        window.close()
        await Task.detached { owner.releaseSession() }.value
        for _ in 0..<50 where native != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(native, "Detached native surface must be released, without a worker-thread teardown trap")
    }
}

private final class SessionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CatusshTerminalSession? = .init()
    var session: CatusshTerminalSession? { lock.withLock { value } }
    func releaseSession() { lock.withLock { value = nil } }
}
