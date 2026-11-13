//
//  UURemoteScreenTests.swift
//  CatusshModuleTests
//
//  A host with several screens: what it lists, which track each is on,
//  and where the pointer goes.
//

@testable import CatusshModule
import XCTest

final class UURemoteScreenTests: XCTestCase {
    /// WinRect `{1: left, 2: top, 3: width, 4: height, 5: pixel_width, 6: pixel_height}`.
    private func rect(width: Int32, height: Int32, pixels: (Int32, Int32)? = nil) -> Data {
        var out = Data()
        UUProtobufWriter.pushInt32Field(3, width, into: &out)
        UUProtobufWriter.pushInt32Field(4, height, into: &out)
        if let pixels {
            UUProtobufWriter.pushInt32Field(5, pixels.0, into: &out)
            UUProtobufWriter.pushInt32Field(6, pixels.1, into: &out)
        }
        return out
    }

    private func screen(id: Int32, name: String, current: Data, type: Int32 = 0, primary: Bool = false, track: Int32? = nil) -> Data {
        var out = Data()
        if id != 0 { UUProtobufWriter.pushInt32Field(1, id, into: &out) }
        UUProtobufWriter.pushInt32Field(2, 60, into: &out)
        UUProtobufWriter.pushMessageField(4, current, into: &out)
        if type != 0 { UUProtobufWriter.pushInt32Field(5, type, into: &out) }
        if primary { UUProtobufWriter.pushVarintField(7, 1, into: &out) }
        UUProtobufWriter.pushStringField(10, name, into: &out)
        if let track, track != 0 { UUProtobufWriter.pushInt32Field(12, track, into: &out) }
        return out
    }

    func testScreenSourcesSayTheCurrentScreenAndEachTrack() {
        var body = Data()
        UUProtobufWriter.pushMessageField(1, screen(id: 0, name: "Built-in Display", current: rect(width: 1728, height: 1117, pixels: (3456, 2234)), primary: true, track: 0), into: &body)
        UUProtobufWriter.pushMessageField(1, screen(id: 3, name: "UU远程 1", current: rect(width: 1920, height: 1080), type: 1, track: 1), into: &body)
        UUProtobufWriter.pushInt32Field(2, 3, into: &body)

        let sources = UUControlProtocol.decodeScreenSources(body)
        XCTAssertEqual(sources.currentID, 3)
        XCTAssertEqual(sources.displays.map(\.id), [0, 3])
        let builtIn = sources.displays[0]
        XCTAssertTrue(builtIn.isPrimary)
        XCTAssertFalse(builtIn.isVirtual)
        // Zero is not on the wire: the other screen's track says it is 0.
        XCTAssertEqual(builtIn.videoTrackIndex, 0)
        XCTAssertEqual(builtIn.width, 3456)
        XCTAssertEqual(builtIn.height, 2234)
        let virtual = sources.displays[1]
        XCTAssertTrue(virtual.isVirtual)
        XCTAssertEqual(virtual.videoTrackIndex, 1)
        XCTAssertEqual(virtual.width, 1920)
        XCTAssertEqual(virtual.name, "UU远程 1")
    }

    func testScreenSourcesWithoutTracksOrCurrentLeaveThemUnknown() {
        var body = Data()
        UUProtobufWriter.pushMessageField(1, screen(id: 1, name: "", current: rect(width: 1920, height: 1080)), into: &body)
        UUProtobufWriter.pushMessageField(1, screen(id: 2, name: "", current: rect(width: 2560, height: 1440)), into: &body)
        let sources = UUControlProtocol.decodeScreenSources(body)
        XCTAssertNil(sources.currentID)
        XCTAssertEqual(sources.displays.map(\.videoTrackIndex), [nil, nil])
        XCTAssertEqual(sources.displays.map(\.name), ["Display 1", "Display 2"])
    }

