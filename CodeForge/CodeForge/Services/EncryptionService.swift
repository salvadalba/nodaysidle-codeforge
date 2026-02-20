import CryptoKit
import Foundation
import OSLog

enum EncryptionError: Error, LocalizedError, Sendable {
    case keychainAccessDenied
    case encryptionFailed
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .keychainAccessDenied:
            "Cannot access macOS Keychain for encryption key. "
            + "Check System Settings > Privacy & Security > Keychain access."
        case .encryptionFailed:
            "Failed to encrypt data"
        case .authenticationFailed:
            "Encrypted data has been tampered with or the key is incorrect"
        }
    }
}

/// AES-256-GCM encryption backed by a Keychain-stored symmetric key.
///
/// Format: 12-byte nonce + ciphertext + 16-byte GCM authentication tag
/// (matches CryptoKit's `AES.GCM.SealedBox.combined` layout).
///
/// The key is generated on first use, stored in the macOS Keychain with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and cached in-memory
/// for the lifetime of this instance.
///
/// On transient Keychain failures the initializer retries 3 times with
/// 500 ms delays before giving up.
final class EncryptionService: @unchecked Sendable {
    private static let keychainAccount = "aes256-encryption-key"
    private static let logger = Logger(subsystem: "com.codeforge.app", category: "encryption")

    private let symmetricKey: SymmetricKey

    /// Production initializer — loads or generates Keychain-backed key.
    /// Retries up to 3 times on transient Keychain failures.
    init() async throws(EncryptionError) {
        let account = Self.keychainAccount

        let existingKeyData: Data?
        do {
            existingKeyData = try KeychainHelper.load(account: account)
        } catch {
            Self.logger.warning("Initial Keychain load failed, retrying...")
            existingKeyData = try await Self.handleKeychainFailure {
                try KeychainHelper.load(account: account)
            }
        }

        if let keyData = existingKeyData {
            self.symmetricKey = SymmetricKey(data: keyData)
            return
        }

        // First launch — generate and persist a new key
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        do {
            try KeychainHelper.save(key: keyData, account: account)
        } catch {
            Self.logger.warning("Initial Keychain save failed, retrying...")
            try await Self.handleKeychainFailure {
                try KeychainHelper.save(key: keyData, account: account)
            }
        }
        self.symmetricKey = newKey
    }

    /// Testing initializer — uses a caller-provided key (no Keychain).
    init(key: SymmetricKey) {
        self.symmetricKey = key
    }

    // MARK: - Keychain retry

    /// Retries a Keychain operation 3 times with 500 ms delays.
    /// Throws `.keychainAccessDenied` if all retries fail.
    @discardableResult
    private static func handleKeychainFailure<T: Sendable>(
        _ operation: @Sendable () throws -> T
    ) async throws(EncryptionError) -> T {
        for attempt in 1...3 {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                logger.error("Keychain retry cancelled")
                throw .keychainAccessDenied
            }
            do {
                let result = try operation()
                logger.info("Keychain retry \(attempt)/3 succeeded")
                return result
            } catch {
                logger.warning("Keychain retry \(attempt)/3 failed")
                if attempt == 3 {
                    logger.error("All 3 Keychain retries exhausted")
                    throw .keychainAccessDenied
                }
            }
        }
        throw .keychainAccessDenied
    }

    /// Encrypt plaintext data using AES-256-GCM.
    /// Returns nonce (12 B) + ciphertext + tag (16 B).
    func encrypt(data: Data) throws(EncryptionError) -> Data {
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        } catch {
            throw .encryptionFailed
        }
        guard let combined = sealedBox.combined else {
            throw .encryptionFailed
        }
        return combined
    }

    /// Decrypt data previously produced by `encrypt(data:)`.
    func decrypt(data: Data) throws(EncryptionError) -> Data {
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: data)
        } catch {
            throw .authenticationFailed
        }
        do {
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw .authenticationFailed
        }
    }
}
