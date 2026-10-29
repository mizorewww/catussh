//
//  UURemoteConnectOptions.swift
//  CatusshModule
//
//  ConnectOptions protobuf encode/decode for the UU Remote streamer handshake
//  (`app_data` attachment of the Socket.IO `control` event).
//  Mirrors /tmp/uu-refs/uurc-web/shared/src/streamer/internal/connectOptionsCodec.ts
//  and /tmp/uu-refs/uurc-web/shared/src/streamer/internal/connectOptionsSchema.ts.
//

import Foundation

public struct UUConnectOptions: Equatable, Sendable {
    public var captureType: Int = UUCaptureType.unknown
    /// Field 2 `type_value`: the official viewer sends u64::MAX for capture
    /// types 1 (desktop) and 8 (virtual display).
    public var typeValue: UInt64 = 0
    public var captureParams = UUCaptureParams()
    /// Field 4 `decoder_cap_list`: one `DecoderCap` submessage per codec.
    public var decoderCapList: [UUDecoderCap] = []
    public var forceVirtualDisplay = false
    public var virtualDisplayModes: [UUVirtualDisplayMode] = []
    public var virtualDisplayInitResolution: UUScreenResolution?
    public var clientType: Int = UUClientType.unspecified
    public var deviceID: String = ""
    public var controlConnectType: Int = UUControlConnectType.unknown
    public var featureFlags = UUFeatureFlags()
    public var clientVersion: String = UUClientVersion.sdk

    public init() {}

    public func encode() -> Data {
        var out = Data()
        if captureType != UUCaptureType.unknown { UUProtobufWriter.pushVarintField(1, UInt64(captureType), into: &out) }
        if typeValue != 0 { UUProtobufWriter.pushVarintField(2, typeValue, into: &out) }
        let params = captureParams.encode()
        if !params.isEmpty { UUProtobufWriter.pushMessageField(3, params, into: &out) }
        for cap in decoderCapList { UUProtobufWriter.pushMessageField(4, cap.encode(), into: &out) }
        if forceVirtualDisplay { UUProtobufWriter.pushVarintField(5, 1, into: &out) }
        for mode in virtualDisplayModes { UUProtobufWriter.pushMessageField(6, mode.encode(), into: &out) }
        if let initRes = virtualDisplayInitResolution { UUProtobufWriter.pushMessageField(7, initRes.encode(), into: &out) }
        if clientType != UUClientType.unspecified { UUProtobufWriter.pushVarintField(8, UInt64(clientType), into: &out) }
        if !deviceID.isEmpty { UUProtobufWriter.pushStringField(9, deviceID, into: &out) }
        if controlConnectType != UUControlConnectType.unknown { UUProtobufWriter.pushVarintField(10, UInt64(controlConnectType), into: &out) }
        let flags = featureFlags.encode()
        if !flags.isEmpty { UUProtobufWriter.pushMessageField(11, flags, into: &out) }
        if !clientVersion.isEmpty { UUProtobufWriter.pushStringField(12, clientVersion, into: &out) }
        return out
    }

    public init(decoding data: Data) {
        guard let fields = try? UUWire.decode(data) else { return }
        for field in fields {
            switch (field.number, field.value) {
            case (1, let .varint(v)): captureType = Int(v)
            case (2, let .varint(v)): typeValue = v
            case (3, let .bytes(b)): captureParams = UUCaptureParams(decoding: b)
            case (4, let .bytes(b)): decoderCapList.append(UUDecoderCap(decoding: b))
            case (5, let .varint(v)): forceVirtualDisplay = v != 0
            case (6, let .bytes(b)): virtualDisplayModes.append(UUVirtualDisplayMode(decoding: b))
            case (7, let .bytes(b)): virtualDisplayInitResolution = UUScreenResolution(decoding: b)
            case (8, let .varint(v)): clientType = Int(v)
            case (9, let .bytes(b)): deviceID = String(data: b, encoding: .utf8) ?? ""
            case (10, let .varint(v)): controlConnectType = Int(v)
            case (11, let .bytes(b)): featureFlags = UUFeatureFlags(decoding: b)
            case (12, let .bytes(b)): clientVersion = String(data: b, encoding: .utf8) ?? ""
            default: break
            }
        }
    }
}

