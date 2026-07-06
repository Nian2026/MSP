import SwiftUI

struct ChatComposerView: View {
    @Binding var text: String
    var isRunning: Bool
    var isExportingTranscript: Bool
    var currentModelTitle: String
    var modelOptions: [MSPModelPickerOption]
    var exportFullTranscript: () -> Void
    var selectModel: (MSPModelPickerOption) -> Void
    var submit: () -> Void
    @State private var isActionPopoverPresented = false
    @State private var isModelPickerPopoverPresented = false

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            composerShell
                .glassEffect(.clear, in: .capsule)
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.8)
                }
        } else {
            composerShell
                .background(
                    .ultraThinMaterial,
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.8)
                }
        }
    }

    private var canSubmit: Bool {
        !isRunning && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerShell: some View {
        HStack(alignment: .center, spacing: 12) {
            addButton

            messageField

            sendButton
                .buttonStyle(.plain)
                .modifier(EmbeddedSendButtonModifier(isEnabled: canSubmit))
        }
        .padding(.leading, 13)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .frame(minHeight: 50)
    }

    private var addButton: some View {
        Button {
            isActionPopoverPresented = true
        } label: {
            Image(systemName: "plus")
                .mspPlaygroundFont(size: 26, weight: .medium)
                .foregroundStyle(Color.black)
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
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isModelPickerPopoverPresented = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .mspPlaygroundFont(size: 17, weight: .semibold)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("选择模型")
                            .mspPlaygroundFont(size: 16, weight: .medium)
                            .foregroundStyle(Color.primary)
                        Text(currentModelTitle)
                            .mspPlaygroundFont(size: 12, weight: .medium)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .mspPlaygroundFont(size: 14, weight: .semibold)
                        .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose model")
            .popover(isPresented: $isModelPickerPopoverPresented, arrowEdge: .leading) {
                modelPickerPopover
                    .presentationCompactAdaptation(.popover)
            }

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
                .mspPlaygroundFont(size: 16, weight: .medium)
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(isExportingTranscript)
        }
        .frame(width: 244)
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
                    isModelPickerPopoverPresented = false
                    isActionPopoverPresented = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.source.systemImageName)
                            .mspPlaygroundFont(size: 16, weight: .semibold)
                            .foregroundStyle(option.isEnabled ? Color.primary : Color.secondary.opacity(0.55))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .mspPlaygroundFont(size: 15, weight: .semibold)
                                .foregroundStyle(option.isEnabled ? Color.primary : Color.secondary.opacity(0.65))
                            Text(option.subtitle)
                                .mspPlaygroundFont(size: 12, weight: .medium)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 10)
                        if option.isSelected {
                            Image(systemName: "checkmark")
                                .mspPlaygroundFont(size: 14, weight: .bold)
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

    private var messageField: some View {
        TextField(
            "Message",
            text: $text,
            prompt: Text("Message").foregroundStyle(Color.secondary),
            axis: .vertical
        )
            .textFieldStyle(.plain)
            .mspPlaygroundFont(size: 24)
            .foregroundStyle(Color.black)
            .tint(Color.black)
            .lineLimit(1...4)
            .submitLabel(.send)
            .onSubmit(submit)
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .mspPlaygroundFont(size: 24, weight: .semibold)
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .disabled(!canSubmit)
        .accessibilityLabel("Send")
    }
}

private struct EmbeddedSendButtonModifier: ViewModifier {
    var isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.58))
            .background(
                Circle()
                    .fill(isEnabled ? Color.black : Color.black.opacity(0.16))
            )
    }
}
