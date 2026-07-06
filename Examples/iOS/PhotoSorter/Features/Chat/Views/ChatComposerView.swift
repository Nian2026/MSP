import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatComposerView: View {
    @Binding var text: String
    var isRunning: Bool
    var isInputDisabled: Bool = false
    var isExportingTranscript: Bool
    var isExportingDiagnostics: Bool
    var selectedTextSelections: [PhotoSorterTextSelectionSnapshot]
    var currentModelTitle: String
    var modelOptions: [MSPModelPickerOption]
    var agentAccessMode: PhotoSorterAgentAccessMode
    var sensitiveReadPolicy: PhotoSorterSensitiveReadPolicy
    @Binding var fontScale: CGFloat
    var exportFullTranscript: () -> Void
    var exportDiagnosticsLog: () -> Void
    var selectModel: (MSPModelPickerOption) -> Void
    var selectAgentAccessMode: (PhotoSorterAgentAccessMode) -> Void
    var selectSensitiveReadPolicy: (PhotoSorterSensitiveReadPolicy) -> Void
    var removeSelectedTextSelection: (UUID) -> Void
    var startNewChat: () -> Void
    var submit: () -> Void
    var stopGenerating: () -> Void
    @State private var isActionPopoverPresented = false

    var body: some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                composerContent
                    .glassEffect(.clear, in: composerBackgroundShape)
                    .overlay {
                        composerBackgroundShape
                            .stroke(MSPDesignTokens.surfaceStroke, lineWidth: 0.8)
                    }
            } else {
                composerContent
                    .background(
                        .ultraThinMaterial,
                        in: composerBackgroundShape
                    )
                    .overlay {
                        composerBackgroundShape
                            .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
                    }
            }
        }
    }

    private var canSubmit: Bool {
        !isRunning && !isInputDisabled && (
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !selectedTextSelections.isEmpty
        )
    }

    private var hasSelectedTextSelections: Bool {
        !selectedTextSelections.isEmpty
    }

    private var composerBackgroundShape: some InsettableShape {
        RoundedRectangle(
            cornerRadius: hasSelectedTextSelections ? 30 : 25,
            style: .continuous
        )
    }

    @ViewBuilder
    private var composerContent: some View {
        if hasSelectedTextSelections {
            VStack(alignment: .leading, spacing: 8) {
                selectedTextSelectionStrip
                composerShell
            }
            .padding(.top, 10)
        } else {
            composerShell
        }
    }

    private var selectedTextSelectionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedTextSelections) { selection in
                    SelectedTextSelectionChip(
                        selection: selection,
                        remove: {
                            removeSelectedTextSelection(selection.id)
                        }
                    )
                }
            }
            .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerShell: some View {
        HStack(alignment: .center, spacing: 12) {
            addButton

            messageField

            sendButton
                .buttonStyle(.plain)
                .modifier(EmbeddedSendButtonModifier(isEnabled: isRunning || canSubmit))
                .offset(x: hasSelectedTextSelections ? -5 : 0, y: hasSelectedTextSelections ? -2 : 0)
        }
        .padding(.leading, 13)
        .padding(.trailing, hasSelectedTextSelections ? 12 : 7)
        .padding(.vertical, 4)
        .frame(minHeight: 50)
    }

    private var addButton: some View {
        Button {
            isActionPopoverPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(MSPDesignTokens.ink)
                .frame(width: 30, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More actions")
        .popover(isPresented: $isActionPopoverPresented, arrowEdge: .bottom) {
            actionPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    private var actionPopover: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isActionPopoverPresented = false
                    startNewChat()
                } label: {
                    Label("新建对话", systemImage: "square.and.pencil")
                        .photoSorterFont(size: 16, weight: .medium)
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRunning)

                Divider()
                    .padding(.leading, 14)

                NavigationLink {
                    modelPickerPopover
                        .navigationTitle("选择模型")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .photoSorterFont(size: 17, weight: .semibold)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("选择模型")
                                .photoSorterFont(size: 16, weight: .medium)
                                .foregroundStyle(Color.primary)
                            Text(currentModelTitle)
                                .photoSorterFont(size: 12, weight: .medium)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .photoSorterFont(size: 14, weight: .semibold)
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose model")

                Divider()
                    .padding(.leading, 14)

                NavigationLink {
                    accessModePopover
                        .navigationTitle("访问模式")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: agentAccessMode.systemImageName)
                            .photoSorterFont(size: 17, weight: .semibold)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("访问模式")
                                .photoSorterFont(size: 16, weight: .medium)
                                .foregroundStyle(Color.primary)
                            Text(agentAccessMode.title)
                                .photoSorterFont(size: 12, weight: .medium)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .photoSorterFont(size: 14, weight: .semibold)
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agent access mode")

                Divider()
                    .padding(.leading, 14)

                NavigationLink {
                    sensitiveReadPolicyPopover
                        .navigationTitle("敏感读取")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: sensitiveReadPolicy.systemImageName)
                            .photoSorterFont(size: 17, weight: .semibold)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("敏感读取")
                                .photoSorterFont(size: 16, weight: .medium)
                                .foregroundStyle(Color.primary)
                            Text(sensitiveReadPolicy.title)
                                .photoSorterFont(size: 12, weight: .medium)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .photoSorterFont(size: 14, weight: .semibold)
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sensitive read policy")

                Divider()
                    .padding(.leading, 14)

                NavigationLink {
                    fontPopover
                        .navigationTitle("字体")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size")
                            .photoSorterFont(size: 17, weight: .semibold)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("字体")
                                .photoSorterFont(size: 16, weight: .medium)
                                .foregroundStyle(Color.primary)
                            Text(PhotoSorterTypography.displayPercent(for: fontScale))
                                .photoSorterFont(size: 12, weight: .medium)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .photoSorterFont(size: 14, weight: .semibold)
                            .foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Font size")

                Divider()
                    .padding(.leading, 14)

                Button {
                    isActionPopoverPresented = false
                    exportFullTranscript()
                } label: {
                    Label(
                        isExportingTranscript ? "正在导出…" : "导出长图",
                        systemImage: "photo"
                    )
                    .photoSorterFont(size: 16, weight: .medium)
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isExportingTranscript)

                Divider()
                    .padding(.leading, 14)

                Button {
                    isActionPopoverPresented = false
                    exportDiagnosticsLog()
                } label: {
                    Label(
                        isExportingDiagnostics ? "正在导出…" : "导出诊断日志",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .photoSorterFont(size: 16, weight: .medium)
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isExportingDiagnostics)
            }
            .frame(width: 302)
            .padding(.vertical, 6)
        }
        .frame(width: 302)
    }

    private var accessModePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PhotoSorterAgentAccessMode.allCases) { mode in
                Button {
                    selectAgentAccessMode(mode)
                    isActionPopoverPresented = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.systemImageName)
                            .photoSorterFont(size: 16, weight: .semibold)
                            .foregroundStyle(Color.primary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .photoSorterFont(size: 15, weight: .semibold)
                                .foregroundStyle(Color.primary)
                            Text(mode.subtitle)
                                .photoSorterFont(size: 12, weight: .medium)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 10)
                        if mode == agentAccessMode {
                            Image(systemName: "checkmark")
                                .photoSorterFont(size: 14, weight: .bold)
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)

                if mode.id != PhotoSorterAgentAccessMode.allCases.last?.id {
                    Divider()
                        .padding(.leading, 48)
                }
            }
        }
        .frame(width: 286)
        .padding(.vertical, 6)
    }

    private var sensitiveReadPolicyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PhotoSorterSensitiveReadPolicy.allCases) { policy in
                Button {
                    selectSensitiveReadPolicy(policy)
                    isActionPopoverPresented = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: policy.systemImageName)
                            .photoSorterFont(size: 16, weight: .semibold)
                            .foregroundStyle(Color.primary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(policy.title)
                                .photoSorterFont(size: 15, weight: .semibold)
                                .foregroundStyle(Color.primary)
                            Text(policy.subtitle)
                                .photoSorterFont(size: 12, weight: .medium)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 10)
                        if policy == sensitiveReadPolicy {
                            Image(systemName: "checkmark")
                                .photoSorterFont(size: 14, weight: .bold)
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(policy.title)

                if policy.id != PhotoSorterSensitiveReadPolicy.allCases.last?.id {
                    Divider()
                        .padding(.leading, 48)
                }
            }
        }
        .frame(width: 286)
        .padding(.vertical, 6)
    }

    private var modelPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(modelOptions) { option in
                Button {
                    guard option.isEnabled else {
                        return
                    }
                    selectModel(option)
                    isActionPopoverPresented = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.source.systemImageName)
                            .photoSorterFont(size: 16, weight: .semibold)
                            .foregroundStyle(option.isEnabled ? Color.primary : Color.secondary.opacity(0.55))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .photoSorterFont(size: 15, weight: .semibold)
                                .foregroundStyle(option.isEnabled ? Color.primary : Color.secondary.opacity(0.65))
                            Text(option.subtitle)
                                .photoSorterFont(size: 12, weight: .medium)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 10)
                        if option.isSelected {
                            Image(systemName: "checkmark")
                                .photoSorterFont(size: 14, weight: .bold)
                                .foregroundStyle(Color.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .opacity(option.isEnabled ? 1 : 0.58)
                }
                .buttonStyle(.plain)
                .disabled(!option.isEnabled)
                .accessibilityLabel("\(option.source.title) \(option.title)")

                if option.id != modelOptions.last?.id {
                    Divider()
                        .padding(.leading, 48)
                }
            }
        }
        .frame(width: 238)
        .padding(.vertical, 6)
    }

    private var fontPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "textformat.size")
                    .photoSorterFont(size: 17, weight: .semibold)
                Text("字体大小")
                    .photoSorterFont(size: 16, weight: .semibold)
                Spacer()
                Text(PhotoSorterTypography.displayPercent(for: fontScale))
                    .photoSorterFont(size: 13, weight: .medium)
                    .foregroundStyle(Color.secondary)
            }

            Slider(
                value: fontScaleBinding,
                in: Double(PhotoSorterTypography.minimumScale)...Double(PhotoSorterTypography.maximumScale),
                step: Double(PhotoSorterTypography.sliderStep)
            ) {
                Text("字体大小")
            } minimumValueLabel: {
                Text("小")
                    .photoSorterFont(size: 12, weight: .medium)
                    .foregroundStyle(Color.secondary)
            } maximumValueLabel: {
                Text("大")
                    .photoSorterFont(size: 12, weight: .medium)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: 266)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var fontScaleBinding: Binding<Double> {
        Binding(
            get: {
                Double(fontScale)
            },
            set: { newValue in
                fontScale = PhotoSorterTypography.clampedScale(CGFloat(newValue))
            }
        )
    }

    private var messageField: some View {
        TextField(
            "Message",
            text: $text,
            prompt: Text("Message").foregroundStyle(Color.secondary),
            axis: .vertical
        )
            .textFieldStyle(.plain)
            .photoSorterFont(size: 24, weight: .regular)
            .foregroundStyle(MSPDesignTokens.ink)
            .tint(MSPDesignTokens.ink)
            .lineLimit(1...4)
            .mspComposerTextInputBehavior()
            .onSubmit(submit)
            .disabled(isInputDisabled)
    }

    private var sendButton: some View {
        Button(action: performSendButtonAction) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: isRunning ? 17 : 24, weight: .semibold))
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .disabled(!isRunning && !canSubmit)
        .accessibilityLabel(isRunning ? "Stop generating" : "Send")
    }

    private func performSendButtonAction() {
        if isRunning {
            ChatComposerHaptics.stop()
            stopGenerating()
        } else {
            guard !isInputDisabled else { return }
            submit()
            Task { @MainActor in
                await Task.yield()
                ChatComposerHaptics.send()
            }
        }
    }
}

