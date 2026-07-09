import Foundation
import WebKit

public final class MSPChatUIWebViewHost: NSObject, WKScriptMessageHandler {
  public typealias BridgeHandler = (_ channel: String, _ payload: Any) -> Void

  private let webView: WKWebView
  private let bridgeHandler: BridgeHandler

  public init(webView: WKWebView, bridgeHandler: @escaping BridgeHandler) {
    self.webView = webView
    self.bridgeHandler = bridgeHandler
    super.init()
    installBridgeHandlers(on: webView.configuration.userContentController)
  }

  deinit {
    removeBridgeHandlers(on: webView.configuration.userContentController)
  }

  public static func makeWebView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    return WKWebView(frame: .zero, configuration: configuration)
  }

  public func load(rendererHTMLURL: URL, allowingReadAccessTo readAccessURL: URL? = nil) {
    let accessRoot = readAccessURL ?? Self.defaultReadAccessRoot(for: rendererHTMLURL)
    webView.loadFileURL(rendererHTMLURL, allowingReadAccessTo: accessRoot)
  }

  public func renderTimelineJSON(_ json: String) {
    evaluateRendererCall("renderTimeline", json)
  }

  public func applyRuntimeEventJSON(_ json: String) {
    evaluateRendererCall("applyRuntimeEvent", json)
  }

  public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    bridgeHandler(message.name, message.body)
  }

  private func installBridgeHandlers(on controller: WKUserContentController) {
    for channel in Self.bridgeChannels {
      controller.removeScriptMessageHandler(forName: channel)
      controller.add(WeakScriptMessageHandler(self), name: channel)
    }
  }

  private func removeBridgeHandlers(on controller: WKUserContentController) {
    for channel in Self.bridgeChannels {
      controller.removeScriptMessageHandler(forName: channel)
    }
  }

  private func evaluateRendererCall(_ method: String, _ json: String) {
    let encodedJSON = Self.javascriptStringLiteral(json)
    let script = """
    (async () => {
      const renderer = await window.MSPChatUIWebHost.waitForRenderer();
      return renderer.\(method)(JSON.parse(\(encodedJSON)));
    })();
    """
    webView.evaluateJavaScript(script)
  }

  private static func javascriptStringLiteral(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
    let encoded = String(data: data ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
  }

  private static func defaultReadAccessRoot(for rendererHTMLURL: URL) -> URL {
    rendererHTMLURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static let bridgeChannels = [
    "messageAction",
    "openAttachment",
    "selectLayoutLabComponent",
    "presentationProbe",
    "codeBlockLayoutChanged",
    "copyCode",
    "explanationAnchor",
    "__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__"
  ]
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}
