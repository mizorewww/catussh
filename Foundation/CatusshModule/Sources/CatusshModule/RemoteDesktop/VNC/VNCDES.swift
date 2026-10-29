//
//  VNCDES.swift
//  CatusshModule
//
//  The 16-byte challenge exchange of RFB security type 2 (VNC
//  authentication). RFB derives the DES key from the password in a
//  surprising way: the password is truncated or zero-padded to 8 bytes and
//  every byte's bit order is reversed before it is used as the key.
//

import CommonCrypto
import Foundation

enum VNCDES {
    /// Reverses the bits of one byte: 0b01234567 -> 0b76543210.
    static func reverseBits(of byte: UInt8) -> UInt8 {
        var value = byte
        var result: UInt8 = 0
        for _ in 0 ..< 8 {
            result = (result << 1) | (value & 1)
            value >>= 1
        }
        return result
    }

    /// The RFB DES key for a password: first 8 bytes, zero padded, each
    /// byte bit-reversed.
    static func key(for password: String) -> [UInt8] {
        var bytes = Array(password.utf8.prefix(8))
        while bytes.count < 8 { bytes.append(0) }
        return bytes.map(reverseBits)
    }

    /// Encrypts the 16-byte challenge with the password-derived key
    /// (DES, ECB, two blocks — no padding).
    static func encryptChallenge(_ challenge: [UInt8], password: String) -> [UInt8]? {
        guard challenge.count == 16 else { return nil }
        let key = key(for: password)
        var output = [UInt8](repeating: 0, count: challenge.count + kCCBlockSizeDES)
        var outputLength = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),
            key, kCCKeySizeDES,
            nil,
            challenge, challenge.count,
            &output, output.count,
            &outputLength
        )
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(outputLength))
    }
}
