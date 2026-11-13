//
//  RemoteDesktopMailboxTests.swift
//  CatusshModuleTests
//
//  Frames and cursors from a driver's threads, on their way to the canvas.
//

@testable import CatusshModule
import CoreGraphics
import XCTest

final class RemoteDesktopMailboxTests: XCTestCase {
    private func image() -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testFramesWaitingForTheMainActorCollapseToTheLatest() {
        let mailbox = RemoteDesktopMailbox()
        let first = image()
        let latest = image()
        XCTAssertTrue(mailbox.post(frame: first, size: CGSize(width: 2, height: 2), desktopName: "host"))
        XCTAssertFalse(mailbox.post(frame: latest, size: CGSize(width: 2, height: 2), desktopName: nil))
        // A size change without a picture keeps the waiting picture.
        XCTAssertFalse(mailbox.post(frame: nil, size: CGSize(width: 4, height: 4), desktopName: nil))
        XCTAssertFalse(mailbox.post(cursor: nil))
        let mail = mailbox.take()
        XCTAssertTrue(mail.frame?.image === latest)
        XCTAssertEqual(mail.frame?.size, CGSize(width: 4, height: 4))
        XCTAssertEqual(mail.frame?.desktopName, "host")
        XCTAssertNotNil(mail.cursor, "a hidden cursor is news too")
        XCTAssertEqual(mailbox.takeFrameCount(), 2)
        // Taken: the next post asks for a trip again.
        XCTAssertTrue(mailbox.post(cursor: nil))
        XCTAssertNil(mailbox.take().frame)
    }
}
