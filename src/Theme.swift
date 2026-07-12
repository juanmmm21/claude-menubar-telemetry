import SwiftUI

struct Theme {
    // JetBrains Mono IDE Color Palette
    static let background = Color(hex: "#1E1F22")        // Deep Slate Dark
    static let cardBackground = Color(hex: "#2B2D30")    // Lighter Slate for content panels
    static let border = Color(hex: "#43454A")            // Grid lines and borders
    
    // Text colors
    static let textPrimary = Color(hex: "#CED0D6")       // High contrast text
    static let textSecondary = Color(hex: "#7A7E85")     // Muted labels and secondary text
    static let textMuted = Color(hex: "#5A5D6B")         // Subtitle/disabled text
    
    // Accents & status colors
    static let accent = Color(hex: "#3574F0")            // JetBrains Blue
    static let success = Color(hex: "#59A869")           // JetBrains Green (OK)
    static let warning = Color(hex: "#EDA200")           // JetBrains Orange/Yellow
    static let error = Color(hex: "#DB5860")             // JetBrains Red
    
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
