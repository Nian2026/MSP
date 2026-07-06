import MSPAgentBridge
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ChatView: View {
    private let transcriptBottomScrollSlack: CGFloat = 120

    @ObservedObject var viewModel: MSPPlaygroundViewModel
    var isModelConfigurationAvailable = true
    @Binding var fontScale: CGFloat
    @StateObject private var transcriptExportController = ExampleChatTranscriptExportController()
    @State private var isModelConfigurationPresented = false
    @State private var isExportingTranscript = false
    @State private var isExportingDiagnostics = false
    @State private var transcriptExportErrorMessage: String?
    @State private var exportedTranscriptDocument: ExportedTranscriptDocument?
    @State private var modelConfigurationDraft = MSPModelConfiguration.placeholder
    @State private var originalModelConfigurationAPIKey = ""
    @State private var clearsModelConfigurationAPIKey = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        mainContent
            .onAppear(perform: updateTranscriptRenderEnvironment)
            .onChange(of: fontScale) { _, _ in
                updateTranscriptRenderEnvironment()
            }
            .onChange(of: colorScheme) { _, _ in
                updateTranscriptRenderEnvironment()
            }
            .sheet(isPresented: modelConfigurationPresentationBinding) {
                modelConfigurationSheet
            }
            .sheet(item: $exportedTranscriptDocument) { document in
                TranscriptExportActivityView(activityItems: [document.url])
            }
            .alert("导出失败", isPresented: exportErrorPresentationBinding) {
                Button("OK", role: .cancel) {
                    transcriptExportErrorMessage = nil
                }
            } message: {
                Text(transcriptExportErrorMessage ?? "")
            }
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            transcriptView
            topControls
            if viewModel.isOpeningChatPackage {
                openingChatOverlay
            }
            bottomSurface
        }
    }

    private var transcriptView: some View {
        ExampleChatTranscriptControlledWebView(
            renderController: viewModel.transcriptRenderController,
            bottomContentInset: transcriptBottomScrollSlack,
            exportController: transcriptExportController,
            onRenderedProbe: renderedProbeHandler,
            onExpansionStateChange: expansionStateChangeHandler,
            onAddSelectedTextToChat: viewModel.addSelectedTextToComposer
        )
    }

    private var openingChatOverlay: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在打开对话")
                .photoSorterFont(size: 14, weight: .medium)
        }
        .foregroundStyle(MSPDesignTokens.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(MSPDesignTokens.surfaceStroke, lineWidth: 0.8)
        }
    }

    private var composerView: some View {
        ChatComposerView(
            text: $viewModel.composerText,
            isRunning: viewModel.isRunningAgent,
            isInputDisabled: viewModel.isOpeningChatPackage || !viewModel.isActiveChatReadyForInput,
            isExportingTranscript: isExportingTranscript,
            isExportingDiagnostics: isExportingDiagnostics,
            selectedTextSelections: viewModel.composerTextSelections,
            currentModelTitle: currentModelTitle,
            modelOptions: modelOptions,
            agentAccessMode: viewModel.agentAccessMode,
            sensitiveReadPolicy: viewModel.sensitiveReadPolicy,
            fontScale: $fontScale,
            exportFullTranscript: exportFullTranscript,
            exportDiagnosticsLog: exportDiagnosticsLog,
            selectModel: selectModel,
            selectAgentAccessMode: viewModel.selectAgentAccessMode,
            selectSensitiveReadPolicy: viewModel.selectSensitiveReadPolicy,
            removeSelectedTextSelection: viewModel.removeComposerTextSelection,
            startNewChat: viewModel.startNewChat,
            submit: viewModel.submitMessage,
            stopGenerating: viewModel.stopCurrentAgentTurn
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var bottomSurface: some View {
        VStack(spacing: ExampleChatPlanProgressPillLayoutMetrics.composerTopGap(at: fontScale)) {
            Spacer(minLength: 0)
            activePlanProgressPill
            composerView
        }
    }

    private var activePlanProgressPill: some View {
        ExampleChatPlanProgressPillSlot(
            update: viewModel.activePlanProgressUpdate,
            isGenerating: viewModel.isRunningAgent,
            zoomScale: fontScale,
            horizontalPadding: 16
        )
    }

    private var modelConfigurationSheet: some View {
        ModelConfigurationSheet(
            configuration: $modelConfigurationDraft,
            codexOAuthConfiguration: $viewModel.codexOAuthConfiguration,
            codexOAuthQuota: viewModel.codexOAuthQuota,
            isStartingCodexOAuthLogin: viewModel.isStartingCodexOAuthLogin,
            isRefreshingCodexOAuthQuota: viewModel.isRefreshingCodexOAuthQuota,
            modelConfigurationSaveError: viewModel.modelConfigurationSaveError,
            hasSavedAPIKey: hasSavedModelConfigurationAPIKey,
            clearsAPIKey: $clearsModelConfigurationAPIKey,
            saveModelConfiguration: saveModelConfiguration,
            saveCodexOAuthConfiguration: viewModel.saveCodexOAuthConfiguration,
            startCodexOAuthLogin: viewModel.startCodexOAuthLogin,
            refreshCodexOAuthQuota: refreshCodexOAuthQuotaFromSheet,
            clearCodexOAuthSession: viewModel.clearCodexOAuthSession
        )
    }

    private var renderedProbeHandler: ((ExampleChatTranscriptVisibleTextProbe) -> Void)? {
        guard viewModel.capturesTranscriptVisibleTextProbe else {
            return nil
        }
        return { probe in
            viewModel.recordTranscriptRenderedProbe(probe)
        }
    }

    private var expansionStateChangeHandler: ((ExampleChatTranscriptExpansionStateChange) -> Void)? {
        { change in
            viewModel.recordTranscriptExpansionStateChange(change)
        }
    }

    private func updateTranscriptRenderEnvironment() {
        viewModel.updateTranscriptRenderEnvironment(
            fontScale: fontScale,
            colorScheme: colorScheme
        )
    }

    private var currentModelTitle: String {
        MSPModelPickerCatalog.currentSelectionTitle(
            configuration: viewModel.modelConfiguration,
            codexOAuthConfiguration: viewModel.codexOAuthConfiguration
        )
    }

    private var modelOptions: [MSPModelPickerOption] {
        MSPModelPickerCatalog.options(
            configuration: viewModel.modelConfiguration,
            codexOAuthConfiguration: viewModel.codexOAuthConfiguration
        )
    }

    private var hasSavedModelConfigurationAPIKey: Bool {
        !originalModelConfigurationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var topControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()

                if let contextUsage = viewModel.contextUsage {
                    PhotoSorterContextUsageControl(usage: contextUsage, scale: 1.35)
                        .frame(width: 48, height: 48)
                        .padding(.top, 1)
                }

                if isModelConfigurationAvailable {
                    Button {
                        presentModelConfiguration()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(MSPDesignTokens.ink)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Model settings")
                    .padding(.trailing, 9)
                    .padding(.top, 1)
                }
            }
            Spacer()
        }
        .allowsHitTesting(isModelConfigurationAvailable || viewModel.contextUsage != nil)
    }

    private func presentModelConfiguration() {
        let configuration = viewModel.reloadModelConfiguration()
        originalModelConfigurationAPIKey = configuration.apiKey
        modelConfigurationDraft = configuration
        modelConfigurationDraft.apiKey = ""
        clearsModelConfigurationAPIKey = false
        isModelConfigurationPresented = true
    }

    private func exportFullTranscript() {
        guard !isExportingTranscript else {
            return
        }
        isExportingTranscript = true
        transcriptExportErrorMessage = nil
        Task { @MainActor in
            do {
                let url = try await transcriptExportController.exportFullTranscriptPDF()
                exportedTranscriptDocument = ExportedTranscriptDocument(url: url)
            } catch {
                transcriptExportErrorMessage = error.localizedDescription
            }
            isExportingTranscript = false
        }
    }

    private func exportDiagnosticsLog() {
        guard !isExportingDiagnostics else {
            return
        }
        isExportingDiagnostics = true
        transcriptExportErrorMessage = nil
        Task { @MainActor in
            do {
                let url = try await PhotoSorterDiagnosticsLog.shared.exportURL()
                exportedTranscriptDocument = ExportedTranscriptDocument(url: url)
            } catch {
                transcriptExportErrorMessage = error.localizedDescription
            }
            isExportingDiagnostics = false
        }
    }

    private func selectModel(_ option: MSPModelPickerOption) {
        guard option.isEnabled else {
            return
        }
        viewModel.modelConfiguration = MSPModelPickerCatalog.configuration(
            selecting: option,
            from: viewModel.modelConfiguration
        )
        _ = viewModel.saveModelConfiguration()
    }

    private func saveModelConfiguration() -> Bool {
        viewModel.modelConfiguration = MSPModelConfigurationDraftCommit.committedConfiguration(
            from: modelConfigurationDraft,
            originalAPIKey: originalModelConfigurationAPIKey,
            clearsAPIKey: clearsModelConfigurationAPIKey
        )
        let didSave = viewModel.saveModelConfiguration()
        if didSave {
            modelConfigurationDraft = viewModel.modelConfiguration
            originalModelConfigurationAPIKey = viewModel.modelConfiguration.apiKey
            clearsModelConfigurationAPIKey = false
        }
        return didSave
    }

    private func refreshCodexOAuthQuotaFromSheet() {
        viewModel.refreshCodexOAuthQuota(isAutomatic: false)
    }

    private var modelConfigurationPresentationBinding: Binding<Bool> {
        Binding(
            get: {
                isModelConfigurationAvailable && isModelConfigurationPresented
            },
            set: { newValue in
                isModelConfigurationPresented = isModelConfigurationAvailable && newValue
            }
        )
    }

    private var exportErrorPresentationBinding: Binding<Bool> {
        Binding(
            get: {
                transcriptExportErrorMessage?.isEmpty == false
            },
            set: { isPresented in
                if !isPresented {
                    transcriptExportErrorMessage = nil
                }
            }
        )
    }
}

