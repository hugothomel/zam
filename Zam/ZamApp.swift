import SwiftUI

@main
struct ZamApp: App {
    @State private var orchestrator = FeedOrchestrator()
    @State private var showingSplash = true
    @State private var splashStartTime = Date()

    var body: some Scene {
        WindowGroup {
            ZStack {
                FeedPageView(orchestrator: orchestrator)
                    .ignoresSafeArea()

                // Fixed overlay — stays in place while games swipe underneath
                if !showingSplash {
                    FeedOverlayView(
                        gameName: orchestrator.currentPage.config.name,
                        modelDescription: orchestrator.currentPage.config.description,
                        onReset: { orchestrator.currentPage.resetGame() }
                    )
                }

                if showingSplash {
                    ZamSplashView()
                        .transition(.opacity)
                }
            }
            .preferredColorScheme(.dark)
            .statusBarHidden()
            .task {
                let configs = await RemoteModelIndex.shared.fetch()
                if !configs.isEmpty {
                    let added = ModelRegistry.mergeRemoteModels(configs)
                    if !added.isEmpty {
                        orchestrator.appendRemoteModels(added)
                    }
                }
            }
            .onChange(of: orchestrator.currentPage.state) { _, newState in
                guard showingSplash else { return }
                if newState == .paused || newState == .playing {
                    dismissSplash()
                }
            }
        }
    }

    private func dismissSplash() {
        let elapsed = Date().timeIntervalSince(splashStartTime)
        let remaining = max(0, 1.0 - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            withAnimation(.easeOut(duration: 0.5)) {
                showingSplash = false
            }
        }
    }
}
