import Foundation

/// Where a preset's 3D LUT comes from.
enum LUTSource: Sendable {
    /// Procedurally generated from a `LookRecipe` at launch (no assets needed).
    case recipe(LookRecipe)
    /// A `.cube` file bundled in the app (e.g. `Resources/LUTs/MyLook.cube` → `"MyLook"`).
    case cubeFile(name: String)
}

/// The catalogue of looks. Adding a case here is the *only* place a new look must be declared;
/// both the live viewfinder and the RAW developer pick it up automatically.
/// See AGENTS.md § "Adding New Presets/LUTs".
enum ColorPreset: String, CaseIterable, Identifiable, Sendable {
    case naturalFilm
    case monochromeContrast
    case warmStreet

    var id: String { rawValue }

    /// Long name for status text.
    var displayName: String {
        switch self {
        case .naturalFilm: "Natural Film"
        case .monochromeContrast: "Monochrome"
        case .warmStreet: "Warm Street"
        }
    }

    /// Short label for the pill selector.
    var shortName: String {
        switch self {
        case .naturalFilm: "NAT"
        case .monochromeContrast: "MONO"
        case .warmStreet: "STREET"
        }
    }

    /// Film-grain strength (0 = none). Grain is resolution-relative so preview == still.
    var grainAmount: Double {
        switch self {
        case .naturalFilm: 0.035
        case .monochromeContrast: 0.07
        case .warmStreet: 0.03
        }
    }

    /// Optical vignette intensity (0 = none).
    var vignetteIntensity: Double {
        switch self {
        case .naturalFilm: 0.0
        case .monochromeContrast: 0.35
        case .warmStreet: 0.25
        }
    }

    var lutSource: LUTSource {
        switch self {
        case .naturalFilm: .recipe(.naturalFilm)
        case .monochromeContrast: .recipe(.monochromeContrast)
        case .warmStreet: .recipe(.warmStreet)
        }
    }
}

// MARK: - Look recipes

extension LookRecipe {

    /// Kodak Portra-inspired: soft shoulder, lifted blacks, gentle warmth, restrained saturation.
    static let naturalFilm = LookRecipe(
        masterCurve: ToneCurve([
            (0.00, 0.045),  // lifted, milky blacks
            (0.15, 0.165),
            (0.50, 0.515),
            (0.80, 0.800),
            (0.93, 0.890),  // long, soft highlight roll-off
            (1.00, 0.945),
        ]),
        redCurve: ToneCurve([(0, 0), (0.5, 0.512), (1, 1)]),
        greenCurve: .identity,
        blueCurve: ToneCurve([(0, 0.015), (0.5, 0.492), (1, 0.975)]),
        saturation: 0.88,
        greenSaturation: 0.9,
        shadowTint: SIMD3(-0.004, 0.004, 0.010),   // faintly cool shadows
        highlightTint: SIMD3(0.012, 0.006, -0.008)  // creamy highlights for skin
    )

    /// Leica Monochrom / Tri-X-inspired: yellow-filter mix, deep blacks, open mids, bright whites.
    static let monochromeContrast = LookRecipe(
        monochromeMix: SIMD3(0.36, 0.50, 0.14),
        masterCurve: ToneCurve([
            (0.00, 0.000),
            (0.06, 0.012),  // crushed, inky blacks
            (0.22, 0.160),
            (0.50, 0.500),
            (0.76, 0.810),
            (0.92, 0.955),
            (1.00, 1.000),
        ])
    )

    /// Ricoh GR Positive / Fuji Classic Chrome-inspired: golden cast, muted greens, punchy contrast.
    static let warmStreet = LookRecipe(
        masterCurve: ToneCurve([
            (0.00, 0.020),
            (0.20, 0.150),
            (0.50, 0.500),
            (0.80, 0.865),
            (1.00, 0.980),
        ]),
        redCurve: ToneCurve([(0, 0), (0.5, 0.530), (1, 1)]),
        greenCurve: ToneCurve([(0, 0), (0.5, 0.505), (1, 0.990)]),
        blueCurve: ToneCurve([(0, 0.030), (0.5, 0.455), (1, 0.920)]),
        saturation: 0.84,
        greenSaturation: 0.55,
        shadowTint: SIMD3(-0.006, 0.004, 0.008),    // slight teal in the deep shadows
        highlightTint: SIMD3(0.020, 0.010, -0.012)  // golden-hour highlights
    )
}