private struct ExportedTranscriptDocument: Identifiable {
    var id: URL { url }
    let url: URL
}

#if canImport(UIKit)
private struct TranscriptExportActivityView: UIViewControllerRepresentable {
    var activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif canImport(AppKit)
private struct TranscriptExportActivityView: NSViewControllerRepresentable {
    var activityItems: [Any]

    func makeNSViewController(context: Context) -> NSViewController {
        TranscriptExportHostingViewController(activityItems: activityItems)
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

private final class TranscriptExportHostingViewController: NSViewController {
    private let activityItems: [Any]

    init(activityItems: [Any]) {
        self.activityItems = activityItems
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else {
            return
        }
        let picker = NSSharingServicePicker(items: activityItems)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        window.performClose(nil)
    }
}
#endif

private struct ModelConfigurationSheet: View {
    @Binding var configuration: MSPModelConfiguration
    @Binding var codexOAuthConfiguration: MSPCodexOAuthConfiguration
    var codexOAuthQuota: MSPCodexOAuthQuotaResult?
    var isStartingCodexOAuthLogin: Bool
    var isRefreshingCodexOAuthQuota: Bool
    var modelConfigurationSaveError: String?
    var hasSavedAPIKey: Bool
    @Binding var clearsAPIKey: Bool
    var saveModelConfiguration: () -> Bool
    var saveCodexOAuthConfiguration: () -> Void
    var startCodexOAuthLogin: () -> Void
    var refreshCodexOAuthQuota: () -> Void
    var clearCodexOAuthSession: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Provider", text: $configuration.providerName)
                    TextField("Base URL", text: baseURLBinding)
                    SecureField(apiKeyPrompt, text: apiKeyBinding)
                        .privacySensitive()
                    TextField("Model", text: $configuration.modelID)
                    HStack(alignment: .center, spacing: 8) {
                        Label {
                            Text(apiKeyStatusText)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: apiKeyStatusIconName)
                        }
                        .font(.subheadline)
                        .foregroundStyle(apiKeyStatusColor)
                        .accessibilityIdentifier("model-api-key-status")
                        Spacer()
                        if hasSavedAPIKey {
                            PhotoSorterLiquidGlassTextButton(clearsAPIKey ? "Keep" : "Clear", role: clearsAPIKey ? nil : .destructive) {
                                clearsAPIKey.toggle()
                                configuration.apiKey = ""
                            }
                        }
                    }
                    if let modelConfigurationSaveError,
                       !modelConfigurationSaveError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(modelConfigurationSaveError)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Picker("Reasoning", selection: $configuration.reasoningEffort) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    Picker("Verbosity", selection: $configuration.verbosity) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex OAuth 登录")
                                .font(.headline)
                            Text(codexOAuthStatusText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 12) {
                            PhotoSorterLiquidGlassTextButton(isStartingCodexOAuthLogin ? "登录中…" : codexOAuthLoginButtonTitle) {
                                startCodexOAuthLogin()
                            }
                            .disabled(isStartingCodexOAuthLogin || isRefreshingCodexOAuthQuota)

                            PhotoSorterLiquidGlassTextButton("退出登录", role: .destructive) {
                                clearCodexOAuthSession()
                            }
                            .disabled(!codexOAuthConfiguration.hasStoredCredential || isStartingCodexOAuthLogin)

                            Spacer(minLength: 0)
                        }
                    }

