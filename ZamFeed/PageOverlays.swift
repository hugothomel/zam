import SwiftUI

/// Swipe hint overlay shown on the first page, auto-dismisses after 3 seconds.
struct SwipeHintOverlay: View {
    @State private var visible = true

    var body: some View {
        if visible {
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))

                    Text("SWIPE UP FOR MORE")
                        .font(ForgeTheme.captionFont)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.bottom, 80)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeOut(duration: 0.5)) {
                    visible = false
                }
            }
        }
    }
}
