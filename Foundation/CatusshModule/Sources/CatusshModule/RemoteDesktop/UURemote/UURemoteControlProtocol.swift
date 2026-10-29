//
//  UURemoteControlProtocol.swift
//  CatusshModule
//
//  The protobuf envelope and JSON input codec for the UU Remote
//  CONTROL_DATA_CHANNEL. Mirrors /tmp/uu-refs/uu-remote-linux/src/control_protocol.rs
//  and /tmp/uu-refs/uurc-web/shared/src/streamer/controlChannelProtocol.ts.
//

import CoreGraphics
import Foundation

/// Envelope Message field numbers on CONTROL_DATA_CHANNEL.
public enum UUControlField {
    public static let sequence: UInt32 = 1
    public static let timestamp: UInt32 = 2
    public static let simpleAction: UInt32 = 3
    public static let screenSources: UInt32 = 7
    public static let captureChange: UInt32 = 8
    public static let romMessage: UInt32 = 10
    public static let sendToRom: UInt32 = 11
    public static let reportError: UInt32 = 12
    public static let systemStateChange: UInt32 = 15
    public static let codecNegotiation: UInt32 = 18
    public static let rpcRequest: UInt32 = 21
    public static let rpcResponse: UInt32 = 22
    public static let portMappingFrame: UInt32 = 27
}

/// SimpleAction.action values (official ActionType table, 28 entries).
public enum UUSimpleActionType {
    public static let echoRequest: UInt64 = 0
    public static let echoResponse: UInt64 = 1
    public static let showDesktop: UInt64 = 2
    public static let showWindows: UInt64 = 3
    public static let captureDesktop: UInt64 = 4
    public static let captureWindow: UInt64 = 5
    public static let captureMumu: UInt64 = 6
    public static let stopCapture: UInt64 = 7
    public static let restartCapture: UInt64 = 8
    public static let rebootSystem: UInt64 = 9
    public static let lockSystem: UInt64 = 10
    public static let keyToggle: UInt64 = 11
    public static let shutdownSystem: UInt64 = 12
    public static let showTaskmgr: UInt64 = 13
    public static let muteSystem: UInt64 = 14
    public static let autoUnlockSystem: UInt64 = 15
    public static let muteRestore: UInt64 = 16
    public static let mutePermanent: UInt64 = 17
    public static let muteTemporary: UInt64 = 18
    public static let setAutoLock: UInt64 = 19
    public static let stopAcquireUpdate: UInt64 = 20
    public static let quitCapture: UInt64 = 21
    public static let acquireSystemInfo: UInt64 = 22
    public static let microphoneOpened: UInt64 = 23
    public static let microphoneClosed: UInt64 = 24
    public static let speakerOpened: UInt64 = 25
    public static let speakerClosed: UInt64 = 26
    public static let needRestartUserapp: UInt64 = 27

    public static func name(of action: UInt64) -> String? {
        let names: [UInt64: String] = [
            echoRequest: "echo_request", echoResponse: "echo_response",
            showDesktop: "show_desktop", showWindows: "show_windows",
            captureDesktop: "capture_desktop", captureWindow: "capture_window",
            captureMumu: "capture_mumu", stopCapture: "stop_capture",
            restartCapture: "restart_capture", rebootSystem: "reboot_system",
            lockSystem: "lock_system", keyToggle: "key_toggle",
            shutdownSystem: "shutdown_system", showTaskmgr: "show_taskmgr",
            muteSystem: "mute_system", autoUnlockSystem: "auto_unlock_system",
            muteRestore: "mute_restore", mutePermanent: "mute_permanent",
            muteTemporary: "mute_temporary", setAutoLock: "set_auto_lock",
            stopAcquireUpdate: "stop_acquire_update", quitCapture: "quit_capture",
            acquireSystemInfo: "acquire_system_info",
            microphoneOpened: "microphone_opened", microphoneClosed: "microphone_closed",
            speakerOpened: "speaker_opened", speakerClosed: "speaker_closed",
            needRestartUserapp: "need_restart_userapp",
        ]
        return names[action]
    }
}

/// FeatureFlag fields inside SimpleAction.field4.
public enum UUFeatureFlagTag {
    public static let captureSetting: Int = 1
    public static let simpleAction: Int = 2
    public static let systemMetrics: Int = 3
    public static let privateScreen: Int = 4
    public static let updateAcquire: Int = 5
    public static let fileTransferFTP: Int = 6
    public static let fileTransferFTP2: Int = 7
    public static let clipboard: Int = 8
    public static let qosStat: Int = 9
    public static let mumuControl: Int = 10
    public static let virtualMouseDevice: Int = 11
}

