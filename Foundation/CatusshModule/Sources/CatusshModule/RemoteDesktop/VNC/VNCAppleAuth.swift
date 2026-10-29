//
//  VNCAppleAuth.swift
//  CatusshModule
//
//  RFB security type 30, Apple Remote Desktop authentication: what macOS
//  Screen Sharing asks for when it is given a user account rather than a
//  VNC password. The server sends Diffie-Hellman parameters and its public
//  key; the client answers with the user name and password, AES-128-ECB
//  encrypted under MD5 of the shared secret, followed by its own public key.
//

import CommonCrypto
import CryptoKit
import Foundation

enum VNCAppleAuth {
    /// The DH parameters the server opens type 30 with.
    struct ServerParameters {
        var generator: [UInt8]
        var prime: [UInt8]
        var serverPublicKey: [UInt8]

        /// Every big number on the wire is this many bytes, big endian.
        var keyLength: Int { prime.count }
    }

    /// Reads generator(u16) keyLength(u16) prime(keyLength) publicKey(keyLength).
    static func readParameters(over channel: VNCByteChannel) throws -> ServerParameters {
        let header = try channel.read(exactly: 4)
        let generator = header.readU16BE(at: 0)
        let keyLength = Int(header.readU16BE(at: 2))
        guard keyLength > 0, keyLength <= 1024 else {
            throw RemoteDesktopFailure("The server sent an unusable Apple authentication key length (\(keyLength)).")
        }
        let prime = Array(try channel.read(exactly: keyLength))
        let publicKey = Array(try channel.read(exactly: keyLength))
        return ServerParameters(
            generator: [UInt8(generator >> 8), UInt8(generator & 0xFF)],
            prime: prime,
            serverPublicKey: publicKey
        )
    }

    /// The client's answer: 128 bytes of encrypted credentials, then the
    /// client public key. `privateKey` is drawn at random unless a test
    /// pins it.
    static func response(
        to parameters: ServerParameters,
        username: String,
        password: String,
        privateKey: [UInt8]? = nil
    ) throws -> Data {
        guard parameters.prime.last.map({ $0 & 1 == 1 }) == true else {
            throw RemoteDesktopFailure("The server's Apple authentication modulus is not usable.")
        }
        let length = parameters.keyLength
        let secret = privateKey ?? randomBytes(length)
        let modulus = VNCBigNum(bigEndian: parameters.prime)
        let exponent = VNCBigNum(bigEndian: secret)
        let publicKey = VNCBigNum(bigEndian: parameters.generator).power(exponent, modulo: modulus)
        let shared = VNCBigNum(bigEndian: parameters.serverPublicKey).power(exponent, modulo: modulus)

        let key = Array(Insecure.MD5.hash(data: Data(shared.bigEndianBytes(length: length))))
        let plain = credentialBlock(username: username, password: password)
        guard let cipher = aes128ECB(plain, key: key) else {
            throw RemoteDesktopFailure("Could not encrypt the Apple authentication credentials.")
        }
        var data = Data(cipher)
        data.append(contentsOf: publicKey.bigEndianBytes(length: length))
        return data
    }

    /// 64 bytes of user name and 64 of password, each NUL-terminated and
    /// padded with random bytes, as Apple's client does.
    static func credentialBlock(username: String, password: String) -> [UInt8] {
        func field(_ text: String) -> [UInt8] {
            var bytes = Array(text.utf8.prefix(63))
            bytes.append(0)
            bytes.append(contentsOf: randomBytes(64 - bytes.count))
            return bytes
        }
        return field(username) + field(password)
    }

    static func aes128ECB(_ input: [UInt8], key: [UInt8], decrypt: Bool = false) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128, input.count % kCCBlockSizeAES128 == 0 else { return nil }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCrypt(
            CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            key, key.count,
            nil,
            input, input.count,
            &output, output.count,
            &moved
        )
        guard status == kCCSuccess, moved == input.count else { return nil }
        return output
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = .random(in: .min ... .max) }
        }
        return bytes
    }
}

/// An unsigned big integer with just what Diffie-Hellman needs: modular
/// exponentiation (Montgomery multiplication, so an odd modulus) and
/// conversion to and from big-endian bytes. Limbs are little endian.
struct VNCBigNum: Equatable {
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    init(bigEndian bytes: [UInt8]) {
        var limbs = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (index, byte) in bytes.reversed().enumerated() {
            limbs[index / 4] |= UInt32(byte) << (UInt32(index % 4) * 8)
        }
        self.init(limbs: limbs)
    }

