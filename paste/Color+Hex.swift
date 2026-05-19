import SwiftUI

/// Convenience initializer for SwiftUI Color from a hex string like "#RRGGBB"
/// (the leading "#" is optional). Used across the app — defined once here so
/// it doesn't drift in 3 different file-private copies like it used to.
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var val: UInt64 = 0
        Scanner(string: h).scanHexInt64(&val)
        self.init(
            red:   Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8)  & 0xFF) / 255,
            blue:  Double( val        & 0xFF) / 255
        )
    }
}
