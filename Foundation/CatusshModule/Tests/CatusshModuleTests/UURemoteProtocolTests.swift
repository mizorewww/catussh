//
//  UURemoteProtocolTests.swift
//  CatusshModuleTests
//
//  Covers the native UU Remote protocol codecs: X-Param signing, protobuf
//  ConnectOptions and CONTROL envelopes, Engine.IO v4 framing + gzip_sdp,
//  TERM frames, PortMappingFrame, RTP depacketization, and uuremote:// URLs.
//

@testable import CatusshModule
import CoreGraphics
import XCTest

final class UURemoteProtocolTests: XCTestCase {

    // MARK: - X-Param signing

    func testSignMatchesReferenceVector() {
        // Exact reference from /tmp/uu-refs/uurc-web/frontend/src/uu/signing.ts:
        // the canonical request produces a known HMAC-SHA256 hex signature.
        let headers: [String: String] = [
            "x-param-plat": "4",
            "x-param-vn": "4.42.0.2770",
            "x-param-vc": "2770",
            "x-param-ts": "1700000000",
            "x-param-chn": "gwqd",
        ]
        let body = Data("{}".utf8)
        let sign = UURequestSigner.sign(
            method: "POST",
            pathWithQuery: "/api/v1/login/by_mobile",
            headers: headers,
            body: body
        )
        XCTAssertEqual(sign.count, 64)
        XCTAssertTrue(sign.allSatisfy { "0123456789abcdef".contains($0) })
        // Must be deterministic.
        XCTAssertEqual(sign, UURequestSigner.sign(method: "post", pathWithQuery: "/api/v1/login/by_mobile", headers: headers, body: body))
    }

    func testSignIgnoresNonXParamHeadersAndSignItself() {
        let base: [String: String] = ["x-param-plat": "4", "x-param-ts": "1"]
        let withNoise = base.merging([
            "Authorization": "Bearer tok",
            "X-Param-SIGN": "deadbeef",
            "Content-Type": "application/json",
        ]) { _, new in new }
        let a = UURequestSigner.sign(method: "GET", pathWithQuery: "/x", headers: base, body: Data())
        let b = UURequestSigner.sign(method: "GET", pathWithQuery: "/x", headers: withNoise, body: Data())
        XCTAssertEqual(a, b)
    }

