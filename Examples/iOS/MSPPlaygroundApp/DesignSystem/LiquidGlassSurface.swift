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
