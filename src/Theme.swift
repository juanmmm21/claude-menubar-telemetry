import SwiftUI
import AppKit

// Paleta opaca que sigue el modo claro u oscuro del sistema. Nada deja ver lo
// que hay detrás del popover, así que el contraste es el mismo sobre una
// ventana blanca que sobre un fondo de escritorio oscuro. Cada color tiene una
// versión para cada modo con contraste suficiente sobre su fondo.
struct Theme {
    // Superficies
    static let background = dynamic(light: "#F2F2F5", dark: "#232325")  // Fondo del panel
    static let card = dynamic(light: "#FFFFFF", dark: "#2F2F32")        // Tarjetas
    static let border = dynamic(light: "#E4E4E9", dark: "#3E3E42")      // Bordes y separadores
    static let track = dynamic(light: "#E8E8ED", dark: "#46464A")       // Parte vacía de las barras e iconos
    // Sombra suave de las tarjetas; en modo oscuro no se vería, así que no hay.
    static let shadow = dynamic(light: NSColor.black.withAlphaComponent(0.07), dark: .clear)

    // Texto
    static let textPrimary = dynamic(light: "#1D1D1F", dark: "#F5F5F7")
    static let textSecondary = dynamic(light: "#55555A", dark: "#AEAEB2")

    // Estados. El aviso es ocre/amarillo y no naranja, para no confundirlo
    // con el color de Claude.
    static let accent = Color.accentColor                                // Enlaces y acciones
    static let success = dynamic(light: "#1E7F3A", dark: "#6FD08C")     // En vivo
    static let warning = dynamic(light: "#9A6700", dark: "#FFD43B")     // 70 %+
    static let error = dynamic(light: "#CF222E", dark: "#FF7B72")       // 90 %+

    // Color de cada proveedor en su tarjeta y sus barras
    static let claude = dynamic(light: "#C15F3C", dark: "#F0A07F")      // Arcilla de Anthropic
    static let gemini = dynamic(light: "#7B4FE0", dark: "#C3A6FF")      // Violeta de Gemini

    private static func dynamic(light: String, dark: String) -> Color {
        dynamic(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private extension NSColor {
    // "#RRGGBB"
    convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
