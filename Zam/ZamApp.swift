import SwiftUI

@main
struct ZamApp: App {
    @State private var orchestrator = FeedOrchestrator()

    var body: some Scene {
        WindowGroup {
            FeedPageView(orchestrator: orchestrator)
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
