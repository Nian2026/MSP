import SwiftUI

struct WorkspaceDrawerContainer<Content: View, Drawer: View>: View {
    @Binding var isOpen: Bool
    @GestureState private var dragTranslation: CGFloat = 0

    @ViewBuilder var content: Content
    @ViewBuilder var drawer: Drawer

    var body: some View {
        GeometryReader { geometry in
            let surfaceWidth = geometry.size.width
            let offset = drawerOffset(width: surfaceWidth)

            ZStack(alignment: .leading) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isOpen {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: DrawerGesture.edgeActivationWidth)
                            .contentShape(Rectangle())
                            .gesture(drawerGesture(width: surfaceWidth))
                        Spacer()
                    }
                    .ignoresSafeArea()
                }

                drawer
                    .frame(width: surfaceWidth)
                    .frame(maxHeight: .infinity)
                    .offset(x: offset)
                    .simultaneousGesture(drawerGesture(width: surfaceWidth))
                    .accessibilityHidden(!isOpen)
            }
            .clipped()
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isOpen)
        }
    }

    private func drawerOffset(width: CGFloat) -> CGFloat {
        let base = isOpen ? CGFloat.zero : -width
        let proposed = base + dragTranslation
        return min(0, max(-width, proposed))
    }

    private func drawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: DrawerGesture.minimumDistance)
            .updating($dragTranslation) { value, state, _ in
                guard DrawerGesture.isHorizontalIntent(value) else {
                    return
                }

                if isOpen {
                    state = min(0, value.translation.width)
                } else {
                    state = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                guard DrawerGesture.isHorizontalIntent(value) else {
                    return
                }

                if isOpen {
                    let threshold = DrawerGesture.closeThreshold(width: width)
                    isOpen = value.translation.width > -threshold
                } else {
                    let threshold = DrawerGesture.openThreshold(width: width)
                    isOpen = value.translation.width > threshold
                }
            }
    }
}

private enum DrawerGesture {
    static let edgeActivationWidth: CGFloat = 28
    static let minimumDistance: CGFloat = 18

    private static let horizontalDominance: CGFloat = 1.35
    private static let closeThresholdRatio: CGFloat = 0.34
    private static let closeThresholdMinimum: CGFloat = 112
    private static let openThresholdRatio: CGFloat = 0.22

    static func isHorizontalIntent(_ value: DragGesture.Value) -> Bool {
        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        return horizontal > vertical * horizontalDominance
    }

    static func closeThreshold(width: CGFloat) -> CGFloat {
        max(width * closeThresholdRatio, closeThresholdMinimum)
    }

    static func openThreshold(width: CGFloat) -> CGFloat {
        width * openThresholdRatio
    }
}
