import SwiftUI

struct Theme {
    // Superficies translúcidas: el fondo es el desenfoque del sistema (ver
    // VisualEffectBackground), así que paneles, bordes y texto se definen como
    // blanco con distinta opacidad para que se integren con lo que hay detrás.
    static let background = Color.black.opacity(0.25)    // Botones sobre el cristal
    static let cardBackground = Color.white.opacity(0.05) // Paneles
    static let border = Color.white.opacity(0.10)         // Bordes y separadores
    static let meterTrack = Color.white.opacity(0.08)     // Segmentos apagados

    // Text colors
    static let textPrimary = Color.white.opacity(0.92)   // High contrast text
    static let textSecondary = Color.white.opacity(0.58) // Muted labels and secondary text
    static let textMuted = Color.white.opacity(0.38)     // Subtitle/disabled text

    // Accents & status colors
    static let accent = Color(hex: "#3574F0")            // JetBrains Blue
    static let success = Color(hex: "#59A869")           // JetBrains Green (OK)
    static let warning = Color(hex: "#EDA200")           // JetBrains Orange/Yellow
    static let error = Color(hex: "#DB5860")             // JetBrains Red

    // Color de cada proveedor en su sección y sus barras
    static let claude = Color(hex: "#D97757")            // Arcilla de Anthropic
    static let gemini = Color(hex: "#A87FFB")            // Violeta del degradado de Gemini
    
    // Monospaced typography support
    static func monospaced(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "JetBrains Mono", size: size) != nil {
            return Font.custom("JetBrains Mono", size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }
}

// SwiftUI Color extension to easily initialize with hex strings
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 1)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
