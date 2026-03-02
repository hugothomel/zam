import CoreML
import Foundation

/// Port of decoder.ts — decodes latent tensors to RGB using a CoreML decoder model.
final class LatentDecoder: @unchecked Sendable {
    private let decoder: CoreMLInference
    private let decoderConfig: DecoderConfig

    // Reusable MLMultiArray for decoder input
    private var mlLatent: MLMultiArray?

    init(decoder: CoreMLInference, config: DecoderConfig) {
        self.decoder = decoder
        self.decoderConfig = config
    }

    /// Pre-allocate input buffer for given latent dimensions.
    func prepareBuffers(C: Int, H: Int, W: Int) throws {
        mlLatent = try CoreMLInference.makeArray(shape: [1, C, H, W])
    }

    /// Decode a latent tensor [C, H, W] to RGB [3, outputH, outputW].
    /// - Parameters:
    ///   - latent: Float array of latent values [C*H*W]
    ///   - C, H, W: Latent dimensions
    /// - Returns: RGB float array [3 * outputH * outputW] in [-1, 1]
    func decode(latent: [Float], C: Int, H: Int, W: Int) throws -> [Float] {
        guard let mlLatent else {
            throw EngineError.buffersNotPrepared
        }

        let latentSize = C * H * W

        // Optional latent rescaling: [-1, 1] → [min, max]
        if decoderConfig.hasLatentScale,
           let scaleMin = decoderConfig.latentScaleMin,
           let scaleMax = decoderConfig.latentScaleMax {
            let ptr = CoreMLInference.floatPointer(mlLatent)
            for i in 0..<latentSize {
                let normalized = (latent[i] + 1.0) / 2.0 // [-1,1] → [0,1]
                ptr[i] = normalized * (scaleMax - scaleMin) + scaleMin // [0,1] → [min,max]
            }
        } else {
            CoreMLInference.copyToArray(latent, dest: mlLatent)
        }

        // Run decoder
        let feeds: [String: MLMultiArray] = ["latent": mlLatent]
        let output = try decoder.predict(feeds: feeds)

        guard let rgbArray = output.featureValue(for: "rgb")?.multiArrayValue else {
            throw EngineError.missingOutput("rgb")
        }

        return CoreMLInference.extractFloats(from: rgbArray)
    }
}
