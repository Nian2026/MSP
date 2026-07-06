import SwiftUI

enum MSPPlaygroundTypography {
    static let defaultScale: CGFloat = 1
    static let minimumScale: CGFloat = 0.82
    static let maximumScale: CGFloat = 2

    static let transcriptBodyFontSize: Double = 19
    static let transcriptRoleFontSize: Double = 13.5
    static let transcriptMetaFontSize: Double = 12.5
    static let transcriptSupportFontSize: Double = 17.5
    static let transcriptHistoryEditorFontSize: Double = 18
    static let transcriptThinkingIndicatorFontSize: Double = 16.5
    static let transcriptToolActivityFontSize: Double = 18

    private static let fontScaleKey = "mspPlayground.typography.fontScale"

    static func loadFontScale(defaults: UserDefaults = .standard) -> CGFloat {
        let storedValue = defaults.double(forKey: fontScaleKey)
        guard storedValue.isFinite, storedValue > 0 else {
            return defaultScale
        }
        return clampedScale(CGFloat(storedValue))
    }

    static func saveFontScale(_ scale: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clampedScale(scale)), forKey: fontScaleKey)
    }

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minimumScale), maximumScale)
    }

    static func clampedScale(_ scale: Double) -> Double {
        Double(clampedScale(CGFloat(scale)))
    }

    static func scaled(_ size: CGFloat, by scale: CGFloat) -> CGFloat {
        size * clampedScale(scale)
    }

    static func dynamicTypeSize(for scale: CGFloat) -> DynamicTypeSize {
        switch clampedScale(scale) {
        case ..<0.88:
            return .small
        case ..<0.96:
            return .medium
        case ..<1.08:
            return .large
        case ..<1.18:
            return .xLarge
        case ..<1.34:
            return .xxLarge
        case ..<1.55:
            return .xxxLarge
        case ..<1.8:
            return .accessibility1
        default:
            return .accessibility2
        }
    }
}

private struct MSPPlaygroundFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = MSPPlaygroundTypography.defaultScale
}

extension EnvironmentValues {
    var mspPlaygroundFontScale: CGFloat {
        get { self[MSPPlaygroundFontScaleKey.self] }
        set { self[MSPPlaygroundFontScaleKey.self] = MSPPlaygroundTypography.clampedScale(newValue) }
    }
}

private struct MSPPlaygroundScaledFontModifier: ViewModifier {
    @Environment(\.mspPlaygroundFontScale) private var fontScale
    var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: MSPPlaygroundTypography.scaled(size, by: fontScale),
                weight: weight,
                design: design
            )
        )
    }
}

extension View {
    func mspPlaygroundFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(
            MSPPlaygroundScaledFontModifier(
                size: size,
                weight: weight,
                design: design
            )
        )
    }
}