                    if !codexOAuthRuntimeMessage.isEmpty {
                        Text(codexOAuthRuntimeMessage)
                            .font(.subheadline)
                            .foregroundStyle(codexOAuthConfiguration.lastLoginStatus == .failed ? .red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .center) {
                        Text(codexOAuthAccountDetailText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if isRefreshingCodexOAuthQuota {
                            ProgressView()
                                .controlSize(.small)
                        }
                        PhotoSorterLiquidGlassTextButton(isRefreshingCodexOAuthQuota ? "刷新中…" : "刷新额度") {
                            refreshCodexOAuthQuota()
                        }
                        .disabled(isRefreshingCodexOAuthQuota || isStartingCodexOAuthLogin || !codexOAuthConfiguration.hasStoredCredential)
                    }
                }

                Section {
                    CodexOAuthQuotaPanel(
                        quota: codexOAuthQuota,
                        isRefreshing: isRefreshingCodexOAuthQuota
                    )
                } header: {
                    Text("Codex 额度")
                }
            }
            .navigationTitle("Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    PhotoSorterToolbarTextButton("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    PhotoSorterToolbarTextButton("Done") {
                        if saveModelConfiguration() {
                            saveCodexOAuthConfiguration()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: {
                configuration.baseURL?.absoluteString ?? ""
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                configuration.baseURL = trimmed.isEmpty ? nil : URL(string: trimmed)
            }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: {
                configuration.apiKey
            },
            set: { value in
                configuration.apiKey = value
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    clearsAPIKey = false
                }
            }
        )
    }

