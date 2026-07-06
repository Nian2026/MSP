import Foundation
import SwiftUI
import WebKit

@MainActor
final class ExampleChatTranscriptExportController: ObservableObject {
    enum ExportError: LocalizedError {
        case webViewUnavailable
        case invalidDocumentSize

        var errorDescription: String? {
            switch self {
            case .webViewUnavailable:
                return "聊天内容还没有准备好。"
            case .invalidDocumentSize:
                return "无法读取当前聊天内容尺寸。"
            }
        }
    }

    private weak var webView: WKWebView?

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func exportFullTranscriptPDF() async throws -> URL {
        guard let webView else {
            throw ExportError.webViewUnavailable
        }

        let contentSize = try await webView.chatFullDocumentContentSize()
        let captureWidth = max(contentSize.width, webView.bounds.width, 1)
        let captureHeight = max(contentSize.height, webView.bounds.height, 1)
        guard captureWidth.isFinite,
              captureHeight.isFinite,
              captureWidth > 0,
              captureHeight > 0 else {
            throw ExportError.invalidDocumentSize
        }

        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0,
            y: 0,
            width: captureWidth.rounded(.up),
            height: captureHeight.rounded(.up)
        )
        if #available(iOS 17.0, macOS 14.0, *) {
            configuration.allowTransparentBackground = false
        }

        let pdfData = try await webView.pdf(configuration: configuration)
        let exportURL = Self.temporaryExportURL()
        try pdfData.write(to: exportURL, options: .atomic)
        return exportURL
    }

    private static func temporaryExportURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Chat-Transcript-\(timestamp).pdf", isDirectory: false)
    }
}

struct ExampleChatTranscriptRenderState {
    var payload: [String: Any]
    var presentation: [String: Any]
    var isGenerating: Bool = false

    static let empty = ExampleChatTranscriptRenderState(
        payload: ExampleChatTranscriptPayloadFactory.payload(from: []),
        presentation: ExampleChatTranscriptPayloadFactory.presentation(isGenerating: false),
        isGenerating: false
    )
}

struct ExampleChatTranscriptVisibleTextProbe: Equatable {
    struct MessageLayout: Equatable, Hashable {
        var role: String
        var dataRole: String
        var left: Double
        var right: Double
        var width: Double
        var centerX: Double
    }

    var visibleText: String
    var normalizedVisibleText: String
    var chatTranscriptTheme: String = ""
    var messageLayouts: [MessageLayout] = []
    var visibleMessageRoleTexts: [String] = []
    var chatSupportLineTitles: [String] = []
    var chatTerminalSupportLineTitles: [String] = []
    var chatToolActivityItemTitles: [String] = []
    var chatApplyPatchActivityTitles: [String] = []
    var chatProcessingTitles: [String] = []
    var chatProcessingClassNames: [String] = []
    var chatProcessingDurationTexts: [String] = []
    var chatProcessingDurationSeconds: [Int] = []
    var chatToolActivityTitles: [String] = []
    var liveExampleChatProcessingBlockCount: Int = 0
    var terminalCommandIconCount: Int = 0
    var mainFlowNormalizedText: String = ""
    var toolActivityDetailsCount: Int = 0
    var toolActivityDisclosureCount: Int = 0
    var shellExecutionDisclosureCount: Int = 0
    var shellExecutionOutputBlockCount: Int = 0
    var shellExecutionOutputNormalizedText: String = ""
    var katexElementCount: Int = 0
    var highlightedCodeElementCount: Int = 0
    var markdownCodeBlockCount: Int = 0
    var chatApplyPatchDiffCardCount: Int = 0
    var capturedAtMilliseconds: Int?
}

struct ExampleChatTranscriptWebView: View {
    var state: ExampleChatTranscriptRenderState
    var bottomContentInset: CGFloat = 0
    var exportController: ExampleChatTranscriptExportController?
    var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    var onExampleChatWriteOperationAction: ((UUID, String) -> Void)?

    var body: some View {
        PlatformExampleChatTranscriptWebView(
            state: state,
            bottomContentInset: bottomContentInset,
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExampleChatWriteOperationAction: onExampleChatWriteOperationAction
        )
            .background(Color.clear)
    }
}