private enum ChatComposerHaptics {
    static func send() {
        impact(.light)
    }

    static func stop() {
        impact(.medium)
    }

    private static func impact(_ style: FeedbackStyle) {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: style.uiImpactFeedbackStyle)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    private enum FeedbackStyle {
        case light
        case medium

        #if canImport(UIKit)
        var uiImpactFeedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light:
                return .light
            case .medium:
                return .medium
            }
        }
        #endif
    }
}

private struct SelectedTextSelectionChip: View {
    var selection: PhotoSorterTextSelectionSnapshot
    var remove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 19, weight: .semibold))
            Text(previewText)
                .photoSorterFont(size: 22, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove selected text")
        }
        .foregroundStyle(chipTint)
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(
            Capsule(style: .continuous)
                .fill(chipBackground)
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(chipBorder, lineWidth: 0.8)
        }
        .frame(maxWidth: 360)
        .accessibilityLabel("Selected text \(previewText)")
    }

    private var previewText: String {
        selection.selectedText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var chipTint: Color {
        Color(red: 0.19, green: 0.48, blue: 0.96)
    }

    private var chipBackground: Color {
        colorScheme == .dark ? Color.black.opacity(0.86) : Color.white
    }

    private var chipBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }
}

private extension View {
    @ViewBuilder
    func mspComposerTextInputBehavior() -> some View {
        #if os(iOS)
        self
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(.send)
        #else
        self
        #endif
    }
}

private struct EmbeddedSendButtonModifier: ViewModifier {
    var isEnabled: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(sendArrowColor)
            .background(
                Circle()
                    .fill(sendButtonFill)
            )
            .opacity(isEnabled ? 1 : disabledOpacity)
    }

    private var sendButtonFill: Color {
        colorScheme == .dark ? .white : .black
    }

    private var sendArrowColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var disabledOpacity: Double {
        colorScheme == .dark ? 1 : 0.16
    }
}
