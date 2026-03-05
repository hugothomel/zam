import SwiftUI

/// TikTok-style fixed overlay: top tabs, bottom game info + action bar.
/// Stays in place while game pages swipe underneath.
struct FeedOverlayView: View {
    let gameName: String
    let modelDescription: String
    let onReset: () -> Void
    var onRemix: (() -> Void)?
    var onProfile: (() -> Void)?

    var body: some View {
        ZStack {
            // Non-interactive decorative elements
            Group {
                // Top section: tabs
                VStack(spacing: 0) {
                    topTabs
                        .padding(.top, 10)
                    Spacer()
                }

                // Bottom section: game name + tab bar
                VStack(spacing: 0) {
                    Spacer()
                    gameInfo
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
            .allowsHitTesting(false)

            // Bottom bar (interactive — remix + profile are tappable)
            VStack {
                Spacer()
                bottomBar
            }

            // Interactive reset button (top-right)
            VStack {
                HStack {
                    Spacer()
                    Button(action: onReset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(ForgeTheme.orange)
                            .shadow(color: .black.opacity(0.5), radius: 4)
                            .padding(10)
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 12)
                }
                Spacer()
            }
        }
    }

    // MARK: - Top Tabs

    private var topTabs: some View {
        HStack(spacing: 20) {
            tabLabel("Explore", active: false)
            tabLabel("Following", active: false)
            tabLabel("For You", active: true)
        }
    }

    private func tabLabel(_ title: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: active ? .bold : .regular))
                .foregroundStyle(active ? .white : .white.opacity(0.5))

            if active {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 28, height: 2)
            }
        }
    }

    // MARK: - Game Info (bottom, above bar)

    private var gameInfo: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(gameName.uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text(modelDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
            Spacer()
        }
        .padding(.bottom, 60) // space for bottom bar
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            barButton(icon: "house.fill", label: "Home", isActive: true)
            Spacer()
            barButton(icon: "heart.fill", label: "Like")
            Spacer()
            remixButton
            Spacer()
            barButton(icon: "bookmark.fill", label: "Save")
            Spacer()
            Button { onProfile?() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Profile")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.9), .black.opacity(0.7)],
                startPoint: .bottom,
                endPoint: .top
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func barButton(icon: String, label: String, isActive: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(isActive ? .white : .white.opacity(0.5))

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(isActive ? .white : .white.opacity(0.5))
        }
    }

    private var remixButton: some View {
        Button { onRemix?() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(ForgeTheme.cyan)
                    .frame(width: 44, height: 30)

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
            }
        }
    }
}
