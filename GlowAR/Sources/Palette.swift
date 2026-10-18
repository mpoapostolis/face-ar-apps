import SwiftUI
import simd

struct Shade: Identifiable, Hashable {
    let name: String
    let hex: UInt32
    var id: String { name }

    var color: Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// Gamma-encoded RGB, 0...1.
    var rgb: SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
    }

    /// Linear-light RGB for the shader.
    var linear: SIMD3<Float> {
        func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let c = rgb
        return SIMD3(lin(c.x), lin(c.y), lin(c.z))
    }
}

enum Palette {
    static let lips: [Shade] = [
        Shade(name: "Κλασικό κόκκινο", hex: 0xB0102A),
        Shade(name: "Κεράσι", hex: 0x8E1B2E),
        Shade(name: "Rosewood", hex: 0xA1525A),
        Shade(name: "Nude", hex: 0xB97A6E),
        Shade(name: "Mauve", hex: 0x915F6D),
        Shade(name: "Κοραλί", hex: 0xD9604E),
        Shade(name: "Ροζ", hex: 0xD2668A),
        Shade(name: "Berry", hex: 0x7A1F3D),
        Shade(name: "Δαμασκηνί", hex: 0x5E2340),
        Shade(name: "Τούβλο", hex: 0x8E3B2E),
    ]
    static let eyeshadow: [Shade] = [
        Shade(name: "Bronze", hex: 0x8C5A3C),
        Shade(name: "Champagne", hex: 0xD8BFA0),
        Shade(name: "Smoky", hex: 0x3E3A3F),
        Shade(name: "Rose gold", hex: 0xB76E79),
        Shade(name: "Δαμασκηνί", hex: 0x5B3651),
        Shade(name: "Taupe", hex: 0x8B7D74),
        Shade(name: "Navy", hex: 0x2B3550),
        Shade(name: "Σμαραγδί", hex: 0x2F5D50),
    ]
    static let liner: [Shade] = [
        Shade(name: "Μαύρο", hex: 0x111111),
        Shade(name: "Καφέ", hex: 0x3B2416),
        Shade(name: "Navy", hex: 0x1C2340),
        Shade(name: "Δαμασκηνί", hex: 0x3A1A2E),
    ]
    static let blush: [Shade] = [
        Shade(name: "Ροδακινί", hex: 0xF3A68A),
        Shade(name: "Ροζ", hex: 0xE08A95),
        Shade(name: "Κοραλί", hex: 0xEE7F6B),
        Shade(name: "Berry", hex: 0xB9546A),
        Shade(name: "Bronze", hex: 0xC1876B),
    ]
}

enum LipFinish: String, CaseIterable, Identifiable {
    case matte, satin, gloss
    var id: String { rawValue }
    var title: String {
        switch self {
        case .matte: return "Ματ"
        case .satin: return "Σατέν"
        case .gloss: return "Γυαλιστερό"
        }
    }
    var value: Double {
        switch self {
        case .matte: return 0
        case .satin: return 0.5
        case .gloss: return 1
        }
    }
}
