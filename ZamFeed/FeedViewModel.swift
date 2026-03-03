import SwiftUI

/// Per-page lifecycle manager. Each page in the feed has its own FeedViewModel.
/// State machine: unloaded → loading → paused ↔ playing, or loadFailed.
@Observable
final class FeedViewModel: Identifiable {
    enum State: Equatable {
        case unloaded
        case loading
        case paused
        case playing
        case loadFailed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.unloaded, .unloaded), (.loading, .loading),
                 (.paused, .paused), (.playing, .playing):
                return true
            case (.loadFailed(let a), .loadFailed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    let id: String
    let modelId: String
    let config: ModelConfig

    private(set) var state: State = .unloaded
    private(set) var downloadProgress: Double = 0

    // Engine components — nil when unloaded
    private(set) var engine: WorldModelEngine?
    private(set) var viewportController: GameViewportController?

    // Model manager persists across load/unload for caching
    let modelManager = ModelManager()

    // Game loop task
    private var gameLoopTask: Task<Void, Never>?
    // In-flight load task — cancelled on unload()
    private var loadTask: Task<Void, Never>?

    // Stored init state for reset
    private var initStateData: Data?

    init(modelId: String) {
        self.id = modelId
        self.modelId = modelId
        self.config = ModelRegistry.config(for: modelId)!
    }

    // MARK: - Lifecycle

    /// Download model, build engine + viewport. Transitions: unloaded/loadFailed → loading → paused.
    /// Heavy work (MLModel loading, engine init, initial frame) runs off MainActor to avoid freezing.
    func load() {
        guard state == .unloaded || state != .loading else { return }
        if case .loadFailed = state {} else if state != .unloaded { return }

        state = .loading
        downloadProgress = 0
        print("[FeedVM:\(modelId)] Loading...")

        loadTask = Task {
            // Observe download progress on MainActor
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    if case .downloading(let p) = self.modelManager.state {
                        self.downloadProgress = p
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }

            await modelManager.loadModel(config)
            progressTask.cancel()
            print("[FeedVM:\(modelId)] ModelManager state: \(modelManager.state)")

            guard !Task.isCancelled else { return }

            guard case .ready(let denoiserURL, let decoderURL, let initStateData) = modelManager.state else {
                if case .error(let msg) = modelManager.state {
                    print("[FeedVM:\(modelId)] Load failed: \(msg)")
                    await MainActor.run { state = .loadFailed(msg) }
                } else {
                    print("[FeedVM:\(modelId)] Load failed: unknown")
                    await MainActor.run { state = .loadFailed("Unknown error") }
                }
                return
            }

            do {
                print("[FeedVM:\(modelId)] Engine starting — denoiser: \(denoiserURL.lastPathComponent), decoder: \(decoderURL?.lastPathComponent ?? "none")")

                // Heavy work OFF MainActor: load MLModels, init engine, decode first frame
                let engine = WorldModelEngine(config: config)
                try engine.load(denoiserURL: denoiserURL, decoderURL: decoderURL)
                try engine.reset(initStateData: initStateData)
                let initialFrame = try engine.currentFrame()

                guard !Task.isCancelled else { return }

                // Hop to MainActor: create viewport (MTKView), assign state
                await MainActor.run {
                    self.initStateData = initStateData
                    self.engine = engine

                    let viewport = GameViewportController()
                    self.viewportController = viewport
                    viewport.displayFrame(data: initialFrame, c: config.outputC, h: config.outputH, w: config.outputW)

                    print("[FeedVM:\(modelId)] Ready — paused")
                    state = .paused
                }
            } catch {
                guard !Task.isCancelled else { return }
                print("[FeedVM:\(modelId)] Engine error: \(error)")
                await MainActor.run { state = .loadFailed(error.localizedDescription) }
            }
        }
    }

    /// Start the game loop. Transition: paused → playing.
    func play() {
        guard state == .paused, let engine, let viewportController else { return }
        state = .playing

        gameLoopTask = Task { @MainActor in
            while !Task.isCancelled && engine.isReady {
                do {
                    let frame = try engine.step()
                    viewportController.displayFrame(
                        data: frame,
                        c: config.outputC,
                        h: config.outputH,
                        w: config.outputW
                    )
                } catch {
                    break
                }
                await Task.yield()
            }
        }
    }

    /// Stop the game loop. Transition: playing → paused.
    func pause() {
        guard state == .playing else { return }
        gameLoopTask?.cancel()
        gameLoopTask = nil
        state = .paused
    }

    /// Release engine + viewport to free memory. Transition: any → unloaded.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        gameLoopTask?.cancel()
        gameLoopTask = nil
        engine = nil
        viewportController = nil
        initStateData = nil
        state = .unloaded
    }

    /// Reset the game to initial state without re-downloading.
    func resetGame() {
        guard let engine, let viewportController, let initStateData else { return }

        let wasPlaying = state == .playing
        pause()

        try? engine.reset(initStateData: initStateData)
        if let frame = try? engine.currentFrame() {
            viewportController.displayFrame(data: frame, c: config.outputC, h: config.outputH, w: config.outputW)
        }

        if wasPlaying {
            play()
        }
    }

    /// Retry loading after failure.
    func retry() {
        state = .unloaded
        load()
    }
}