/// The `DecoderCap` submessage of `decoder_cap_list` (field 4): one codec
/// the viewer can decode, with the size/chroma it supports.
/// Mirrors `Decoder` in /tmp/uu-refs/uu-remote-linux/src/viewer/wire.rs.
public struct UUDecoderCap: Equatable, Sendable {
    /// Field 1: the decoder's frame-rate capability as a raw fps (30/60/…),
    /// NOT the fps option enum used in `CaptureParams.fpsTier`.
    public var fps: Int32 = 0
    /// Field 2: `UUDecoderCodecType` (1 = H.264, 2 = H.265).
    public var codec: Int32 = 0
    /// Field 3/4: maximum decodable frame size.
    public var width: Int32 = 0
    public var height: Int32 = 0
    /// Field 5: `UUChromaFormat` (1 = 4:2:0, 3 = 4:4:4); only sent for
    /// capture_type 1.
    public var chroma: Int32 = 0

    public init() {}

    public init(fps: Int32, codec: Int32, width: Int32, height: Int32, chroma: Int32) {
        self.fps = fps
        self.codec = codec
        self.width = width
        self.height = height
        self.chroma = chroma
    }

    public func encode() -> Data {
        var out = Data()
        if fps != 0 { UUProtobufWriter.pushVarintField(1, UInt64(fps), into: &out) }
        if codec != 0 { UUProtobufWriter.pushVarintField(2, UInt64(codec), into: &out) }
        if width != 0 { UUProtobufWriter.pushVarintField(3, UInt64(width), into: &out) }
        if height != 0 { UUProtobufWriter.pushVarintField(4, UInt64(height), into: &out) }
        if chroma != 0 { UUProtobufWriter.pushVarintField(5, UInt64(chroma), into: &out) }
        return out
    }

    public init(decoding data: Data) {
        guard let fields = try? UUWire.decode(data) else { return }
        for field in fields {
            switch (field.number, field.value) {
            case (1, let .varint(v)): fps = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (2, let .varint(v)): codec = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (3, let .varint(v)): width = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (4, let .varint(v)): height = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (5, let .varint(v)): chroma = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            default: break
            }
        }
    }
}

/// The fps *option index* carried by `CaptureParams` field 1 and
/// `CaptureSettingRequest` field 1 — an enum, not a raw frame rate.
/// The actual requested frame rate always travels in field 11 / 18
/// (`fpsCount`) as a raw integer.
public enum UUFpsTier {
    public static let fps30 = 1
    public static let fps60 = 2
    public static let fps90 = 3
    public static let fps144 = 4

    /// Maps a raw requested fps to the closest tier index.
    public static func encode(rawFPS: Int) -> Int {
        switch rawFPS {
        case ..<45: fps30
        case ..<75: fps60
        case ..<120: fps90
        default: fps144
        }
    }

    /// The raw frame rate a tier index stands for (60 for unknown).
    public static func rawFPS(for tier: Int) -> Int {
        switch tier {
        case fps30: 30
        case fps60: 60
        case fps90: 90
        case fps144: 144
        default: 60
        }
    }
}

public struct UUCaptureParams: Equatable, Sendable {
    /// Field 1: the fps *option index* (`UUFpsTier`, 1 = 30 … 4 = 144).
    /// Raw requested fps belongs in `fpsCount` (field 11).
    public var fpsTier: Int = 0
    public var videoQuality: Int = 0
    public var cursorCapture = false
    public var chooseResolutionType: Int = 0
    public var localResolution: UUScreenResolution?
    public var chooseResolution: UUScreenResolution?
    public var chromaFormat: Int = 0
    public var maxCustomBitrate: Int32 = 0
    public var enableHDR = false
    public var autoFrameQuality: Int = 0
    public var fpsCount: Int32 = 0

    public init() {}

