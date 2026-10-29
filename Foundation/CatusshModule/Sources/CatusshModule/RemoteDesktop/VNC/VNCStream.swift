//
//  VNCStream.swift
//  CatusshModule
//
//  The ordered byte channel the RFB client talks over, and its TCP
//  implementation. An in-memory implementation sits in the tests, so the
//  whole protocol machine is drivable without a network.
//

import Darwin
import Foundation

/// An ordered stream of bytes: reads block until enough arrive, a failure
/// or a peer close surfaces as `endOfStream` / `failed`.
protocol VNCByteChannel: AnyObject, Sendable {
    /// Reads exactly `count` bytes, blocking until they arrive.
    func read(exactly count: Int) throws -> Data
    /// Writes all of `data`.
    func write(_ data: Data) throws
    /// Closes both directions; blocked readers wake with an error.
    func close()
}

enum VNCStreamError: Error, Equatable {
    case endOfStream
    case failed(String)
}

/// A blocking TCP socket. Reads and writes happen on the caller's thread —
/// the RFB client runs one reader thread and sends from the input path —
/// so send and receive never share the descriptor's critical section.
final class VNCSocket: VNCByteChannel, @unchecked Sendable {
    private var fd: Int32 = -1
    private let fdLock = NSLock()

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Connects to `host:port`, failing after `timeout` seconds.
    static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> VNCSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw VNCStreamError.failed("Could not resolve \(host)")
        }
        defer { freeaddrinfo(list) }

        var lastError: String = "no usable address"
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // Connect with a deadline: nonblocking connect, wait writable.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let connectResult = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if connectResult == 0 || errno == EINPROGRESS {
                if connectResult != 0 {
                    var poll = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let millis = Int32(max(timeout, 1) * 1000)
                    guard Darwin.poll(&poll, 1, millis) > 0, poll.revents & Int16(POLLOUT) != 0 else {
                        Darwin.close(fd)
                        lastError = "timed out after \(Int(timeout))s"
                        continue
                    }
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                    guard socketError == 0 else {
                        Darwin.close(fd)
                        lastError = String(cString: strerror(socketError))
                        continue
                    }
                }
                _ = fcntl(fd, F_SETFL, flags)
                return VNCSocket(fd: fd)
            }
            lastError = String(cString: strerror(errno))
            Darwin.close(fd)
        }
        throw VNCStreamError.failed("Could not connect to \(host):\(port) (\(lastError))")
    }

    /// Wraps an already-connected descriptor.
    static func open(fd: Int32) -> VNCSocket {
        VNCSocket(fd: fd)
    }

    func read(exactly count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        while received < count {
            let descriptor = fdLock.withLock { fd }
            guard descriptor >= 0 else { throw VNCStreamError.endOfStream }
            let count_ = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.recv(descriptor, base + received, count - received, 0)
            }
            if count_ < 0, errno == EINTR { continue }
            if count_ == 0 { throw VNCStreamError.endOfStream }
            guard count_ > 0 else {
                throw VNCStreamError.failed(String(cString: strerror(errno)))
            }
            received += count_
        }
        return data
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let descriptor = fdLock.withLock { fd }
                guard descriptor >= 0 else { throw VNCStreamError.endOfStream }
                let count = Darwin.send(descriptor, base + sent, buffer.count - sent, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw VNCStreamError.endOfStream }
                sent += count
            }
        }
    }

    /// Wakes any blocked read without freeing the descriptor first.
    func interrupt() {
        let descriptor = fdLock.withLock { fd }
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR) }
    }

    func close() {
        fdLock.withLock {
            if fd >= 0 {
                shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
                fd = -1
            }
        }
    }

    deinit {
        close()
    }
}
