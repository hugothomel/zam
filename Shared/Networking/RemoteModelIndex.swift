import Foundation

/// Fetches and caches the remote CoreML model index from GCS.
/// Uses on-device URL signing via GCSURLSigner (no server needed).
actor RemoteModelIndex {
    static let shared = RemoteModelIndex()

    private let indexPath = "coreml/index.json"
    private let cacheKey = "RemoteModelIndex_cache"

    /// Fetch remote index, returning parsed ModelConfigs.
    /// Falls back to cached data if the network request fails.
    func fetch() async -> [ModelConfig] {
        do {
            let data = try await GCSURLSigner.shared.fetchData(path: indexPath)
            UserDefaults.standard.set(data, forKey: cacheKey)
            return parse(data)
        } catch {
            print("[RemoteModelIndex] Fetch failed: \(error.localizedDescription)")
            return loadCached()
        }
    }

    private func loadCached() -> [ModelConfig] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        return parse(data)
    }

    private func parse(_ data: Data) -> [ModelConfig] {
        let index: RemoteIndex
        do {
            index = try JSONDecoder().decode(RemoteIndex.self, from: data)
        } catch {
            print("[RemoteModelIndex] Failed to decode index: \(error)")
            return []
        }
        return index.models.compactMap { $0.toModelConfig() }
    }
}

// MARK: - JSON Schema

private struct RemoteIndex: Decodable {
    let version: Int
    let models: [RemoteModelEntry]
}

private struct RemoteModelEntry: Decodable {
    let id: String
    let name: String
    let description: String
    let gameId: String
    let isLatent: Bool
    let config: RemoteConfig
    let denoiser: RemoteDenoiser
    let decoder: RemoteDecoder?
    let paths: RemotePaths

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case gameId = "game_id"
        case isLatent = "is_latent"
        case config, denoiser, decoder, paths
    }

    func toModelConfig() -> ModelConfig {
        let decoderConfig: DecoderConfig? = if let d = decoder {
            DecoderConfig(
                outputH: d.outputH,
                outputW: d.outputW,
                latentScaleMin: d.latentScaleMin,
                latentScaleMax: d.latentScaleMax
            )
        } else {
            nil
        }

        return ModelConfig(
            id: id,
            name: name,
            description: description,
            C: config.C,
            H: config.H,
            W: config.W,
            T: config.T,
            isLatent: isLatent,
            isFP16: false,
            numActions: config.numActions,
            actionNames: config.actionNames,
            defaultAction: config.defaultAction,
            denoiser: DenoiserConfig(
                numSteps: denoiser.numSteps,
                sigmaMin: denoiser.sigmaMin,
                sigmaMax: denoiser.sigmaMax
            ),
            decoder: decoderConfig,
            paths: ModelPaths(
                denoiser: paths.denoiser,
                decoder: paths.decoder,
                initState: paths.initState
            ),
            gameId: gameId
        )
    }
}

private struct RemoteConfig: Decodable {
    let C: Int
    let H: Int
    let W: Int
    let T: Int
    let numActions: Int
    let actionNames: [String]
    let defaultAction: Int

    enum CodingKeys: String, CodingKey {
        case C, H, W, T
        case numActions = "num_actions"
        case actionNames = "action_names"
        case defaultAction = "default_action"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        C = try c.decode(Int.self, forKey: .C)
        H = try c.decode(Int.self, forKey: .H)
        W = try c.decode(Int.self, forKey: .W)
        T = try c.decode(Int.self, forKey: .T)
        numActions = try c.decode(Int.self, forKey: .numActions)
        actionNames = try c.decodeIfPresent([String].self, forKey: .actionNames) ?? []
        defaultAction = try c.decodeIfPresent(Int.self, forKey: .defaultAction) ?? 0
    }
}

private struct RemoteDenoiser: Decodable {
    let numSteps: Int
    let sigmaMin: Float
    let sigmaMax: Float

    enum CodingKeys: String, CodingKey {
        case numSteps = "num_steps"
        case sigmaMin = "sigma_min"
        case sigmaMax = "sigma_max"
    }
}

private struct RemoteDecoder: Decodable {
    let outputH: Int
    let outputW: Int
    let latentScaleMin: Float?
    let latentScaleMax: Float?

    enum CodingKeys: String, CodingKey {
        case outputH = "output_h"
        case outputW = "output_w"
        case latentScaleMin = "latent_scale_min"
        case latentScaleMax = "latent_scale_max"
    }
}

private struct RemotePaths: Decodable {
    let denoiser: String
    let decoder: String?
    let initState: String

    enum CodingKeys: String, CodingKey {
        case denoiser, decoder
        case initState = "init_state"
    }
}
