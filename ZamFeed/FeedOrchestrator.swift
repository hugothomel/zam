import SwiftUI

/// Manages the feed of game pages, controlling which pages are loaded/playing/paused/unloaded
/// based on a 3-page memory window around the current page.
@Observable
final class FeedOrchestrator {
    /// Curated feed order — one model ID per page.
    /// Only models with embedded CoreML bundles are included.
    static let feedModelIds: [String] = [
        "tube_runner",               // embedded latent model, loads instantly
        "flappy_bird",               // embedded pixel-space model
        "jurassic",                  // embedded latent model, 3 actions
    ]

    /// One view model per page. Starts with embedded models, remote models appended later.
    private(set) var pages: [FeedViewModel]

    /// Index of the currently visible page.
    private(set) var currentIndex: Int = 0

    init() {
        self.pages = Self.feedModelIds.map { FeedViewModel(modelId: $0) }
    }

    /// Append remote models to the feed. Filters out any model IDs already present.
    func appendRemoteModels(_ modelIds: [String]) {
        let existing = Set(pages.map(\.modelId))
        let newIds = modelIds.filter { !existing.contains($0) }
        guard !newIds.isEmpty else { return }

        let newPages = newIds.map { FeedViewModel(modelId: $0) }
        pages.append(contentsOf: newPages)
        print("[FeedOrchestrator] Appended \(newPages.count) remote pages, total: \(pages.count)")

        // Preload adjacent if new pages are now within window
        updateLifecycles()
    }

    var currentPage: FeedViewModel {
        pages[currentIndex]
    }

    var pageCount: Int { pages.count }

    // MARK: - Navigation

    /// Called when the page view controller finishes a transition.
    func didNavigate(to index: Int) {
        guard index >= 0 && index < pages.count else { return }
        currentIndex = index
        updateLifecycles()
    }

    /// Bootstrap: load + play the first page on app launch.
    func bootstrap() {
        updateLifecycles()
    }

    // MARK: - Memory Window

    /// Enforce the 3-page memory window:
    /// - Current page: playing
    /// - ±1 adjacent: preloaded (paused)
    /// - ±2+ distant: unloaded
    func updateLifecycles() {
        let pageCount = pages.count
        for (i, page) in pages.enumerated() {
            let linearDist = abs(i - currentIndex)
            let distance = min(linearDist, pageCount - linearDist)

            switch distance {
            case 0:
                // Current page — should be playing
                switch page.state {
                case .unloaded:
                    page.load()
                    // Auto-play is triggered by observing state transition to .paused
                    observeAutoPlay(page)
                case .loading:
                    // Started loading as adjacent page — set up auto-play now
                    observeAutoPlay(page)
                case .paused:
                    page.play()
                case .playing:
                    break // Already playing
                case .loadFailed:
                    break // User must tap retry
                }

            case 1:
                // Adjacent page — preloaded but paused
                switch page.state {
                case .unloaded:
                    page.load()
                case .loading:
                    break // Already loading
                case .playing:
                    page.pause()
                case .paused:
                    break // Already in correct state
                case .loadFailed:
                    break
                }

            default:
                // Distant page — unload to free memory
                if page.state != .unloaded {
                    page.unload()
                }
            }
        }
    }

    /// Watch a loading page and auto-play it if it becomes the current page.
    private func observeAutoPlay(_ page: FeedViewModel) {
        Task { @MainActor in
            // Poll until page finishes loading
            while page.state == .loading || page.state == .unloaded {
                try? await Task.sleep(for: .milliseconds(100))
            }

            // If still the current page and now paused, play it
            if page.state == .paused && pages[currentIndex].id == page.id {
                page.play()
            }
        }
    }
}