    private var apiKeyPrompt: String {
        apiKeyStatus.fieldPrompt
    }

    private var apiKeyStatusText: String {
        apiKeyStatus.text
    }

    private var apiKeyStatusIconName: String {
        apiKeyStatus.systemImageName
    }

    private var apiKeyStatusColor: Color {
        if apiKeyStatus.isDestructive {
            return .red
        }
        if apiKeyStatus.isPositive {
            return .green
        }
        if apiKeyStatus.isPendingReplacement {
            return .blue
        }
        return .orange
    }

    private var apiKeyStatus: MSPModelAPIKeyStatus {
        MSPModelAPIKeyStatus.status(
            hasSavedAPIKey: hasSavedAPIKey,
            draftAPIKey: configuration.apiKey,
            clearsAPIKey: clearsAPIKey
        )
    }

    private var codexOAuthStatusText: String {
        let normalized = codexOAuthConfiguration.normalized()
        var parts = [normalized.lastLoginStatus.title]
        if !normalized.email.isEmpty {
            parts.append(normalized.email)
        }
        if let planName = CodexOAuthQuotaPanel.planDisplayName(normalized.planType) {
            parts.append(planName)
        } else if !normalized.planType.isEmpty {
            parts.append(normalized.planType)
        }
        return parts.joined(separator: " · ")
    }

