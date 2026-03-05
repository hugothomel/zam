import SwiftUI

@main
struct ZamApp: App {
    @State private var orchestrator = FeedOrchestrator()
    @State private var auth = AuthManager()
    @State private var apiClient: ForgeAPIClient?
    @State private var showingSplash = true
    @State private var splashStartTime = Date()

    // Sheet state
    @State private var showLogin = false
    @State private var showProfile = false
    @State private var showWorldSetup = false
    @State private var remixGameId: String?
    @State private var worldSetupConfig = WorldSetupConfig()

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
                        onReset: { orchestrator.currentPage.resetGame() },
                        onRemix: { handleRemix() },
                        onProfile: { handleProfile() }
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
                auth.restoreSession()
                apiClient = ForgeAPIClient(authManager: auth)

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
            .sheet(isPresented: $showLogin) {
                LoginView(auth: auth)
            }
            .sheet(isPresented: $showProfile) {
                if let client = apiClient {
                    ProfileView(auth: auth, apiClient: client)
                }
            }
            .sheet(isPresented: $showWorldSetup) {
                if let client = apiClient, let gameId = remixGameId {
                    WorldSetupView(
                        gameId: gameId,
                        apiClient: client,
                        config: $worldSetupConfig,
                        onBuildStarted: {
                            // Build running in background — user can check profile for status
                        }
                    )
                }
            }
        }
    }

    // MARK: - Splash

    private func dismissSplash() {
        let elapsed = Date().timeIntervalSince(splashStartTime)
        let remaining = max(0, 1.0 - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            withAnimation(.easeOut(duration: 0.5)) {
                showingSplash = false
            }
        }
    }

    // MARK: - Remix Flow

    private func handleRemix() {
        if Self.useMockFork {
            forkAndOpenEditor()
            return
        }

        switch auth.state {
        case .signedIn:
            forkAndOpenEditor()
        case .signedOut, .unknown:
            showLogin = true
            Task {
                while auth.state != .signedIn {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !showLogin { return }
                }
                forkAndOpenEditor()
            }
        }
    }

    /// Set to true to skip Supabase RPC and open WorldSetupView with mock data.
    private static let useMockFork = true

    private func forkAndOpenEditor() {
        if Self.useMockFork {
            openMockEditor()
            return
        }

        guard let client = apiClient, let userId = auth.userId else { return }

        let gameId = orchestrator.currentPage.config.gameId

        // Look up the sourceGraphId from the game definition
        guard let game = ModelRegistry.allGames.first(where: { $0.id == gameId }),
              let sourceGraphId = game.sourceGraphId else {
            print("[Remix] No sourceGraphId for game: \(gameId)")
            return
        }

        let remixName = "\(game.name) Remix \(Int(Date().timeIntervalSince1970))"

        Task {
            do {
                print("[Remix] Forking via Supabase RPC: sourceGraphId=\(sourceGraphId), userId=\(userId), name=\(remixName)")

                let response = try await auth.client.rpc(
                    "fork_graph",
                    params: [
                        "p_source_graph_id": sourceGraphId,
                        "p_user_id": userId,
                        "p_name": remixName,
                    ]
                ).execute()

                let forkResult = try JSONDecoder().decode(ForkGraphResponse.self, from: response.data)
                print("[Remix] Forked graph ID: \(forkResult.id)")
                remixGameId = forkResult.id

                worldSetupConfig = WorldSetupConfig.from(configData: forkResult.configData)

                if worldSetupConfig.gameName.isEmpty {
                    worldSetupConfig.gameName = forkResult.name ?? remixName
                }

                showWorldSetup = true
            } catch {
                print("[Remix] Fork failed (RPC path): \(error)")
            }
        }
    }

    private func openMockEditor() {
        let gameName = orchestrator.currentPage.config.name
        remixGameId = "mock-\(UUID().uuidString.prefix(8))"
        worldSetupConfig = WorldSetupConfig(
            gameName: "\(gameName) Remix",
            cameraType: "third_person",
            style: "3D stylized low-poly with vibrant neon colors, glowing edges, and smooth shading. Sci-fi aesthetic with metallic surfaces.",
            character: "A small geometric spacecraft/pod that morphs and shifts shape. Chrome-like reflective surface with cyan energy trails.",
            world: "An endless procedural tunnel with hexagonal walls, laser obstacles, and energy gates. Deep space backdrop visible through gaps.",
            actions: [
                GameAction(name: "noop"),
                GameAction(name: "hold", keyBinding: "space"),
            ]
        )
        showWorldSetup = true
    }

    // MARK: - Profile

    private func handleProfile() {
        switch auth.state {
        case .signedIn:
            showProfile = true
        case .signedOut, .unknown:
            showLogin = true
        }
    }
}
