//
//  SSI+NetworkInfo.swift
//
//
//  Created by Lakr Aream on 2022/3/2.
//

import Foundation

public extension ServerStatus {
    /// 服务器 NET 信息
    struct NetworkInfo: Codable, Equatable, Hashable {
        public let elements: [NetworkInfoElement]

        public struct NetworkInfoElement: Codable, Equatable, Hashable, Identifiable {
            /// Stable across refreshes: the parser keeps one row per device.
            public var id: String { device }

            public let device: String
            public let rxBytesPerSec: Int
            public let txBytesPerSec: Int

            public init(device: String, rxBytesPerSec: Int, txBytesPerSec: Int) {
                self.device = device
                self.rxBytesPerSec = rxBytesPerSec
                self.txBytesPerSec = txBytesPerSec
            }

            public func description() -> String {
                """
                interface: \(device)
                rxBytes: \(rxBytesPerSec)/s txBytes: \(txBytesPerSec)/s
                """
            }
        }

        public init() {
            elements = []
        }

        public init(elements: [NetworkInfoElement]) {
            self.elements = elements
        }

        /// Builds from two `/proc/net/dev` payloads sampled about `interval` seconds
        /// apart; rates are the counter deltas divided by `interval`.
        public init?(netDevBefore: String?, netDevAfter: String?, interval: Double = 1.0) {
            guard let netDevBefore, let netDevAfter else { return nil }
            let duration = max(0.1, interval)

            typealias RxTxPair = (Int, Int)

            func build(str: String) -> [String: RxTxPair] {
                var result = [String: RxTxPair]()
                go: for item in str.components(separatedBy: "\n") where item.contains(":") {
                    let sepName = item.components(separatedBy: ":")
                    if sepName.count != 2 {
                        continue go
                    }
                    guard let name = sepName.first,
                          let payload = sepName.last
                    else {
                        continue go
                    }
                    let key = name.trimmingCharacters(in: .whitespaces)
                    let split = ProcParsers.splitWhitespaceRuns(payload)
                    if split.count < 10 {
                        continue go
                    }
                    // 0     1       2    3    4    5     6          7
                    // bytes packets errs drop fifo frame compressed multicast
                    // 8     9       10   11   12   13    14      15
                    // bytes packets errs drop fifo colls carrier compressed
                    guard let rxBytes = Int(split[0]), // string
                          let txBytes = Int(split[8]) // string
                    else {
                        continue go
                    }
                    if result[key] != nil {
                        result.removeValue(forKey: key)
                        continue
                    }
                    result[key] = (rxBytes, txBytes)
                }
                return result
            }

            let getPriv = build(str: netDevBefore)
            let getCurr = build(str: netDevAfter)
            var result = [NetworkInfoElement]()
            for item in getPriv {
                if let target = getCurr[item.key] {
                    let rxIncrease = target.0 - item.value.0
                    let txIncrease = target.1 - item.value.1
                    if rxIncrease < 0 || txIncrease < 0 {
                        continue
                    }
                    let rxRate = Int((Double(rxIncrease) / duration).rounded())
                    let txRate = Int((Double(txIncrease) / duration).rounded())
                    result.append(NetworkInfoElement(device: item.key, rxBytesPerSec: rxRate, txBytesPerSec: txRate))
                }
            }

            self.init(elements: result.sorted(by: { a, b in
                a.device < b.device
            }))
        }

        /// Builds from two macOS `netstat -ibn` samples. Only link-level
        /// rows are used so each interface appears once, without its IPv4 and
        /// IPv6 aliases duplicating the same counters.
        public init?(netstatBefore: String?, netstatAfter: String?, interval: Double = 1.0) {
            guard let netstatBefore, let netstatAfter else { return nil }
            let duration = max(0.1, interval)
            let before = ProcParsers.parseDarwinNetstat(netstatBefore)
            let after = ProcParsers.parseDarwinNetstat(netstatAfter)
            let result = before.compactMap { device, previous -> NetworkInfoElement? in
                guard let current = after[device] else { return nil }
                let rxIncrease = current.rx - previous.rx
                let txIncrease = current.tx - previous.tx
                guard rxIncrease >= 0, txIncrease >= 0 else { return nil }
                let rxRate = Int((Double(rxIncrease) / duration).rounded())
                let txRate = Int((Double(txIncrease) / duration).rounded())
                return NetworkInfoElement(device: device, rxBytesPerSec: rxRate, txBytesPerSec: txRate)
            }
            self.init(elements: result.sorted { $0.device < $1.device })
        }
    }
}
