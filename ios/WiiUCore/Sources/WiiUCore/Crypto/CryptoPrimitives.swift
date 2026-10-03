import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Nintendo keys

/// Wii U common key, ported verbatim from `wiiUCommonKey` in `decryption.go`.
public let wiiUCommonKey: [UInt8] = [
    0xD7, 0xB0, 0x04, 0x02, 0x65, 0x9B, 0xA2, 0xAB,
    0xD2, 0xCB, 0x0D, 0xB2, 0x7F, 0xA2, 0xB6, 0x56,
]

/// Wii common keys indexed by ticket key index, ported verbatim from
/// `wiiCommonKeys` in `decryption.go`.
public let wiiCommonKeys: [UInt8: [UInt8]] = [
    0: [0xEB, 0xE4, 0x2A, 0x22, 0x5E, 0x85, 0x93, 0xE4, 0x48, 0xD9, 0xC5, 0x45, 0x73, 0x81, 0xAA, 0xF7],
    1: [0x63, 0xB8, 0x2B, 0xB4, 0xF4, 0x61, 0x4E, 0x2E, 0x13, 0xF2, 0xFE, 0xFB, 0xBA, 0x4C, 0x9B, 0x7E],
    2: [0x30, 0xBF, 0xC7, 0x6E, 0x7C, 0x19, 0xAF, 0xBB, 0x23, 0x16, 0x33, 0x30, 0xCE, 0xD7, 0xC2, 0x8D],
]

// MARK: - AES

public enum AESPrimitives {
    /// PKCS7 padding, matching Go's `PKCS7Padding`. A full block of padding is
    /// appended when the input is already block aligned.
    public static func pkcs7Pad(_ data: [UInt8], blockSize: Int) -> [UInt8] {
        let padding = blockSize - (data.count % blockSize)
        var padded = [UInt8](repeating: 0, count: data.count + padding)
        for i in 0..<data.count {
            padded[i] = data[i]
        }
        for i in data.count..<padded.count {
            padded[i] = UInt8(padding)
        }
        return padded
    }

    /// CBC encryption with PKCS7 padding, matching Go's `encryptAES`. The output
    /// length equals the padded input length.
    public static func cbcEncrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        let padded = pkcs7Pad(data, blockSize: WiiUConstants.aesBlockSize)
        guard key.count == WiiUConstants.aesBlockSize, iv.count == WiiUConstants.aesBlockSize else {
            throw WiiUError.validation("invalid AES key or IV size")
        }

        var output = [UInt8](repeating: 0, count: padded.count + kCCBlockSizeAES128)
        let paddedCount = padded.count
        let outputCount = output.count
        var moved = 0
        let status = padded.withUnsafeBytes { inputPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    output.withUnsafeMutableBytes { outputPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyPtr.baseAddress,
                            key.count,
                            ivPtr.baseAddress,
                            inputPtr.baseAddress,
                            paddedCount,
                            outputPtr.baseAddress,
                            outputCount,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw WiiUError.validation("AES-CBC encryption failed: \(status)")
        }
        return Array(output[0..<moved])
    }
}

/// Reusable AES-CBC decryptor with no padding, mirroring Go's `reusableCBC`
/// (a single `cipher.BlockMode` reused across blocks). The IV is reset on every
/// call, just like `cipher.NewCBCDecrypter`.
public final class AESCBCDecryptor {
    private var cryptor: CCCryptorRef?
    private let key: [UInt8]

    public init(key: [UInt8]) throws {
        self.key = key
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            CCCryptorCreate(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(0),
                keyPtr.baseAddress,
                key.count,
                nil,
                &ref
            )
        }
        guard status == kCCSuccess, let cryptor = ref else {
            throw WiiUError.validation("failed to create AES cryptor: \(status)")
        }
        self.cryptor = cryptor
    }

    deinit {
        if let cryptor = cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    /// Decrypts `input` in place. `input.count` must be a multiple of the AES
    /// block size; the output length equals the input length.
    public func decryptInPlace(_ buffer: inout [UInt8], iv: [UInt8]) throws {
        guard buffer.count % WiiUConstants.aesBlockSize == 0 else {
            throw WiiUError.validation("AES-CBC input must be a multiple of the block size")
        }
        guard let cryptor = cryptor else {
            throw WiiUError.validation("AES cryptor is not initialized")
        }
        if buffer.isEmpty {
            return
        }
        let resetStatus = iv.withUnsafeBytes { ivPtr in
            CCCryptorReset(cryptor, ivPtr.baseAddress)
        }
        guard resetStatus == kCCSuccess else {
            throw WiiUError.validation("failed to reset AES cryptor: \(resetStatus)")
        }

        let count = buffer.count
        var moved = 0
        let status = buffer.withUnsafeMutableBytes { bufPtr in
            CCCryptorUpdate(
                cryptor,
                bufPtr.baseAddress,
                count,
                bufPtr.baseAddress,
                count,
                &moved
            )
        }
        guard status == kCCSuccess else {
            throw WiiUError.validation("AES-CBC decryption failed: \(status)")
        }
    }

    /// Decrypts `input` and returns a new buffer. `input.count` must be a
    /// multiple of the AES block size.
    public func decrypt(_ input: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var buffer = input
        try decryptInPlace(&buffer, iv: iv)
        return buffer
    }
}

// MARK: - Digests / KDF

public enum Digests {
    public static func md5(_ data: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: data))
    }

    public static func sha1(_ data: [UInt8]) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: data))
    }

    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    /// PBKDF2-HMAC-SHA1, matching Go's `pbkdf2.Key(..., sha1.New)`.
    public static func pbkdf2SHA1(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: keyLength)
        // CommonCrypto expects non-nil pointers when the lengths are zero, so
        // fall back to a single dummy byte for empty inputs.
        let passwordBytes = password.isEmpty ? [UInt8(0)] : password
        let saltBytes = salt.isEmpty ? [UInt8(0)] : salt

        _ = derived.withUnsafeMutableBytes { derivedPtr in
            passwordBytes.withUnsafeBytes { passwordPtr in
                saltBytes.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(iterations),
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return derived
    }
}