#if os(iOS)
private struct PlatformExampleChatTranscriptWebView: UIViewRepresentable {
    var state: ExampleChatTranscriptRenderState
    var bottomContentInset: CGFloat
    var exportController: ExampleChatTranscriptExportController?
    var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    var onExampleChatWriteOperationAction: ((UUID, String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExampleChatWriteOperationAction: onExampleChatWriteOperationAction
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView(initialState: state)
        context.coordinator.applyScrollInsets(
            to: webView,
            bottomContentInset: bottomContentInset
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyScrollInsets(
            to: webView,
            bottomContentInset: bottomContentInset
        )
        context.coordinator.update(
            webView: webView,
            state: state,
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExampleChatWriteOperationAction: onExampleChatWriteOperationAction
        )
    }
}
#elseif os(macOS)
private struct PlatformExampleChatTranscriptWebView: NSViewRepresentable {
    var state: ExampleChatTranscriptRenderState
    var bottomContentInset: CGFloat
    var exportController: ExampleChatTranscriptExportController?
    var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    var onExampleChatWriteOperationAction: ((UUID, String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExampleChatWriteOperationAction: onExampleChatWriteOperationAction
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.makeWebView(initialState: state)
        context.coordinator.applyScrollInsets(
            to: webView,
            bottomContentInset: bottomContentInset
        )
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyScrollInsets(
            to: webView,
            bottomContentInset: bottomContentInset
        )
        context.coordinator.update(
            webView: webView,
            state: state,
            exportController: exportController,
            onRenderedProbe: onRenderedProbe,
            onExampleChatWriteOperationAction: onExampleChatWriteOperationAction
        )
    }
}
#endif

@MainActor
private final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let streamingRenderMinimumInterval: TimeInterval = 0.12

    private var isLoaded = false
    private var pendingState: ExampleChatTranscriptRenderState?
    private var lastRenderedSignature: String?
    private var scheduledRenderWorkItem: DispatchWorkItem?
    private var lastRenderStartedAt = Date.distantPast
    private var isRenderInFlight = false
    private var needsRenderAfterInFlight = false
    private var pendingVisibleTextProbeToken: UUID?
    private var lastVisibleTextProbeFingerprint: String?
    private weak var exportController: ExampleChatTranscriptExportController?
    private var onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?
    private var onExampleChatWriteOperationAction: ((UUID, String) -> Void)?

    init(
        exportController: ExampleChatTranscriptExportController?,
        onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?,
        onExampleChatWriteOperationAction: ((UUID, String) -> Void)?
    ) {
        self.exportController = exportController
        self.onRenderedProbe = onRenderedProbe
        self.onExampleChatWriteOperationAction = onExampleChatWriteOperationAction
    }

    func makeWebView(initialState: ExampleChatTranscriptRenderState) -> WKWebView {
        pendingState = initialState

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: "readexTranscriptHost")
        configuration.userContentController.add(self, name: "messageAction")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #elseif os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #endif
        exportController?.attach(webView: webView)

        webView.loadHTMLString(
            ExampleChatTranscriptRendererShell.htmlString(initialMetadata: initialState.presentation),
            baseURL: ExampleChatTranscriptRendererShell.resourcesBaseURL()
        )
        return webView
    }

    func applyScrollInsets(to webView: WKWebView, bottomContentInset: CGFloat) {
        #if os(iOS)
        var contentInset = webView.scrollView.contentInset
        contentInset.bottom = bottomContentInset
        webView.scrollView.contentInset = contentInset

        var indicatorInsets = webView.scrollView.verticalScrollIndicatorInsets
        indicatorInsets.bottom = bottomContentInset
        webView.scrollView.verticalScrollIndicatorInsets = indicatorInsets
        #endif
    }

    func update(
        webView: WKWebView,
        state: ExampleChatTranscriptRenderState,
        exportController: ExampleChatTranscriptExportController?,
        onRenderedProbe: ((ExampleChatTranscriptVisibleTextProbe) -> Void)?,
        onExampleChatWriteOperationAction: ((UUID, String) -> Void)?
    ) {
        pendingState = state
        self.exportController = exportController
        exportController?.attach(webView: webView)
        self.onRenderedProbe = onRenderedProbe
        self.onExampleChatWriteOperationAction = onExampleChatWriteOperationAction
        guard isLoaded else {
            return
        }
        scheduleRender(in: webView, allowsCoalescing: state.isGenerating)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        lastRenderedSignature = nil
        isRenderInFlight = false
        needsRenderAfterInFlight = false
        scheduledRenderWorkItem?.cancel()
        scheduledRenderWorkItem = nil
        scheduleRender(in: webView, allowsCoalescing: false)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "messageAction",
              let body = message.body as? [String: Any],
              Self.stringValue(from: body["action"]) == "readexWriteOperationAction",
              let rawOperationID = Self.stringValue(from: body["operation_id"]),
              let operationID = UUID(uuidString: rawOperationID) else {
            return
        }
        let direction = Self.stringValue(from: body["direction"]) ?? "undo"
        onExampleChatWriteOperationAction?(operationID, direction)
    }

    private static func stringValue(from value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func scheduleRender(in webView: WKWebView, allowsCoalescing: Bool) {
        scheduledRenderWorkItem?.cancel()
        scheduledRenderWorkItem = nil

        guard allowsCoalescing else {
            renderPendingState(in: webView)
            return
        }

        let elapsed = Date().timeIntervalSince(lastRenderStartedAt)
        let delay = max(0, Self.streamingRenderMinimumInterval - elapsed)
        guard delay > 0 else {
            renderPendingState(in: webView)
            return
        }

        let workItem = DispatchWorkItem { [weak self, weak webView] in
            guard let self, let webView else {
                return
            }
            self.scheduledRenderWorkItem = nil
            self.renderPendingState(in: webView)
        }
        scheduledRenderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func renderPendingState(in webView: WKWebView) {
        guard let state = pendingState else {
            return
        }

        let signature = Self.signature(for: state)
        guard signature != lastRenderedSignature else {
            return
        }
        guard !isRenderInFlight else {
            needsRenderAfterInFlight = true
            return
        }

        lastRenderStartedAt = Date()
        lastRenderedSignature = signature
        isRenderInFlight = true
        invoke(command: "set_presentation", payload: state.presentation, options: [
            "suppressConversationRerender": true,
            "preserveScrollAnchor": true,
            "followBottomIfNearBottom": true
        ], in: webView)
        invoke(command: "render_payload", payload: state.payload, options: [
            "followBottomIfNearBottom": true,
            "forceImmediateRender": !state.isGenerating,
            "debugReason": "msp_playground_render"
        ], in: webView) { [weak self, weak webView] succeeded in
            guard let self, let webView else {
                return
            }
            self.isRenderInFlight = false
            if !succeeded {
                self.lastRenderedSignature = nil
            }
            if self.needsRenderAfterInFlight {
                self.needsRenderAfterInFlight = false
                self.scheduleRender(
                    in: webView,
                    allowsCoalescing: self.pendingState?.isGenerating == true
                )
                return
            }
            guard succeeded else {
                return
            }
            self.scheduleVisibleTextProbe(in: webView)
        }
    }

    private func invoke(
        command: String,
        payload: [String: Any],
        options: [String: Any],
        in webView: WKWebView,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard let payloadJSON = Self.javascriptLiteral(payload),
              let optionsJSON = Self.javascriptLiteral(options) else {
            completion?(false)
            return
        }

        let functionBody = ExampleChatTranscriptRendererShell.hostCommandInvocationScriptSource()
        let script = """
        (() => {
          const command = \(Self.javascriptStringLiteral(command));
          const payload = \(payloadJSON);
          const options = \(optionsJSON);
          \(functionBody)
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            if let error {
                debugPrint("Chat transcript command failed:", command, error)
                completion?(false)
            } else if let result = result as? [String: Any], result["ok"] as? Bool == false {
                debugPrint("Chat transcript command returned failure:", command, result)
                completion?(false)
            } else {
                completion?(true)
            }
        }
    }

    private func scheduleVisibleTextProbe(in webView: WKWebView) {
        guard onRenderedProbe != nil else {
            return
        }
        let token = UUID()
        pendingVisibleTextProbeToken = token
        for delay in [0.35, 1.55, 2.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.pendingVisibleTextProbeToken == token else {
                    return
                }
                self.captureVisibleTextProbe(in: webView)
            }
        }
    }

    private func captureVisibleTextProbe(in webView: WKWebView) {
        let script = """
        (() => {
          const text = document.body && typeof document.body.innerText === "string"
            ? document.body.innerText
            : "";
          const normalizedText = text.replace(/\\s+/g, " ").trim();
          const normalizedDetachedText = (element) => {
            if (!element) {
              return "";
            }
            const source = typeof element.innerText === "string"
              ? element.innerText
              : (element.textContent || "");
            return source.replace(/\\s+/g, " ").trim();
          };
          const mainFlowClone = document.body ? document.body.cloneNode(true) : null;
          if (mainFlowClone) {
            mainFlowClone.querySelectorAll(
              ".readex-tool-activity-details, .readex-tool-activity-nested, .readex-shell-execution"
            ).forEach((element) => element.remove());
          }
          const mainFlowNormalizedText = normalizedDetachedText(mainFlowClone);
          const processingBlocks = Array.from(document.querySelectorAll(".readex-processing-block"));
          const toolActivityBlocks = Array.from(document.querySelectorAll(".readex-tool-activity-block"));
          const supportLines = Array.from(document.querySelectorAll(".support-line"));
          const shellExecutionOutputBlocks = Array.from(document.querySelectorAll(".readex-shell-execution-output-block"));
          const titleText = (block) => {
            const title = block.querySelector(".support-line-title");
            return title && typeof title.innerText === "string"
              ? title.innerText.replace(/\\s+/g, " ").trim()
              : "";
          };
          const durationText = (block) => {
            const duration = block.querySelector(".readex-processing-duration");
            return duration && typeof duration.innerText === "string"
              ? duration.innerText.replace(/\\s+/g, " ").trim()
              : "";
          };
          const durationSeconds = (text) => {
            const source = String(text || "").trim();
            if (!source) {
              return null;
            }
            const pieces = source.match(/(\\d+)\\s*([hms])/g) || [];
            if (!pieces.length) {
              return null;
            }
            return pieces.reduce((total, piece) => {
              const match = /(\\d+)\\s*([hms])/.exec(piece);
              if (!match) {
                return total;
              }
              const value = Number(match[1]);
              if (!Number.isFinite(value)) {
                return total;
              }
              if (match[2] === "h") {
                return total + value * 3600;
              }
              if (match[2] === "m") {
                return total + value * 60;
              }
              return total + value;
            }, 0);
          };
          const visibleText = (element) => {
            if (!element) {
              return "";
            }
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            if (
              style.display === "none" ||
              style.visibility === "hidden" ||
              Number(rect.width) <= 0 ||
              Number(rect.height) <= 0
            ) {
              return "";
            }
            return typeof element.innerText === "string"
              ? element.innerText.replace(/\\s+/g, " ").trim()
              : "";
          };
          const messageRole = (message) => {
            if (message.classList.contains("user")) {
              return "user";
            }
            if (message.classList.contains("assistant")) {
              return "assistant";
            }
            return message.getAttribute("data-message-role") || "";
          };
          const messageLayouts = Array.from(document.querySelectorAll(".message"))
            .filter((message) => !message.classList.contains("steered"))
            .map((message) => {
              const rect = message.getBoundingClientRect();
              return {
                role: messageRole(message),
                dataRole: message.getAttribute("data-message-role") || "",
                left: rect.left,
                right: rect.right,
                width: rect.width,
                centerX: rect.left + rect.width / 2
              };
            });
          const durationTexts = processingBlocks.map(durationText).filter(Boolean);
          return {
            text,
            normalizedText,
            chatTranscriptTheme: document.documentElement.getAttribute("data-readex-transcript-theme") || "",
            messageLayouts,
            visibleMessageRoleTexts: Array.from(document.querySelectorAll(".message-role"))
              .map(visibleText)
              .filter(Boolean),
            capturedAtMilliseconds: Date.now(),
            chatSupportLineTitles: supportLines.map(titleText).filter(Boolean),
            chatTerminalSupportLineTitles: supportLines
              .filter((line) => line.querySelector(".readex-terminal-command-icon"))
              .map(titleText)
              .filter(Boolean),
            chatToolActivityItemTitles: Array.from(document.querySelectorAll(".readex-tool-activity-item-title"))
              .map((title) => typeof title.innerText === "string"
                ? title.innerText.replace(/\\s+/g, " ").trim()
                : "")
              .filter(Boolean),
            chatApplyPatchActivityTitles: Array.from(document.querySelectorAll(".readex-apply-patch-activity-text"))
              .map(visibleText)
              .filter(Boolean),
            chatProcessingTitles: processingBlocks.map(titleText).filter(Boolean),
            chatProcessingClassNames: processingBlocks
              .map((block) => block.className || "")
              .filter(Boolean),
            chatProcessingDurationTexts: durationTexts,
            chatProcessingDurationSeconds: durationTexts
              .map(durationSeconds)
              .filter((value) => Number.isFinite(value)),
            chatToolActivityTitles: toolActivityBlocks.map(titleText).filter(Boolean),
            liveExampleChatProcessingBlockCount: processingBlocks
              .filter((block) => block.classList.contains("is-live"))
              .length,
            terminalCommandIconCount: document.querySelectorAll(".readex-terminal-command-icon").length,
            mainFlowNormalizedText,
            toolActivityDetailsCount: document.querySelectorAll(".readex-tool-activity-details").length,
            toolActivityDisclosureCount: document.querySelectorAll(".readex-tool-activity-disclosure").length,
            shellExecutionDisclosureCount: document.querySelectorAll(".readex-shell-execution-disclosure").length,
            shellExecutionOutputBlockCount: shellExecutionOutputBlocks.length,
            shellExecutionOutputNormalizedText: shellExecutionOutputBlocks
              .map(normalizedDetachedText)
              .filter(Boolean)
              .join("\\n"),
            katexElementCount: document.querySelectorAll(".katex").length,
            highlightedCodeElementCount: document.querySelectorAll("code.hljs, pre code.hljs, .hljs").length,
            markdownCodeBlockCount: document.querySelectorAll("pre code, .code-block, .message-code-block, .markdown-code-block").length,
            chatApplyPatchDiffCardCount: document.querySelectorAll(".readex-apply-patch-diff-card").length
          };
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard error == nil,
                  let self,
                  let object = result as? [String: Any] else {
                return
            }
            let probe = ExampleChatTranscriptVisibleTextProbe(
                visibleText: object["text"] as? String ?? "",
                normalizedVisibleText: object["normalizedText"] as? String ?? "",
                chatTranscriptTheme: object["chatTranscriptTheme"] as? String ?? "",
                messageLayouts: (object["messageLayouts"] as? [Any] ?? [])
                    .compactMap(Self.messageLayout),
                visibleMessageRoleTexts: object["visibleMessageRoleTexts"] as? [String] ?? [],
                chatSupportLineTitles: object["chatSupportLineTitles"] as? [String] ?? [],
                chatTerminalSupportLineTitles: object["chatTerminalSupportLineTitles"] as? [String] ?? [],
                chatToolActivityItemTitles: object["chatToolActivityItemTitles"] as? [String] ?? [],
                chatApplyPatchActivityTitles: object["chatApplyPatchActivityTitles"] as? [String] ?? [],
                chatProcessingTitles: object["chatProcessingTitles"] as? [String] ?? [],
                chatProcessingClassNames: object["chatProcessingClassNames"] as? [String] ?? [],
                chatProcessingDurationTexts: object["chatProcessingDurationTexts"] as? [String] ?? [],
                chatProcessingDurationSeconds: (object["chatProcessingDurationSeconds"] as? [Any] ?? [])
                    .compactMap { value in
                        if let intValue = value as? Int {
                            return intValue
                        }
                        if let doubleValue = value as? Double {
                            return Int(doubleValue)
                        }
                        return nil
                    },
                chatToolActivityTitles: object["chatToolActivityTitles"] as? [String] ?? [],
                liveExampleChatProcessingBlockCount: object["liveExampleChatProcessingBlockCount"] as? Int ?? 0,
                terminalCommandIconCount: object["terminalCommandIconCount"] as? Int ?? 0,
                mainFlowNormalizedText: object["mainFlowNormalizedText"] as? String ?? "",
                toolActivityDetailsCount: object["toolActivityDetailsCount"] as? Int ?? 0,
                toolActivityDisclosureCount: object["toolActivityDisclosureCount"] as? Int ?? 0,
                shellExecutionDisclosureCount: object["shellExecutionDisclosureCount"] as? Int ?? 0,
                shellExecutionOutputBlockCount: object["shellExecutionOutputBlockCount"] as? Int ?? 0,
                shellExecutionOutputNormalizedText: object["shellExecutionOutputNormalizedText"] as? String ?? "",
                katexElementCount: object["katexElementCount"] as? Int ?? 0,
                highlightedCodeElementCount: object["highlightedCodeElementCount"] as? Int ?? 0,
                markdownCodeBlockCount: object["markdownCodeBlockCount"] as? Int ?? 0,
                chatApplyPatchDiffCardCount: object["chatApplyPatchDiffCardCount"] as? Int ?? 0,
                capturedAtMilliseconds: object["capturedAtMilliseconds"] as? Int
            )
            let fingerprint = Self.fingerprint(for: probe)
            guard fingerprint != self.lastVisibleTextProbeFingerprint else {
                return
            }
            self.lastVisibleTextProbeFingerprint = fingerprint
            self.onRenderedProbe?(probe)
        }
    }

    private static func messageLayout(_ value: Any) -> ExampleChatTranscriptVisibleTextProbe.MessageLayout? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        return ExampleChatTranscriptVisibleTextProbe.MessageLayout(
            role: object["role"] as? String ?? "",
            dataRole: object["dataRole"] as? String ?? "",
            left: doubleValue(object["left"]) ?? 0,
            right: doubleValue(object["right"]) ?? 0,
            width: doubleValue(object["width"]) ?? 0,
            centerX: doubleValue(object["centerX"]) ?? 0
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let number as NSNumber:
            return number.doubleValue
        default:
            return nil
        }
    }

    private static func javascriptLiteral(_ value: [String: Any]) -> String? {
        let object = value.mapValues { anyJSONValue($0) }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
            .replacingOccurrences(of: "</script", with: "<\\/script")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func anyJSONValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { anyJSONValue($0) }
        case let array as [Any]:
            return array.map { anyJSONValue($0) }
        default:
            return value
        }
    }

    private static func javascriptStringLiteral(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    private static func signature(for state: ExampleChatTranscriptRenderState) -> String {
        let object: [String: Any] = [
            "payload": state.payload,
            "presentation": state.presentation
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return UUID().uuidString
        }
        return json
    }

    private static func fingerprint(for probe: ExampleChatTranscriptVisibleTextProbe) -> String {
        [
            "\(probe.visibleText.count)",
            "\(probe.normalizedVisibleText.hashValue)",
            "\(probe.chatTranscriptTheme)",
            "\(probe.messageLayouts.hashValue)",
            "\(probe.visibleMessageRoleTexts.hashValue)",
            "\(probe.chatSupportLineTitles.hashValue)",
            "\(probe.chatTerminalSupportLineTitles.hashValue)",
            "\(probe.chatToolActivityItemTitles.hashValue)",
            "\(probe.chatApplyPatchActivityTitles.hashValue)",
            "\(probe.chatProcessingTitles.hashValue)",
            "\(probe.chatProcessingClassNames.hashValue)",
            "\(probe.chatProcessingDurationTexts.hashValue)",
            "\(probe.chatToolActivityTitles.hashValue)",
            "\(probe.terminalCommandIconCount)",
            "\(probe.liveExampleChatProcessingBlockCount)",
            "\(probe.mainFlowNormalizedText.hashValue)",
            "\(probe.toolActivityDetailsCount)",
            "\(probe.toolActivityDisclosureCount)",
            "\(probe.shellExecutionDisclosureCount)",
            "\(probe.shellExecutionOutputBlockCount)",
            "\(probe.shellExecutionOutputNormalizedText.hashValue)",
            "\(probe.katexElementCount)",
            "\(probe.highlightedCodeElementCount)",
            "\(probe.markdownCodeBlockCount)",
            "\(probe.chatApplyPatchDiffCardCount)"
        ].joined(separator: ":")
    }
}

private extension WKWebView {
    @MainActor
    func chatFullDocumentContentSize() async throws -> CGSize {
        let script = """
        (() => {
          const root = document.scrollingElement || document.documentElement || document.body;
          const html = document.documentElement || root;
          const body = document.body || root;
          const width = Math.max(
            root ? root.scrollWidth : 0,
            html ? html.scrollWidth : 0,
            body ? body.scrollWidth : 0,
            root ? root.clientWidth : 0,
            html ? html.clientWidth : 0
          );
          const height = Math.max(
            root ? root.scrollHeight : 0,
            html ? html.scrollHeight : 0,
            body ? body.scrollHeight : 0,
            root ? root.clientHeight : 0,
            html ? html.clientHeight : 0
          );
          return JSON.stringify({ width, height });
        })();
        """
        let result = try await evaluateJavaScriptValue(script)
        guard let json = result as? String,
              let data = json.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let width = Self.doubleValue(payload["width"]),
              let height = Self.doubleValue(payload["height"]) else {
            throw ExampleChatTranscriptExportController.ExportError.invalidDocumentSize
        }
        return CGSize(width: width, height: height)
    }

    @MainActor
    private func evaluateJavaScriptValue(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }
}
