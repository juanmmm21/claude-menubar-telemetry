import SwiftUI

struct Theme {
    // Superficies translúcidas: el fondo es el desenfoque del sistema (ver
    // VisualEffectBackground), así que paneles, bordes y texto se definen como
    // blanco con distinta opacidad para que se integren con lo que hay detrás.
    static let background = Color.black.opacity(0.25)    // Botones sobre el cristal
    // Velo oscuro sobre el desenfoque: sin él, con una ventana blanca detrás el
    // cristal se aclara tanto que el texto blanco apenas se lee. Deja ver el
    // fondo difuminado pero garantiza contraste sobre cualquier color.
    static let glassTint = Color.black.opacity(0.62)
    static let cardBackground = Color.white.opacity(0.05) // Paneles
    static let border = Color.white.opacity(0.10)         // Bordes y separadores
    static let meterTrack = Color.white.opacity(0.16)     // Parte vacía de las barras

    // Text colors
    static let textPrimary = Color.white.opacity(0.92)   // High contrast text
    static let textSecondary = Color.white.opacity(0.70) // Muted labels and secondary text
    static let textMuted = Color.white.opacity(0.50)     // Subtitle/disabled text

    // Acentos y estados. Tonos claros para que destaquen sobre el cristal
    // oscuro, y el aviso en amarillo (no naranja) para no confundirlo con el
    // color de Claude.
    static let accent = Color(hex: "#6EA0FF")            // Azul (enlaces y acciones)
    static let success = Color(hex: "#6FD08C")           // Verde (OK)
    static let warning = Color(hex: "#FFD43B")           // Amarillo (70 %+)
    static let error = Color(hex: "#FF7B72")             // Rojo (90 %+)

    // Color de cada proveedor en su sección y sus barras
    static let claude = Color(hex: "#F0A07F")            // Arcilla de Anthropic, aclarada
    static let gemini = Color(hex: "#C3A6FF")            // Violeta de Gemini, aclarado
    
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
