import SwiftUI
import AppKit

// Paleta opaca que sigue el modo claro u oscuro del sistema. Nada deja ver lo
// que hay detrás del popover, así que el contraste es el mismo sobre una
// ventana blanca que sobre un fondo de escritorio oscuro. Cada color tiene una
// versión para cada modo con contraste suficiente sobre su fondo.
struct Theme {
    // Superficies: grises fríos, como un editor de código en modo claro u oscuro.
    static let background = dynamic(light: "#F3F4F6", dark: "#1B1D21")  // Fondo del panel
    static let card = dynamic(light: "#FFFFFF", dark: "#25282D")        // Paneles
    static let border = dynamic(light: "#DDE1E6", dark: "#383C43")      // Bordes y separadores
    static let track = dynamic(light: "#E6E9ED", dark: "#3A3F46")       // Parte vacía de las barras

    // Texto
    static let textPrimary = dynamic(light: "#1F2328", dark: "#EDEFF2")
    static let textSecondary = dynamic(light: "#57606A", dark: "#A3ABB5")

    // Estados. El aviso es ocre/amarillo y no naranja, para no confundirlo
    // con el color de Claude.
    static let accent = dynamic(light: "#2563EB", dark: "#6EA0FF")      // Azul de terminal (acciones)
    static let success = dynamic(light: "#1E7F3A", dark: "#6FD08C")     // LIVE
    static let warning = dynamic(light: "#9A6700", dark: "#FFD43B")     // 70 %+
    static let error = dynamic(light: "#CF222E", dark: "#FF7B72")       // 90 %+

    // Color de cada proveedor en su sección y sus barras
    static let claude = dynamic(light: "#C15F3C", dark: "#F0A07F")      // Arcilla de Anthropic
    static let gemini = dynamic(light: "#7B4FE0", dark: "#C3A6FF")      // Violeta de Gemini

    // Tipografía monoespaciada: JetBrains Mono si está instalada, si no la del sistema.
    static func monospaced(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: "JetBrains Mono", size: size) != nil {
            return Font.custom("JetBrains Mono", size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }

    private static func dynamic(light: String, dark: String) -> Color {
        let lightColor = NSColor(hex: light)
        let darkColor = NSColor(hex: dark)
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
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