    func testAbsoluteMovesNameTheirScreen() throws {
        let data = UUControlProtocol.mouseMoveAbsolute(x: 0.25, y: 0.75, screenID: 3)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["screen_id"] as? Int, 3)
        XCTAssertEqual(json["abs_x"] as? Double, 0.25)
        let bare = try XCTUnwrap(JSONSerialization.jsonObject(with: UUControlProtocol.mouseMoveAbsolute(x: 0.5, y: 0.5)) as? [String: Any])
        XCTAssertNil(bare["screen_id"])
    }

    func testCapturingAScreenStartsAndStopsIt() throws {
        for (start, action) in [(true, UUSimpleActionType.restartCapture), (false, UUSimpleActionType.stopCapture)] {
            let inbound = try XCTUnwrap(UUControlProtocol.decodeInbound(UUControlProtocol.captureScreen(2, start: start, sequence: 9)))
            XCTAssertEqual(inbound.field.number, UUControlField.simpleAction)
            guard case let .bytes(body) = inbound.field.value else { return XCTFail("no body") }
            let decoded = try XCTUnwrap(UUControlProtocol.decodeSimpleAction(body))
            XCTAssertEqual(decoded.action, action)
            XCTAssertEqual(decoded.argsJSON, #"{"screen_id":2}"#)
        }
    }

    /// The RpcRequest's case `field` and its body.
    private func rpcBody(_ data: Data, field: UInt32) throws -> [UUWireField] {
        let inbound = try XCTUnwrap(UUControlProtocol.decodeInbound(data))
        XCTAssertEqual(inbound.field.number, UUControlField.rpcRequest)
        guard case let .bytes(rpc) = inbound.field.value else { throw XCTSkip("no rpc") }
        let fields = try UUWire.decode(rpc)
        guard case let .bytes(body)? = fields.first(where: { $0.number == field })?.value else {
            XCTFail("no case \(field)")
            return []
        }
        return try UUWire.decode(body)
    }

    func testVirtualDisplaysAreAskedForAndRemoved() throws {
        let create = try rpcBody(UUControlProtocol.createVirtualDisplay(requestID: 4, width: 2732, height: 2048), field: 12)
        guard case let .bytes(resolution)? = create.first(where: { $0.number == 1 })?.value else { return XCTFail("no resolution") }
        let size = try UUWire.decode(resolution)
        XCTAssertEqual(size.compactMap { if case let .varint(v) = $0.value { v.int32Value } else { nil } }, [2732, 2048])
        guard case let .varint(count)? = create.first(where: { $0.number == 2 })?.value else { return XCTFail("no count") }
        XCTAssertEqual(count, 1)

        let remove = try rpcBody(UUControlProtocol.removeVirtualDisplay(requestID: 5, screenID: 3), field: 13)
        guard case let .varint(id)? = remove.first?.value else { return XCTFail("no id") }
        XCTAssertEqual(id, 3)
    }

    func testVideoTracksRegisterEveryIndex() throws {
        let tracks = try rpcBody(UUControlProtocol.sendVideoTrackRequest(requestID: 6, tracks: [0, 1, 2]), field: 15)
        XCTAssertEqual(tracks.compactMap { if case let .varint(v) = $0.value { v.int32Value } else { nil } }, [0, 1, 2])
    }

    func testTrackIndexesComeFromMsidOrTheVideoLinesOrder() {
        let named = """
        v=0\r
        m=video 9 UDP/TLS/RTP/SAVPF 96\r
        a=mid:1\r
        a=msid:stream video_1\r
        m=video 9 UDP/TLS/RTP/SAVPF 96\r
        a=mid:0\r
        a=msid:stream video_0\r
        m=video 0 UDP/TLS/RTP/SAVPF 96\r
        a=mid:2\r
        m=audio 9 UDP/TLS/RTP/SAVPF 111\r
        a=mid:5\r
        m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r
        a=mid:6\r
        """
        XCTAssertEqual(UURemoteDriver.videoTrackMids(in: named), [1: "1", 0: "0"])

        let unnamed = "m=video 9 RTP 96\na=mid:a\nm=video 9 RTP 96\na=mid:b\n"
        XCTAssertEqual(UURemoteDriver.videoTrackMids(in: unnamed), [0: "a", 1: "b"])
    }
}
