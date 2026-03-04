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

    /// Maximum total cache size before LRU eviction kicks in (2 GB).
    private let maxCacheBytes: UInt64 = 2_000_000_000

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

    /// Resolve a path to a download URL — signs relative GCS paths, passes through absolute URLs.
    private func resolveURL(_ path: String) async -> URL? {
        if let url = URL(string: path), url.scheme != nil {
            return url // Already absolute (e.g. https://...)
        }
        // Relative GCS path — sign it
        return await GCSURLSigner.shared.signedURL(for: path)
    }

    private func downloadAndCompile(_ config: ModelConfig) async throws {
        let dir = modelCacheDir(config)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let hasDecoder = config.decoder != nil
        let isZip = config.paths.denoiser.contains(".zip")

        // Download denoiser
        guard let denoiserURL = await resolveURL(config.paths.denoiser) else {
            throw GCSError.invalidURL(config.paths.denoiser)
        }

        state = .downloading(progress: 0)
        let denoiserDest = dir.appendingPathComponent(isZip ? "denoiser.zip" : "denoiser_raw.mlmodelc")
        _ = try await gcsClient.download(from: denoiserURL, to: denoiserDest) { _ in }
        state = .downloading(progress: hasDecoder ? 0.33 : 0.5)

        // Download decoder if needed
        var decoderDownloadURL: URL?
        if let decoderPath = config.paths.decoder,
           let decoderURL = await resolveURL(decoderPath) {
            let decoderDest = dir.appendingPathComponent(isZip ? "decoder.zip" : "decoder_raw.mlmodelc")
            _ = try await gcsClient.download(from: decoderURL, to: decoderDest) { _ in }
            decoderDownloadURL = decoderDest
            state = .downloading(progress: 0.66)
        }

        // Download init_state.json
        guard let initStateURL = await resolveURL(config.paths.initState) else {
            throw GCSError.invalidURL(config.paths.initState)
        }
        let initStateData = try await gcsClient.fetchJSON(from: initStateURL)
        let initStateDest = dir.appendingPathComponent("init_state.json")
        try initStateData.write(to: initStateDest)
        state = .downloading(progress: 1.0)

        // Extract or compile models
        state = .compiling

        let compiledDenoiserURL: URL
        var compiledDecoderURL: URL?

        if isZip {
            // Pre-compiled .mlmodelc in zip — just unzip
            compiledDenoiserURL = try unzipModel(at: denoiserDest, expectedName: "denoiser.mlmodelc", in: dir)
            if let decoderZip = decoderDownloadURL {
                compiledDecoderURL = try unzipModel(at: decoderZip, expectedName: "decoder.mlmodelc", in: dir)
            }
        } else {
            compiledDenoiserURL = try await compileModel(at: denoiserDest, to: dir.appendingPathComponent("denoiser.mlmodelc"))
            if let rawDecoder = decoderDownloadURL {
                compiledDecoderURL = try await compileModel(at: rawDecoder, to: dir.appendingPathComponent("decoder.mlmodelc"))
            }
        }

        state = .ready(denoiserURL: compiledDenoiserURL, decoderURL: compiledDecoderURL, initStateData: initStateData)

        evictIfNeeded(keeping: config.id)
    }

    /// Unzip a downloaded .mlmodelc.zip to extract the .mlmodelc directory.
    private func unzipModel(at zipURL: URL, expectedName: String, in dir: URL) throws -> URL {
        let destination = dir.appendingPathComponent(expectedName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try ZipExtractor.extract(zipURL: zipURL, to: dir)

        guard fileManager.fileExists(atPath: destination.path) else {
            throw GCSError.httpError(-1)
        }

        try? fileManager.removeItem(at: zipURL)
        return destination
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

    // MARK: - LRU Cache Eviction

    /// Evict oldest cached models when total cache exceeds `maxCacheBytes`.
    private func evictIfNeeded(keeping currentId: String) {
        guard fileManager.fileExists(atPath: cacheDir.path) else { return }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        struct CacheEntry {
            let url: URL
            let name: String
            let size: UInt64
            let modified: Date
        }

        var items: [CacheEntry] = []
        var totalSize: UInt64 = 0

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true else { continue }

            let size = directorySize(entry)
            let modified = values.contentModificationDate ?? .distantPast
            items.append(CacheEntry(url: entry, name: entry.lastPathComponent, size: size, modified: modified))
            totalSize += size
        }

        guard totalSize > maxCacheBytes else { return }

        // Sort oldest first
        items.sort { $0.modified < $1.modified }

        for item in items {
            guard totalSize > maxCacheBytes else { break }
            // Never evict the model we just loaded or embedded model caches
            if item.name == currentId || item.name.hasPrefix("embedded_") { continue }

            print("[ModelManager] Evicting \(item.name) (\(item.size / 1_000_000) MB)")
            try? fileManager.removeItem(at: item.url)
            totalSize -= item.size
        }
    }

    private func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }
}
