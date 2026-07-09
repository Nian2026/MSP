export type MSPChatUIHostMessage = {
  channel: string;
  payload: unknown;
};

export type MSPChatUIWebView2 = {
  Source?: string;
  CoreWebView2?: {
    ExecuteScriptAsync(script: string): Promise<string>;
    WebMessageReceived?: unknown;
  };
  addEventListener?(name: string, handler: (event: MessageEvent) => void): void;
};

export type MSPChatUIWebView2HostOptions = {
  webView: MSPChatUIWebView2;
  rendererURL: string;
  onHostMessage?: (message: MSPChatUIHostMessage) => void;
};

export class MSPChatUIWebView2Host {
  private readonly webView: MSPChatUIWebView2;
  private readonly onHostMessage?: (message: MSPChatUIHostMessage) => void;

  constructor(options: MSPChatUIWebView2HostOptions) {
    this.webView = options.webView;
    this.onHostMessage = options.onHostMessage;
    this.webView.Source = options.rendererURL;
    this.installBridge();
  }

  renderTimeline(timeline: unknown): Promise<string> {
    return this.callRenderer("renderTimeline", timeline);
  }

  applyRuntimeEvent(event: unknown): Promise<string> {
    return this.callRenderer("applyRuntimeEvent", event);
  }

  private installBridge(): void {
    this.webView.addEventListener?.("message", (event) => {
      const data = event.data as MSPChatUIHostMessage;
      if (data && typeof data.channel === "string") {
        this.onHostMessage?.(data);
      }
    });
  }

  private callRenderer(method: string, value: unknown): Promise<string> {
    const payload = JSON.stringify(value);
    const script = `
      (async () => {
        const renderer = await window.MSPChatUIWebHost.waitForRenderer();
        return renderer.${method}(${payload});
      })();
    `;
    const core = this.webView.CoreWebView2;
    if (!core) return Promise.reject(new Error("CoreWebView2 is not ready."));
    return core.ExecuteScriptAsync(script);
  }
}