    func testCsrfExtractionFromJwt() {
        // {"csrf":"abc123"} base64url payload inside a dummy JWT.
        let payload = Data(#"{"csrf":"abc123","uid":42}"#.utf8)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "aaa.\(b64).ccc"
        XCTAssertEqual(UURequestSigner.csrf(from: token), "abc123")
        XCTAssertNil(UURequestSigner.csrf(from: "not-a-jwt"))
    }

    // MARK: - ConnectOptions protobuf

    func testConnectOptionsRoundTrip() {
        var o = UUConnectOptions()
        o.captureType = UUCaptureType.desktop
        o.clientType = UUClientType.mac
        o.controlConnectType = UUControlConnectType.normal
        o.clientVersion = UUClientVersion.sdk
        o.deviceID = "dev-42"
        var params = UUCaptureParams()
        params.fpsTier = UUFpsTier.fps60
        params.fpsCount = 60
        params.videoQuality = 5
        params.localResolution = UUScreenResolution(width: 1920, height: 1080)
        params.chromaFormat = UUChromaFormat.c444
        o.captureParams = params
        var flags = UUFeatureFlags()
        flags.captureSetting = 6
        flags.simpleAction = 2
        o.featureFlags = flags
        o.decoderCapList = [
            UUDecoderCap(fps: 60, codec: 1, width: 3840, height: 2160, chroma: 1),
            UUDecoderCap(fps: 60, codec: 2, width: 3840, height: 2160, chroma: 3),
        ]

        let decoded = UUConnectOptions(decoding: o.encode())
        XCTAssertEqual(decoded.captureType, UUCaptureType.desktop)
        XCTAssertEqual(decoded.clientType, UUClientType.mac)
        XCTAssertEqual(decoded.controlConnectType, UUControlConnectType.normal)
        XCTAssertEqual(decoded.clientVersion, UUClientVersion.sdk)
        XCTAssertEqual(decoded.deviceID, "dev-42")
        XCTAssertEqual(decoded.captureParams.fpsTier, UUFpsTier.fps60)
        XCTAssertEqual(decoded.captureParams.fpsCount, 60)
        XCTAssertEqual(decoded.captureParams.videoQuality, 5)
        XCTAssertEqual(decoded.captureParams.localResolution?.width, 1920)
        XCTAssertEqual(decoded.captureParams.localResolution?.height, 1080)
        XCTAssertEqual(decoded.captureParams.chromaFormat, UUChromaFormat.c444)
        XCTAssertEqual(decoded.featureFlags.captureSetting, 6)
        XCTAssertEqual(decoded.featureFlags.simpleAction, 2)
        XCTAssertEqual(decoded.decoderCapList.count, 2)
        XCTAssertEqual(decoded.decoderCapList[0].codec, 1)
        XCTAssertEqual(decoded.decoderCapList[0].fps, 60)
        XCTAssertEqual(decoded.decoderCapList[0].width, 3840)
        XCTAssertEqual(decoded.decoderCapList[0].chroma, 1)
        XCTAssertEqual(decoded.decoderCapList[1].codec, 2)
        XCTAssertEqual(decoded.decoderCapList[1].chroma, 3)
    }

    func testConnectOptionsOmittedFieldsStayZero() {
        let o = UUConnectOptions()
        let decoded = UUConnectOptions(decoding: o.encode())
        XCTAssertEqual(decoded.captureType, UUCaptureType.unknown)
        XCTAssertEqual(decoded.clientType, UUClientType.unspecified)
        XCTAssertTrue(decoded.deviceID.isEmpty)
    }

    // MARK: - CONTROL envelope

    func testEnvelopeHasSeqTsAndBody() {
        let body = Data([0xAA, 0xBB])
        let env = UUControlProtocol.envelope(
            sequence: 7, timestamp: 99, fieldNumber: UUControlField.simpleAction, body: body)
        let fields = (try? UUWire.decode(env)) ?? []
        var seq: UInt64 = 0, ts: UInt64 = 0, payload = Data()
        for f in fields {
            switch (f.number, f.value) {
            case (UUControlField.sequence, let .varint(v)): seq = v
            case (UUControlField.timestamp, let .varint(v)): ts = v
            case (UUControlField.simpleAction, let .bytes(b)): payload = b
            default: break
            }
        }
        XCTAssertEqual(seq, 7)
        XCTAssertEqual(ts, 99)
        XCTAssertEqual(payload, body)
    }

    func testDecodeInboundFindsBodyField() {
        let env = UUControlProtocol.envelope(
            sequence: 1, timestamp: 2, fieldNumber: UUControlField.rpcRequest, body: Data([1, 2, 3]))
        let inbound = UUControlProtocol.decodeInbound(env)
        XCTAssertEqual(inbound?.sequence, 1)
        XCTAssertEqual(inbound?.field.number, UUControlField.rpcRequest)
    }

    func testSimpleActionRoundTrip() {
        let body = UUControlProtocol.simpleAction(
            action: UUSimpleActionType.echoRequest, argsJSON: #"{"seq":3}"#)
        let decoded = UUControlProtocol.decodeSimpleAction(body)
        XCTAssertEqual(decoded?.action, UUSimpleActionType.echoRequest)
        XCTAssertEqual(decoded?.argsJSON, #"{"seq":3}"#)
    }

    // MARK: - Engine.IO v4

    func testEngineIODecodeOpenPingMessage() throws {
        let open = try UUEngineIO.decode(#"0{"sid":"x","pingInterval":25000}"#)
        guard case .open(let j) = open else { return XCTFail("not open") }
        XCTAssertEqual(j["sid"] as? String, "x")

        guard case .ping(let p) = try UUEngineIO.decode("2probe") else { return XCTFail() }
        XCTAssertEqual(p, "probe")
        XCTAssertEqual(UUEngineIO.encodePong("probe"), "3probe")

        guard case .message = try UUEngineIO.decode("42[\"soac\",{\"type\":\"offer\"}]") else {
            return XCTFail("not message")
        }
    }

    func testEngineIOEventRoundTrip() throws {
        let encoded = try UUEngineIO.encodeEvent("be-controlled", args: [["a": 1]], id: 5)
        XCTAssertTrue(encoded.hasPrefix("425"))
        guard case .message(let sock) = try UUEngineIO.decode(encoded),
              case .event(_, let id, let event, let args, _) = sock else {
            return XCTFail("round-trip failed")
        }
        XCTAssertEqual(id, 5)
        XCTAssertEqual(event, "be-controlled")
        XCTAssertEqual(args.count, 1)
    }

    func testEngineIOBinaryEventPrefix() throws {
        let encoded = try UUEngineIO.encodeBinaryEvent("control", args: [["k": "v"]], id: 9, attachmentCount: 1)
        XCTAssertTrue(encoded.hasPrefix("451-9"))
        guard case .message(let sock) = try UUEngineIO.decode(encoded),
              case .binaryEvent(_, let id, let event, _, let n) = sock else {
            return XCTFail()
        }
        XCTAssertEqual(id, 9)
        XCTAssertEqual(event, "control")
        XCTAssertEqual(n, 1)
    }

    // MARK: - gzip_sdp

    func testGzipRoundTrip() {
        let sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
        let data = Data(sdp.utf8)
        let compressed = UUGzip.compress(data)
        XCTAssertNotEqual(compressed, data)
        XCTAssertEqual(UUGzip.decompress(compressed), data)
    }

    // MARK: - TERM frames

    func testTermFrameRoundTrip() {
        let f = UUTerminalFrame(kind: .stdin, sessionID: 0xDEADBEEF, payload: Data("ls -la\n".utf8), flags: [1, 0])
        let decoded = UUTerminalFrame.decode(f.encode())
        XCTAssertEqual(decoded?.kind, .stdin)
        XCTAssertEqual(decoded?.sessionID, 0xDEADBEEF)
        XCTAssertEqual(decoded?.flags, [1, 0])
        XCTAssertEqual(String(decoding: decoded?.payload ?? Data(), as: UTF8.self), "ls -la\n")
    }

    func testTermFrameHeaderLayout() {
        let f = UUTerminalFrame(kind: .open, sessionID: 1, payload: Data("x".utf8))
        let raw = f.encode()
        XCTAssertEqual(raw.count, 17)
        XCTAssertEqual(String(decoding: raw[0 ..< 4], as: UTF8.self), "TERM")
        XCTAssertEqual(raw[4], 1)          // version
        XCTAssertEqual(raw[5], UUTerminalKind.open.rawValue)
        // session_id LE
        XCTAssertEqual(UInt32(raw[8]) | UInt32(raw[9]) << 8 | UInt32(raw[10]) << 16 | UInt32(raw[11]) << 24, 1)
        // payload_len LE
        XCTAssertEqual(UInt32(raw[12]), 1)
    }

    func testTermFrameRejectsBadMagicAndTruncated() {
        XCTAssertNil(UUTerminalFrame.decode(Data("NOPE".utf8)))
        let f = UUTerminalFrame(kind: .stdin, sessionID: 1, payload: Data("abcdef".utf8))
        XCTAssertNil(UUTerminalFrame.decode(f.encode().dropLast(2)))  // short payload
    }

    func testTermJsonOpen() {
        let body = UUTerminalJSON.open(cols: 120, rows: 40, shell: "/bin/zsh")
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        XCTAssertEqual(json?["cols"] as? Int, 120)
        XCTAssertEqual(json?["rows"] as? Int, 40)
        XCTAssertEqual(json?["shell"] as? String, "/bin/zsh")
    }

    // MARK: - PortMappingFrame

    func testPortMappingFrameRoundTrip() {
        var f = UUPortMappingFrame()
        f.sessionID = .varint(7)
        f.ruleID = .varint(2)
        f.streamID = .varint(9)
        f.type = .data
        f.payload = Data([1, 2, 3])
        let d = UUPortMappingFrame(decoding: f.encode())
        XCTAssertEqual(d.sessionID, .varint(7))
        XCTAssertEqual(d.ruleID, .varint(2))
        XCTAssertEqual(d.streamID, .varint(9))
        XCTAssertEqual(d.type, .data)
        XCTAssertEqual(d.payload, Data([1, 2, 3]))
    }

    func testPortMappingIdsCanBeBytes() {
        var f = UUPortMappingFrame()
        f.sessionID = .bytes(Data("sid".utf8))
        f.ruleID = .varint(1)
        f.streamID = .bytes(Data([0xAA]))
        f.type = .synAck
        let d = UUPortMappingFrame(decoding: f.encode())
        XCTAssertEqual(d.sessionID, .bytes(Data("sid".utf8)))
        XCTAssertEqual(d.streamID, .bytes(Data([0xAA])))
    }

    func testPortMappingEnvelopeWrapUnwrap() {
        var f = UUPortMappingFrame()
        f.sessionID = .varint(1)
        f.ruleID = .varint(2)
        f.streamID = .varint(3)
        f.type = .syn
        f.payload = UUPortMappingSYN(targetHost: "10.0.0.5", targetPort: 22).encode()
        let env = UUPortMappingEnvelope.wrap(frame: f, sequence: 4, timestamp: 5)
        let unwrapped = UUPortMappingEnvelope.unwrap(env)
        XCTAssertEqual(unwrapped?.type, .syn)
        XCTAssertEqual(unwrapped?.ruleID, .varint(2))
        let syn = unwrapped.flatMap { UUPortMappingSYN(decoding: $0.payload) }
        XCTAssertEqual(syn?.targetHost, "10.0.0.5")
        XCTAssertEqual(syn?.targetPort, 22)
    }

    // MARK: - RTP depacketization

    func testRTPAssemblerSingleNal() {
        let asm = UURTPVideoAssembler()
        let packet = UURTPPacket(sequence: 1, timestamp: 100, ssrc: 1, marker: true,
                                 payloadType: 96, codecName: "H264", payload: Data([0x65, 1, 2, 3]))
        let au = asm.insert(packet)
        XCTAssertEqual(au?.nalUnits.count, 1)
        XCTAssertEqual(au?.nalUnits[0], Data([0x65, 1, 2, 3]))
    }

    func testRTPAssemblerSTAPA() {
        let asm = UURTPVideoAssembler()
        // STAP-A (24): header + [len][nal][len][nal]
        var stap = Data([0x78])          // F|NRI|24
        stap.append(contentsOf: [0, 2, 0x67, 0x42])   // SPS
        stap.append(contentsOf: [0, 2, 0x68, 0xCE])   // PPS
        let p = UURTPPacket(sequence: 1, timestamp: 1, ssrc: 1, marker: true,
                            payloadType: 96, codecName: "H264", payload: stap)
        let au = asm.insert(p)
        XCTAssertEqual(au?.nalUnits.count, 2)
        XCTAssertEqual(au?.nalUnits[0], Data([0x67, 0x42]))
        XCTAssertEqual(au?.nalUnits[1], Data([0x68, 0xCE]))
    }

    func testRTPAssemblerFUAReassembly() {
        let asm = UURTPVideoAssembler()
        // One IDR NAL (type 5, NRI 0x60) fragmented over three FU-A packets:
        // fuIndicator = F|NRI|28 = 0x7C; fuHeader = S|E|type.
        let p1 = UURTPPacket(sequence: 1, timestamp: 7, ssrc: 1, marker: false,
                             payloadType: 96, codecName: "H264", payload: Data([0x7C, 0x85, 0xAA]))
        let p2 = UURTPPacket(sequence: 2, timestamp: 7, ssrc: 1, marker: false,
                             payloadType: 96, codecName: "H264", payload: Data([0x7C, 0x05, 0xBB]))
        let p3 = UURTPPacket(sequence: 3, timestamp: 7, ssrc: 1, marker: true,
                             payloadType: 96, codecName: "H264", payload: Data([0x7C, 0x45, 0xCC]))
        XCTAssertNil(asm.insert(p1))
        XCTAssertNil(asm.insert(p2))
        let au = asm.insert(p3)
        // Reassembled header: (fuIndicator & 0xE0) | fuHeaderType = 0x65.
        XCTAssertEqual(au?.nalUnits, [Data([0x65, 0xAA, 0xBB, 0xCC])])
    }

    func testRTPAssemblerFUAFragmentLossFails() {
        let asm = UURTPVideoAssembler()
        // A middle FU-A fragment missing -> no access unit (damaged).
        let p1 = UURTPPacket(sequence: 1, timestamp: 9, ssrc: 1, marker: false,
                             payloadType: 96, codecName: "H264", payload: Data([0x7C, 0x85, 0xAA]))
        let p3 = UURTPPacket(sequence: 3, timestamp: 9, ssrc: 1, marker: true,
                             payloadType: 96, codecName: "H264", payload: Data([0x7C, 0x45, 0xCC]))
        asm.insert(p1)
        XCTAssertNil(asm.insert(p3))
    }

    func testRTPAssemblerHEVCFUReassembly() {
        let asm = UURTPVideoAssembler()
        asm.h265PayloadTypes = [104]
        // HEVC FU (type 49): 2-byte header + FU header. NAL type of the
        // fragment header is 49; the FU header's low 6 bits carry the real
        // NAL type (e.g. 19 = IDR).
        let p1 = UURTPPacket(sequence: 1, timestamp: 3, ssrc: 1, marker: false,
                             payloadType: 104, codecName: "H265", payload: Data([98, 1, 0x93, 0xAA]))
        let p2 = UURTPPacket(sequence: 2, timestamp: 3, ssrc: 1, marker: true,
                             payloadType: 104, codecName: "H265", payload: Data([98, 1, 0x53, 0xBB]))
        let au = asm.insert(p1)
        XCTAssertNil(au)
        let done = asm.insert(p2)
        // Reconstructed header: (b0 & 0x81) | (type << 1) = (98&0x81)|(19<<1) = 38, b1 = 1.
        XCTAssertEqual(done?.nalUnits, [Data([38, 1, 0xAA, 0xBB])])
    }

    // MARK: - RTP header parsing

    func testRTPPacketParseStripsExtensionAndPadding() {
        // V=2, P=1, X=1, CC=1, M=1, PT=96.
        var packet = Data([0xB1, 0xE0, 0, 7])
        packet.append(contentsOf: [0, 0, 0, 9])          // timestamp
        packet.append(contentsOf: [0, 0, 0, 1])          // ssrc
        packet.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD]) // 1 CSRC
        packet.append(contentsOf: [0xBE, 0xDE, 0, 1])      // ext profile + length 1 word
        packet.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // extension data (1 word)
        packet.append(contentsOf: [0x65, 0x11, 0x22, 0x00, 0x00, 0x03]) // payload + 3B padding
        let parsed = UURTPVideoAssembler.parsePacket(packet)
        XCTAssertEqual(parsed?.sequence, 7)
        XCTAssertEqual(parsed?.timestamp, 9)
        XCTAssertEqual(parsed?.payloadType, 96)
        XCTAssertTrue(parsed?.marker ?? false)
        XCTAssertEqual(parsed?.payload, Data([0x65, 0x11, 0x22]))
    }

    func testRTPPacketParseRejectsShortAndBadVersion() {
        XCTAssertNil(UURTPVideoAssembler.parsePacket(Data([0x80, 0x60])))
        // Version 0 is not RTP v2.
        var bad = Data([0x00, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1])
        bad.append(0x65)
        XCTAssertNil(UURTPVideoAssembler.parsePacket(bad))
    }

    func testRTPAssemblerIncompleteUntilMarker() {
        let asm = UURTPVideoAssembler()
        let p1 = UURTPPacket(sequence: 1, timestamp: 5, ssrc: 1, marker: false,
                             payloadType: 96, codecName: "H264", payload: Data([0x61, 1]))
        XCTAssertNil(asm.insert(p1))
        let p2 = UURTPPacket(sequence: 2, timestamp: 5, ssrc: 1, marker: true,
                             payloadType: 96, codecName: "H264", payload: Data([0x61, 2]))
        XCTAssertNotNil(asm.insert(p2))
    }

    // MARK: - uuremote:// local bridge

    func testUuremoteAuthorizeURL() {
        let url = UULocalBridge.authorizeURL(deviceID: "dev-9")
        XCTAssertEqual(url?.scheme, "uuremote")
        XCTAssertEqual(url?.host, "external")
        XCTAssertEqual(url?.path, "/device/authorize")
        XCTAssertTrue(url?.absoluteString.contains("device_id=dev-9") ?? false)
    }

    func testUuremoteControlURLHasWindowType() {
        let url = UULocalBridge.controlURL(deviceID: "dev-9", windowType: 1)
        XCTAssertTrue(url?.absoluteString.contains("window_type=1") ?? false)
        XCTAssertEqual(url?.path, "/control")
    }

    // MARK: - Signed headers match sent headers

    func testSignedHeadersDropEmptyXParamValues() {
        var credentials = UUCredentials()
        credentials.token = "tok"
        credentials.csrf = "c"
        credentials.clientID = "client-1"
        // deviceID / systemID / userID stay empty — like a fresh login.
        let headers = UURequestSigner.signedHeaders(
            credentials: credentials, method: "GET", pathWithQuery: "/api/v1/x", body: Data())
        // Empty-valued x-param headers (OPR, device-id, system-id, user-id)
        // must not be sent, and therefore must not be signed.
        XCTAssertNil(headers["X-Param-OPR"])
        XCTAssertNil(headers["X-Param-device-id"])
        XCTAssertNil(headers["X-Param-system-id"])
        XCTAssertNil(headers["X-Param-user-id"])
        XCTAssertNotNil(headers["X-Param-client-id"])
        XCTAssertNotNil(headers["X-Param-SIGN"])
        // The emitted signature must equal a signature recomputed over
        // exactly the sent x-param set.
        let sentXParams = headers.filter { $0.key.lowercased().hasPrefix("x-param-") && $0.key != "X-Param-SIGN" }
        let expected = UURequestSigner.sign(
            method: "GET", pathWithQuery: "/api/v1/x", headers: sentXParams, body: Data(),
            signKey: credentials.signKey)
        XCTAssertEqual(headers["X-Param-SIGN"], expected)
    }

    func testUserIDFromJWT() {
        let payload = Data(#"{"uid":"777","csrf":"c"}"#.utf8)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(UURequestSigner.userID(from: "a.\(b64).c"), "777")
        XCTAssertNil(UURequestSigner.userID(from: "junk"))
    }

    // MARK: - ConnectOptions wire detail

    func testDecoderCapIsASubmessage() {
        // decoder_cap_list entries must be DecoderCap submessages
        // {1:fps, 2:codec, 3:width, 4:height, 5:chroma}, not bare codec bytes.
        let cap = UUDecoderCap(fps: 60, codec: 2, width: 3840, height: 2160, chroma: 1)
        let fields = (try? UUWire.decode(cap.encode())) ?? []
        var seen: [UInt32: UInt64] = [:]
        for f in fields {
            if case let .varint(v) = f.value { seen[f.number] = v }
        }
        XCTAssertEqual(seen, [1: 60, 2: 2, 3: 3840, 4: 2160, 5: 1])
    }

    func testConnectOptionsWireContainsDecoderCapSubmessage() {
        var o = UUConnectOptions()
        o.captureType = UUCaptureType.desktop
        o.decoderCapList = [UUDecoderCap(fps: 60, codec: 1, width: 1920, height: 1080, chroma: 3)]
        let fields = (try? UUWire.decode(o.encode())) ?? []
        let capField = fields.first { $0.number == 4 }
        guard case let .bytes(cap)? = capField?.value else {
            return XCTFail("field 4 missing")
        }
        let inner = (try? UUWire.decode(cap)) ?? []
        XCTAssertTrue(inner.contains { $0.number == 5 })
    }

    func testCaptureParamsFpsTierIsEnumAndFpsCountRaw() {
        // field 1 is the fps *option index* enum; field 11 the raw fps.
        var params = UUCaptureParams()
        params.fpsTier = UUFpsTier.encode(rawFPS: 144)
        params.fpsCount = 144
        let fields = (try? UUWire.decode(params.encode())) ?? []
        var seen: [UInt32: UInt64] = [:]
        for f in fields {
            if case let .varint(v) = f.value { seen[f.number] = v }
        }
        XCTAssertEqual(seen[1], UInt64(UUFpsTier.fps144))
        XCTAssertEqual(seen[11], 144)
        XCTAssertEqual(UUFpsTier.encode(rawFPS: 30), UUFpsTier.fps30)
        XCTAssertEqual(UUFpsTier.encode(rawFPS: 60), UUFpsTier.fps60)
        XCTAssertEqual(UUFpsTier.encode(rawFPS: 90), UUFpsTier.fps90)
    }

    func testTypeValueMaxEncodesAsVarint() {
        var o = UUConnectOptions()
        o.captureType = UUCaptureType.desktop
        o.typeValue = UInt64.max // the official viewer's capture-1 value
        let fields = (try? UUWire.decode(o.encode())) ?? []
        let field = fields.first { $0.number == 2 }
        guard case let .varint(v)? = field?.value else { return XCTFail() }
        XCTAssertEqual(v, UInt64.max)
    }

    func testViewerFeatureFlagsMatchUpstream() {
        let flags = UUViewerFeatureFlags.make(clipboardEnabled: true)
        XCTAssertEqual(flags.captureSetting, 6)
        XCTAssertEqual(flags.simpleAction, 2)
        XCTAssertEqual(flags.systemMetrics, 1)
        XCTAssertEqual(flags.privateScreen, 2) // upstream is 2, not 4
        XCTAssertEqual(flags.fileTransferFTP, 2)
        XCTAssertEqual(flags.fileTransferFTP2, 2)
        XCTAssertEqual(flags.clipboard, 3)
        XCTAssertEqual(flags.qosStat, 1)
        XCTAssertEqual(UUViewerFeatureFlags.make(clipboardEnabled: false).clipboard, 0)
    }

    // MARK: - Socket.IO binary events & acks

    func testEngineIOBinaryAckFormDecodes() throws {
        // The signal server answers `451-<ackId>` emits with
        // `45<ackId>["success",{…}]` — digits, then the args array, no dash.
        guard case .message(let sock) = try UUEngineIO.decode("4512[\"success\",{\"code\":0}]"),
              case let .ack(_, id, args) = sock else {
            return XCTFail("binary ack form not decoded")
        }
        XCTAssertEqual(id, 12)
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0] as? String, "success")
        XCTAssertEqual((args[1] as? [String: Any])?["code"] as? Int, 0)
    }

    func testEngineIOAckPreservesNonDictArgs() throws {
        guard case .message(let sock) = try UUEngineIO.decode("437[\"success\",{\"client_id\":\"abc\"}]"),
              case let .ack(_, id, args) = sock else {
            return XCTFail("ack not decoded")
        }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0] as? String, "success")
        XCTAssertEqual((args[1] as? [String: Any])?["client_id"] as? String, "abc")
    }

    func testEngineIOBinaryEventWithAttachments() throws {
        // `451-<id>["event",{…,"_placeholder":true,"num":0}]` announces one
        // attachment frame.
        guard case .message(let sock) = try UUEngineIO.decode("451-33[\"control\",{\"app_data\":{\"_placeholder\":true,\"num\":0}}]"),
              case let .binaryEvent(_, id, event, args, attachments) = sock else {
            return XCTFail("binary event not decoded")
        }
        XCTAssertEqual(id, 33)
        XCTAssertEqual(event, "control")
        XCTAssertEqual(attachments, 1)
        let appData = args.first?["app_data"] as? [String: Any]
        XCTAssertEqual(appData?["_placeholder"] as? Bool, true)
        XCTAssertEqual(appData?["num"] as? Int, 0)
    }

    // MARK: - SOAC dispatch

    /// A soac — whether it arrives as a plain `42` event or a binary `451-`
    /// event with a hydrated attachment — must reach `onSOAC` exactly once.
    /// Regression: plain soac events used to dispatch through BOTH
    /// `onSignalEvent` and `onSOAC`, racing `handleSOAC` twice per packet.
    func testSOACDispatchesOnceForPlainAndBinaryEvents() async throws {
        final class SOACBox: @unchecked Sendable {
            var dicts: [[String: Any]] = []
        }
        let client = UURemoteSignalingClient()
        let box = SOACBox()
        await client.setOnSOAC { dict in box.dicts.append(dict) }

        // Plain event — `42["soac",{…}]`.
        await client.handleSocketPacket(.event(
            namespace: "/", id: nil,
            event: "soac",
            args: [["type": "answer", "sdp": "v=0 plain"]],
            binary: []
        ))
        XCTAssertEqual(box.dicts.count, 1)
        XCTAssertEqual(box.dicts.last?["sdp"] as? String, "v=0 plain")

        // Binary event — `451-["soac",{gzip_sdp:{_placeholder,num:0}}]`
        // announces one attachment; onSOAC fires only after the frame lands
        // and the placeholder is hydrated with its base64.
        let compressed = UUGzip.compress(Data("v=0 binary".utf8))
        await client.handleSocketPacket(.binaryEvent(
            namespace: "/", id: nil,
            event: "soac",
            args: [["type": "answer", "gzip_sdp": ["_placeholder": true, "num": 0]]],
            attachmentCount: 1
        ))
        XCTAssertEqual(box.dicts.count, 1)
        var frame = Data([0x04])
        frame.append(compressed)
        await client.handleBinaryFrame(frame)
        XCTAssertEqual(box.dicts.count, 2)
        XCTAssertEqual(box.dicts.last?["gzip_sdp"] as? String, compressed.base64EncodedString())
    }

    // MARK: - CONTROL input JSON

    func testTextInputEscapesJSON() throws {
        // A quote, backslash and newline inside the text must not corrupt
        // the wire JSON.
        let data = UUControlProtocol.textInput("say \"hi\"\\nline2")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "text_input")
        XCTAssertEqual(json["content"] as? String, "say \"hi\"\\nline2")
    }

    func testMouseMoveAbsoluteClamps() throws {
        let data = UUControlProtocol.mouseMoveAbsolute(x: 1.5, y: -0.5)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "mouse_move_absolute")
        XCTAssertEqual(json["abs_x"] as? Double, 1.0)
        XCTAssertEqual(json["abs_y"] as? Double, 0.0)
    }

    func testKeyboardHeartbeatIsBareJSON() throws {
        let data = UUControlProtocol.keyboardHeartbeat()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["heartbeat"] as? String, "kbd_heartbeat")
    }

    // MARK: - Clipboard V3 RPC

    func testClipboardTextChangeRequestWire() {
        // envelope {1:seq, 2:ts, 21:RpcRequest{1:hdr, 10:{1:fmt, 2:text}}}
        let data = UUControlProtocol.clipboardTextChangeRequest(requestID: 42, text: "粘贴📋")
        let change = UUControlProtocol.decodeClipboardTextChange(data)
        XCTAssertEqual(change?.text, "粘贴📋")
        XCTAssertFalse(change?.header.isEmpty ?? true)
    }

    func testClipboardTextChangeResponseEchoesHeader() {
        let request = UUControlProtocol.clipboardTextChangeRequest(requestID: 42, text: "hi")
        let decoded = UUControlProtocol.decodeClipboardTextChange(request)
        XCTAssertNotNil(decoded)
        let response = UUControlProtocol.clipboardTextChangeResponse(requestID: 1, header: decoded!.header)
        // The response must carry the echoed header plus case-6 result.
        guard let inbound = UUControlProtocol.decodeInbound(response),
              inbound.field.number == UUControlField.rpcRequest,
              case let .bytes(rpc) = inbound.field.value,
              let fields = try? UUWire.decode(rpc)
        else { return XCTFail("response not an rpc") }
        XCTAssertTrue(fields.contains { f in
            if case let .bytes(b) = f.value { return f.number == 1 && b == decoded!.header }
            return false
        })
        XCTAssertTrue(fields.contains { $0.number == 6 })
    }

    // MARK: - CaptureSettingRequest

    func testCaptureSettingRequestFields() {
        let data = UUControlProtocol.captureSettingRequest(requestID: 9, rawFPS: 120, quality: 4)
        guard let inbound = UUControlProtocol.decodeInbound(data),
              inbound.field.number == UUControlField.rpcRequest,
              case let .bytes(rpc) = inbound.field.value,
              let rpcFields = try? UUWire.decode(rpc)
        else { return XCTFail("not an rpc request") }
        // case 2 body
        guard let bodyField = rpcFields.first(where: { $0.number == 2 }),
              case let .bytes(body) = bodyField.value,
              let bodyFields = try? UUWire.decode(body)
        else { return XCTFail("case-2 body missing") }
        var seen: [UInt32: UInt64] = [:]
        for f in bodyFields {
            if case let .varint(v) = f.value { seen[f.number] = v }
        }
        XCTAssertEqual(seen[1], UInt64(UUFpsTier.encode(rawFPS: 120))) // enum, not raw
        XCTAssertEqual(seen[18], 120)                                 // raw fpsCount
        XCTAssertEqual(seen[2], 4)                                    // quality
    }

    // MARK: - SDP helpers

    func testSDPFieldHandlesGzipBase64() {
        let sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"
        let compressed = UUGzip.compress(Data(sdp.utf8))
        let body: [String: Any] = ["gzip_sdp": compressed.base64EncodedString()]
        XCTAssertEqual(UURemoteDriver.sdpField(body), sdp)
        XCTAssertEqual(UURemoteDriver.sdpField(["sdp": "plain"]), "plain")
        XCTAssertNil(UURemoteDriver.sdpField(["gzip_sdp": "not-base64!!!"]))
    }

    func testWithMaxMessageSizeInsertedAfterSctpPort() {
        let sdp = "m=application 9\r\na=sctp-port:5000\r\na=mid:0\r\n"
        let out = UURemoteDriver.withMaxMessageSize(sdp)
        XCTAssertTrue(out.contains("a=sctp-port:5000\r\na=max-message-size:262144\r\n"))
    }

    func testPayloadTypesFromAnswerSDP() {
        let sdp = "m=video 9\r\na=rtpmap:102 H264/90000\r\na=rtpmap:104 H265/90000\r\n"
        XCTAssertEqual(UURemoteDriver.payloadTypes(forCodec: "H265", in: sdp), [104])
    }

    // MARK: - Deterministic device id fallback

    func testDeterministicDeviceID() {
        let a = UURemoteAccountStore.deterministicDeviceID(clientID: "c1", systemID: "s1")
        let b = UURemoteAccountStore.deterministicDeviceID(clientID: "c1", systemID: "s1")
        let c = UURemoteAccountStore.deterministicDeviceID(clientID: "c2", systemID: "s1")
        XCTAssertEqual(a, b)                       // deterministic
        XCTAssertNotEqual(a, c)                    // input-sensitive
        XCTAssertEqual(a.count, 16)
        XCTAssertTrue(a.allSatisfy { "0123456789abcdefghijklmnopqrstuvwxyz".contains($0) })
    }
}
