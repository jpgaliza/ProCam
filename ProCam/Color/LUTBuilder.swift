import Foundation
import simd

/// A monotone cubic (Fritsch–Carlson) tone curve defined by control points in `0...1`.
/// Monotonicity guarantees no tonal inversions/banding regardless of how points are placed.
struct ToneCurve: Sendable {

    private let xs: [Double]
    private let ys: [Double]
    private let tangents: [Double]

    static let identity = ToneCurve([(0, 0), (1, 1)])

    init(_ points: [(Double, Double)]) {
        precondition(points.count >= 2, "A ToneCurve needs at least two control points.")
        let sorted = points.sorted { $0.0 < $1.0 }
        let xs = sorted.map(\.0)
        let ys = sorted.map(\.1)
        let n = xs.count

        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            secants[i] = (ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], .ulpOfOne)
        }

        var m = [Double](repeating: 0, count: n)
        m[0] = secants[0]
        m[n - 1] = secants[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                m[i] = secants[i - 1] * secants[i] <= 0 ? 0 : (secants[i - 1] + secants[i]) / 2
            }
        }
        for i in 0..<(n - 1) {
            if secants[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            let a = m[i] / secants[i]
            let b = m[i + 1] / secants[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * secants[i]
                m[i + 1] = t * b * secants[i]
            }
        }

        self.xs = xs
        self.ys = ys
        self.tangents = m
    }

    func callAsFunction(_ value: Double) -> Double {
        let x = min(max(value, xs[0]), xs[xs.count - 1])
        var i = 0
        while i < xs.count - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i]
        guard h > 0 else { return ys[i] }
        let t = (x - xs[i]) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * ys[i] + h10 * h * tangents[i] + h01 * ys[i + 1] + h11 * h * tangents[i + 1]
    }
}

/// Declarative description of a look. Compiled once into a 3D LUT by `LUTBuilder`.
/// All math is performed on gamma-encoded Display P3 values in `0...1`.
struct LookRecipe: Sendable {
    /// If set, the image is converted to monochrome with these channel weights (sum ≈ 1)
    /// *before* any other step — emulates panchromatic B&W film + contrast filter.
    var monochromeMix: SIMD3<Double>?
    var masterCurve: ToneCurve = .identity
    var redCurve: ToneCurve = .identity
    var greenCurve: ToneCurve = .identity
    var blueCurve: ToneCurve = .identity
    /// Global saturation multiplier (1 = unchanged).
    var saturation: Double = 1
    /// Extra saturation multiplier applied only to green/foliage hues (1 = unchanged).
    var greenSaturation: Double = 1
    /// Additive tint weighted toward shadows / highlights (small values, e.g. ±0.03).
    var shadowTint: SIMD3<Double> = .zero
    var highlightTint: SIMD3<Double> = .zero
}

/// A baked 3D LUT ready for `CIColorCubeWithColorSpace` (RGBA Float32, red-fastest ordering).
struct ColorCube: Sendable {
    let dimension: Int
    let data: Data
}

enum LUTBuilder {

    static let defaultDimension = 33
    private static let luma = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    static func build(_ recipe: LookRecipe, dimension: Int = defaultDimension) -> ColorCube {
        let count = dimension * dimension * dimension * 4
        var values = [Float](repeating: 0, count: count)
        let scale = 1.0 / Double(dimension - 1)
        var offset = 0
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let input = SIMD3<Double>(Double(r), Double(g), Double(b)) * scale
                    let out = transform(input, recipe)
                    values[offset] = Float(out.x)
                    values[offset + 1] = Float(out.y)
                    values[offset + 2] = Float(out.z)
                    values[offset + 3] = 1
                    offset += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return ColorCube(dimension: dimension, data: data)
    }

    static func identity(dimension: Int = defaultDimension) -> ColorCube {
        build(LookRecipe(), dimension: dimension)
    }

    // MARK: Per-sample transform

