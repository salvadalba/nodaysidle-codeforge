import CryptoKit
import Foundation
import Testing

@testable import CodeForge

@Suite("EncryptionService")
struct EncryptionTests {

    private func makeService() -> EncryptionService {
        let key = SymmetricKey(size: .bits256)
        return EncryptionService(key: key)
    }

    // MARK: - Roundtrip

    @Test("Encrypt/decrypt roundtrip preserves plaintext")
    func roundtrip() throws {
        let service = makeService()
        let plaintext = Data("Hello, CodeForge!".utf8)

        let encrypted = try service.encrypt(data: plaintext)
        let decrypted = try service.decrypt(data: encrypted)

        #expect(decrypted == plaintext)
    }

    @Test("Roundtrip with empty data")
    func roundtripEmpty() throws {
        let service = makeService()
        let plaintext = Data()

        let encrypted = try service.encrypt(data: plaintext)
        let decrypted = try service.decrypt(data: encrypted)

        #expect(decrypted == plaintext)
    }

    @Test("Roundtrip with single byte")
    func roundtripSingleByte() throws {
        let service = makeService()
        let plaintext = Data([0x42])

        let encrypted = try service.encrypt(data: plaintext)
        let decrypted = try service.decrypt(data: encrypted)

        #expect(decrypted == plaintext)
    }

    @Test("Roundtrip with 1 MB payload")
    func roundtripLarge() throws {
        let service = makeService()
        let plaintext = Data(repeating: 0xAB, count: 1_000_000)

        let encrypted = try service.encrypt(data: plaintext)
        let decrypted = try service.decrypt(data: encrypted)

        #expect(decrypted == plaintext)
    }

    // MARK: - Ciphertext format

    @Test("Encrypted data is longer than plaintext (nonce + tag overhead)")
    func ciphertextOverhead() throws {
        let service = makeService()
        let plaintext = Data("test".utf8)

        let encrypted = try service.encrypt(data: plaintext)

        // AES-GCM combined = 12-byte nonce + ciphertext + 16-byte tag
        #expect(encrypted.count == plaintext.count + 12 + 16)
    }

    @Test("Encrypted data is not plaintext")
    func ciphertextIsObfuscated() throws {
        let service = makeService()
        let plaintext = Data("sensitive code contents".utf8)

        let encrypted = try service.encrypt(data: plaintext)

        #expect(encrypted != plaintext)
    }

    // MARK: - Tamper detection

    @Test("Tampered ciphertext produces authenticationFailed")
    func tamperedCiphertext() throws {
        let service = makeService()
        let plaintext = Data("protect me".utf8)

        var encrypted = try service.encrypt(data: plaintext)
        // Flip a byte in the ciphertext region (after 12-byte nonce)
        encrypted[14] ^= 0xFF

        #expect(throws: EncryptionError.authenticationFailed) {
            try service.decrypt(data: encrypted)
        }
    }

    @Test("Truncated ciphertext produces authenticationFailed")
    func truncatedCiphertext() throws {
        let service = makeService()
        let plaintext = Data("protect me".utf8)

        let encrypted = try service.encrypt(data: plaintext)
        let truncated = encrypted.prefix(10) // too short to be valid

        #expect(throws: EncryptionError.authenticationFailed) {
            try service.decrypt(data: Data(truncated))
        }
    }

    // MARK: - IV uniqueness

    @Test("1000 encryptions produce 1000 unique nonces")
    func ivUniqueness() throws {
        let service = makeService()
        let plaintext = Data("same input".utf8)

        var nonces: Set<Data> = []
        for _ in 0..<1000 {
            let encrypted = try service.encrypt(data: plaintext)
            let nonce = encrypted.prefix(12) // first 12 bytes = nonce
            nonces.insert(nonce)
        }

        #expect(nonces.count == 1000)
    }

    // MARK: - Cross-key isolation

    @Test("Decryption with different key fails")
    func differentKeyFails() throws {
        let service1 = EncryptionService(key: SymmetricKey(size: .bits256))
        let service2 = EncryptionService(key: SymmetricKey(size: .bits256))

        let encrypted = try service1.encrypt(data: Data("secret".utf8))

        #expect(throws: EncryptionError.authenticationFailed) {
            try service2.decrypt(data: encrypted)
        }
    }
}
