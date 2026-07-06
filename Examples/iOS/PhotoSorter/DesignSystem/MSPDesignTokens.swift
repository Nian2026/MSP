import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum PhotoSorterInterfaceTheme: String {
    case light
    case dark

    init(colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}

enum MSPDesignTokens {
    static var pageBackground: Color {
#if canImport(UIKit)
        Color(uiColor: .systemBackground)
#elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
#else
        Color.primary.opacity(0.04)
#endif
    }
    static let ink = Color.primary
    static let secondaryInk = Color.secondary
    static var inverseInk: Color { pageBackground }
    static let accent = Color.accentColor
    static let command = Color.accentColor
    static let error = Color.red
    static let surfaceStroke = Color.primary.opacity(0.12)
}
