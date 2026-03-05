import SwiftUI

/// User profile sheet — email, sign-out, user's games with build status.
struct ProfileView: View {
    let auth: AuthManager
    let apiClient: ForgeAPIClient

    @Environment(\.dismiss) private var dismiss

    @State private var games: [GameSummary] = []
    @State private var buildStatuses: [String: BuildStatus] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // User info
                VStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(ForgeTheme.cyan)

                    Text(auth.userEmail ?? "—")
                        .font(ForgeTheme.bodyFont)
                        .foregroundStyle(ForgeTheme.white)

                    Button {
                        Task {
                            await auth.signOut()
                            dismiss()
                        }
                    } label: {
                        Text("SIGN OUT")
                            .font(ForgeTheme.captionFont)
                            .foregroundStyle(ForgeTheme.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .border(ForgeTheme.red.opacity(0.5), width: 1)
                    }
                }
                .padding(.vertical, 20)

                Divider().background(ForgeTheme.border)

                // Games list
                if isLoading {
                    Spacer()
                    ProgressView().tint(ForgeTheme.cyan)
                    Spacer()
                } else if let error = errorMessage {
                    Spacer()
                    Text(error)
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.red)
                        .padding()
                    Spacer()
                } else if games.isEmpty {
                    Spacer()
                    Text("No games yet")
                        .font(ForgeTheme.bodyFont)
                        .foregroundStyle(ForgeTheme.dimWhite)
                    Text("Remix a game to get started!")
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.dimWhite)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(games) { game in
                                gameRow(game)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(ForgeTheme.background.ignoresSafeArea())
            .navigationTitle("PROFILE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.dimWhite)
                }
            }
        }
        .task { await loadGames() }
    }

    private func gameRow(_ game: GameSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name)
                    .font(ForgeTheme.bodyFont)
                    .foregroundStyle(ForgeTheme.white)

                if game.forkedFromId != nil {
                    Text("Remix")
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.dimWhite)
                }
            }

            Spacer()

            buildStatusBadge(for: game.id)
        }
        .padding(12)
        .background(ForgeTheme.surface)
        .border(ForgeTheme.border, width: 1)
    }

    @ViewBuilder
    private func buildStatusBadge(for gameId: String) -> some View {
        if let status = buildStatuses[gameId] {
            switch status.status {
            case "running":
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(ForgeTheme.orange)
                    Text(status.stage ?? "building")
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(ForgeTheme.orange)
                }
            case "completed":
                Text("READY")
                    .font(ForgeTheme.captionFont)
                    .foregroundStyle(ForgeTheme.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .border(ForgeTheme.green.opacity(0.5), width: 1)
            case "failed":
                Text("FAILED")
                    .font(ForgeTheme.captionFont)
                    .foregroundStyle(ForgeTheme.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .border(ForgeTheme.red.opacity(0.5), width: 1)
            default:
                EmptyView()
            }
        }
    }

    private func loadGames() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await apiClient.listUserGames()
            games = response.games

            for game in games {
                if let status = try? await apiClient.getBuildStatus(gameId: game.id) {
                    buildStatuses[game.id] = status
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
