//
//  UURemoteChannelOutbox.swift
//  CatusshModule
//
//  What waits to go out on a UU Remote connection's data channels. Every
//  send is a call into the WebRTC page, and with one call per message the
//  queue can fall behind a finger: a touch screen reports a moving finger
//  120 times a second, each move waits its turn, and the heartbeats the host
//  watches for queue behind them. Messages leave in batches, a call each,
//  and a pointer move waiting to go is replaced by a newer one.
//

import Foundation

struct UUChannelOutbox: Sendable {
    /// What a message is to the queue.
    enum Kind: Sendable, Equatable {
        /// An absolute pointer move: only the latest one waiting matters.
        case pointerMove
        /// Other input (buttons, wheel, keys, text): sent, in order.
        case input
        /// Heartbeats, RPCs, terminal and port-mapping data.
        case other
    }

    struct Message: Sendable, Equatable {
        let label: String
        let data: Data
        let kind: Kind
    }

    /// The most a batch carries, in payload bytes: port-mapping data is
    /// large, and a call into the page has to stay small.
    static let batchBytes = 256 * 1024

    private(set) var pending: [Message] = []

    /// Queues `message`. A pointer move replaces the move still waiting, if
    /// no other input was queued after it: the pointer goes straight to
    /// where it is now, and a click after a move still lands where it was.
    mutating func push(_ message: Message) {
        if message.kind == .pointerMove,
           let index = pending.lastIndex(where: { $0.kind != .other && $0.label == message.label }),
           pending[index].kind == .pointerMove
        {
            pending[index] = message
            return
        }
        pending.append(message)
    }

    /// The next batch, oldest first: at least one message, then as many as
    /// fit in `batchBytes`.
    mutating func take() -> [Message] {
        var bytes = 0
        var count = 0
        for message in pending {
            if count > 0, bytes + message.data.count > Self.batchBytes { break }
            bytes += message.data.count
            count += 1
        }
        let batch = Array(pending.prefix(count))
        pending.removeFirst(count)
        return batch
    }

    /// The page call that sends `batch`: `dcSendBatch([[label, base64], …])`.
    static func script(for batch: [Message]) -> String {
        let items = batch.map { #"["\#($0.label)","\#($0.data.base64EncodedString())"]"# }
        return "dcSendBatch([\(items.joined(separator: ","))])"
    }
}
