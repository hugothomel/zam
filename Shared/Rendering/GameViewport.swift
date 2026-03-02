import SwiftUI
import MetalKit

/// UIViewRepresentable wrapping an MTKView for SwiftUI integration.
struct GameViewport: UIViewRepresentable {
    let renderer: MetalRenderer?
    let outputWidth: Int
    let outputHeight: Int

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.preferredFramesPerSecond = 30
        mtkView.backgroundColor = .black
        mtkView.contentMode = .scaleAspectFit

        // Renderer configures the view's device, delegate, etc.
        // The renderer is already initialized with the view externally.
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Trigger a redraw when frame data is updated
        uiView.setNeedsDisplay()
    }
}

/// Coordinator that owns the MTKView and MetalRenderer together.
@Observable
final class GameViewportController {
    private(set) var renderer: MetalRenderer?
    let mtkView: MTKView

    init() {
        self.mtkView = MTKView()
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.preferredFramesPerSecond = 60
        mtkView.backgroundColor = .black

        self.renderer = MetalRenderer(mtkView: mtkView)
        print("[GameViewport] renderer: \(renderer != nil ? "OK" : "NIL - Metal init failed!")")
    }

    /// Push a new frame to the renderer and trigger display.
    func displayFrame(data: [Float], c: Int, h: Int, w: Int) {
        renderer?.updateFrame(data: data, c: c, h: h, w: w)
        mtkView.setNeedsDisplay()
    }
}

/// UIViewRepresentable that uses the controller's pre-configured MTKView.
struct ManagedGameViewport: UIViewRepresentable {
    let controller: GameViewportController

    func makeUIView(context: Context) -> MTKView {
        controller.mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.setNeedsDisplay()
    }
}