    private var codexOAuthLoginButtonTitle: String {
        codexOAuthConfiguration.hasStoredCredential ? "重新登录" : "登录 Codex"
    }

    private var codexOAuthRuntimeMessage: String {
        codexOAuthConfiguration.lastStatusMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var codexOAuthAccountDetailText: String {
        let normalized = codexOAuthConfiguration.normalized()
        guard normalized.hasStoredCredential else {
            return "登录后自动读取套餐和额度。"
        }
        return "Codex OAuth 会话已保存。"
    }
}

private struct PhotoSorterContextUsagePopoverMetrics: Hashable, Sendable {
    static let contentPadding: CGFloat = 16
    static let verticalSpacing: CGFloat = 14
    static let detailRowSpacing: CGFloat = 10
    static let detailRowMinHeight: CGFloat = 30
    static let headerTitleFontSize: CGFloat = 24
    static let headerValueFontSize: CGFloat = 18
    static let detailFontSize: CGFloat = 18
    static let progressPercentFontSize: CGFloat = 18
    static let headerTitleFontWeight: Font.Weight = .semibold
    static let headerValueFontWeight: Font.Weight = .medium
    static let progressPercentFontWeight: Font.Weight = .medium
    static let detailTitleFontWeight: Font.Weight = .medium
    static let detailValueFontWeight: Font.Weight = .medium
    static let progressBarHeight: CGFloat = 8
    static let progressAnimationDurationSeconds = 0.32
    static let donutAnimationDurationSeconds = 0.32
    static let donutTrackOpacity = 0.28

    static func donutLineWidth(at scale: CGFloat) -> CGFloat {
        max(2.0, 2.85 * min(max(scale, 0.75), 1.6))
    }

    static func accentColor(for level: MSPAgentContextUsageLevel?) -> Color {
        switch level {
        case .low:
            return Color(red: 0.24, green: 0.74, blue: 0.42)
        case .moderate:
            return Color(red: 0.12, green: 0.47, blue: 0.79)
        case .high:
            return Color(red: 0.88, green: 0.62, blue: 0.12)
        case .critical:
            return Color(red: 0.84, green: 0.22, blue: 0.20)
        case nil:
            return Color(red: 0.24, green: 0.74, blue: 0.42)
        }
    }
}

private struct PhotoSorterContextUsagePopoverDetailRow: Hashable, Sendable {
    var title: String
    var value: String
}

private struct PhotoSorterContextUsagePopoverPresentation: Hashable, Sendable {
    var headerTitle: String
    var headerValue: String
    var progressLabel: String
    var progressFraction: Double
    var progressPercentText: String
    var accentLevel: MSPAgentContextUsageLevel
    var detailRows: [PhotoSorterContextUsagePopoverDetailRow]

