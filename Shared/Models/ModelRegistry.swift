import Foundation

final class ModelRegistry: @unchecked Sendable {
    static let shared = ModelRegistry()

    // MARK: - GCS base URL
    static let gcsBase = "https://storage.googleapis.com/alakazam-models/coreml"

    // MARK: - Embedded demo model ID
    static let embeddedModelId = "tube_runner"

    // MARK: - Dynamic models from remote index
    private var dynamicModels: [String: ModelConfig] = [:]
    private var dynamicGames: [GameDefinition] = []

    // MARK: - Action name sets
    private static let embeddedDemoActions = ["NOOP", "LEFT", "RIGHT"]
    private static let doomActions = ["NOOP", "FORWARD", "TURN_LEFT", "TURN_RIGHT", "STRAFE_LEFT", "STRAFE_RIGHT", "ATTACK", "USE"]
    private static let flappyActions = ["NOOP", "FLAP"]
    private static let anamnesisActions = ["NOOP", "FORWARD", "BACKWARD", "TURN_LEFT", "TURN_RIGHT", "ATTACK"]
    private static let mercuryActions = ["NOOP", "FORWARD", "BACKWARD", "LEFT", "RIGHT", "ATTACK"]
    private static let knightfallActions = ["NOOP", "FORWARD", "BACKWARD", "LEFT", "RIGHT", "ATTACK", "HOLD"]
    private static let jurassicActions = ["NOOP", "LEFT", "RIGHT"]
    private static let tubeActions = ["NOOP", "HOLD"]
    private static let spaceActions = ["NOOP", "FORWARD", "LEFT", "RIGHT", "SHOOT"]

    // MARK: - All models
    static let allModels: [String: ModelConfig] = {
        var m: [String: ModelConfig] = [:]
        for config in allModelsList { m[config.id] = config }
        return m
    }()

    static let allModelsList: [ModelConfig] = [
        // --- Embedded Demo (shipped in binary) ---
        ModelConfig(
            id: "embedded_demo",
            name: "Demo",
            description: "Embedded demo model (pixel-space, 64x64)",
            C: 3, H: 64, W: 64, T: 4,
            isLatent: false, isFP16: false,
            numActions: 3, actionNames: embeddedDemoActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 2, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: nil,
            paths: ModelPaths(denoiser: "", initState: ""),
            gameId: "demo"
        ),

        // --- Doom ---
        ModelConfig(
            id: "doom_defend_line",
            name: "DOOM Defend the Line",
            description: "Doom defend the line scenario (pixel-space, diffusion)",
            C: 3, H: 48, W: 64, T: 4,
            isLatent: false, isFP16: false,
            numActions: 8, actionNames: doomActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 2, sigmaMin: 0.002, sigmaMax: 5.0, obsInputName: "obs", actInputName: "act", hasSigmaCond: true),
            decoder: nil,
            paths: ModelPaths(denoiser: "\(gcsBase)/doom_defend_line/denoiser.mlmodelc", initState: "\(gcsBase)/doom_defend_line/init_state.json"),
            gameId: "doom"
        ),

        // --- Flappy Bird ---
        ModelConfig(
            id: "flappy_bird",
            name: "Flappy Bird",
            description: "Flappy Bird (pixel-space)",
            C: 3, H: 64, W: 64, T: 4,
            isLatent: false, isFP16: false,
            numActions: 2, actionNames: flappyActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 2, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: nil,
            paths: ModelPaths(denoiser: "\(gcsBase)/flappy_bird/denoiser.mlmodelc", initState: "\(gcsBase)/flappy_bird/init_state.json"),
            gameId: "flappy_bird"
        ),