    /// Big endian, left-padded with zeros (or cut from the left) to `length`.
    func bigEndianBytes(length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        for index in 0 ..< length {
            let limb = index / 4
            guard limb < limbs.count else { break }
            bytes[length - 1 - index] = UInt8(truncatingIfNeeded: limbs[limb] >> (UInt32(index % 4) * 8))
        }
        return bytes
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    private var bitWidth: Int {
        guard let top = limbs.last, top != 0 else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    private func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return limbs[limb] >> UInt32(index % 32) & 1 == 1
    }

    private mutating func normalize() {
        while limbs.count > 1, limbs.last == 0 { limbs.removeLast() }
        if limbs.isEmpty { limbs = [0] }
    }

    // MARK: Fixed-width helpers (`n` limbs, little endian)

    private static func padded(_ value: [UInt32], to count: Int) -> [UInt32] {
        value.count >= count ? Array(value.prefix(count)) : value + [UInt32](repeating: 0, count: count - value.count)
    }

    private static func compare(_ lhs: [UInt32], _ rhs: [UInt32]) -> Int {
        for index in stride(from: lhs.count - 1, through: 0, by: -1) where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index] ? -1 : 1
        }
        return 0
    }

    /// lhs -= rhs, with lhs >= rhs.
    private static func subtract(_ lhs: inout [UInt32], _ rhs: [UInt32]) {
        var borrow: UInt64 = 0
        for index in lhs.indices {
            let difference = UInt64(lhs[index]) &- UInt64(rhs[index]) &- borrow
            lhs[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference >> 63
        }
    }

    /// `self mod modulus`, by shifting the bits of `self` in one at a time.
    func reduced(modulo modulus: VNCBigNum) -> [UInt32] {
        let n = modulus.limbs.count
        let m = Self.padded(modulus.limbs, to: n + 1)
        var remainder = [UInt32](repeating: 0, count: n + 1)
        for index in stride(from: bitWidth - 1, through: 0, by: -1) {
            var carry: UInt32 = bit(index) ? 1 : 0
            for limb in remainder.indices {
                let next = remainder[limb] >> 31
                remainder[limb] = remainder[limb] << 1 | carry
                carry = next
            }
            if Self.compare(remainder, m) >= 0 { Self.subtract(&remainder, m) }
        }
        return Array(remainder.prefix(n))
    }

    /// `self ^ exponent mod modulus`; the modulus must be odd.
    func power(_ exponent: VNCBigNum, modulo modulus: VNCBigNum) -> VNCBigNum {
        let montgomery = Montgomery(modulus: modulus.limbs)
        let base = montgomery.enter(reduced(modulo: modulus))
        var accumulator = montgomery.one
        for index in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            accumulator = montgomery.multiply(accumulator, accumulator)
            if exponent.bit(index) { accumulator = montgomery.multiply(accumulator, base) }
        }
        return VNCBigNum(limbs: montgomery.leave(accumulator))
    }

    /// Montgomery arithmetic modulo an odd `modulus` of `n` limbs, R = 2^(32n).
    private struct Montgomery {
        let modulus: [UInt32]
        let n: Int
        /// −modulus⁻¹ mod 2^32.
        let inverse: UInt32
        /// R² mod modulus, to bring numbers into Montgomery form.
        let rSquared: [UInt32]

        init(modulus: [UInt32]) {
            self.modulus = modulus
            n = modulus.count
            // Newton's iteration doubles the correct low bits each step.
            var x: UInt32 = 1
            for _ in 0 ..< 5 { x = x &* (2 &- modulus[0] &* x) }
            inverse = 0 &- x
            // R² mod m: double 1 modulo m, 2·32n times.
            var value = [UInt32](repeating: 0, count: n + 1)
            value[0] = 1
            let m = VNCBigNum.padded(modulus, to: n + 1)
            for _ in 0 ..< 2 * 32 * n {
                var carry: UInt32 = 0
                for limb in value.indices {
                    let next = value[limb] >> 31
                    value[limb] = value[limb] << 1 | carry
                    carry = next
                }
                if VNCBigNum.compare(value, m) >= 0 { VNCBigNum.subtract(&value, m) }
            }
            rSquared = Array(value.prefix(n))
        }

        var one: [UInt32] {
            var unit = [UInt32](repeating: 0, count: n)
            unit[0] = 1
            return enter(unit)
        }

        func enter(_ value: [UInt32]) -> [UInt32] {
            multiply(VNCBigNum.padded(value, to: n), rSquared)
        }

        func leave(_ value: [UInt32]) -> [UInt32] {
            var unit = [UInt32](repeating: 0, count: n)
            unit[0] = 1
            return multiply(value, unit)
        }

        /// a·b·R⁻¹ mod m (CIOS), for a, b < m.
        func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: n + 2)
            for i in 0 ..< n {
                var carry: UInt64 = 0
                let bi = UInt64(b[i])
                for j in 0 ..< n {
                    let sum = UInt64(t[j]) + UInt64(a[j]) * bi + carry
                    t[j] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                var sum = UInt64(t[n]) + carry
                t[n] = UInt32(truncatingIfNeeded: sum)
                t[n + 1] = UInt32(sum >> 32)

                let q = UInt64(t[0] &* inverse)
                sum = UInt64(t[0]) + q * UInt64(modulus[0])
                carry = sum >> 32
                for j in 1 ..< n {
                    sum = UInt64(t[j]) + q * UInt64(modulus[j]) + carry
                    t[j - 1] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                sum = UInt64(t[n]) + carry
                t[n - 1] = UInt32(truncatingIfNeeded: sum)
                t[n] = t[n + 1] + UInt32(sum >> 32)
            }
            var result = Array(t.prefix(n + 1))
            let m = VNCBigNum.padded(modulus, to: n + 1)
            if VNCBigNum.compare(result, m) >= 0 { VNCBigNum.subtract(&result, m) }
            return Array(result.prefix(n))
        }
    }
}
