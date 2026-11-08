//
//  SSI+GraphicsInfo.swift
//
//
//  Created by Lakr Aream on 2022/3/2.
//

import Foundation
import NSRemoteShell

public extension ServerStatus {
    /// 服务器 GPU 信息
    struct GraphicsInfo: Codable, Equatable, Sendable {
        public let version: String // Driver / CUDA version
        public let units: [SingleGraphicsInfo]

        enum CodingKeys: String, CodingKey {
            case version = "cuda_version"
            case units = "gpu"
        }

        public init() {
            version = "unknown"
            units = []
        }

        public init(version: String, units: [SingleGraphicsInfo]) {
            self.version = version
            self.units = units
        }

        public init?(withRemote shell: NSRemoteShell, timeout: Double) {
            let downloadResult = downloadResultFrom(shell: shell, command: ServerStatus.graphicsScript, timeout: timeout)
            guard let parsed = Self.parseCSV(downloadResult) else {
                return nil
            }
            self = parsed
        }

        /// Parses `nvidia-smi --query-gpu=driver_version,uuid,name,memory.total,memory.used,memory.free,vbios_version,fan.speed,utilization.gpu,utilization.memory --format=csv,noheader,nounits`
        public static func parseCSV(_ raw: String) -> GraphicsInfo? {
            var units: [SingleGraphicsInfo] = []
            var driverVersion = "unknown"
            for line in raw.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.hasPrefix("no nvidia gpu"),
                      !trimmed.lowercased().contains("nvidia-smi has failed"),
                      !trimmed.lowercased().contains("command not found")
                else {
                    continue
                }
                let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard fields.count >= 10, !fields[1].isEmpty else {
                    continue
                }
                if driverVersion == "unknown", !fields[0].isEmpty {
                    driverVersion = fields[0]
                }
                let uuid = fields[1]
                let name = fields[2]
                let memTotal = SingleGraphicsInfo.s2f(fields[3])
                let memUsed = SingleGraphicsInfo.s2f(fields[4])
                let memFree = SingleGraphicsInfo.s2f(fields[5])
                let vbios = fields[6]
                let fanRaw = fields[7]
                let fanSpeed: String
                if fanRaw.contains("%") || fanRaw.contains("N/A") || fanRaw.isEmpty {
                    fanSpeed = fanRaw
                } else {
                    fanSpeed = "\(fanRaw) %"
                }
                let gpuUtil = SingleGraphicsInfo.s2f(fields[8])
                let memUtil = SingleGraphicsInfo.s2f(fields[9])
                let encUtil = fields.count > 10 ? SingleGraphicsInfo.s2f(fields[10]) : 0
                let decUtil = fields.count > 11 ? SingleGraphicsInfo.s2f(fields[11]) : 0

                units.append(SingleGraphicsInfo(
                    uuid: uuid,
                    name: name,
                    memory: .init(total: memTotal, used: memUsed, free: memFree),
                    vbios_version: vbios,
                    fan_speed: fanSpeed,
                    utilization: .init(
                        gpu_util: gpuUtil,
                        memory_util: memUtil,
                        encoder_util: encUtil,
                        decoder_util: decUtil
                    )
                ))
            }
            guard !units.isEmpty else { return nil }
            return GraphicsInfo(version: driverVersion, units: units)
        }
    }

    /// 单块 GPU 信息
    struct SingleGraphicsInfo: Codable, Equatable, Identifiable, Sendable {
        /// Stable across refreshes: nvidia-smi reports the GPU's own uuid.
        public var id: String { uuid }

        public let uuid: String // GPU uuid from Nvidia
        public let name: String // GPU name, like '2080 Ti'
        public let memory: Memory
        public let vbios_version: String
        public let fan_speed: String
        public let utilization: Utilization

        static func s2f(_ status: String) -> Float {
            // 11019 MiB -> 11019
            let tmp = status.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")[0]
            return Float(tmp) ?? 0
        }

        public struct Memory: Codable, Equatable, Sendable {
            public let total: Float
            public let used: Float
            public let free: Float

            public init(total: Float = 0, used: Float = 0, free: Float = 0) {
                self.total = total
                self.used = used
                self.free = free
            }
        }

        public struct Utilization: Codable, Equatable, Sendable {
            public let gpu_util: Float
            public let memory_util: Float
            public let encoder_util: Float
            public let decoder_util: Float

            public init(gpu_util: Float = 0, memory_util: Float = 0, encoder_util: Float = 0, decoder_util: Float = 0) {
                self.gpu_util = gpu_util
                self.memory_util = memory_util
                self.encoder_util = encoder_util
                self.decoder_util = decoder_util
            }
        }

        public enum CodingKeys: String, CodingKey {
            case uuid
            case name = "product_name"
            case memory = "fb_memory_usage"
            case vbios_version
            case fan_speed
            case utilization
        }

        public init(uuid: String = "", name: String = "", memory: Memory = .init(), vbios_version: String = "", fan_speed: String = "", utilization: Utilization = .init()) {
            self.uuid = uuid
            self.name = name
            self.memory = memory
            self.vbios_version = vbios_version
            self.fan_speed = fan_speed
            self.utilization = utilization
        }

        public func description() -> String {
            """
            uuid: \(uuid) name: \(name)
            """
        }
    }
}
