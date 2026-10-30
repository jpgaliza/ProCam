import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Tunables for RAW development. Defaults implement the "clean single frame" philosophy.
struct DevelopSettings: Sendable {
    enum OutputFormat: Sendable { case heic, jpeg }

    /// 0 = no capture sharpening → no halos / digital edges.
    var sharpness: Float = 0
    /// 0 = keep genuine sensor grain.
    var luminanceNoiseReduction: Float = 0
    /// 0 = untouched chroma. Raise to ~0.05–0.1 if high-ISO color blotches are objectionable.
    var colorNoiseReduction: Float = 0
    /// 0 = no local tone mapping (Apple's "Smart HDR-like" local contrast in the RAW decoder).
    var localToneMap: Float = 0
    /// Lens profile correction (distortion/vignetting). Off to match the uncorrected viewfinder.
    var lensCorrection = false
    var outputFormat: OutputFormat = .heic
    var compressionQuality: Double = 0.92
    var thumbnailMaxPixelSize = 240

    static let `default` = DevelopSettings()
}

/// Result of a development: encoded image + a small preview for the UI.
struct DevelopedPhoto {
    let data: Data
    let uniformTypeIdentifier: String
    let thumbnail: UIImage?
}

/// Develops Bayer RAW with `CIRAWFilter`, applies the active look and encodes HEIC/JPEG.
///
/// - Important: Not thread-safe (owns a `ColorPipeline`). Only call from `CameraManager`'s
///   serial processing queue.
final class RAWDeveloper {

    private let context = RenderContext.shared
    private let pipeline = ColorPipeline()
    private let settings: DevelopSettings

    init(settings: DevelopSettings = .default) {
        self.settings = settings
    }

    func develop(_ capture: RAWCapture) throws -> DevelopedPhoto {
        guard let raw = CIRAWFilter(imageData: capture.dngData, identifierHint: UTType.dngIdentifier) else {
            throw CameraError.developFailed("Core Image could not decode the RAW file.")
        }

        // Neutralize every "computational" stage of the RAW decoder.
        if raw.isSharpnessSupported { raw.sharpnessAmount = settings.sharpness }
        if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = settings.luminanceNoiseReduction }
        if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = settings.colorNoiseReduction }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = settings.localToneMap }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = settings.lensCorrection }
        raw.extendedDynamicRangeAmount = 0   // SDR output, identical tone scale to the viewfinder.

        guard let developed = raw.outputImage else {
            throw CameraError.developFailed("RAW decoder produced no image.")
        }

        // Exactly the same look graph as the viewfinder (deterministic grain for stills).
        let graded = pipeline
            .apply(capture.preset, to: developed, grainSeed: nil)
            .settingProperties(Self.outputProperties(from: capture.metadata))

        let (data, uti) = try encode(graded)
        return DevelopedPhoto(data: data, uniformTypeIdentifier: uti, thumbnail: Self.thumbnail(from: data, maxPixelSize: settings.thumbnailMaxPixelSize))
    }

    // MARK: Encoding

    private func encode(_ image: CIImage) throws -> (Data, String) {
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.compressionQuality,
        ]
        let colorSpace = context.outputColorSpace

        if settings.outputFormat == .heic,
           let heic = context.ciContext.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: options) {
            return (heic, UTType.heic.identifier)
        }
        if let jpeg = context.ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) {
            return (jpeg, UTType.jpeg.identifier)
        }
        throw CameraError.developFailed("Failed to encode the developed photo.")
    }

    /// Keeps EXIF/TIFF/GPS but resets orientation: `CIRAWFilter` has already applied it to pixels.
    static func outputProperties(from metadata: [String: Any]) -> [String: Any] {
        var properties: [String: Any] = [:]
        let keep: [CFString] = [
            kCGImagePropertyExifDictionary,
            kCGImagePropertyExifAuxDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyTIFFDictionary,
            kCGImagePropertyMakerAppleDictionary,
        ]
        for key in keep {
            if let value = metadata[key as String] { properties[key as String] = value }
        }
        properties[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation.up.rawValue

        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = CGImagePropertyOrientation.up.rawValue
            tiff[kCGImagePropertyTIFFSoftware as String] = "ProCam"
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        return properties
    }

    /// Hardware-decoded thumbnail from the encoded file (far cheaper than re-rendering the graph).
    static func thumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
