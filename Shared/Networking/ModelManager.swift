import CoreML
import Foundation

/// Manages downloading, caching, and compiling CoreML models.
@Observable
final class ModelManager {
    enum State: Sendable {
        case idle
        case downloading(progress: Double)
        case compiling
        case ready(denoiserURL: URL, decoderURL: URL?, initStateData: Data)
        case error(String)
    }

    var state: State = .idle

    private let gcsClient = GCSClient()
    private let fileManager = FileManager.default

    /// Cache directory for downloaded and compiled models.
    private var cacheDir: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CoreMLModels", isDirectory: true)
    }

    /// Load a model — checks embedded first, then cache, then downloads.
    func loadModel(_ config: ModelConfig) async {
        state = .downloading(progress: 0)

        do {
            // 1. Check for embedded model (per-game subdirectory)
            if let embedded = try loadEmbeddedModel(config) {
                state = embedded
                return
            }

            // 2. Check cache
            if let cached = try loadCachedModel(config) {
                state = cached
                return
            }

            // 3. Download from GCS
            try await downloadAndCompile(config)

        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Embedded Model

    /// Look for embedded models in EmbeddedModels/<model_id>/ subdirectory.
    /// Uses direct path construction since EmbeddedModels is a folder reference.
    private func loadEmbeddedModel(_ config: ModelConfig) throws -> State? {
        let embeddedDir = Bundle.main.bundleURL
            .appendingPathComponent("EmbeddedModels", isDirectory: true)
            .appendingPathComponent(config.id, isDirectory: true)

        let initStateURL = embeddedDir.appendingPathComponent("init_state.json")
        guard fileManager.fileExists(atPath: initStateURL.path) else {
            return nil
        }

        // Try .mlmodelc first (pre-compiled), then .mlpackage (compile on-device)
        let mlmodelcURL = embeddedDir.appendingPathComponent("denoiser.mlmodelc")
        let mlpackageURL = embeddedDir.appendingPathComponent("denoiser.mlpackage")

        var denoiserURL: URL?
        if fileManager.fileExists(atPath: mlmodelcURL.path) {
            denoiserURL = mlmodelcURL
        } else if fileManager.fileExists(atPath: mlpackageURL.path) {
            print("[ModelManager] Compiling embedded denoiser.mlpackage for \(config.id)...")
            let compiled = try MLModel.compileModel(at: mlpackageURL)
            let cachedPath = cacheDir.appendingPathComponent("\(config.id)_denoiser.mlmodelc")
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: cachedPath.path) {
                try fileManager.removeItem(at: cachedPath)
            }
            try fileManager.moveItem(at: compiled, to: cachedPath)
            denoiserURL = cachedPath
            print("[ModelManager] Compiled to: \(cachedPath)")
        }

        guard let denoiserURL else { return nil }

        let initStateData = try Data(contentsOf: initStateURL)

        // Decoder is optional — try .mlmodelc first, then .mlpackage
        let decoderMlmodelcURL = embeddedDir.appendingPathComponent("decoder.mlmodelc")
        let decoderMlpackageURL = embeddedDir.appendingPathComponent("decoder.mlpackage")

        var decoderURL: URL?
        if fileManager.fileExists(atPath: decoderMlmodelcURL.path) {
            decoderURL = decoderMlmodelcURL
        } else if fileManager.fileExists(atPath: decoderMlpackageURL.path) {
            print("[ModelManager] Compiling embedded decoder.mlpackage for \(config.id)...")
            let compiled = try MLModel.compileModel(at: decoderMlpackageURL)
            let cachedPath = cacheDir.appendingPathComponent("\(config.id)_decoder.mlmodelc")
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: cachedPath.path) {
                try fileManager.removeItem(at: cachedPath)
            }
            try fileManager.moveItem(at: compiled, to: cachedPath)
            decoderURL = cachedPath
            print("[ModelManager] Compiled decoder to: \(cachedPath)")
        }

        return .ready(denoiserURL: denoiserURL, decoderURL: decoderURL, initStateData: initStateData)
    }

    // MARK: - Cache

    private func modelCacheDir(_ config: ModelConfig) -> URL {
        cacheDir.appendingPathComponent(config.id, isDirectory: true)
    }

    private func loadCachedModel(_ config: ModelConfig) throws -> State? {
        let dir = modelCacheDir(config)
        let denoiserURL = dir.appendingPathComponent("denoiser.mlmodelc")
        let initStateURL = dir.appendingPathComponent("init_state.json")

        guard fileManager.fileExists(atPath: denoiserURL.path),
              fileManager.fileExists(atPath: initStateURL.path) else {
            return nil
        }

        let initStateData = try Data(contentsOf: initStateURL)

        // Check decoder
        var decoderURL: URL?
        if config.decoder != nil {
            let url = dir.appendingPathComponent("decoder.mlmodelc")
            if fileManager.fileExists(atPath: url.path) {
                decoderURL = url
            } else {
                return nil // Incomplete cache
            }
        }

        return .ready(denoiserURL: denoiserURL, decoderURL: decoderURL, initStateData: initStateData)
    }

    // MARK: - Download & Compile

    private func downloadAndCompile(_ config: ModelConfig) async throws {
        let dir = modelCacheDir(config)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let hasDecoder = config.decoder != nil

        // Download denoiser
        guard let denoiserURL = URL(string: config.paths.denoiser) else {
            throw GCSError.invalidURL(config.paths.denoiser)
        }

        state = .downloading(progress: 0)
        let denoiserDest = dir.appendingPathComponent("denoiser_raw.mlmodelc")
        _ = try await gcsClient.download(from: denoiserURL, to: denoiserDest) { _ in }
        state = .downloading(progress: hasDecoder ? 0.33 : 0.5)

        // Download decoder if needed
        var decoderCompiledURL: URL?
        if let decoderPath = config.paths.decoder,
           let decoderURL = URL(string: decoderPath) {
            let decoderDest = dir.appendingPathComponent("decoder_raw.mlmodelc")
            _ = try await gcsClient.download(from: decoderURL, to: decoderDest) { _ in }
            decoderCompiledURL = decoderDest
            state = .downloading(progress: 0.66)
        }

        // Download init_state.json
        guard let initStateURL = URL(string: config.paths.initState) else {
            throw GCSError.invalidURL(config.paths.initState)
        }
        let initStateData = try await gcsClient.fetchJSON(from: initStateURL)
        let initStateDest = dir.appendingPathComponent("init_state.json")
        try initStateData.write(to: initStateDest)
        state = .downloading(progress: 1.0)

        // Compile models
        state = .compiling

        let compiledDenoiserURL = try await compileModel(at: denoiserDest, to: dir.appendingPathComponent("denoiser.mlmodelc"))

        var compiledDecoderURL: URL?
        if let rawDecoder = decoderCompiledURL {
            compiledDecoderURL = try await compileModel(at: rawDecoder, to: dir.appendingPathComponent("decoder.mlmodelc"))
        }

        state = .ready(denoiserURL: compiledDenoiserURL, decoderURL: compiledDecoderURL, initStateData: initStateData)
    }

    /// Compile an mlpackage/mlmodel to mlmodelc.
    private func compileModel(at source: URL, to destination: URL) async throws -> URL {
        // If already compiled (.mlmodelc directory exists), just use it
        if source.pathExtension == "mlmodelc" && fileManager.fileExists(atPath: source.path) {
            if source != destination {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: source, to: destination)
            }
            return destination
        }

        // Compile from .mlpackage or .mlmodel
        let compiled = try await Task.detached {
            try MLModel.compileModel(at: source)
        }.value

        // Move compiled model to destination
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: compiled, to: destination)

        // Clean up source
        try? fileManager.removeItem(at: source)

        return destination
    }
}