    init(usage: MSPAgentContextUsageRecord) {
        let clampedFraction = Self.clamped(usage.currentWindowFraction ?? 0)
        let thresholdFraction: Double
        if usage.contextWindowTokens > 0 {
            thresholdFraction = Self.clamped(Double(usage.autoCompactTokenLimit) / Double(usage.contextWindowTokens))
        } else {
            thresholdFraction = 0
        }

        var rows = [
            PhotoSorterContextUsagePopoverDetailRow(
                title: "压缩阈值",
                value: Self.percentText(for: thresholdFraction)
            )
        ]
        if let serverTotalTokens = usage.serverTotalTokens {
            rows.append(PhotoSorterContextUsagePopoverDetailRow(
                title: "上次服务端 total",
                value: Self.shortTokenCount(serverTotalTokens)
            ))
        }
        if let serverInputTokens = usage.serverInputTokens,
           let serverOutputTokens = usage.serverOutputTokens {
            rows.append(PhotoSorterContextUsagePopoverDetailRow(
                title: "input/output",
                value: "\(Self.shortTokenCount(serverInputTokens)) / \(Self.shortTokenCount(serverOutputTokens))"
            ))
        }

        headerTitle = "上下文窗口"
        headerValue = "\(Self.shortTokenCount(usage.currentTokens)) / \(Self.shortTokenCount(usage.contextWindowTokens))"
        progressLabel = "窗口占用"
        progressFraction = clampedFraction
        progressPercentText = Self.percentText(for: clampedFraction)
        accentLevel = MSPAgentContextUsageRecord.usageLevel(forWindowFraction: clampedFraction)
        detailRows = rows
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func percentText(for fraction: Double) -> String {
        "\(Int((clamped(fraction) * 100).rounded()))%"
    }

    fileprivate static func shortTokenCount(_ tokens: Int) -> String {
        let absoluteTokens = abs(tokens)
        let sign = tokens < 0 ? "-" : ""
        if absoluteTokens >= 1_000_000 {
            let value = Double(absoluteTokens) / 1_000_000
            return "\(sign)\(compactDecimalString(value))M"
        }
        if absoluteTokens >= 1_000 {
            let value = Double(absoluteTokens) / 1_000
            return "\(sign)\(compactDecimalString(value))k"
        }
        return "\(tokens)"
    }

    private static func compactDecimalString(_ value: Double) -> String {
        if value >= 100 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        if value >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}

private struct PhotoSorterContextUsageControl: View {
    let usage: MSPAgentContextUsageRecord
    let scale: CGFloat

    @State private var showsPopover = false

    var body: some View {
        Button {
            showsPopover.toggle()
        } label: {
            PhotoSorterContextUsageIndicator(usage: usage, scale: scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("上下文窗口")
        .accessibilityValue(PhotoSorterContextUsageIndicator.compactTitle(for: usage))
        .popover(isPresented: $showsPopover, arrowEdge: .top) {
            PhotoSorterContextUsagePopover(usage: usage)
                .frame(width: 280)
                .presentationCompactAdaptation(.popover)
        }
        .onDisappear {
            showsPopover = false
        }
    }
}

private struct PhotoSorterContextUsageIndicator: View {
    let usage: MSPAgentContextUsageRecord
    let scale: CGFloat

    private var clampedContextFraction: CGFloat? {
        guard let fraction = usage.currentWindowFraction else { return nil }
        return CGFloat(min(max(fraction, 0), 1))
    }

    private var ringColor: Color {
        PhotoSorterContextUsagePopoverMetrics.accentColor(for: usage.currentUsageLevel)
    }

    var body: some View {
        if let clampedContextFraction {
            ZStack {
                Circle()
                    .stroke(
                        ringColor.opacity(PhotoSorterContextUsagePopoverMetrics.donutTrackOpacity),
                        lineWidth: lineWidth
                    )

                Circle()
                    .trim(from: 0, to: clampedContextFraction)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(
                        .easeOut(duration: PhotoSorterContextUsagePopoverMetrics.donutAnimationDurationSeconds),
                        value: clampedContextFraction
                    )
            }
            .frame(width: max(12, 14 * scale), height: max(12, 14 * scale))
        }
    }

    private var lineWidth: CGFloat {
        PhotoSorterContextUsagePopoverMetrics.donutLineWidth(at: scale)
    }

    static func compactTitle(for usage: MSPAgentContextUsageRecord) -> String {
        let windowPercent = Int((min(max(usage.currentWindowFraction ?? 0, 0), 1) * 100).rounded())
        let thresholdPercent: Int
        if usage.contextWindowTokens > 0 {
            thresholdPercent = Int((min(max(Double(usage.autoCompactTokenLimit) / Double(usage.contextWindowTokens), 0), 1) * 100).rounded())
        } else {
            thresholdPercent = 0
        }
        var lines = [
            "上下文窗口：\(PhotoSorterContextUsagePopoverPresentation.shortTokenCount(usage.currentTokens))/\(PhotoSorterContextUsagePopoverPresentation.shortTokenCount(usage.contextWindowTokens))",
            "窗口占用：\(windowPercent)%",
            "压缩阈值：\(thresholdPercent)%"
        ]
        if let serverTotalTokens = usage.serverTotalTokens {
            lines.append("上次服务端 total：\(PhotoSorterContextUsagePopoverPresentation.shortTokenCount(serverTotalTokens))")
        }
        if let serverInputTokens = usage.serverInputTokens,
           let serverOutputTokens = usage.serverOutputTokens {
            lines.append("input/output：\(PhotoSorterContextUsagePopoverPresentation.shortTokenCount(serverInputTokens))/\(PhotoSorterContextUsagePopoverPresentation.shortTokenCount(serverOutputTokens))")
        }
        return lines.joined(separator: "\n")
    }
}

private struct PhotoSorterContextUsagePopover: View {
    let usage: MSPAgentContextUsageRecord

    private var presentation: PhotoSorterContextUsagePopoverPresentation {
        PhotoSorterContextUsagePopoverPresentation(usage: usage)
    }

    private var accentColor: Color {
        PhotoSorterContextUsagePopoverMetrics.accentColor(for: presentation.accentLevel)
    }

    var body: some View {
        let currentPresentation = presentation
        VStack(alignment: .leading, spacing: PhotoSorterContextUsagePopoverMetrics.verticalSpacing) {
            PhotoSorterContextUsageHeader(presentation: currentPresentation)

            PhotoSorterContextUsageProgressRow(
                presentation: currentPresentation,
                accentColor: accentColor
            )

            VStack(alignment: .leading, spacing: PhotoSorterContextUsagePopoverMetrics.detailRowSpacing) {
                ForEach(currentPresentation.detailRows, id: \.self) { row in
                    PhotoSorterContextUsageDetailRow(row: row)
                }
            }
        }
        .padding(PhotoSorterContextUsagePopoverMetrics.contentPadding)
    }
}

private struct PhotoSorterContextUsageHeader: View {
    let presentation: PhotoSorterContextUsagePopoverPresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(presentation.headerTitle)
                .font(.system(
                    size: PhotoSorterContextUsagePopoverMetrics.headerTitleFontSize,
                    weight: PhotoSorterContextUsagePopoverMetrics.headerTitleFontWeight,
                    design: .rounded
                ))
                .lineLimit(1)

            Spacer(minLength: 10)

            Text(presentation.headerValue)
                .font(.system(
                    size: PhotoSorterContextUsagePopoverMetrics.headerValueFontSize,
                    weight: PhotoSorterContextUsagePopoverMetrics.headerValueFontWeight,
                    design: .rounded
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
    }
}

private struct PhotoSorterContextUsageProgressRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let presentation: PhotoSorterContextUsagePopoverPresentation
    let accentColor: Color

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackColor)

                    Capsule()
                        .fill(accentColor)
                        .frame(
                            width: max(0, proxy.size.width * CGFloat(presentation.progressFraction)),
                            height: PhotoSorterContextUsagePopoverMetrics.progressBarHeight
                        )
                        .animation(
                            .easeOut(duration: PhotoSorterContextUsagePopoverMetrics.progressAnimationDurationSeconds),
                            value: presentation.progressFraction
                        )
                }
            }
            .frame(height: PhotoSorterContextUsagePopoverMetrics.progressBarHeight)
            .accessibilityLabel(presentation.progressLabel)
            .accessibilityValue(presentation.progressPercentText)

            Text(presentation.progressPercentText)
                .font(.system(
                    size: PhotoSorterContextUsagePopoverMetrics.progressPercentFontSize,
                    weight: PhotoSorterContextUsagePopoverMetrics.progressPercentFontWeight,
                    design: .rounded
                ))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
        }
    }