/// SimpleAction.field4 FeatureFlag values the desktop controller advertises.
public enum UUControllerFeatureFlag {
    public static let captureSetting: Int32 = 6
    public static let simpleAction: Int32 = 2
    public static let systemMetrics: Int32 = 1
    public static let privateScreen: Int32 = 4
    public static let updateAcquire: Int32 = 0
    public static let fileTransferFTP: Int32 = 2
    public static let fileTransferFTP2: Int32 = 2
    public static let clipboard: Int32 = 3
    public static let qosStat: Int32 = 1
    public static let mumuControl: Int32 = 0
    public static let virtualMouseDevice: Int32 = 0
}

/// Encodes/decodes the CONTROL_DATA_CHANNEL envelope and input JSON.
public enum UUControlProtocol {
    /// Wraps a body message into the standard envelope `{1:seq, 2:ts, <which>}`.
    public static func envelope(sequence: UInt64, timestamp: UInt64, fieldNumber: UInt32, body: Data) -> Data {
        var out = Data()
        if sequence != 0 { UUProtobufWriter.pushVarintField(Int(UUControlField.sequence), sequence, into: &out) }
        if timestamp != 0 { UUProtobufWriter.pushVarintField(Int(UUControlField.timestamp), timestamp, into: &out) }
        UUProtobufWriter.pushMessageField(Int(fieldNumber), body, into: &out)
        return out
    }

    /// Builds a SimpleAction body: `{1:action, 2:argsJson, 4:FeatureFlag}`.
    public static func simpleAction(action: UInt64, argsJSON: String, featureFlags: Data? = nil) -> Data {
        var out = Data()
        UUProtobufWriter.pushVarintField(1, action, into: &out)
        let args = Data(argsJSON.utf8)
        if !args.isEmpty { UUProtobufWriter.pushBytesField(2, args, into: &out) }
        if let featureFlags, !featureFlags.isEmpty { UUProtobufWriter.pushMessageField(4, featureFlags, into: &out) }
        return out
    }

