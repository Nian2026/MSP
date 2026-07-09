(function () {
  const CHANNELS = [
    "messageAction",
    "openAttachment",
    "selectLayoutLabComponent",
    "presentationProbe",
    "codeBlockLayoutChanged",
    "copyCode",
    "explanationAnchor",
    "__CHAT_TRANSCRIPT_SELECTION_CONTEXT_MENU_HANDLER_NAME__"
  ];

  function hostBridge() {
    return window.MSPChatUIHost && typeof window.MSPChatUIHost === "object"
      ? window.MSPChatUIHost
      : null;
  }

  function postToMSPHost(channel, payload) {
    const bridge = hostBridge();
    if (bridge && typeof bridge.postMessage === "function") {
      bridge.postMessage(channel, payload);
      return;
    }
    if (bridge && typeof bridge[channel] === "function") {
      bridge[channel](payload);
      return;
    }
    const androidHost = window.MSPChatUIAndroidHost;
    if (androidHost && typeof androidHost.postMessage === "function") {
      androidHost.postMessage(channel, JSON.stringify(payload ?? null));
      return;
    }
    const webView2 = window.chrome?.webview;
    if (webView2 && typeof webView2.postMessage === "function") {
      webView2.postMessage({ channel, payload });
      return;
    }
    window.dispatchEvent(new CustomEvent("msp-chat-ui-host-message", {
      detail: { channel, payload }
    }));
  }

  const webkit = window.webkit && typeof window.webkit === "object"
    ? window.webkit
    : {};
  const messageHandlers = webkit.messageHandlers && typeof webkit.messageHandlers === "object"
    ? webkit.messageHandlers
    : {};

  CHANNELS.forEach((channel) => {
    if (messageHandlers[channel] && typeof messageHandlers[channel].postMessage === "function") {
      return;
    }
    messageHandlers[channel] = {
      postMessage(payload) {
        postToMSPHost(channel, payload);
      }
    };
  });

  webkit.messageHandlers = messageHandlers;
  if (!window.webkit) {
    window.webkit = webkit;
  }

  window.MSPChatUIHostBridgeCompat = Object.freeze({
    channels: CHANNELS.slice(),
    postMessage: postToMSPHost
  });
})();