    private static func transform(_ input: SIMD3<Double>, _ recipe: LookRecipe) -> SIMD3<Double> {
        var rgb = input

        // 1. Monochrome conversion (channel mixer).
        if let mix = recipe.monochromeMix {
            let l = (rgb * mix).sum()
            rgb = SIMD3(repeating: l)
        }

        // 2. Tone: master curve, then per-channel curves (color casts / crossover).
        rgb = SIMD3(recipe.masterCurve(rgb.x), recipe.masterCurve(rgb.y), recipe.masterCurve(rgb.z))
        rgb = SIMD3(recipe.redCurve(rgb.x), recipe.greenCurve(rgb.y), recipe.blueCurve(rgb.z))

        // 3. Saturation (luma-preserving), with hue-selective control of greens.
        if recipe.monochromeMix == nil {
            let l = (rgb * luma).sum()
            var sat = recipe.saturation
            if recipe.greenSaturation != 1 {
                let weight = greenWeight(rgb)
                sat *= 1 + (recipe.greenSaturation - 1) * weight
            }
            rgb = SIMD3(repeating: l) + (rgb - SIMD3(repeating: l)) * sat
        }

        // 4. Split toning.
        let l = min(max((rgb * luma).sum(), 0), 1)
        let shadowWeight = (1 - l) * (1 - l)
        let highlightWeight = l * l
        rgb += recipe.shadowTint * shadowWeight + recipe.highlightTint * highlightWeight

        return simd_clamp(rgb, .zero, SIMD3(repeating: 1))
    }

    /// 0...1 weight for how "green/foliage" a color is (hue ~70°–170°, scaled by chroma).
    private static func greenWeight(_ rgb: SIMD3<Double>) -> Double {
        let maxC = max(rgb.x, rgb.y, rgb.z)
        let minC = min(rgb.x, rgb.y, rgb.z)
        let chroma = maxC - minC
        guard chroma > 1e-4 else { return 0 }
        var hue: Double
        if maxC == rgb.x {
            hue = 60 * (((rgb.y - rgb.z) / chroma).truncatingRemainder(dividingBy: 6))
        } else if maxC == rgb.y {
            hue = 60 * (((rgb.z - rgb.x) / chroma) + 2)
        } else {
            hue = 60 * (((rgb.x - rgb.y) / chroma) + 4)
        }
        if hue < 0 { hue += 360 }
        let distance = abs(hue - 115)
        let hueWeight = exp(-pow(distance / 45, 2))
        return hueWeight * min(chroma * 2.5, 1)
    }
}

/// Parser for Adobe/Resolve `.cube` 3D LUT files (the de-facto interchange format).
enum CubeFileParser {

    enum ParseError: LocalizedError {
        case missingSize
        case unsupportedSize(Int)
        case wrongEntryCount(expected: Int, found: Int)

        var errorDescription: String? {
            switch self {
            case .missingSize: "LUT_3D_SIZE not found in .cube file."
            case .unsupportedSize(let n): "Unsupported LUT_3D_SIZE \(n) (2...128)."
            case .wrongEntryCount(let e, let f): "Expected \(e) LUT entries, found \(f)."
            }
        }
    }

    static func parse(contentsOf url: URL) throws -> ColorCube {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    static func parse(_ text: String) throws -> ColorCube {
        var dimension: Int?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            switch parts.first {
            case "LUT_3D_SIZE":
                if parts.count > 1, let n = Int(parts[1]) { dimension = n; values.reserveCapacity(n * n * n * 4) }
            case "DOMAIN_MIN" where parts.count == 4:
                domainMin = SIMD3(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0)
            case "DOMAIN_MAX" where parts.count == 4:
                domainMax = SIMD3(Float(parts[1]) ?? 1, Float(parts[2]) ?? 1, Float(parts[3]) ?? 1)
            case "LUT_1D_SIZE", "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                continue
            default:
                guard parts.count == 3,
                      let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else { continue }
                let range = domainMax - domainMin
                let v = (SIMD3(r, g, b) - domainMin) / range
                values.append(contentsOf: [v.x, v.y, v.z, 1])
            }
        }

        guard let n = dimension else { throw ParseError.missingSize }
        guard (2...128).contains(n) else { throw ParseError.unsupportedSize(n) }
        let expected = n * n * n
        guard values.count / 4 == expected else {
            throw ParseError.wrongEntryCount(expected: expected, found: values.count / 4)
        }
        // .cube ordering is red-fastest, identical to CIColorCube.
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return ColorCube(dimension: n, data: data)
    }
}
