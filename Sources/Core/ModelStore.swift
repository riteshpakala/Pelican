import Foundation
import MLXLLM
import MLXLMCommon
import FrigateBridge

/// Thin wrapper over Frigate's model loading (port of Fleet's ModelLoader).
enum ModelStore {

    static let defaultModelId = "mlx-community/Mistral-7B-Instruct-v0.3-4bit"

    /// Download (if needed) and warm a HuggingFace MLX model, reporting progress
    /// as `(fractionCompleted, status)`. Throws if the id is invalid/unavailable.
    static func warm(
        id: String,
        onProgress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        _ = try await loadModelContainer(
            from: HubDownloader(), using: HubTokenizerLoader(), id: id
        ) { progress in
            onProgress(progress.fractionCompleted, progress.localizedDescription ?? "Working…")
        }
    }

    /// True when mlx.metallib sits next to the running binary — without it, MLX
    /// GPU inference dies at the first token with "Failed to load the default
    /// metallib". Checked at launch so we can show a fix banner instead.
    /// What to run when the metallib is missing, for however this copy was built.
    static var metallibFixCommand: String {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return "./scripts/make-app.sh    # from the Pelican checkout; it installs the metallib into the app"
        }
        let config = Bundle.main.executableURL?.path.contains("/release/") == true ? "release" : "debug"
        return "./scripts/build-metallib.sh \(config)    # from the Pelican checkout"
    }

    static var metallibPresent: Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let metallib = executable.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        return FileManager.default.fileExists(atPath: metallib.path)
    }
}