    private var trackColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.10)
    }
}

private struct PhotoSorterContextUsageDetailRow: View {
    let row: PhotoSorterContextUsagePopoverDetailRow

    var body: some View {
        HStack(spacing: 10) {
            Text(row.title)
                .font(.system(
                    size: PhotoSorterContextUsagePopoverMetrics.detailFontSize,
                    weight: PhotoSorterContextUsagePopoverMetrics.detailTitleFontWeight,
                    design: .rounded
                ))
                .foregroundStyle(Color.primary.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.value)
                .font(.system(
                    size: PhotoSorterContextUsagePopoverMetrics.detailFontSize,
                    weight: PhotoSorterContextUsagePopoverMetrics.detailValueFontWeight,
                    design: .rounded
                ))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(minHeight: PhotoSorterContextUsagePopoverMetrics.detailRowMinHeight)
    }
}

private struct CodexOAuthQuotaPanel: View {
    var quota: MSPCodexOAuthQuotaResult?
    var isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let quota {
                if let planType = quota.planType,
                   let planName = Self.planDisplayName(planType) {
                    HStack(spacing: 10) {
                        Text("套餐")
                            .photoSorterFont(size: 13, weight: .semibold, design: .rounded)
                            .foregroundStyle(.secondary)
                        Text(planName)
                            .photoSorterFont(size: 13, weight: .bold, design: .rounded)
                            .foregroundStyle(Self.isPremiumPlan(planType) ? Color(red: 0.55, green: 0.34, blue: 0.02) : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Self.isPremiumPlan(planType)
                                    ? Color(red: 1.0, green: 0.78, blue: 0.16).opacity(0.22)
                                    : Color.secondary.opacity(0.10),
                                in: Capsule()
                            )
                    }
                }

                if quota.windows.isEmpty {
                    Text(quota.message)
                        .photoSorterFont(size: 13, weight: .medium, design: .rounded)
                        .foregroundStyle(quota.status == .failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(quota.windows) { window in
                            quotaRow(window)
                        }
                    }

                    Text("更新于 \(quota.checkedAt.formatted(date: .omitted, time: .shortened))")
                        .photoSorterFont(size: 12, weight: .medium, design: .rounded)
                        .foregroundStyle(.secondary)
                }
            } else if isRefreshing {
                Text("正在刷新 Codex 额度…")
                    .photoSorterFont(size: 13, weight: .medium, design: .rounded)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无额度数据")
                    .photoSorterFont(size: 13, weight: .medium, design: .rounded)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func quotaRow(_ window: MSPCodexOAuthQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(window.title)
                    .photoSorterFont(size: 13, weight: .bold, design: .rounded)
                    .foregroundStyle(.primary)
                Spacer()
                Text(Self.percentText(window.remainingPercent))
                    .photoSorterFont(size: 13, weight: .bold, design: .rounded)
                    .foregroundStyle(.primary)
                Text(Self.resetText(window.resetAt))
                    .photoSorterFont(size: 13, weight: .medium, design: .rounded)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Self.progressValue(window.remainingPercent))
                .progressViewStyle(.linear)
                .tint(Self.tint(window.remainingPercent))
        }
    }

