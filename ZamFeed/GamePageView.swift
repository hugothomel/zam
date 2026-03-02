import SwiftUI

/// Full-screen page for a single game in the feed.
/// Switches between loading, error, and playing states.
struct GamePageView: View {
    let viewModel: FeedViewModel
    let pageIndex: Int
    let totalPages: Int
    var onSwipeUp: (() -> Void)?
    var onSwipeDown: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.state {
            case .unloaded:
                loadingOverlay(progress: 0, status: "Waiting...")

            case .loading:
                loadingOverlay(progress: viewModel.downloadProgress, status: downloadStatus)

            case .paused:
                if let engine = viewModel.engine, let viewport = viewModel.viewportController {
                    PlayerView(
                        engine: engine,
                        viewportController: viewport,
                        onReset: { viewModel.resetGame() },
                        onSwipeUp: onSwipeUp,
                        onSwipeDown: onSwipeDown
                    )
                    pausedOverlay
                }

            case .playing:
                if let engine = viewModel.engine, let viewport = viewModel.viewportController {
                    PlayerView(
                        engine: engine,
                        viewportController: viewport,
                        onReset: { viewModel.resetGame() },
                        onSwipeUp: onSwipeUp,
                        onSwipeDown: onSwipeDown
                    )
                }

            case .loadFailed(let message):
                errorOverlay(message: message)
            }

            // Page indicator
            pageIndicator

            // Swipe hint on first page
            if pageIndex == 0 && viewModel.state == .playing {
                SwipeHintOverlay()
            }
        }
    }

    // MARK: - Loading

    private var downloadStatus: String {
        switch viewModel.modelManager.state {
        case .downloading(let p) where p < 1.0:
            return "Downloading..."
        case .compiling:
            return "Compiling model..."
        default:
            return "Loading..."
        }
    }

    private func loadingOverlay(progress: Double, status: String) -> some View {
        VStack(spacing: 16) {
            Text(viewModel.config.name.uppercased())
                .font(ForgeTheme.titleFont)
                .foregroundStyle(ForgeTheme.cyan)

            Text(status)
                .font(ForgeTheme.bodyFont)
                .foregroundStyle(ForgeTheme.dimWhite)

            if progress > 0 && progress < 1.0 {
                ProgressView(value: progress)
                    .tint(ForgeTheme.cyan)
                    .frame(width: 200)
            } else {
                ProgressView()
                    .tint(ForgeTheme.cyan)
            }
        }
    }

    // MARK: - Paused

    private var pausedOverlay: some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .overlay {
                Image(systemName: "pause.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .allowsHitTesting(false)
    }

    // MARK: - Error

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 16) {
            Text(viewModel.config.name.uppercased())
                .font(ForgeTheme.titleFont)
                .foregroundStyle(ForgeTheme.red)

            Text(message)
                .font(ForgeTheme.captionFont)
                .foregroundStyle(ForgeTheme.dimWhite)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: { viewModel.retry() }) {
                Text("RETRY")
                    .font(ForgeTheme.bodyFont)
                    .foregroundStyle(ForgeTheme.cyan)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .border(ForgeTheme.cyan, width: ForgeTheme.borderWidth)
            }
        }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Circle()
                            .fill(i == pageIndex ? ForgeTheme.cyan : ForgeTheme.dimWhite.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, 40)
            }
        }
    }
}
