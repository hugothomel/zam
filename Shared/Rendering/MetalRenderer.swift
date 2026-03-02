import Metal
import MetalKit
import Foundation

/// Renders Float32 CHW image data to an MTKView via Metal.
/// Uses a compute shader to convert CHW [-1,1] → RGBA on the GPU.
final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let computePipeline: MTLComputePipelineState
    private var texture: MTLTexture?
    private var floatBuffer: MTLBuffer?

    // Current frame dimensions
    private var frameWidth: Int = 0
    private var frameHeight: Int = 0

    // Viewport params for aspect ratio
    private struct ViewportParams {
        var scaleX: Float = 1.0
        var scaleY: Float = 1.0
    }
    private var viewportParams = ViewportParams()
    private var viewportSize: CGSize = .zero

    // Compute shader params
    private struct FrameParams {
        var width: Int32 = 0
        var height: Int32 = 0
        var channels: Int32 = 3
    }

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        // Render pipeline
        guard let vertexFn = library.makeFunction(name: "vertexShader"),
              let fragmentFn = library.makeFunction(name: "fragmentShader") else {
            return nil
        }
        let renderDesc = MTLRenderPipelineDescriptor()
        renderDesc.vertexFunction = vertexFn
        renderDesc.fragmentFunction = fragmentFn
        renderDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        // Compute pipeline
        guard let computeFn = library.makeFunction(name: "chwToRGBA") else {
            return nil
        }

        do {
            self.renderPipeline = try device.makeRenderPipelineState(descriptor: renderDesc)
            self.computePipeline = try device.makeComputePipelineState(function: computeFn)
        } catch {
            return nil
        }

        super.init()
        mtkView.delegate = self
    }

    // MARK: - Frame Update

    /// Update the texture with new CHW float data (GPU conversion).
    func updateFrame(data: [Float], c: Int, h: Int, w: Int) {
        // Recreate texture and buffer if dimensions changed
        if w != frameWidth || h != frameHeight {
            frameWidth = w
            frameHeight = h

            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: w,
                height: h,
                mipmapped: false
            )
            texDesc.usage = [.shaderRead, .shaderWrite]
            texture = device.makeTexture(descriptor: texDesc)

            let bufferSize = c * h * w * MemoryLayout<Float>.size
            floatBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)

            updateViewportParams()
        }

        guard let texture, let floatBuffer else { return }

        // Copy float data to GPU buffer
        let byteCount = min(data.count * MemoryLayout<Float>.size, floatBuffer.length)
        data.withUnsafeBytes { src in
            _ = memcpy(floatBuffer.contents(), src.baseAddress!, byteCount)
        }

        // Dispatch compute shader to convert CHW → RGBA on GPU
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }

        var params = FrameParams(width: Int32(w), height: Int32(h), channels: Int32(c))

        computeEncoder.setComputePipelineState(computePipeline)
        computeEncoder.setBuffer(floatBuffer, offset: 0, index: 0)
        computeEncoder.setBytes(&params, length: MemoryLayout<FrameParams>.size, index: 1)
        computeEncoder.setTexture(texture, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (w + 15) / 16,
            height: (h + 15) / 16,
            depth: 1
        )
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size
        updateViewportParams()
    }

    func draw(in view: MTKView) {
        guard let texture,
              let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        else { return }

        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBytes(&viewportParams, length: MemoryLayout<ViewportParams>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Helpers

    private func updateViewportParams() {
        guard frameWidth > 0, frameHeight > 0, viewportSize.width > 0, viewportSize.height > 0 else {
            viewportParams = ViewportParams(scaleX: 1.0, scaleY: 1.0)
            return
        }

        let texAspect = Float(frameWidth) / Float(frameHeight)
        let viewAspect = Float(viewportSize.width) / Float(viewportSize.height)

        if texAspect > viewAspect {
            viewportParams = ViewportParams(scaleX: 1.0, scaleY: viewAspect / texAspect)
        } else {
            viewportParams = ViewportParams(scaleX: texAspect / viewAspect, scaleY: 1.0)
        }
    }
}
