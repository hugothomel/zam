import SwiftUI

/// Main game view: Metal viewport + touch controls + HUD overlay.
/// Taps anywhere trigger game actions instantly.
/// Vertical swipes starting in the bottom zone trigger page navigation callbacks.
struct PlayerView: View {
    let engine: WorldModelEngine
    let viewportController: GameViewportController
    let onReset: () -> Void
    var onSwipeUp: (() -> Void)?
    var onSwipeDown: (() -> Void)?

    /// Bottom fraction of screen reserved for swipe-to-page.
    private let swipeZoneFraction: CGFloat = 0.15
    /// Minimum vertical distance to count as a swipe.
    private let swipeThreshold: CGFloat = 50

    @State private var touchStartedInSwipeZone = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Game viewport (Metal)
                ManagedGameViewport(controller: viewportController)
                    .ignoresSafeArea()

                // Full-screen touch overlay
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let swipeZoneY = geo.size.height * (1.0 - swipeZoneFraction)
                                if value.startLocation.y >= swipeZoneY {
                                    // Started in swipe zone — don't send game action
                                    touchStartedInSwipeZone = true
                                } else {
                                    touchStartedInSwipeZone = false
                                    engine.inputAction(1)
                                }
                            }
                            .onEnded { value in
                                if touchStartedInSwipeZone {
                                    // Check for vertical swipe
                                    let dy = value.translation.height
                                    if dy < -swipeThreshold {
                                        onSwipeUp?()
                                    } else if dy > swipeThreshold {
                                        onSwipeDown?()
                                    }
                                }
                                touchStartedInSwipeZone = false
                                engine.inputAction(engine.config.defaultAction)
                            }
                    )
                    .ignoresSafeArea()

                // HUD overlay
                VStack {
                    hudBar
                        .padding(.top, 8)
                        .padding(.horizontal, 16)
                    Spacer()
                }
            }
        }
    }

    // MARK: - HUD

    private var hudBar: some View {
        HStack {
            Text("\(Int(engine.fps)) FPS")
                .font(ForgeTheme.hudFont)
                .foregroundStyle(engine.fps > 10 ? ForgeTheme.green : ForgeTheme.red)
                .shadow(color: .black.opacity(0.6), radius: 3)

            Spacer()
        }
    }
}
