import SwiftUI

struct LiquidGlassSurface<Content: View>: View {
    var cornerRadius: CGFloat = 22
    var interactive = false
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                content
                    .glassEffect(
                        .regular.interactive(interactive),
                        in: .rect(cornerRadius: cornerRadius)
                    )
            }
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        }
    }
}

struct PhotoSorterLiquidGlassTextButton: View {
    private let title: String
    private let role: ButtonRole?
    private let controlSize: ControlSize
    private let fontSize: CGFloat
    private let fontWeight: Font.Weight
    private let action: () -> Void

    init(
        _ title: String,
        role: ButtonRole? = nil,
        controlSize: ControlSize = .large,
        fontSize: CGFloat = 17,
        fontWeight: Font.Weight = .semibold,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.controlSize = controlSize
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .lineLimit(1)
        }
        .photoSorterFont(size: fontSize, weight: fontWeight)
        .photoSorterLiquidGlassButtonStyle(controlSize: controlSize)
    }
}

struct PhotoSorterToolbarTextButton: View {
    private let title: String
    private let role: ButtonRole?
    private let action: () -> Void

    init(
        _ title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .lineLimit(1)
        }
        .photoSorterFont(size: 17, weight: .semibold)
    }
}

private extension View {
    @ViewBuilder
    func photoSorterLiquidGlassButtonStyle(controlSize: ControlSize) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .controlSize(controlSize)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(controlSize)
        }
    }
}
