package dev.msp.chatui;

import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;

public final class MSPChatUIWebViewHost {
  public interface BridgeHandler {
    void onHostMessage(String channel, String payloadJSON);
  }

  private final WebView webView;
  private final BridgeHandler bridgeHandler;

  public MSPChatUIWebViewHost(WebView webView, BridgeHandler bridgeHandler) {
    this.webView = webView;
    this.bridgeHandler = bridgeHandler;
    configureWebView(webView);
    webView.addJavascriptInterface(new Bridge(), "MSPChatUIAndroidHost");
  }

  public void load(String rendererURL) {
    webView.loadUrl(rendererURL);
  }

  public void renderTimelineJSON(String json) {
    callRenderer("renderTimeline", json);
  }

  public void applyRuntimeEventJSON(String json) {
    callRenderer("applyRuntimeEvent", json);
  }

  private static void configureWebView(WebView webView) {
    WebSettings settings = webView.getSettings();
    settings.setJavaScriptEnabled(true);
    settings.setDomStorageEnabled(true);
    settings.setAllowFileAccess(true);
    settings.setAllowContentAccess(true);
  }

  private void callRenderer(String method, String json) {
    String script = "(async()=>{const r=await window.MSPChatUIWebHost.waitForRenderer();"
      + "return r." + method + "(JSON.parse(" + quote(json) + "));})();";
    webView.evaluateJavascript(script, null);
  }

  private static String quote(String value) {
    return "\"" + value
      .replace("\\", "\\\\")
      .replace("\"", "\\\"")
      .replace("\n", "\\n")
      .replace("\r", "\\r") + "\"";
  }

  private final class Bridge {
    @JavascriptInterface
    public void postMessage(String channel, String payloadJSON) {
      bridgeHandler.onHostMessage(channel, payloadJSON);
    }
  }
}
