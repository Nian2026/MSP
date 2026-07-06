import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

enum ExampleChatTranscriptRendererShell {
    private struct HTMLShellTemplate {
        var prefix: String
        var suffix: String
        var reservedCapacity: Int

        func htmlString(bodyPreambleMarkup: String) -> String {
            var html = String()
            html.reserveCapacity(reservedCapacity + bodyPreambleMarkup.utf8.count)
            html += prefix
            html += bodyPreambleMarkup
            html += suffix
            return html
        }
    }

    private struct DocumentAssetManifest: Decodable {
        struct HighlightThemeStyleSheetNames: Decodable {
            var light: String
            var dark: String
        }

        var documentTemplateName: String
        var katexStyleSheetName: String
        var highlightScriptName: String
        var highlightThemeStyleSheetNames: HighlightThemeStyleSheetNames
        var documentStyleSheetName: String
        var symbolCatalogBootstrapScriptName: String
        var hostCommandInvocationScriptName: String
        var bootstrapProbeScriptName: String
        var selectionRepairPayloadScriptName: String
        var selectionContextMenuUserScriptName: String
        var markdownDependencyScriptNames: [String]
        var transcriptRuntimeScriptNames: [String]
        var compatibilityExportBridgeScriptName: String
    }

    private static let documentAssetManifestName = "chat-transcript-document-assets.json"
    private static let runtimeResourcesDirectoryName = "RuntimeResources"
    private static let initialMetadataPreamblePlaceholder = "__READEX_TRANSCRIPT_INITIAL_METADATA_PREAMBLE__"
    static let shellResourceRevision = "chat-transcript-shell-2026-06-18-single-owner-streaming"

    @MainActor private static var documentAssetManifestCache: DocumentAssetManifest?
    @MainActor private static var documentHTMLTemplateCache: String?
    @MainActor private static var documentHTMLShellTemplateCache: HTMLShellTemplate?
    @MainActor private static var inlineMathScriptTagCache: [String: String] = [:]
    @MainActor private static var inlineMathStyleSheetTagCache: [String: String] = [:]
    @MainActor private static var symbolCatalogBootstrapScriptTemplateCache: String?
    @MainActor private static var hostCommandInvocationScriptCache: String?
    @MainActor private static var selectionContextMenuUserScriptTemplateCache: String?
    private static let transcriptSymbolNames = [
        "bubble.left"
    ]

    static func resourcesBaseURL() -> URL? {
        var candidates: [URL] = []

        #if SWIFT_PACKAGE
        if let packageURL = Bundle.module.resourceURL {
            candidates.append(packageURL.appendingPathComponent(runtimeResourcesDirectoryName, isDirectory: true))
            candidates.append(packageURL)
        }
        #endif

        if let mainURL = Bundle.main.resourceURL {
            candidates.append(mainURL.appendingPathComponent(runtimeResourcesDirectoryName, isDirectory: true))
            candidates.append(mainURL)
        }

        return candidates.first { url in
            FileManager.default.fileExists(
                atPath: url
                    .appendingPathComponent("Math", isDirectory: true)
                    .appendingPathComponent(documentAssetManifestName, isDirectory: false)
                    .path
            )
        }
    }

