import SwiftUI

/// Full-screen splash: animated grid background with centered "ZAM!" title.
struct ZamSplashView: View {
    @State private var appeared = false
    @State private var shimmerOffset: CGFloat = -1.5

    var body: some View {
        ZStack {
            Color.black
            GridBackgroundView()

            ZStack {
                // Outer glow layers
                zamText
                    .foregroundStyle(ForgeTheme.cyan.opacity(0.3))
                    .blur(radius: 40)

                zamText
                    .foregroundStyle(ForgeTheme.cyan.opacity(0.5))
                    .blur(radius: 20)

                // Main text with shimmer gradient
                zamText
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: ForgeTheme.cyan, location: shimmerOffset - 0.3),
                                .init(color: .white, location: shimmerOffset),
                                .init(color: ForgeTheme.cyan, location: shimmerOffset + 0.3),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: ForgeTheme.cyan.opacity(0.8), radius: 12)
            }
            .scaleEffect(appeared ? 1.0 : 0.5)
            .opacity(appeared ? 1.0 : 0.0)
            .offset(y: -140)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                appeared = true
            }
            withAnimation(
                .easeInOut(duration: 2.0)
                .repeatForever(autoreverses: false)
            ) {
                shimmerOffset = 1.5
            }
        }
    }

    private var zamText: Text {
        Text("ZAM!")
            .font(.system(size: 72, weight: .black, design: .rounded))
            .kerning(4)
    }
}
