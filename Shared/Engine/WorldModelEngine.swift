import Foundation

/// Port of worldModelEnv.ts — manages observation/action buffers and drives the inference loop.
@Observable
final class WorldModelEngine {
    // MARK: - Public state
    private(set) var isReady = false
    private(set) var fps: Double = 0
    private(set) var stepCount: Int = 0

    // MARK: - Configuration
    let config: ModelConfig

    // MARK: - Buffers
    /// Observation buffer: [T * C * H * W] — rolling window of past frames
    private var obsBuf: [Float]
    /// Action buffer: [T] — rolling window of past actions
    private var actBuf: [Int32]
    /// Copy buffers for passing to sampler (avoids mutation during inference)
    private var prevObsBuf: [Float]
    private var prevActBuf: [Int32]
    /// Current persistent action (held until changed)
    private var currentAction: Int

    // MARK: - Engine components
    private var sampler: DiffusionSampler?
    private var denoiser: CoreMLInference?
    private var latentDecoder: LatentDecoder?

    // MARK: - Dimensions (convenience)
    private let C: Int
    private let H: Int
    private let W: Int
    private let T: Int
    private let frameSize: Int

    // MARK: - Timing
    private var lastStepTime: CFAbsoluteTime = 0

    init(config: ModelConfig) {
        self.config = config
        self.C = config.C
        self.H = config.H
        self.W = config.W
        self.T = config.T
        self.frameSize = config.frameSize
        self.currentAction = config.defaultAction

        self.obsBuf = [Float](repeating: 0, count: T * frameSize)
        self.actBuf = [Int32](repeating: 0, count: T)
        self.prevObsBuf = [Float](repeating: 0, count: T * frameSize)
        self.prevActBuf = [Int32](repeating: 0, count: T)
    }

    // MARK: - Setup

    /// Load CoreML models and prepare engine for inference.
    func load(denoiserURL: URL, decoderURL: URL?) throws {
        // Load denoiser
        let denoiserModel = try CoreMLInference(compiledModelURL: denoiserURL)
        self.denoiser = denoiserModel

        // Load decoder if latent model
        if let decoderURL, let decoderConfig = config.decoder {
            let decoderModel = try CoreMLInference(compiledModelURL: decoderURL)
            let decoder = LatentDecoder(decoder: decoderModel, config: decoderConfig)
            try decoder.prepareBuffers(C: C, H: H, W: W)
            self.latentDecoder = decoder
        }

        // Create sampler and prepare buffers
        let sampler = DiffusionSampler(config: config.denoiser)
        try sampler.prepareBuffers(C: C, H: H, W: W, T: T)
        self.sampler = sampler
    }

    /// Load initial state from JSON data and mark engine as ready.
    func reset(initStateData: Data) throws {
        let initState = try JSONDecoder().decode(InitState.self, from: initStateData)

        // Validate dimensions
        let stateT = initState.T ?? T
        let stateC = initState.C ?? C
        let stateH = initState.H ?? H
        let stateW = initState.W ?? W

        if stateT == T && stateC == C && stateH == H && stateW == W {
            let obsCount = initState.obs_buffer.count
            let actCount = initState.act_buffer.count
            if obsCount == obsBuf.count {
                obsBuf = initState.obs_buffer
            }
            if actCount == actBuf.count {
                actBuf = initState.act_buffer
            }
        } else {
            // Dimension mismatch — zero-initialize
            obsBuf = [Float](repeating: 0, count: T * frameSize)
            actBuf = [Int32](repeating: 0, count: T)
        }

        currentAction = config.defaultAction
        stepCount = 0
        isReady = true
    }

    // MARK: - Input

    /// Set the persistent action (held until changed).
    func inputAction(_ action: Int) {
        currentAction = max(0, min(config.numActions - 1, action))
    }

    // MARK: - Step

    /// Run one inference step: sample next frame, roll buffers.
    /// Returns the output frame (RGB float array) for rendering.
    func step() throws -> [Float] {
        guard let sampler, let denoiser else {
            throw EngineError.modelNotLoaded
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. Set current action in buffer at T-1
        actBuf[T - 1] = Int32(currentAction)

        // 2. Copy buffers for sampler (avoids mutation during inference)
        prevObsBuf = obsBuf
        prevActBuf = actBuf

        // 3. Get last frame pointer for noise initialization
        let lastFrameOffset = (T - 1) * frameSize

        // 4. Run diffusion sampling
        let nextFrame: [Float] = try prevObsBuf.withUnsafeBufferPointer { obsBufPtr in
            try prevActBuf.withUnsafeBufferPointer { actBufPtr in
                let lastFramePtr = UnsafeBufferPointer(
                    start: obsBufPtr.baseAddress! + lastFrameOffset,
                    count: frameSize
                )
                return try sampler.sample(
                    denoiser: denoiser,
                    prevObs: obsBufPtr,
                    prevAct: actBufPtr,
                    lastFrame: lastFramePtr,
                    C: C, H: H, W: W, T: T
                )
            }
        }

        // 5. Roll buffers
        rollBuffers(nextObs: nextFrame, action: Int32(currentAction))

        // 6. Update timing
        stepCount += 1
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        fps = elapsed > 0 ? 1.0 / elapsed : 0

        // 7. Decode if latent model, otherwise return raw frame
        if let latentDecoder {
            return try latentDecoder.decode(latent: nextFrame, C: C, H: H, W: W)
        }

        // If model outputs [0, 255] range, normalize to [-1, 1]
        if let maxVal = nextFrame.max(), maxVal > 2.0 {
            return nextFrame.map { $0 / 127.5 - 1.0 }
        }
        return nextFrame
    }

    /// Get the current (most recent) observation for initial rendering.
    func currentFrame() throws -> [Float] {
        let lastFrameOffset = (T - 1) * frameSize
        let lastFrame = Array(obsBuf[lastFrameOffset..<(lastFrameOffset + frameSize)])

        if let latentDecoder {
            return try latentDecoder.decode(latent: lastFrame, C: C, H: H, W: W)
        }

        if let maxVal = lastFrame.max(), maxVal > 2.0 {
            return lastFrame.map { $0 / 127.5 - 1.0 }
        }
        return lastFrame
    }

    // MARK: - Private

    /// Roll observation and action buffers left by one slot, append new values.
    private func rollBuffers(nextObs: [Float], action: Int32) {
        // Roll obs: [f0, f1, f2, f3] → [f1, f2, f3, nextObs]
        obsBuf.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.update(
                from: buf.baseAddress!.advanced(by: frameSize),
                count: (T - 1) * frameSize
            )
        }
        obsBuf.replaceSubrange((T - 1) * frameSize..<T * frameSize, with: nextObs)

        // Roll actions: [a0, a1, a2, a3] → [a1, a2, a3, action]
        actBuf.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.update(
                from: buf.baseAddress!.advanced(by: 1),
                count: T - 1
            )
        }
        actBuf[T - 1] = action
    }
}
