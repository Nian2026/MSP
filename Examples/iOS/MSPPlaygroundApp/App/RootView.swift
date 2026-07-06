import SwiftUI
#if canImport(QuickLook)
import QuickLook
#endif

struct RootView: View {
    @StateObject private var viewModel = MSPPlaygroundViewModel()
    @State private var isWorkspaceDrawerOpen = ProcessInfo.processInfo.arguments.contains("--msp-workspace-drawer-open")
    @State private var appFontScale = MSPPlaygroundTypography.loadFontScale()
    @Environment(\.scenePhase) private var scenePhase
    private let isModelConfigurationAvailable = !ProcessInfo.processInfo.arguments.contains("--msp-hide-model-settings")

    var body: some View {
        ZStack {
            MSPDesignTokens.pageBackground
                .ignoresSafeArea()

            WorkspaceDrawerContainer(isOpen: $isWorkspaceDrawerOpen) {
                ChatView(
                    viewModel: viewModel,
                    isModelConfigurationAvailable: isModelConfigurationAvailable,
                    fontScale: appFontScale
                )
            } drawer: {
                WorkspaceDrawerView(
                    treeState: viewModel.fileTreeState,
                    openFile: viewModel.openWorkspaceFile
                )
            }
        }
        .onAppear {
            viewModel.recordScenePhase(scenePhase)
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.recordScenePhase(newPhase)
        }
        .task {
            await viewModel.start()
        }
        .environment(\.mspPlaygroundFontScale, appFontScale)
        .dynamicTypeSize(MSPPlaygroundTypography.dynamicTypeSize(for: appFontScale))
        .onChange(of: appFontScale) { _, newValue in
            let clampedScale = MSPPlaygroundTypography.clampedScale(newValue)
            if clampedScale != newValue {
                appFontScale = clampedScale
            }
            MSPPlaygroundTypography.saveFontScale(clampedScale)
        }
#if canImport(QuickLook)
        .quickLookPreview($viewModel.workspaceQuickLookURL)
#endif
    }
}
