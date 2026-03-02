import SwiftUI

enum ForgeTheme {
    // MARK: - Colors (Neobrutalist dark)
    static let background = Color(red: 0, green: 0, blue: 0)
    static let surface = Color(red: 0.1, green: 0.1, blue: 0.1)
    static let border = Color(red: 0.3, green: 0.3, blue: 0.3)

    static let cyan = Color(red: 0, green: 1, blue: 1)
    static let orange = Color(red: 1, green: 0.6, blue: 0)
    static let green = Color(red: 0, green: 1, blue: 0.4)
    static let red = Color(red: 1, green: 0.2, blue: 0.2)
    static let white = Color.white
    static let dimWhite = Color(white: 0.6)

    static let accent = cyan
    static let destructive = red

    // MARK: - Fonts
    static func mono(_ size: CGFloat) -> Font {
        .custom("SpaceMono-Regular", size: size)
    }

    static let titleFont = mono(20)
    static let bodyFont = mono(14)
    static let captionFont = mono(11)
    static let hudFont = mono(10)

    // MARK: - Layout
    static let cornerRadius: CGFloat = 0 // neobrutalist: sharp corners
    static let borderWidth: CGFloat = 2
    static let buttonPadding: CGFloat = 12
    static let controlSize: CGFloat = 56
    static let controlOpacity: Double = 0.7
}
