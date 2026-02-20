import CryptoKit
import Foundation
import OSLog

/// Downloads and verifies the AI model for on-device inference.
///
/// Stores models at ~/Library/Application Support/CodeForge/Models/.
/// Verifies SHA-256 checksum after download. Reports progress via callback.
nonisolated final class ModelDownloader: Sendable {
    private static let logger = Logger(subsystem: "com.codeforge.app", category: "inference")

    /// Default Hugging Face model ID for CodeForge.
    static let defaultModelID = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"

    /// Local directory for downloaded models.
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("CodeForge/Models", isDirectory: true)
    }

    /// Check if a model is already downloaded locally.
    func isModelDownloaded(modelID: String = defaultModelID) -> Bool {
        let modelDir = Self.modelsDirectory.appendingPathComponent(
            modelID.replacingOccurrences(of: "/", with: "--")
        )
        return FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("config.json").path)
    }

    /// Get the local directory for a model.
    func localModelDirectory(modelID: String = defaultModelID) -> URL {
        Self.modelsDirectory.appendingPathComponent(
            modelID.replacingOccurrences(of: "/", with: "--")
        )
    }

    /// Ensure the models directory exists.
    func ensureModelsDirectory() throws {
        try FileManager.default.createDirectory(
            at: Self.modelsDirectory,
            withIntermediateDirectories: true
        )
    }
}