    public func encode() -> Data {
        var out = Data()
        if fpsTier != 0 { UUProtobufWriter.pushVarintField(1, UInt64(fpsTier), into: &out) }
        if videoQuality != 0 { UUProtobufWriter.pushVarintField(2, UInt64(videoQuality), into: &out) }
        if cursorCapture { UUProtobufWriter.pushVarintField(3, 1, into: &out) }
        if chooseResolutionType != 0 { UUProtobufWriter.pushVarintField(4, UInt64(chooseResolutionType), into: &out) }
        if let local = localResolution { UUProtobufWriter.pushMessageField(5, local.encode(), into: &out) }
        if let choose = chooseResolution { UUProtobufWriter.pushMessageField(6, choose.encode(), into: &out) }
        if chromaFormat != 0 { UUProtobufWriter.pushVarintField(7, UInt64(chromaFormat), into: &out) }
        if maxCustomBitrate != 0 { UUProtobufWriter.pushInt32Field(8, maxCustomBitrate, into: &out) }
        if enableHDR { UUProtobufWriter.pushVarintField(9, 1, into: &out) }
        if autoFrameQuality != 0 { UUProtobufWriter.pushVarintField(10, UInt64(autoFrameQuality), into: &out) }
        if fpsCount != 0 { UUProtobufWriter.pushInt32Field(11, fpsCount, into: &out) }
        return out
    }

    public init(decoding data: Data) {
        guard let fields = try? UUWire.decode(data) else { return }
        for field in fields {
            switch (field.number, field.value) {
            case (1, let .varint(v)): fpsTier = Int(v)
            case (2, let .varint(v)): videoQuality = Int(v)
            case (3, let .varint(v)): cursorCapture = v != 0
            case (4, let .varint(v)): chooseResolutionType = Int(v)
            case (5, let .bytes(b)): localResolution = UUScreenResolution(decoding: b)
            case (6, let .bytes(b)): chooseResolution = UUScreenResolution(decoding: b)
            case (7, let .varint(v)): chromaFormat = Int(v)
            case (8, let .varint(v)): maxCustomBitrate = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (9, let .varint(v)): enableHDR = v != 0
            case (10, let .varint(v)): autoFrameQuality = Int(v)
            case (11, let .varint(v)): fpsCount = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            default: break
            }
        }
    }
}

public struct UUScreenResolution: Equatable, Sendable {
    public var width: Int32 = 0
    public var height: Int32 = 0

    public init(width: Int32 = 0, height: Int32 = 0) {
        self.width = width
        self.height = height
    }

    public func encode() -> Data {
        var out = Data()
        if width != 0 { UUProtobufWriter.pushInt32Field(1, width, into: &out) }
        if height != 0 { UUProtobufWriter.pushInt32Field(2, height, into: &out) }
        return out
    }

    public init(decoding data: Data) {
        guard let fields = try? UUWire.decode(data) else { return }
        for field in fields {
            switch (field.number, field.value) {
            case (1, let .varint(v)): width = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (2, let .varint(v)): height = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            default: break
            }
        }
    }
}

public struct UUVirtualDisplayMode: Equatable, Sendable {
    public var width: Int32 = 0
    public var height: Int32 = 0
    public var fps: Int32 = 0

    public init(width: Int32 = 0, height: Int32 = 0, fps: Int32 = 0) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    public func encode() -> Data {
        var out = UUScreenResolution(width: width, height: height).encode()
        if fps != 0 { UUProtobufWriter.pushInt32Field(3, fps, into: &out) }
        return out
    }

    public init(decoding data: Data) {
        guard let fields = try? UUWire.decode(data) else { return }
        var resolution = UUScreenResolution()
        for field in fields {
            switch (field.number, field.value) {
            case (1, let .varint(v)): resolution.width = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (2, let .varint(v)): resolution.height = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (3, let .varint(v)): fps = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            default: break
            }
        }
        width = resolution.width
        height = resolution.height
    }
}

public struct UUFeatureFlags: Equatable, Sendable {
    public var captureSetting: Int32 = 0
    public var simpleAction: Int32 = 0
    public var systemMetrics: Int32 = 0
    public var privateScreen: Int32 = 0
    public var updateAcquire: Int32 = 0
    public var fileTransferFTP: Int32 = 0
    public var fileTransferFTP2: Int32 = 0
    public var clipboard: Int32 = 0
    public var qosStat: Int32 = 0
    public var mumuControl: Int32 = 0
    public var virtualMouseDevice: Int32 = 0

    public init() {}

