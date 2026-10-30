import CoreImage
import MetalKit
import SwiftUI
import os

// MARK: - PreviewRenderer

/// Renders graded `CIImage` frames into an `MTKView`'s drawable from the **video data queue**.
///
/// Design notes (read before modifying — see AGENTS.md § Rules):
/// - The `MTKView` is *paused* (`isPaused = true`, `enableSetNeedsDisplay = false`). It is only a
///   host for its `CAMetalLayer` and handles drawable resizing on layout. Frames are pushed by the
///   camera at sensor cadence (up to 60 FPS) instead of being pulled by a display-link, which removes
///   one frame of latency and avoids any cross-thread hand-off of pixel buffers.
/// - `CAMetalLayer.nextDrawable()` and `MTLCommandQueue` are thread-safe, so encoding off the main
///   thread is legal. The layer reference is guarded by a lock because SwiftUI may tear the view down.
/// - A 3-slot semaphore bounds GPU work in flight. If the GPU is behind we **drop** the frame
///   (`wait(timeout: .now())`) rather than block the capture queue.
final class PreviewRenderer: NSObject, @unchecked Sendable {

    private static let maxFramesInFlight = 3

    private let context = RenderContext.shared
    private let commandQueue: MTLCommandQueue
    private let frameSemaphore = DispatchSemaphore(value: PreviewRenderer.maxFramesInFlight)

    private let layerLock = NSLock()
    private var metalLayer: CAMetalLayer?   // guarded by layerLock

    /// Size of the last oriented source frame (used to map taps → device points of interest).
    private let sourceSize = OSAllocatedUnfairLock(initialState: CGSize.zero)

    override init() {
        guard let queue = RenderContext.shared.device.makeCommandQueue() else {
            fatalError("Unable to create the preview Metal command queue.")
        }
        queue.label = "com.procam.preview"
        self.commandQueue = queue
        super.init()
    }

    // MARK: View lifecycle (main thread)

    @MainActor
    func attach(to view: MTKView) {
        view.device = context.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false            // Core Image writes with compute → needs shaderWrite.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.backgroundColor = .black
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let layer = view.layer as? CAMetalLayer else { return }
        layer.colorspace = context.outputColorSpace
        layer.maximumDrawableCount = PreviewRenderer.maxFramesInFlight
        layer.presentsWithTransaction = false

        layerLock.withLock { metalLayer = layer }
    }

    @MainActor
    func detach(from view: MTKView) {
        layerLock.withLock {
            if metalLayer === view.layer { metalLayer = nil }
        }
    }

    // MARK: Rendering (video data queue)

    /// Encodes `image` into the next drawable and presents it. Never blocks.
    /// - Important: Called on the capture video queue. Do not allocate filters, contexts,
    ///   color spaces or textures here.
    func render(_ image: CIImage) {
        sourceSize.withLock { $0 = image.extent.size }

        guard frameSemaphore.wait(timeout: .now()) == .success else { return } // GPU behind → drop.

        guard
            let layer = layerLock.withLock({ metalLayer }),
            let drawable = layer.nextDrawable(),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            frameSemaphore.signal()
            return
        }

        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let filled = Self.aspectFill(image, into: target)

        context.ciContext.render(
            filled,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: target),
            colorSpace: context.outputColorSpace
        )

        let semaphore = frameSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Scales + centers `image` so it fully covers `size` (edge-to-edge, cropping the overflow).
    static func aspectFill(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(
                translationX: (size.width - scaledWidth) / 2,
                y: (size.height - scaledHeight) / 2
            ))
        return image.transformed(by: transform)
    }

    // MARK: Coordinate mapping

    /// Converts a point in the (aspect-filled, portrait) preview view into a capture-device
    /// point of interest (`0...1`, landscape-right sensor space, back camera).
    func devicePoint(forViewPoint point: CGPoint, viewSize: CGSize) -> CGPoint? {
        let source = sourceSize.withLock { $0 }
        guard source.width > 0, source.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return nil
        }
        let scale = max(viewSize.width / source.width, viewSize.height / source.height)
        let displayedWidth = source.width * scale
        let displayedHeight = source.height * scale
        let x = (point.x - (viewSize.width - displayedWidth) / 2) / displayedWidth
        let y = (point.y - (viewSize.height - displayedHeight) / 2) / displayedHeight
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        // Portrait (top-left origin) → landscape-right sensor coordinates.
        return CGPoint(x: y, y: 1 - x)
    }
}

// MARK: - MetalPreviewView

/// SwiftUI host for the live, color-graded viewfinder.
struct MetalPreviewView: UIViewRepresentable {

    let renderer: PreviewRenderer

    func makeCoordinator() -> PreviewRenderer { renderer }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: RenderContext.shared.device)
        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: PreviewRenderer) {
        coordinator.detach(from: uiView)
    }
}
