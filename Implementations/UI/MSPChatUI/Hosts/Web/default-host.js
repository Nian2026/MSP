(function () {
  const currentScript = document.currentScript;
  const defaultFixture = currentScript?.dataset?.defaultFixture || "";

  async function readJSON(url) {
    const response = await fetch(url, { cache: "no-cache" });
    if (!response.ok) {
      throw new Error(`Failed to load fixture ${url}: HTTP ${response.status}`);
    }
    return response.json();
  }

  function rendererReady() {
    return window.MSPChatUIDefaultRenderer &&
      typeof window.MSPChatUIDefaultRenderer.renderTimeline === "function";
  }

  function waitForRenderer(timeoutMilliseconds = 5000) {
    if (rendererReady()) return Promise.resolve(window.MSPChatUIDefaultRenderer);
    return new Promise((resolve, reject) => {
      const started = performance.now();
      let timer = 0;
      function poll() {
        if (rendererReady()) {
          window.clearTimeout(timer);
          resolve(window.MSPChatUIDefaultRenderer);
          return;
        }
        if (performance.now() - started > timeoutMilliseconds) {
          reject(new Error("MSPChatUI Default renderer API did not become ready."));
          return;
        }
        timer = window.setTimeout(poll, 25);
      }
      poll();
    });
  }

  async function renderTimelineFixture(url, options = {}) {
    const [renderer, timeline] = await Promise.all([waitForRenderer(), readJSON(url)]);
    return renderer.renderTimeline(timeline, options);
  }

  async function renderDefaultFixture() {
    const url = new URL(window.location.href);
    const fixture = url.searchParams.get("fixture") || defaultFixture;
    if (!fixture) return;
    try {
      await renderTimelineFixture(fixture);
    } catch (error) {
      window.__mspChatUIDefaultFixtureError = error instanceof Error ? error.message : String(error);
      console.error("[MSPChatUIDefaultHost]", error);
    }
  }

  window.MSPChatUIWebHost = Object.freeze({
    waitForRenderer,
    renderTimelineFixture
  });

  renderDefaultFixture();
})();