    private static func mathResourceURL(named fileName: String) -> URL? {
        resourcesBaseURL()?
            .appendingPathComponent("Math", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func defaultDocumentAssetManifest() -> DocumentAssetManifest {
        DocumentAssetManifest(
            documentTemplateName: "chat-transcript-document-template.html",
            katexStyleSheetName: "katex.min.css",
            highlightScriptName: "highlight.min.js",
            highlightThemeStyleSheetNames: .init(
                light: "highlight-github.min.css",
                dark: "highlight-github-dark.min.css"
            ),
            documentStyleSheetName: "chat-transcript-document.css",
            symbolCatalogBootstrapScriptName: "chat-transcript-symbol-catalog-bootstrap.js",
            hostCommandInvocationScriptName: "chat-transcript-host-command-invocation.js",
            bootstrapProbeScriptName: "chat-transcript-bootstrap-probe.js",
            selectionRepairPayloadScriptName: "chat-transcript-selection-repair-payload.js",
            selectionContextMenuUserScriptName: "chat-transcript-selection-context-menu.js",
            markdownDependencyScriptNames: [
                "katex.min.js",
                "mhchem.min.js",
                "copy-tex.min.js",
                "prettier-standalone.js",
                "prettier-parser-html.js",
                "prettier-parser-postcss.js",
                "prettier-parser-babel.js",
                "prettier-parser-typescript.js",
                "chat-unified-markdown.js",
                "chat-markdown-renderer.js"
            ],
            transcriptRuntimeScriptNames: [
                "chat-transcript-renderer-components.js",
                "chat-transcript-message-status-model.js",
                "chat-transcript-message-block-model.js",
                "chat-transcript-message-runtime-model.js",
                "chat-transcript-host-bridge.js",
                "chat-transcript-style-platform.js",
                "chat-transcript-message-dom.js",
                "chat-transcript-scroll-metrics.js",
                "chat-transcript-anchor-platform.js",
                "chat-transcript-dom-platform.js",
                "chat-transcript-render-support.js",
                "chat-transcript-visual-support.js",
                "chat-transcript-presentation-controller.js",
                "chat-transcript-scroll-coordinator.js",
                "chat-transcript-conversation-controller.js",
                "chat-transcript-interaction-state.js",
                "chat-transcript-overlay-controller.js",
                "chat-transcript-video-progress-renderer.js",
                "chat-transcript-message-block-support-renderer.js",
                "chat-transcript-message-block-renderer.js",
                "chat-transcript-message-ui-renderer.js",
                "chat-transcript-message-article-renderer.js",
                "chat-transcript-conversation-layout.js",
                "chat-transcript-conversation-renderer.js",
                "chat-transcript-render-pipeline.js",
                "chat-transcript-render-coordinator.js",
                "chat-transcript-payload-model.js",
                "chat-transcript-payload-patcher.js",
                "chat-transcript-payload-store.js",
                "chat-transcript-runtime.js",
                "chat-transcript-document-shell.js",
                "chat-transcript-document-runtime.js",
                "chat-transcript-explanation-anchors.js",
                "chat-transcript-bootstrap-legacy-runtime-bindings.js",
                "chat-transcript-command-bridge.js",
                "chat-transcript-bootstrap-bindings.js",
                "chat-transcript-bootstrap-foundation-stage.js",
                "chat-transcript-bootstrap-interaction-stage.js",
                "chat-transcript-bootstrap-document-stage.js",
                "chat-transcript-bootstrap-render-stage.js",
                "chat-transcript-bootstrap-runtime-stage.js",
                "chat-transcript-bootstrap-stage-assembler.js",
                "chat-transcript-bootstrap-composer.js",
                "chat-transcript-bootstrap-support.js",
                "chat-transcript-bootstrap-lifecycle.js",
                "chat-transcript-bootstrap.js",
                "chat-transcript-bootstrap-entry.js",
                "chat-transcript-bootstrap-launch.js",
                "chat-transcript-bootstrap-autostart.js"
            ],
            compatibilityExportBridgeScriptName: "chat-long-image-export-bridge.js"
        )
    }

    @MainActor
    private static func documentAssetManifest() -> DocumentAssetManifest {
        if let cached = documentAssetManifestCache {
            return cached
        }

        guard let manifestURL = mathResourceURL(named: documentAssetManifestName),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(DocumentAssetManifest.self, from: data) else {
            let fallback = defaultDocumentAssetManifest()
            documentAssetManifestCache = fallback
            return fallback
        }

        documentAssetManifestCache = manifest
        return manifest
    }

    @MainActor
    private static func documentHTMLTemplate() -> String {
        if let cached = documentHTMLTemplateCache {
            return cached
        }

        let manifest = documentAssetManifest()
        let template = mathResourceURL(named: manifest.documentTemplateName)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? defaultDocumentHTMLTemplate()
        documentHTMLTemplateCache = template
        return template
    }

    private static func defaultDocumentHTMLTemplate() -> String {
        """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            __CHAT_TRANSCRIPT_KATEX_STYLESHEET_LINK__
            __CHAT_TRANSCRIPT_HIGHLIGHT_THEME_LINKS__
            __CHAT_TRANSCRIPT_STYLE_MARKUP__
            __CHAT_TRANSCRIPT_MARKDOWN_DEPENDENCY_SCRIPT_TAGS__
          </head>
          <body>
            <div id="page">
              <section id="messages"></section>
            </div>__CHAT_TRANSCRIPT_BODY_PREAMBLE__
            __CHAT_TRANSCRIPT_RUNTIME_SCRIPT_TAGS__
          </body>
        </html>
        """
    }

    @MainActor
    static func hostCommandInvocationScriptSource() -> String {
        if let cached = hostCommandInvocationScriptCache {
            return cached
        }

        let manifest = documentAssetManifest()
        let source = mathResourceURL(named: manifest.hostCommandInvocationScriptName)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? defaultHostCommandInvocationScript()
        hostCommandInvocationScriptCache = source
        return source
    }

    @MainActor
    static func selectionContextMenuUserScriptSource(handlerName: String) -> String {
        if let cached = selectionContextMenuUserScriptTemplateCache {
            return cached.replacingOccurrences(
                of: "__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__",
                with: handlerName
            )
        }

        let manifest = documentAssetManifest()
        guard let scriptURL = mathResourceURL(named: manifest.selectionContextMenuUserScriptName),
              let template = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            return ""
        }

        selectionContextMenuUserScriptTemplateCache = template
        return template.replacingOccurrences(
            of: "__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__",
            with: handlerName
        )
    }

    @MainActor
    private static func documentHTMLShellTemplate() -> HTMLShellTemplate {
        if let cached = documentHTMLShellTemplateCache {
            return cached
        }

        let html = documentHTML(
            styleMarkup: transcriptDocumentStyleMarkup(inline: true),
            bodyPreambleMarkup: initialMetadataPreamblePlaceholder,
            inlineScripts: true,
            includeHighlight: true,
            includeSymbolCatalog: true,
            includeCompatibilityExportBridge: false
        )

        let template: HTMLShellTemplate
        if let placeholderRange = html.range(of: initialMetadataPreamblePlaceholder) {
            template = HTMLShellTemplate(
                prefix: String(html[..<placeholderRange.lowerBound]),
                suffix: String(html[placeholderRange.upperBound...]),
                reservedCapacity: html.utf8.count
            )
        } else {
            template = HTMLShellTemplate(prefix: html, suffix: "", reservedCapacity: html.utf8.count)
        }

        documentHTMLShellTemplateCache = template
        return template
    }

    @MainActor
    static func htmlString(initialMetadata: [String: Any]? = nil) -> String {
        let preamble = [
            shellResourceRevisionPreamble(),
            initialShellStylePreamble(initialMetadata: initialMetadata)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        return documentHTMLShellTemplate().htmlString(bodyPreambleMarkup: preamble)
    }

    @MainActor
    private static func documentHTML(
        styleMarkup: String,
        bodyPreambleMarkup: String = "",
        inlineScripts: Bool,
        includeHighlight: Bool,
        includeSymbolCatalog: Bool,
        includeCompatibilityExportBridge: Bool
    ) -> String {
        let manifest = documentAssetManifest()
        let highlightThemeLinks = includeHighlight
            ? """
            <link id="highlight-theme-light" rel="stylesheet" href="Math/\(manifest.highlightThemeStyleSheetNames.light)" />
            <link id="highlight-theme-dark" rel="stylesheet" href="Math/\(manifest.highlightThemeStyleSheetNames.dark)" disabled />
            """
            : ""
        let replacements = [
            ("__CHAT_TRANSCRIPT_KATEX_STYLESHEET_LINK__", #"<link rel="stylesheet" href="Math/\#(manifest.katexStyleSheetName)" />"#),
            ("__CHAT_TRANSCRIPT_HIGHLIGHT_THEME_LINKS__", highlightThemeLinks),
            ("__CHAT_TRANSCRIPT_STYLE_MARKUP__", styleMarkup),
            (
                "__CHAT_TRANSCRIPT_MARKDOWN_DEPENDENCY_SCRIPT_TAGS__",
                markdownDependencyScriptTags(inline: inlineScripts, includeHighlight: includeHighlight)
            ),
            ("__CHAT_TRANSCRIPT_BODY_PREAMBLE__", bodyPreambleMarkup.isEmpty ? "" : "\n\(bodyPreambleMarkup)"),
            (
                "__CHAT_TRANSCRIPT_RUNTIME_SCRIPT_TAGS__",
                transcriptRuntimeScriptTags(
                    inline: inlineScripts,
                    includeSymbolCatalog: includeSymbolCatalog,
                    includeCompatibilityExportBridge: includeCompatibilityExportBridge
                )
            )
        ]

        return replacements.reduce(documentHTMLTemplate()) { partial, replacement in
            partial.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    @MainActor
    private static func markdownDependencyScriptTags(inline: Bool, includeHighlight: Bool) -> String {
        let manifest = documentAssetManifest()
        var tags: [String] = []
        if includeHighlight {
            tags.append(externalMathScriptTag(named: manifest.highlightScriptName))
        }
        tags.append(contentsOf: manifest.markdownDependencyScriptNames.map { mathScriptTag(named: $0, inline: inline) })
        return tags.joined(separator: "\n            ")
    }

    @MainActor
    private static func transcriptRuntimeScriptTags(
        inline: Bool,
        includeSymbolCatalog: Bool,
        includeCompatibilityExportBridge: Bool
    ) -> String {
        let manifest = documentAssetManifest()
        var tags: [String] = []
        if includeSymbolCatalog {
            tags.append(symbolCatalogBootstrapScriptTag())
        }
        tags.append(contentsOf: manifest.transcriptRuntimeScriptNames.map { mathScriptTag(named: $0, inline: inline) })
        if includeCompatibilityExportBridge {
            tags.append(mathScriptTag(named: manifest.compatibilityExportBridgeScriptName, inline: inline))
        }
        return tags.joined(separator: "\n            ")
    }

    @MainActor
    private static func transcriptDocumentStyleMarkup(inline: Bool) -> String {
        mathStyleSheetTag(named: documentAssetManifest().documentStyleSheetName, inline: inline)
    }

    @MainActor
    private static func inlineMathScriptTag(named fileName: String) -> String {
        if let cached = inlineMathScriptTagCache[fileName] {
            return cached
        }

        let fallbackTag = externalMathScriptTag(named: fileName)
        guard let scriptURL = mathResourceURL(named: fileName),
              let scriptContents = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            return fallbackTag
        }

        let sanitized = scriptContents.replacingOccurrences(of: "</script", with: "<\\/script")
        let tag = "<script>\n\(sanitized)\n</script>"
        inlineMathScriptTagCache[fileName] = tag
        return tag
    }

    private static func externalMathScriptTag(named fileName: String) -> String {
        #"<script src="Math/\#(fileName)"></script>"#
    }

    @MainActor
    private static func mathScriptTag(named fileName: String, inline: Bool) -> String {
        inline ? inlineMathScriptTag(named: fileName) : externalMathScriptTag(named: fileName)
    }

    @MainActor
    private static func inlineMathStyleSheetTag(named fileName: String) -> String {
        if let cached = inlineMathStyleSheetTagCache[fileName] {
            return cached
        }

        let fallbackTag = externalMathStyleSheetTag(named: fileName)
        guard let styleURL = mathResourceURL(named: fileName),
              let styleContents = try? String(contentsOf: styleURL, encoding: .utf8) else {
            return fallbackTag
        }

        let sanitized = styleContents.replacingOccurrences(of: "</style", with: "<\\/style")
        let tag = "<style>\n\(sanitized)\n</style>"
        inlineMathStyleSheetTagCache[fileName] = tag
        return tag
    }

    private static func externalMathStyleSheetTag(named fileName: String) -> String {
        #"<link rel="stylesheet" href="Math/\#(fileName)" />"#
    }

    @MainActor
    private static func mathStyleSheetTag(named fileName: String, inline: Bool) -> String {
        inline ? inlineMathStyleSheetTag(named: fileName) : externalMathStyleSheetTag(named: fileName)
    }

    @MainActor
    private static func symbolCatalogBootstrapScriptTag() -> String {
        let payloadJSON = symbolCatalogPayloadJSON()
        let template = symbolCatalogBootstrapScriptTemplate()
        let source = template.replacingOccurrences(
            of: "__CHAT_TRANSCRIPT_SYSTEM_SYMBOLS_PAYLOAD__",
            with: payloadJSON
        )
        return "<script>\n\(source)\n</script>"
    }

    @MainActor
    private static func symbolCatalogBootstrapScriptTemplate() -> String {
        if let cached = symbolCatalogBootstrapScriptTemplateCache {
            return cached
        }

        let manifest = documentAssetManifest()
        let template = mathResourceURL(named: manifest.symbolCatalogBootstrapScriptName)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? """
            (() => {
              const catalog = __CHAT_TRANSCRIPT_SYSTEM_SYMBOLS_PAYLOAD__;
              window.__chatTranscriptSystemSymbols =
                catalog && typeof catalog === "object" ? catalog : {};
            })();
            """
        symbolCatalogBootstrapScriptTemplateCache = template
        return template
    }

    @MainActor
    private static func symbolCatalogPayloadJSON() -> String {
        let transcriptSymbols = transcriptSymbolNames.reduce(into: [String: String]()) { result, systemName in
            guard let dataURL = symbolDataURL(systemName: systemName) else {
                return
            }
            result[systemName] = dataURL
        }

        var payload: [String: Any] = [
            "toolbar": transcriptSymbols
        ]

        if let spinner = legacySpinnerDataURL() {
            payload["spinnerLegacyAnimated"] = spinner
            payload["spinnerLegacy"] = spinner
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func legacySpinnerDataURL() -> String? {
        guard let url = mathResourceURL(named: "legacy-spinner.apng"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return "data:image/apng;base64,\(data.base64EncodedString())"
    }

    private static func symbolDataURL(systemName: String) -> String? {
        #if canImport(UIKit)
        let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        guard let image = UIImage(systemName: systemName, withConfiguration: configuration)?
            .withTintColor(.black, renderingMode: .alwaysOriginal),
              let data = image.pngData() else {
            return nil
        }
        return "data:image/png;base64,\(data.base64EncodedString())"
        #elseif canImport(AppKit)
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        let configuredImage = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        ) ?? image
        guard let tiff = configuredImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return "data:image/png;base64,\(data.base64EncodedString())"
        #else
        return nil
        #endif
    }

    @MainActor
    private static func initialShellStylePreamble(initialMetadata: [String: Any]?) -> String {
        guard let initialMetadata,
              JSONSerialization.isValidJSONObject(initialMetadata),
              let data = try? JSONSerialization.data(withJSONObject: initialMetadata),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            return ""
        }

        let sanitizedPayloadJSON = payloadJSON
            .replacingOccurrences(of: "</script", with: "<\\/script")
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
            <script>
              (() => {
                const metadata = \(sanitizedPayloadJSON);
                const root = document.documentElement;
                if (!root || !metadata) {
                  return;
                }
                const theme = metadata.theme === "dark" ? "dark" : "light";
                root.setAttribute("data-theme", theme);
                const transcriptTheme = typeof metadata.chatTranscriptTheme === "string"
                  ? metadata.chatTranscriptTheme.trim()
                  : typeof metadata.readexTranscriptTheme === "string"
                  ? metadata.readexTranscriptTheme.trim()
                  : "";
                if (transcriptTheme) {
                  root.setAttribute("data-chat-transcript-theme", transcriptTheme);
                  root.setAttribute("data-readex-transcript-theme", transcriptTheme);
                }

                const style = metadata.style || {};
                const variableMappings = {
                  "--app-bg": style.appBackground,
                  "--title": style.title,
                  "--secondary": style.secondary,
                  "--assistant-bg": style.assistantBackground,
                  "--assistant-border": style.assistantBorder,
                  "--user-bg": style.userBackground,
                  "--user-border": style.userBorder,
                  "--assistant-accent": style.assistantAccent,
                  "--user-accent": style.userAccent,
                  "--chip-bg": style.chipBackground,
                  "--code-bg": style.codeBackground,
                  "--quote-border": style.blockquoteBorder,
                  "--math-bg": style.codeBackgroundSoft
                };
                Object.entries(variableMappings).forEach(([key, value]) => {
                  if (typeof value === "string" && value.trim()) {
                    root.style.setProperty(key, value);
                  }
                });
              })();
            </script>
            """
    }

    @MainActor
    private static func shellResourceRevisionPreamble() -> String {
        """
            <script>
              (() => {
                const revision = "\(shellResourceRevision)";
                window.__chatTranscriptShellResourceRevision = revision;
                document.documentElement.setAttribute("data-chat-transcript-shell-resource-revision", revision);
              })();
            </script>
            """
    }

    private static func defaultHostCommandInvocationScript() -> String {
        """
        try {
          const commandBridge = window.__chatTranscriptCommandBridge;
          if (!commandBridge || typeof commandBridge.execute !== "function") {
            throw new Error("Chat transcript command bridge unavailable");
          }
          return {
            ok: true,
            result: commandBridge.execute(command, payload, options || {}),
            bootstrapState: window.__chatTranscriptRuntimeBootstrap || null
          };
        } catch (error) {
          const commandBridge = window.__chatTranscriptCommandBridge;
          return {
            ok: false,
            command,
            errorName: error?.name || "Error",
            errorMessage: error?.message || String(error),
            errorStack: typeof error?.stack === "string" ? error.stack : "",
            hasCommandBridgeObject: typeof commandBridge,
            availableCommands: typeof commandBridge?.availableCommands === "function" ? commandBridge.availableCommands() : [],
            bootstrapState: window.__chatTranscriptRuntimeBootstrap || null
          };
        }
        """
    }
}