        // --- Anamnesis (pixel) ---
        ModelConfig(
            id: "anamnesis",
            name: "Anamnesis",
            description: "Anamnesis (pixel-space, 64x64)",
            C: 3, H: 64, W: 64, T: 4,
            isLatent: false, isFP16: false,
            numActions: 6, actionNames: anamnesisActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 2, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: nil,
            paths: ModelPaths(denoiser: "\(gcsBase)/anamnesis/denoiser.mlmodelc", initState: "\(gcsBase)/anamnesis/init_state.json"),
            gameId: "anamnesis"
        ),

        // --- Anamnesis Latent ---
        ModelConfig(
            id: "anamnesis_latent",
            name: "Anamnesis Latent",
            description: "Anamnesis (latent-space, decoder to 256x256)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 6, actionNames: anamnesisActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 2, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256),
            paths: ModelPaths(denoiser: "\(gcsBase)/anamnesis_latent/denoiser.mlmodelc", decoder: "\(gcsBase)/anamnesis_latent/decoder.mlmodelc", initState: "\(gcsBase)/anamnesis_latent/init_state.json"),
            gameId: "anamnesis"
        ),

        // --- Anamnesis Small ---
        ModelConfig(
            id: "anamnesis_small",
            name: "Anamnesis Small",
            description: "Anamnesis small variant (latent)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 6, actionNames: anamnesisActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 2, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256),
            paths: ModelPaths(denoiser: "\(gcsBase)/anamnesis_small/denoiser.mlmodelc", decoder: "\(gcsBase)/anamnesis_small/decoder.mlmodelc", initState: "\(gcsBase)/anamnesis_small/init_state.json"),
            gameId: "anamnesis"
        ),

        // --- Anamnesis Tiny ---
        ModelConfig(
            id: "anamnesis_tiny",
            name: "Anamnesis Tiny",
            description: "Anamnesis tiny variant (latent)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 6, actionNames: anamnesisActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 2, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256),
            paths: ModelPaths(denoiser: "\(gcsBase)/anamnesis_tiny/denoiser.mlmodelc", decoder: "\(gcsBase)/anamnesis_tiny/decoder.mlmodelc", initState: "\(gcsBase)/anamnesis_tiny/init_state.json"),
            gameId: "anamnesis"
        ),

        // --- Anamnesis Consistency (1-step) ---
        ModelConfig(
            id: "anamnesis_consistency",
            name: "Anamnesis Consistency",
            description: "Anamnesis consistency-distilled (1-step, latent)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 6, actionNames: anamnesisActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256),
            paths: ModelPaths(denoiser: "\(gcsBase)/anamnesis_consistency/denoiser.mlmodelc", decoder: "\(gcsBase)/anamnesis_consistency/decoder.mlmodelc", initState: "\(gcsBase)/anamnesis_consistency/init_state.json"),
            gameId: "anamnesis"
        ),

        // --- Anamnesis Small Distill ---
        ModelConfig(
            id: "anamnesis_small_distill",
            name: "Anamnesis Small Distill",
            description: "Anamnesis small distilled (1-step, latent)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 6, actionNames: anamnesisActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256),
            paths: ModelPaths(denoiser: "\(gcsBase)/anamnesis_small_distill/denoiser.mlmodelc", decoder: "\(gcsBase)/anamnesis_small_distill/decoder.mlmodelc", initState: "\(gcsBase)/anamnesis_small_distill/init_state.json"),
            gameId: "anamnesis"
        ),

        // --- Mercury Flow Consistency ---
        ModelConfig(
            id: "mercury_flow_consistency",
            name: "Mercury Flow",
            description: "Mercury Flow consistency (1-step, latent)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 6, actionNames: mercuryActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256, latentScaleMin: -4.397, latentScaleMax: 11.336),
            paths: ModelPaths(denoiser: "\(gcsBase)/mercury_flow_consistency/denoiser.mlmodelc", decoder: "\(gcsBase)/mercury_flow_consistency/decoder.mlmodelc", initState: "\(gcsBase)/mercury_flow_consistency/init_state.json"),
            gameId: "mercury_flow"
        ),