    static func planDisplayName(_ planType: String) -> String? {
        let normalized = planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "pro":
            return "Pro 20x"
        case "prolite", "pro-lite", "pro_lite":
            return "Pro 5x"
        case "plus":
            return "Plus"
        case "team", "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        case "edu":
            return "Edu"
        default:
            return planType
        }
    }

    private static func isPremiumPlan(_ planType: String) -> Bool {
        let normalized = planType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "pro" || normalized == "business" || normalized == "team" || normalized == "enterprise"
    }

    private static func percentText(_ percent: Double?) -> String {
        guard let percent else { return "--" }
        return "\(Int(clampedPercent(percent).rounded()))%"
    }

    private static func progressValue(_ percent: Double?) -> Double {
        clampedPercent(percent ?? 0) / 100
    }

    private static func tint(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        switch clampedPercent(percent) {
        case 70 ... 100:
            return Color(red: 0.09, green: 0.72, blue: 0.48)
        case 35 ..< 70:
            return Color(red: 0.86, green: 0.64, blue: 0.04)
        default:
            return Color(red: 0.86, green: 0.22, blue: 0.18)
        }
    }

    private static func resetText(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(
            .dateTime
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }

    private static func clampedPercent(_ percent: Double) -> Double {
        min(max(percent, 0), 100)
    }
}

private extension View {
    @ViewBuilder
    func mspDisablesAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
