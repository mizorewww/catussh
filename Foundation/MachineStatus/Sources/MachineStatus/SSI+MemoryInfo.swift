//
//  SSI+MemoryInfo.swift
//
//
//  Created by Lakr Aream on 2022/3/2.
//

import Foundation

public extension ServerStatus {
    /// 服务器 RAM 信息
    struct MemoryInfo: Codable, Equatable, Sendable {
        public let memTotal: Double
        public let memFree: Double
        public let memAvailable: Double?
        public let memBuffers: Double
        public let memCached: Double
        public let swapTotal: Double
        public let swapFree: Double
        public let phyUsed: Double
        public let swapUsed: Double
        public init() {
            memTotal = 0
            memFree = 0
            memAvailable = nil
            memBuffers = 0
            memCached = 0
            swapTotal = 0
            swapFree = 0
            phyUsed = 0
            swapUsed = 0
        }

        public init(
            total: Double,
            free: Double,
            available: Double? = nil,
            buffers: Double,
            cached: Double,
            swapTotal: Double,
            swapFree: Double
        ) {
            memTotal = total
            memFree = free
            memAvailable = available
            memBuffers = buffers
            memCached = cached
            self.swapTotal = swapTotal
            self.swapFree = swapFree
            if total != 0 {
                if let available, available > 0, available <= total {
                    phyUsed = max(0, min(1, (total - available) / total))
                } else {
                    phyUsed = max(0, min(1, (total - free - memCached - memBuffers) / total))
                }
            } else {
                phyUsed = 0
            }
            // Swap usage is relative to swapTotal, not physical memory,
            // and machines without swap must not divide by zero.
            if swapTotal != 0 {
                swapUsed = (
                    (swapTotal - swapFree) / swapTotal
                )
            } else {
                swapUsed = 0
            }
        }

        public init(meminfo: String) {
            let info = ProcParsers.parseMeminfo(meminfo)
            let cached = (info["Cached".uppercased()] ?? 0) + (info["SReclaimable".uppercased()] ?? 0)
            self.init(
                total: info["MemTotal".uppercased()] ?? 0,
                free: info["MemFree".uppercased()] ?? 0,
                available: info["MemAvailable".uppercased()],
                buffers: info["Buffers".uppercased()] ?? 0,
                cached: cached,
                swapTotal: info["SwapTotal".uppercased()] ?? 0,
                swapFree: info["SwapFree".uppercased()] ?? 0
            )
        }

        public init(darwinMemory: String) {
            let info = ProcParsers.parseDarwinMemory(darwinMemory)
            self.init(
                total: info.total,
                free: info.free,
                buffers: 0,
                cached: info.cached,
                swapTotal: info.swapTotal,
                swapFree: info.swapFree
            )
        }

        public func description() -> String {
            """
            total: \(Int(exactly: memTotal) ?? 0) kB
            free: \(Int(exactly: memFree) ?? 0) kB
            buffers: \(Int(exactly: memBuffers) ?? 0) kB
            cached: \(Int(exactly: memCached) ?? 0) kB
            swap: \(Int(exactly: swapFree) ?? 0)/\(Int(exactly: swapTotal) ?? 0) kB
            """
        }
    }
}
