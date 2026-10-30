import CoreImage
import Metal

/// Process-wide Metal + Core Image resources.
///
/// A single `CIContext` is shared by the real-time viewfinder and the RAW developer so that
/// compiled CI kernels, LUT textures and pipeline state are reused across both paths.
///
/// The context is created from the `MTLDevice` (not from a command queue) on purpose:
/// - The **preview** encodes into its *own* `MTLCommandQueue` via explicit command buffers
///   (see `PreviewRenderer`), so it is never queued behind a heavy RAW develop.
/// - The **still** path (`heifRepresentation`/`jpegRepresentation`) uses the context's internal queue.
///
/// `CIContext` is thread-safe; `CIFilter` instances are NOT (see `ColorPipeline`).
final class RenderContext: @unchecked Sendable {

    static let shared = RenderContext()

    let device: MTLDevice
    let ciContext: CIContext

    /// Linear, extended-range working space. All filter math happens here.
    let workingColorSpace: CGColorSpace
    /// Output / display space. iPhone 17 panels are Display P3, and RAW develops are wide gamut,
    /// so both the viewfinder and the encoded HEIC use P3 to keep preview == output.
    let outputColorSpace: CGColorSpace

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // Every iOS 17 device (and the Simulator) supports Metal. Reaching this is a platform bug.
            fatalError("ProCam requires a Metal-capable device.")
        }
        guard
            let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
            let output = CGColorSpace(name: CGColorSpace.displayP3)
        else {
            fatalError("Required system color spaces are unavailable.")
        }

        self.device = device
        self.workingColorSpace = working
        self.outputColorSpace = output
        self.ciContext = CIContext(mtlDevice: device, options: [
            .name: "ProCam.Shared",
            .workingColorSpace: working,
            .workingFormat: CIFormat.RGBAh,
            // Video frames are never re-rendered; caching intermediates only wastes memory.
            .cacheIntermediates: false,
            .useSoftwareRenderer: false,
        ])
    }
}
