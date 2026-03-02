import CoreML
import Foundation

/// Port of diffusionSampler.ts — handles sigma schedule computation and Euler ODE sampling.
final class DiffusionSampler: @unchecked Sendable {
    private let config: DenoiserConfig
    private let rho: Float = 7.0

    /// Pre-computed sigma schedule: [numSteps + 1] values, last is 0.
    let sigmas: [Float]

    // Reusable buffers to avoid per-frame allocations
    private var noisyBuf: [Float] = []
    private var denoisedBuf: [Float] = []
    private var derivBuf: [Float] = []

    // Reusable MLMultiArray inputs (allocated once)
    private var mlNoisyNext: MLMultiArray?
    private var mlSigma: MLMultiArray?
    private var mlSigmaCond: MLMultiArray?
    private var mlPrevObs: MLMultiArray?
    private var mlPrevAct: MLMultiArray?

    init(config: DenoiserConfig) {
        self.config = config

        // Compute sigma schedule
        if config.numSteps == 1 {
            // Consistency model: single step [sigmaMax, 0]
            self.sigmas = [config.sigmaMax, 0]
        } else {
            let n = config.numSteps
            let minInv = powf(config.sigmaMin, 1.0 / 7.0)
            let maxInv = powf(config.sigmaMax, 1.0 / 7.0)
            var s = [Float](repeating: 0, count: n + 1)
            for i in 0..<n {
                let l = Float(i) / Float(n - 1)
                s[i] = powf(maxInv + l * (minInv - maxInv), 7.0)
            }
            s[n] = 0
            self.sigmas = s
        }
    }

    /// Pre-allocate reusable buffers for given frame dimensions.
    func prepareBuffers(C: Int, H: Int, W: Int, T: Int) throws {
        let frameSize = C * H * W

        noisyBuf = [Float](repeating: 0, count: frameSize)
        denoisedBuf = [Float](repeating: 0, count: frameSize)
        derivBuf = [Float](repeating: 0, count: frameSize)

        mlNoisyNext = try CoreMLInference.makeArray(shape: [1, C, H, W], dataType: .float32)
        mlSigma = try CoreMLInference.makeArray(shape: [1], dataType: .float32)
        if config.hasSigmaCond {
            mlSigmaCond = try CoreMLInference.makeArray(shape: [1], dataType: .float32)
        }
        mlPrevObs = try CoreMLInference.makeArray(shape: [1, T * C, H, W], dataType: .float32)
        mlPrevAct = try CoreMLInference.makeArray(shape: [1, T], dataType: .float32)
    }

    /// Run the diffusion sampling loop (Euler ODE).
    func sample(
        denoiser: CoreMLInference,
        prevObs: UnsafeBufferPointer<Float>,
        prevAct: UnsafeBufferPointer<Int32>,
        lastFrame: UnsafeBufferPointer<Float>,
        C: Int, H: Int, W: Int, T: Int
    ) throws -> [Float] {
        let frameSize = C * H * W

        // 1. Initialize noisy sample: last frame + gaussian noise * sigma[0]
        let initialSigma = sigmas[0]
        for i in 0..<frameSize {
            let gaussian = boxMullerGaussian()
            noisyBuf[i] = lastFrame[i] + gaussian * initialSigma
        }

        // 2. Copy prev_obs into MLMultiArray
        guard let mlPrevObs, let mlPrevAct else {
            throw EngineError.buffersNotPrepared
        }

        CoreMLInference.copyToArray(prevObs, dest: mlPrevObs)

        // Copy prev_act as Float32
        let actPtr = CoreMLInference.floatPointer(mlPrevAct)
        for i in 0..<T {
            actPtr[i] = Float(prevAct[i])
        }

        // 3. Euler discretization loop
        for i in 0..<(sigmas.count - 1) {
            let sigma = sigmas[i]
            let nextSigma = sigmas[i + 1]

            // Call denoiser
            let den = try denoise(denoiser: denoiser, sigma: sigma, C: C, H: H, W: W)

            // Compute derivative: d = (x - denoised) / sigma
            for j in 0..<frameSize {
                derivBuf[j] = (noisyBuf[j] - den[j]) / sigma
            }

            // Euler step: x = x + d * dt
            let dt = nextSigma - sigma
            for j in 0..<frameSize {
                noisyBuf[j] = noisyBuf[j] + derivBuf[j] * dt
            }
        }

        return noisyBuf
    }

    // MARK: - Private

    /// Call the CoreML denoiser model with current noisy buffer and sigma.
    private func denoise(
        denoiser: CoreMLInference,
        sigma: Float,
        C: Int, H: Int, W: Int
    ) throws -> [Float] {
        guard let mlNoisyNext, let mlSigma, let mlPrevObs, let mlPrevAct else {
            throw EngineError.buffersNotPrepared
        }

        // Set noisy_next_obs
        CoreMLInference.copyToArray(noisyBuf, dest: mlNoisyNext)

        // Set sigma
        CoreMLInference.floatPointer(mlSigma)[0] = sigma

        // Build feeds
        var feeds: [String: MLMultiArray] = [
            "noisy_next_obs": mlNoisyNext,
            "sigma": mlSigma,
            config.obsInputName: mlPrevObs,
            config.actInputName: mlPrevAct,
        ]

        if config.hasSigmaCond, let mlSigmaCond {
            CoreMLInference.floatPointer(mlSigmaCond)[0] = sigma
            feeds["sigma_cond"] = mlSigmaCond
        }

        let output = try denoiser.predict(feeds: feeds)

        // Extract "denoised" output
        guard let denoisedArray = output.featureValue(for: "denoised")?.multiArrayValue else {
            throw EngineError.missingOutput("denoised")
        }

        denoisedBuf = CoreMLInference.extractFloats(from: denoisedArray)

        return denoisedBuf
    }

    /// Box-Muller transform for gaussian random number.
    @inline(__always)
    private func boxMullerGaussian() -> Float {
        let u1 = Float.random(in: Float.leastNormalMagnitude...1.0)
        let u2 = Float.random(in: 0...1)
        return sqrtf(-2.0 * logf(u1)) * cosf(2.0 * .pi * u2)
    }
}

enum EngineError: Error, LocalizedError {
    case buffersNotPrepared
    case missingOutput(String)
    case modelNotLoaded
    case initStateLoadFailed
    case dimensionMismatch

    var errorDescription: String? {
        switch self {
        case .buffersNotPrepared: return "Engine buffers not prepared"
        case .missingOutput(let name): return "Missing model output: \(name)"
        case .modelNotLoaded: return "Model not loaded"
        case .initStateLoadFailed: return "Failed to load init state"
        case .dimensionMismatch: return "Dimension mismatch in init state"
        }
    }
}
