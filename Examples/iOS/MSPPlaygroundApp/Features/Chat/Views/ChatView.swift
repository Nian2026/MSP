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
    var fontScale: CGFloat = MSPPlaygroundTypography.defaultScale
    @StateObject private var transcriptExportController = ExampleChatTranscriptExportController()
    @State private var isModelConfigurationPresented = false
    @State private var isExportingTranscript = false
    @State private var transcriptExportErrorMessage: String?
    @State private var exportedTranscriptDocument: ExportedTranscriptDocument?
    @State private var modelConfigurationDraft = MSPModelConfiguration.placeholder
    @State private var originalModelConfigurationAPIKey = ""
    @State private var clearsModelConfigurationAPIKey = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ExampleChatTranscriptWebView(
                state: ExampleChatTranscriptPayloadFactory.renderState(
                    from: viewModel.transcript,
                    isGenerating: viewModel.isRunningAgent,
                    expandToolActivityBlocks: viewModel.expandsTranscriptToolDetailsForTesting,
                    fontScale: Double(fontScale)
                ),
                bottomContentInset: transcriptBottomScrollSlack,
                exportController: transcriptExportController,
                onRenderedProbe: viewModel.recordTranscriptRenderedProbe,
                onExampleChatWriteOperationAction: viewModel.handleExampleChatWriteOperationAction
            )

            topControls

            ChatComposerView(
                text: $viewModel.composerText,
                isRunning: viewModel.isRunningAgent,
                isExportingTranscript: isExportingTranscript,
                currentModelTitle: MSPModelPickerCatalog.currentSelectionTitle(
                    configuration: viewModel.modelConfiguration,
                    codexOAuthConfiguration: viewModel.codexOAuthConfiguration
                ),
                modelOptions: MSPModelPickerCatalog.options(
                    configuration: viewModel.modelConfiguration,
                    codexOAuthConfiguration: viewModel.codexOAuthConfiguration
                ),
                exportFullTranscript: exportFullTranscript,
                selectModel: selectModel,
                submit: viewModel.submitMessage
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .sheet(isPresented: modelConfigurationPresentationBinding) {
            ModelConfigurationSheet(
                configuration: $modelConfigurationDraft,
                codexOAuthConfiguration: $viewModel.codexOAuthConfiguration,
                codexOAuthQuota: viewModel.codexOAuthQuota,
                isStartingCodexOAuthLogin: viewModel.isStartingCodexOAuthLogin,
                isRefreshingCodexOAuthQuota: viewModel.isRefreshingCodexOAuthQuota,
                modelConfigurationSaveError: viewModel.modelConfigurationSaveError,
                hasSavedAPIKey: !originalModelConfigurationAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                clearsAPIKey: $clearsModelConfigurationAPIKey,
                saveModelConfiguration: {
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
                },
                saveCodexOAuthConfiguration: viewModel.saveCodexOAuthConfiguration,
                startCodexOAuthLogin: viewModel.startCodexOAuthLogin,
                refreshCodexOAuthQuota: {
                    viewModel.refreshCodexOAuthQuota(isAutomatic: false)
                },
                clearCodexOAuthSession: viewModel.clearCodexOAuthSession
            )
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

    private var topControls: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()

                if isModelConfigurationAvailable {
                    Button {
                        presentModelConfiguration()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.black)
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
        .allowsHitTesting(isModelConfigurationAvailable)
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
                            Button(clearsAPIKey ? "Keep" : "Clear", role: clearsAPIKey ? nil : .destructive) {
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
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Codex OAuth 登录")
                                .font(.headline)
                            Text(codexOAuthStatusText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(isStartingCodexOAuthLogin ? "登录中…" : codexOAuthLoginButtonTitle) {
                            startCodexOAuthLogin()
                        }
                        .disabled(isStartingCodexOAuthLogin || isRefreshingCodexOAuthQuota)
                        Button("退出登录", role: .destructive) {
                            clearCodexOAuthSession()
                        }
                        .disabled(!codexOAuthConfiguration.hasStoredCredential || isStartingCodexOAuthLogin)
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
                        Button(isRefreshingCodexOAuthQuota ? "刷新中…" : "刷新额度") {
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
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(planName)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
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
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(quota.status == .failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(quota.windows) { window in
                            quotaRow(window)
                        }
                    }

                    Text("更新于 \(quota.checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else if isRefreshing {
                Text("正在刷新 Codex 额度…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无额度数据")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func quotaRow(_ window: MSPCodexOAuthQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(window.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Text(Self.percentText(window.remainingPercent))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(Self.resetText(window.resetAt))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
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