        // --- Mercury Flow Consistency FP16 ---
        ModelConfig(
            id: "mercury_flow_consistency_fp16",
            name: "Mercury Flow FP16",
            description: "Mercury Flow consistency FP16 (1-step, latent)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: true,
            numActions: 6, actionNames: mercuryActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256, latentScaleMin: -4.397, latentScaleMax: 11.336),
            paths: ModelPaths(denoiser: "\(gcsBase)/mercury_flow_consistency_fp16/denoiser.mlmodelc", decoder: "\(gcsBase)/mercury_flow_consistency_fp16/decoder.mlmodelc", initState: "\(gcsBase)/mercury_flow_consistency_fp16/init_state.json"),
            gameId: "mercury_flow"
        ),

        // --- Knightfall ---
        ModelConfig(
            id: "knightfall_002",
            name: "Knightfall",
            description: "Knightfall (latent, decoder to 512x512)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 7, actionNames: knightfallActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 512, outputW: 512, latentScaleMin: -18.9, latentScaleMax: 15.7),
            paths: ModelPaths(denoiser: "\(gcsBase)/knightfall_002/denoiser.mlmodelc", decoder: "\(gcsBase)/knightfall_002/decoder.mlmodelc", initState: "\(gcsBase)/knightfall_002/init_state.json"),
            gameId: "knightfall"
        ),

        // --- Jurassic ---
        ModelConfig(
            id: "jurassic",
            name: "Jurassic",
            description: "Jurassic (latent, 1-step consistency, decoder to 256x256)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 3, actionNames: jurassicActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256, latentScaleMin: -8.824, latentScaleMax: 9.229),
            paths: ModelPaths(denoiser: "\(gcsBase)/jurassic/denoiser.mlmodelc", decoder: "\(gcsBase)/jurassic/decoder.mlmodelc", initState: "\(gcsBase)/jurassic/init_state.json"),
            gameId: "jurassic"
        ),

        // --- Tube Runner (Mercury Flow HD 512) ---
        ModelConfig(
            id: "tube_runner",
            name: "Tube Runner",
            description: "Mercury Flow HD 512 (latent, 1-step consistency)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 2, actionNames: tubeActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 512, outputW: 512, latentScaleMin: -32.577, latentScaleMax: 26.275),
            paths: ModelPaths(denoiser: "\(gcsBase)/tube_runner/denoiser.mlmodelc", decoder: "\(gcsBase)/tube_runner/decoder.mlmodelc", initState: "\(gcsBase)/tube_runner/init_state.json"),
            gameId: "tube_runner"
        ),

        // --- Tube Runner FP16 ---
        ModelConfig(
            id: "tube_runner_fp16",
            name: "Tube Runner FP16",
            description: "Tube Runner FP16 (latent)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: true,
            numActions: 3, actionNames: tubeActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256, latentScaleMin: -32.577, latentScaleMax: 26.275),
            paths: ModelPaths(denoiser: "\(gcsBase)/tube_runner_fp16/denoiser.mlmodelc", decoder: "\(gcsBase)/tube_runner_fp16/decoder.mlmodelc", initState: "\(gcsBase)/tube_runner_fp16/init_state.json"),
            gameId: "tube_runner"
        ),

        // --- Space Shooter ---
        ModelConfig(
            id: "space_shooter",
            name: "Space Shooter",
            description: "Space Shooter (latent, consistency 1-step)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 5, actionNames: spaceActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256),
            paths: ModelPaths(denoiser: "\(gcsBase)/space_shooter/denoiser.mlmodelc", decoder: "\(gcsBase)/space_shooter/decoder.mlmodelc", initState: "\(gcsBase)/space_shooter/init_state.json"),
            gameId: "space_shooter"
        ),

        // --- Space Shooter GCS ---
        ModelConfig(
            id: "space_shooter_gcs",
            name: "Space Shooter (GCS)",
            description: "Space Shooter from GCS (latent, consistency 1-step)",
            C: 4, H: 64, W: 64, T: 4,
            isLatent: true, isFP16: false,
            numActions: 5, actionNames: spaceActions, defaultAction: 0,
            denoiser: DenoiserConfig(numSteps: 1, sigmaMin: 0.002, sigmaMax: 5.0),
            decoder: DecoderConfig(outputH: 256, outputW: 256),
            paths: ModelPaths(denoiser: "\(gcsBase)/space_shooter_gcs/denoiser.mlmodelc", decoder: "\(gcsBase)/space_shooter_gcs/decoder.mlmodelc", initState: "\(gcsBase)/space_shooter_gcs/init_state.json"),
            gameId: "space_shooter"
        ),
    ]

    // MARK: - Game definitions
    static let games: [GameDefinition] = [
        GameDefinition(id: "demo", name: "Demo", description: "Embedded demo", variants: ["embedded_demo"]),
        GameDefinition(id: "doom", name: "DOOM", description: "Defend the line", variants: ["doom_defend_line"]),
        GameDefinition(id: "flappy_bird", name: "Flappy Bird", description: "Flap to survive", variants: ["flappy_bird"]),
        GameDefinition(id: "anamnesis", name: "Anamnesis", description: "First-person exploration", variants: [
            "anamnesis", "anamnesis_latent", "anamnesis_small", "anamnesis_tiny",
            "anamnesis_consistency", "anamnesis_small_distill"
        ]),
        GameDefinition(id: "mercury_flow", name: "Mercury Flow", description: "Action combat", variants: ["mercury_flow_consistency", "mercury_flow_consistency_fp16"]),
        GameDefinition(id: "knightfall", name: "Knightfall", description: "Medieval combat", variants: ["knightfall_002"]),
        GameDefinition(id: "tube_runner", name: "Tube Runner", description: "Endless runner", variants: ["tube_runner", "tube_runner_fp16"]),
        GameDefinition(id: "space_shooter", name: "Space Shooter", description: "Arcade shooter", variants: ["space_shooter", "space_shooter_gcs"]),
        GameDefinition(id: "jurassic", name: "Jurassic", description: "Dinosaur world", variants: ["jurassic"]),
    ]

    // MARK: - Config lookup (dynamic first, then static)

    static func config(for id: String) -> ModelConfig? {
        shared.dynamicModels[id] ?? allModels[id]
    }

    // MARK: - All games including dynamic

    static var allGames: [GameDefinition] {
        var seen = Set(games.map(\.id))
        var result = games
        for game in shared.dynamicGames where !seen.contains(game.id) {
            result.append(game)
            seen.insert(game.id)
        }
        return result
    }

    // MARK: - Merge remote models

    /// Merge remote model configs into the registry.
    /// Skips models that already exist in the static registry.
    /// Returns IDs of newly added models.
    @discardableResult
    static func mergeRemoteModels(_ configs: [ModelConfig]) -> [String] {
        var added: [String] = []
        var gameVariants: [String: [String]] = [:]

        for config in configs {
            guard allModels[config.id] == nil else { continue }
            guard shared.dynamicModels[config.id] == nil else { continue }

            shared.dynamicModels[config.id] = config
            added.append(config.id)
            gameVariants[config.gameId, default: []].append(config.id)
        }

        for (gameId, variantIds) in gameVariants {
            let existsStatic = games.contains { $0.id == gameId }
            let existsDynamic = shared.dynamicGames.contains { $0.id == gameId }

            if !existsStatic && !existsDynamic {
                if let first = variantIds.first, let config = shared.dynamicModels[first] {
                    shared.dynamicGames.append(GameDefinition(
                        id: gameId,
                        name: config.name,
                        description: config.description,
                        variants: variantIds
                    ))
                }
            }
        }

        if !added.isEmpty {
            print("[ModelRegistry] Merged \(added.count) remote models: \(added)")
        }
        return added
    }
}
