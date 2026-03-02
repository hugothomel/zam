import Foundation

struct DenoiserConfig: Codable, Sendable {
    let numSteps: Int
    let sigmaMin: Float
    let sigmaMax: Float
    let obsInputName: String
    let actInputName: String
    let hasSigmaCond: Bool

    init(
        numSteps: Int,
        sigmaMin: Float = 0.002,
        sigmaMax: Float = 5.0,
        obsInputName: String = "prev_obs",
        actInputName: String = "prev_act",
        hasSigmaCond: Bool = false
    ) {
        self.numSteps = numSteps
        self.sigmaMin = sigmaMin
        self.sigmaMax = sigmaMax
        self.obsInputName = obsInputName
        self.actInputName = actInputName
        self.hasSigmaCond = hasSigmaCond
    }
}

struct DecoderConfig: Codable, Sendable {
    let outputH: Int
    let outputW: Int
    let outputC: Int
    let latentScaleMin: Float?
    let latentScaleMax: Float?

    var hasLatentScale: Bool { latentScaleMin != nil && latentScaleMax != nil }

    init(outputH: Int, outputW: Int, outputC: Int = 3, latentScaleMin: Float? = nil, latentScaleMax: Float? = nil) {
        self.outputH = outputH
        self.outputW = outputW
        self.outputC = outputC
        self.latentScaleMin = latentScaleMin
        self.latentScaleMax = latentScaleMax
    }
}

struct ModelPaths: Codable, Sendable {
    let denoiser: String
    let decoder: String?
    let initState: String

    init(denoiser: String, decoder: String? = nil, initState: String) {
        self.denoiser = denoiser
        self.decoder = decoder
        self.initState = initState
    }
}

struct ModelConfig: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String

    // Tensor dimensions
    let C: Int  // channels (3 for pixel, 4 for latent)
    let H: Int  // height
    let W: Int  // width
    let T: Int  // temporal context

    // Type flags
    let isLatent: Bool
    let isFP16: Bool

    // Actions
    let numActions: Int
    let actionNames: [String]
    let defaultAction: Int

    // Sub-configs
    let denoiser: DenoiserConfig
    let decoder: DecoderConfig?
    let paths: ModelPaths

    // Game grouping
    let gameId: String

    /// Output resolution (after decoding if latent)
    var outputH: Int { decoder?.outputH ?? H }
    var outputW: Int { decoder?.outputW ?? W }
    var outputC: Int { decoder?.outputC ?? 3 }
    var frameSize: Int { C * H * W }
    var outputFrameSize: Int { outputC * outputH * outputW }
}

struct GameDefinition: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let variants: [String]  // model IDs
}
