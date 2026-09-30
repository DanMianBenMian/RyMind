import SwiftUI

enum RMTheme {
    static let bg      = Color(hex: 0x1B1B1D)
    static let rail    = Color(hex: 0x141416)
    static let panel   = Color(hex: 0x242428)
    static let surface = Color(hex: 0x2C2C30)
    static let accent  = Color(hex: 0x2DD4BF)
    static let text    = Color(hex: 0xE8E8EA)
    static let textSub = Color(hex: 0x8A8A90)
    static let warn    = Color(hex: 0xEF9F27)
    static let danger  = Color(hex: 0xE24B4A)
    static let user    = Color(hex: 0x0F6E56)
    static let bot     = Color(hex: 0x2C2C30)
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue:  Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

extension View {
    func rmCard() -> some View {
        self
            .background(RMTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