    public func encode() -> Data {
        var out = Data()
        if captureSetting != 0 { UUProtobufWriter.pushInt32Field(1, captureSetting, into: &out) }
        if simpleAction != 0 { UUProtobufWriter.pushInt32Field(2, simpleAction, into: &out) }
        if systemMetrics != 0 { UUProtobufWriter.pushInt32Field(3, systemMetrics, into: &out) }
        if privateScreen != 0 { UUProtobufWriter.pushInt32Field(4, privateScreen, into: &out) }
        if updateAcquire != 0 { UUProtobufWriter.pushInt32Field(5, updateAcquire, into: &out) }
        if fileTransferFTP != 0 { UUProtobufWriter.pushInt32Field(6, fileTransferFTP, into: &out) }
        if fileTransferFTP2 != 0 { UUProtobufWriter.pushInt32Field(7, fileTransferFTP2, into: &out) }
        if clipboard != 0 { UUProtobufWriter.pushInt32Field(8, clipboard, into: &out) }
        if qosStat != 0 { UUProtobufWriter.pushInt32Field(9, qosStat, into: &out) }
        if mumuControl != 0 { UUProtobufWriter.pushInt32Field(10, mumuControl, into: &out) }
        if virtualMouseDevice != 0 { UUProtobufWriter.pushInt32Field(11, virtualMouseDevice, into: &out) }
        return out
    }

    public init(decoding data: Data) {
        guard let fields = try? UUWire.decode(data) else { return }
        for field in fields {
            let value: Int32
            if case let .varint(v) = field.value {
                value = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            } else {
                value = 0
            }
            switch field.number {
            case 1: captureSetting = value
            case 2: simpleAction = value
            case 3: systemMetrics = value
            case 4: privateScreen = value
            case 5: updateAcquire = value
            case 6: fileTransferFTP = value
            case 7: fileTransferFTP2 = value
            case 8: clipboard = value
            case 9: qosStat = value
            case 10: mumuControl = value
            case 11: virtualMouseDevice = value
            default: break
            }
        }
    }
}

public enum UUCaptureType {
    public static let unknown = 0
    public static let desktop = 1
    public static let window = 2
    public static let mumu = 3
    public static let hook = 4
    public static let fileTransfer = 5
    public static let secondScreen = 6
    public static let quickLaunch = 7
    public static let terminal = 8
    public static let portMapping = 9
}

public enum UUClientType {
    public static let unspecified = 0
    public static let android = 2
    public static let windows = 3
    public static let mac = 4
    public static let ios = 5
}

public enum UUControlConnectType {
    public static let unknown = 0
    public static let normal = 1
    public static let assistance = 2
}

public enum UUClientVersion {
    public static let sdk = "4.23.0"
    public static let streamer = "V3.1.14"
}

public enum UUDecoderCodecType {
    public static let unknown = 0
    public static let h264 = 1
    public static let h265 = 2
}

/// The `feature_flag` (ConnectOptions field 11) version pairs the upstream
/// desktop viewer advertises — `[[1,6],[2,2],[3,1],[4,2],[6,2],[7,2],[8,3],[9,1]]`
/// in /tmp/uu-refs/uu-remote-linux/src/viewer/wire.rs (clipboard 8:3 only
/// when clipboard sync is enabled).
public enum UUViewerFeatureFlags {
    public static let captureSetting: Int32 = 6
    public static let simpleAction: Int32 = 2
    public static let systemMetrics: Int32 = 1
    public static let privateScreen: Int32 = 2
    public static let fileTransferFTP: Int32 = 2
    public static let fileTransferFTP2: Int32 = 2
    public static let clipboard: Int32 = 3
    public static let qosStat: Int32 = 1

    /// Builds the flag set matching the upstream viewer defaults.
    public static func make(clipboardEnabled: Bool = true) -> UUFeatureFlags {
        var flags = UUFeatureFlags()
        flags.captureSetting = captureSetting
        flags.simpleAction = simpleAction
        flags.systemMetrics = systemMetrics
        flags.privateScreen = privateScreen
        flags.fileTransferFTP = fileTransferFTP
        flags.fileTransferFTP2 = fileTransferFTP2
        flags.clipboard = clipboardEnabled ? clipboard : 0
        flags.qosStat = qosStat
        return flags
    }
}

public enum UUChromaFormat {
    public static let unknown = 0
    public static let c420 = 1
    public static let c422 = 2
    public static let c444 = 3
    public static let c400 = 4
}
