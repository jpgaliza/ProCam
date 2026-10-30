import CoreImage
import CoreImage.CIFilterBuiltins
import os

// MARK: - LUTLibrary

/// Immutable, process-wide cache of baked LUTs (one per `ColorPreset`).
/// Built once (≈ a few ms per preset) and shared by every `ColorPipeline` instance.
final class LUTLibrary: @unchecked Sendable {

    static let shared = LUTLibrary()

    private static let log = Logger(subsystem: "com.procam", category: "LUT")
    private let cubes: [ColorPreset: ColorCube]

    private init() {
        var cubes: [ColorPreset: ColorCube] = [:]
        for preset in ColorPreset.allCases {
            cubes[preset] = Self.load(preset)
        }
        self.cubes = cubes
    }

    func cube(for preset: ColorPreset) -> ColorCube {
        cubes[preset] ?? LUTBuilder.identity()
    }

    private static func load(_ preset: ColorPreset) -> ColorCube {
        switch preset.lutSource {
        case .recipe(let recipe):
            return LUTBuilder.build(recipe)
        case .cubeFile(let name):
            guard let url = Bundle.main.url(forResource: name, withExtension: "cube") else {
                log.error("Missing LUT resource \(name, privacy: .public).cube — using identity.")
                return LUTBuilder.identity()
            }
            do {
                return try CubeFileParser.parse(contentsOf: url)
            } catch {
                log.error("Failed to parse \(name, privacy: .public).cube: \(error.localizedDescription, privacy: .public)")
                return LUTBuilder.identity()
            }
        }
    }
}

// MARK: - ColorPipeline

/// The single source of truth for "what a preset does to pixels".
///
/// The *same* graph — 3D LUT → vignette → film grain — is applied to the 60 FPS viewfinder and to
/// the developed RAW, which is what guarantees WYSIWYG grading.
///
/// - Important: `CIFilter` objects are **not thread-safe**. Each queue owns its own `ColorPipeline`
///   (the video queue has one, the RAW processing queue has another). All filters are created once
///   in `init`; `apply` only rebinds inputs, so it performs no filter/LUT allocation per frame.
final class ColorPipeline {

    /// Width (px) at which grain is drawn 1:1. Larger images get proportionally larger grain so the
    /// texture looks the same on a 1440-px viewfinder frame and on a 3024-px RAW develop.
    static let grainReferenceWidth: CGFloat = 1440

    private struct PresetStage {
        let cube: CIFilter & CIColorCubeWithColorSpace
        let grainRVector: CIVector
        let grainBias: CIVector
    }

    private let stages: [ColorPreset: PresetStage]
    private let noise: CIImage
    private let grainMatrix = CIFilter.colorMatrix()
    private let grainBlend = CIFilter.softLightBlendMode()
    private let vignette = CIFilter.vignetteEffect()
    private let zeroVector = CIVector(x: 0, y: 0, z: 0, w: 0)

    init(library: LUTLibrary = .shared) {
        let colorSpace = RenderContext.shared.outputColorSpace
        var stages: [ColorPreset: PresetStage] = [:]
        for preset in ColorPreset.allCases {
            let lut = library.cube(for: preset)
            let cube = CIFilter.colorCubeWithColorSpace()
            cube.cubeDimension = Float(lut.dimension)
            cube.cubeData = lut.data
            // Apply the LUT on gamma-encoded Display P3 values: perceptual + no gamut clipping.
            cube.colorSpace = colorSpace
            let k = CGFloat(preset.grainAmount)
            stages[preset] = PresetStage(
                cube: cube,
                grainRVector: CIVector(x: k, y: 0, z: 0, w: 0),
                grainBias: CIVector(x: 0.5 - 0.5 * k, y: 0.5 - 0.5 * k, z: 0.5 - 0.5 * k, w: 1)
            )
        }
        self.stages = stages
        self.noise = CIFilter.randomGenerator().outputImage ?? CIImage.empty()
    }

    /// Applies `preset` to `image`.
    /// - Parameter grainSeed: Per-frame seed to animate grain in the viewfinder. Pass `nil` for stills
    ///   (deterministic grain).
    func apply(_ preset: ColorPreset, to image: CIImage, grainSeed: UInt32? = nil) -> CIImage {
        guard let stage = stages[preset] else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0 else { return image }

        // 1. 3D LUT (tone, color, monochrome conversion).
        stage.cube.inputImage = image
        var output = stage.cube.outputImage ?? image

        // 2. Vignette.
        if preset.vignetteIntensity > 0 {
            vignette.inputImage = output
            vignette.center = CGPoint(x: extent.midX, y: extent.midY)
            vignette.radius = Float(hypot(extent.width, extent.height) * 0.42)
            vignette.intensity = Float(preset.vignetteIntensity)
            vignette.falloff = 0.65
            output = vignette.outputImage ?? output
        }

        // 3. Film grain (luminance-only noise, soft-light blended around 50% gray).
        if preset.grainAmount > 0 {
            let scale = max(1, extent.width / Self.grainReferenceWidth)
            var transform = CGAffineTransform(scaleX: scale, y: scale)
            if let seed = grainSeed {
                // Integral offsets → no resampling blur, just a different patch of the noise field.
                let dx = CGFloat(seed & 0x3FF)
                let dy = CGFloat((seed >> 10) & 0x3FF)
                transform = CGAffineTransform(translationX: dx, y: dy).concatenating(transform)
            }
            grainMatrix.inputImage = noise.transformed(by: transform)
            grainMatrix.rVector = stage.grainRVector
            grainMatrix.gVector = stage.grainRVector
            grainMatrix.bVector = stage.grainRVector
            grainMatrix.aVector = zeroVector
            grainMatrix.biasVector = stage.grainBias
            if let grain = grainMatrix.outputImage?.cropped(to: extent) {
                grainBlend.inputImage = grain
                grainBlend.backgroundImage = output
                output = grainBlend.outputImage ?? output
            }
        }

        return output.cropped(to: extent)
    }
}
