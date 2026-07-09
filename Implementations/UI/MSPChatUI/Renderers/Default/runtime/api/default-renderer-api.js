(function (root, factory) {
  const api = factory({
    projection: root.MSPChatUIProjection
  });
  root.MSPChatUIDefaultRenderer = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ projection }) {
  let lastProjection = null;
  let lastTimeline = null;

  function clone(value) {
    if (value === undefined) return undefined;
    return JSON.parse(JSON.stringify(value));
  }

  function manifest() {
    return window.MSPChatUIDefaultManifest?.manifest || {};
  }

  function defaultPresentation() {
    return clone(manifest().defaultPresentation || {});
  }

  function commandBridge() {
    const bridge = window.__chatTranscriptCommandBridge;
    return bridge && typeof bridge.execute === "function" ? bridge : null;
  }

  function runtimeReady() {
    return Boolean(commandBridge());
  }

  function waitForRuntime(timeoutMilliseconds = 5000) {
    if (runtimeReady()) return Promise.resolve(commandBridge());
    return new Promise((resolve, reject) => {
      const started = performance.now();
      let timer = 0;
      function poll() {
        if (runtimeReady()) {
          window.clearTimeout(timer);
          resolve(commandBridge());
          return;
        }
        if (performance.now() - started > timeoutMilliseconds) {
          reject(new Error("MSPChatUI Default command bridge did not become ready."));
          return;
        }
        timer = window.setTimeout(poll, 25);
      }
      poll();
    });
  }

  async function invokeCommand(command, payload, options = {}) {
    const bridge = await waitForRuntime(options.timeoutMilliseconds);
    return bridge.execute(command, clone(payload ?? null), options.commandOptions || {});
  }

  async function applyOperation(operation, options = {}) {
    switch (operation.kind) {
    case "fullRender":
      await invokeCommand("set_presentation", operation.presentation, { commandOptions: { preserveScrollAnchor: true } });
      return invokeCommand("render_payload", operation.payload, options);
    case "presentationOnlyUpdate":
      return invokeCommand("set_presentation", operation.presentation, {
        commandOptions: { preserveScrollAnchor: true, suppressConversationRerender: true }
      });
    case "payloadPatch":
      if (operation.presentation) {
        await invokeCommand("set_presentation", operation.presentation, {
          commandOptions: { preserveScrollAnchor: true, suppressConversationRerender: true }
        });
      }
      return invokeCommand("apply_payload_patch", operation.patch, options);
    case "directStreamingUpdate":
      if (operation.presentation) {
        await invokeCommand("set_presentation", operation.presentation, {
          commandOptions: { preserveScrollAnchor: true, suppressConversationRerender: true }
        });
      }
      return invokeCommand("update_streaming_markdown_blocks", operation.update, options);
    case "scrollSync":
      return invokeCommand("set_presentation", window.__chatTranscriptPresentation || {}, {
        commandOptions: { preserveScrollAnchor: true, suppressConversationRerender: true }
      });
    default:
      throw new Error(`Unknown MSPChatUI render operation: ${operation.kind}`);
    }
  }

  function projectTimeline(timeline, options = {}) {
    return projection.projectTimeline(timeline, {
      ...options,
      defaultPresentation: options.defaultPresentation || defaultPresentation()
    });
  }

  async function renderTimeline(timeline, options = {}) {
    const nextProjection = projectTimeline(timeline, options);
    const operation = { kind: "fullRender", payload: nextProjection.payload, presentation: nextProjection.presentation };
    const result = await applyOperation(operation, options);
    lastProjection = clone(nextProjection);
    lastTimeline = clone(nextProjection.timeline);
    window.dispatchEvent(new CustomEvent("msp-chat-ui-default-rendered", {
      detail: { operation: clone(operation), projection: clone(nextProjection), result }
    }));
    return result;
  }

  async function updateTimeline(timeline, options = {}) {
    const planned = projection.planTimeline(lastProjection, timeline, {
      ...options,
      defaultPresentation: options.defaultPresentation || defaultPresentation()
    });
    const result = await applyOperation(planned.operation, options);
    lastProjection = clone(planned.projection);
    lastTimeline = clone(planned.projection.timeline);
    window.dispatchEvent(new CustomEvent("msp-chat-ui-default-updated", {
      detail: { operation: clone(planned.operation), projection: clone(planned.projection), result }
    }));
    return result;
  }

  function reset() {
    lastProjection = null;
    lastTimeline = null;
  }

  async function applyRuntimeEvent(event, options = {}) {
    if (!lastTimeline && event?.type !== "timeline.replace") {
      throw new Error("MSPChatUI Default cannot apply runtime events before a timeline is rendered.");
    }
    const nextTimeline = projection.applyRuntimeEvent(lastTimeline || event.timeline, event);
    return lastProjection ? updateTimeline(nextTimeline, options) : renderTimeline(nextTimeline, options);
  }

  async function applyRuntimeEvents(events, options = {}) {
    let result = null;
    for (const event of Array.isArray(events) ? events : []) {
      result = await applyRuntimeEvent(event, options);
    }
    return result;
  }

  return Object.freeze({
    waitForRuntime,
    invokeCommand,
    projectTimeline,
    renderTimeline,
    updateTimeline,
    applyRuntimeEvent,
    applyRuntimeEvents,
    applyOperation,
    reset
  });
});