    /// Verified protobuf echo-response envelope for the host's echo request.
    public static func echoResponseEnvelope(sequence: UInt64, timestamp: UInt64, requestSequence: UInt64, clipboardEnabled: Bool) -> Data {
        var action = Data()
        UUProtobufWriter.pushVarintField(1, UUSimpleActionType.echoResponse, into: &action)
        let args = #"{"seq":\#(requestSequence)}"#.data(using: .utf8)!
        UUProtobufWriter.pushBytesField(2, args, into: &action)
        var flags = Data()
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.captureSetting, UUControllerFeatureFlag.captureSetting, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.simpleAction, UUControllerFeatureFlag.simpleAction, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.systemMetrics, UUControllerFeatureFlag.systemMetrics, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.fileTransferFTP, 2, into: &flags)
        if clipboardEnabled {
            UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.clipboard, UUControllerFeatureFlag.clipboard, into: &flags)
        }
        UUProtobufWriter.pushMessageField(4, flags, into: &action)
        return envelope(sequence: sequence, timestamp: timestamp, fieldNumber: UUControlField.simpleAction, body: action)
    }

    /// The heartbeat echo request sent every 100 ms once the channel opens.
    /// Flag versions mirror the upstream viewer's `feature_flag` pairs
    /// (`UUViewerFeatureFlags`): private_screen is 2, not 4.
    public static func echoRequestEnvelope(sequence: UInt64, timestamp: UInt64) -> Data {
        var action = Data()
        UUProtobufWriter.pushVarintField(1, UUSimpleActionType.echoRequest, into: &action)
        var flags = Data()
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.captureSetting, UUViewerFeatureFlags.captureSetting, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.simpleAction, UUViewerFeatureFlags.simpleAction, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.systemMetrics, UUViewerFeatureFlags.systemMetrics, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.privateScreen, UUViewerFeatureFlags.privateScreen, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.fileTransferFTP, UUViewerFeatureFlags.fileTransferFTP, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.fileTransferFTP2, UUViewerFeatureFlags.fileTransferFTP2, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.clipboard, UUViewerFeatureFlags.clipboard, into: &flags)
        UUProtobufWriter.pushInt32Field(UUFeatureFlagTag.qosStat, UUViewerFeatureFlags.qosStat, into: &flags)
        UUProtobufWriter.pushMessageField(4, flags, into: &action)
        return envelope(sequence: sequence, timestamp: timestamp, fieldNumber: UUControlField.simpleAction, body: action)
    }

    /// RPC request envelope `{21:RpcRequest{1:header{1:requestId},<case>}}`.
    public static func rpcRequest(requestID: UInt64, bodyField: UInt32, body: Data) -> Data {
        var header = Data()
        UUProtobufWriter.pushVarintField(1, requestID, into: &header)
        var request = Data()
        UUProtobufWriter.pushMessageField(1, header, into: &request)
        UUProtobufWriter.pushMessageField(Int(bodyField), body, into: &request)
        return envelope(sequence: requestID, timestamp: UInt64(Date().timeIntervalSince1970 * 1000), fieldNumber: UUControlField.rpcRequest, body: request)
    }

    /// Asks the host for an immediate IDR / keyframe.
    public static func sendVideoTrackRequest(requestID: UInt64) -> Data {
        rpcRequest(requestID: requestID, bodyField: 15, body: Data())
    }

    /// CaptureSettingRequest field 7 = chroma (3 = 4:4:4 true color).
    public static func captureSettingRequest(requestID: UInt64, chromaFormat: Int32) -> Data {
        var body = Data()
        UUProtobufWriter.pushInt32Field(7, chromaFormat, into: &body)
        return rpcRequest(requestID: requestID, bodyField: 2, body: body)
    }

    /// CaptureSettingRequest carrying the viewer's fps/quality choice:
    /// field 1 is the fps *option index* (`UUFpsTier`), field 18
    /// (`fpsCount`) the raw frame rate, field 2 the quality preset — the
    /// same pairing the upstream viewer sends (src/capture_setting.rs).
    public static func captureSettingRequest(requestID: UInt64, rawFPS: Int32, quality: Int32? = nil) -> Data {
        var body = Data()
        UUProtobufWriter.pushInt32Field(1, Int32(UUFpsTier.encode(rawFPS: Int(rawFPS))), into: &body)
        if let quality, quality > 0 {
            UUProtobufWriter.pushInt32Field(2, quality, into: &body)
        }
        UUProtobufWriter.pushInt32Field(18, rawFPS, into: &body)
        return rpcRequest(requestID: requestID, bodyField: 2, body: body)
    }

    /// Clipboard V3: `RpcRequest` case 10 `ClipboardTextChangeRequest`
    /// `{1: format_id, 2: text}` — format 13 is unicode text (formats are
    /// `STREAMER_CLIPBOARD_FORMATS` = {text: 1, unicodeText: 13}). Sent on
    /// TEXT_DATA_CHANNEL, which is where the host's clipboard bridge lives.
    public static func clipboardTextChangeRequest(requestID: UInt64, text: String, formatID: Int32 = 13) -> Data {
        var body = Data()
        UUProtobufWriter.pushInt32Field(1, formatID, into: &body)
        UUProtobufWriter.pushStringField(2, text, into: &body)
        return rpcRequest(requestID: requestID, bodyField: 10, body: body)
    }

    /// A decoded inbound case-10 clipboard text change: the RpcRequest
    /// header (field 1, echoed in the response) and the text (field 2).
    public static func decodeClipboardTextChange(_ data: Data) -> (header: Data, text: String)? {
        guard let inbound = decodeInbound(data),
              inbound.field.number == UUControlField.rpcRequest,
              case let .bytes(rpc) = inbound.field.value,
              let rpcFields = try? UUWire.decode(rpc)
        else { return nil }
        var header: Data?
        var body: Data?
        for field in rpcFields {
            switch (field.number, field.value) {
            case (1, let .bytes(b)): header = b
            case (10, let .bytes(b)): body = b
            default: break
            }
        }
        guard let header, let body,
              let parts = try? UUWire.decode(body)
        else { return nil }
        for part in parts {
            if part.number == 2, case let .bytes(text) = part.value,
               let string = String(data: text, encoding: .utf8) {
                return (header, string)
            }
        }
        return nil
    }

    /// The case-6 `TextChangeResponse` the viewer owes the host after an
    /// inbound text change: `{1: echoed header, 6: {1: err=1 (CB_SUCCEEDED)}}`.
    public static func clipboardTextChangeResponse(requestID: UInt64, header: Data) -> Data {
        var response = Data()
        UUProtobufWriter.pushVarintField(1, 1, into: &response)
        return rpcRequest(requestID: requestID, bodyField: 6, header: header, body: response)
    }

    /// `rpcRequest` variant that echoes an inbound request's header verbatim
    /// (the response must carry the requester's header, not a fresh one).
    public static func rpcRequest(requestID: UInt64, bodyField: UInt32, header: Data, body: Data) -> Data {
        var request = Data()
        UUProtobufWriter.pushMessageField(1, header, into: &request)
        UUProtobufWriter.pushMessageField(Int(bodyField), body, into: &request)
        return envelope(sequence: requestID, timestamp: UInt64(Date().timeIntervalSince1970 * 1000), fieldNumber: UUControlField.rpcRequest, body: request)
    }

    // MARK: - JSON input on CONTROL_DATA_CHANNEL

    /// Wire values per upstream `STREAMER_MOUSE_BUTTON_CODES`:
    /// primary=1, secondary=2, tertiary=4, back=8, forward=16.
    public enum Button: Int32 {
        case left = 1
        case right = 2
        case middle = 4
        case back = 8
        case forward = 16
    }

    public static func mouseMoveAbsolute(x: Double, y: Double) -> Data {
        // Mac hosts take normalized 0...1 axes (clamped, like upstream's
        // `normalizeAbsolutePointerAxis`).
        let cx = min(1, max(0, x))
        let cy = min(1, max(0, y))
        return #"{"action":"mouse_move_absolute","abs_x":\#(cx),"abs_y":\#(cy)}"#.data(using: .utf8)!
    }

    public static func mouseMoveRelative(dx: Int32, dy: Int32) -> Data {
        #"{"action":"mouse_move_relative","delta_x":\#(dx),"delta_y":\#(dy)}"#.data(using: .utf8)!
    }

    public static func mouseButton(_ button: Button, isDown: Bool) -> Data {
        let action = isDown ? "mouse_press" : "mouse_release"
        return #"{"action":"\#(action)","button":\#(button.rawValue)}"#.data(using: .utf8)!
    }

    public static func mouseClick(_ button: Button) -> Data {
        #"{"action":"mouse_click","button":\#(button.rawValue)}"#.data(using: .utf8)!
    }

    public static func mouseScroll(dx: Int32, dy: Int32) -> Data {
        #"{"action":"mouse_scroll","delta_x":\#(dx),"delta_y":\#(dy)}"#.data(using: .utf8)!
    }

    public static func keyPress(key: Int32, isDown: Bool, windowsTarget: Bool = false) -> Data {
        let action = isDown ? "kbd_press" : "kbd_release"
        var json = #"{"action":"\#(action)","key":\#(key)}"#
        if windowsTarget { json = json.dropLast() + #","interrept":true}"# }
        return json.data(using: .utf8)!
    }

    public static func keyClick(key: Int32) -> Data {
        #"{"action":"kbd_click","key":\#(key)}"#.data(using: .utf8)!
    }

    public static func textInput(_ text: String) -> Data {
        // JSON-escape via the serializer: quotes, backslashes and control
        // characters in `text` must not corrupt the wire JSON.
        (try? JSONSerialization.data(withJSONObject: ["action": "text_input", "content": text])) ?? Data()
    }

    public static func keyboardHeartbeat() -> Data {
        #"{"heartbeat":"kbd_heartbeat"}"#.data(using: .utf8)!
    }

    /// Decodes the CONTROL_DATA_CHANNEL envelope `{1:seq, 2:ts, <which>}` into
    /// a typed inbound message, or `nil` for malformed payloads.
    public static func decodeInbound(_ data: Data) -> Inbound? {
        guard let fields = try? UUWire.decode(data) else { return nil }
        var sequence: UInt64 = 0
        var timestamp: UInt64 = 0
        var body: [UUWireField] = []
        for field in fields {
            switch field.number {
            case UUControlField.sequence:
                if case let .varint(v) = field.value { sequence = v }
            case UUControlField.timestamp:
                if case let .varint(v) = field.value { timestamp = v }
            default:
                body.append(field)
            }
        }
        guard let first = body.first else { return nil }
        return Inbound(sequence: sequence, timestamp: timestamp, field: first)
    }

    public struct Inbound: Sendable {
        public var sequence: UInt64
        public var timestamp: UInt64
        public var field: UUWireField
    }

    /// Decodes a SimpleAction body (inside field 3).
    public static func decodeSimpleAction(_ data: Data) -> (action: UInt64, argsJSON: String?, featureFlags: UUFeatureFlags)? {
        guard let fields = try? UUWire.decode(data) else { return nil }
        var action: UInt64 = 0
        var args: String?
        var flags = UUFeatureFlags()
        for field in fields {
            switch (field.number, field.value) {
            case (1, let .varint(v)): action = v
            case (2, let .bytes(b)): args = String(data: b, encoding: .utf8)
            case (4, let .bytes(b)): flags = UUFeatureFlags(decoding: b)
            default: break
            }
        }
        return (action, args, flags)
    }

    /// Decodes ScreenSources (field 7) into display descriptors.
    public static func decodeScreenSources(_ data: Data) -> [RemoteDisplayInfo] {
        guard let fields = try? UUWire.decode(data) else { return [] }
        var displays: [RemoteDisplayInfo] = []
        for field in fields where field.number == 1 {
            guard case let .bytes(b) = field.value,
                  let sub = try? UUWire.decode(b) else { continue }
            var id = 0
            var fps = 0
            var isPrimary = false
            var name = ""
            var width = 0
            var height = 0
            for item in sub {
                switch (item.number, item.value) {
                case (1, let .varint(v)): id = Int(v)
                case (2, let .varint(v)): fps = Int(v)
                case (4, let .varint(v)): isPrimary = v != 0
                case (7, let .varint(v)): isPrimary = v != 0
                case (8, let .fixed64(b)):
                    if b.count == 8 {
                        let raw = b.withUnsafeBytes { $0.load(as: Double.self) }
                        width = Int(raw)
                    }
                case (10, let .bytes(b)): name = String(data: b, encoding: .utf8) ?? ""
                case (3, let .bytes(b)):
                    // WinRect{l,t,w,h,pw,ph}
                    if let rectFields = try? UUWire.decode(b) {
                        for rect in rectFields {
                            switch (rect.number, rect.value) {
                            case (3, let .varint(v)): width = Int(v)
                            case (4, let .varint(v)): height = Int(v)
                            case (5, let .varint(v)): width = Int(v)
                            case (6, let .varint(v)): height = Int(v)
                            default: break
                            }
                        }
                    }
                default: break
                }
            }
            displays.append(RemoteDisplayInfo(id: id, name: name.isEmpty ? "Display \(id)" : name, width: width, height: height, fps: fps, isPrimary: isPrimary))
        }
        return displays
    }

    /// Decodes CaptureChange (field 8).
    public static func decodeCaptureChange(_ data: Data) -> (captureType: UInt64, captureID: UInt64, description: String)? {
        guard let fields = try? UUWire.decode(data) else { return nil }
        var captureType: UInt64 = 0
        var captureID: UInt64 = 0
        var desc = ""
        for field in fields {
            switch (field.number, field.value) {
            case (1, let .varint(v)): captureType = v
            case (2, let .varint(v)): captureID = v
            case (3, let .bytes(b)): desc = String(data: b, encoding: .utf8) ?? ""
            default: break
            }
        }
        return (captureType, captureID, desc)
    }

    /// Decodes SystemStateChange (field 15): lock state and cursor shape.
    public static func decodeSystemStateChange(_ data: Data) -> (isLocked: Bool?, cursor: RemoteCursorInfo?)? {
        guard let fields = try? UUWire.decode(data) else { return nil }
        var isLocked: Bool?
        var cursor: RemoteCursorInfo?
        for field in fields {
            switch field.number {
            case 1:
                if case let .varint(v) = field.value { isLocked = v != 0 }
            case 2:
                guard case let .bytes(b) = field.value,
                      let sub = try? UUWire.decode(b) else { continue }
                var x = 0.0, y = 0.0, w = 0, h = 0
                var cursorType = 0
                var xScale = 1.0, yScale = 1.0
                var image: CGImage?
                var visible = false
                for item in sub {
                    switch (item.number, item.value) {
                    case (1, let .varint(v)): x = Double(v)
                    case (2, let .varint(v)): y = Double(v)
                    case (3, let .varint(v)): w = Int(v)
                    case (4, let .varint(v)): h = Int(v)
                    case (5, let .bytes(b)):
                        image = Self.rgbaToCGImage(b, width: w, height: h)
                    case (6, let .varint(v)): cursorType = Int(v)
                    case (7, let .fixed64(b)):
                        if b.count == 8 { xScale = b.withUnsafeBytes { $0.load(as: Double.self) } }
                    case (8, let .fixed64(b)):
                        if b.count == 8 { yScale = b.withUnsafeBytes { $0.load(as: Double.self) } }
                    case (9, let .varint(v)): visible = v != 0
                    default: break
                    }
                }
                cursor = RemoteCursorInfo(x: x, y: y, width: w, height: h, image: image, visible: visible)
            default: break
            }
        }
        return (isLocked, cursor)
    }

    /// Converts raw RGBA bytes into a CGImage for cursor rendering.
    static func rgbaToCGImage(_ rgba: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo,
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return image
    }
}
