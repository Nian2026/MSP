(function (root, factory) {
  const api = factory({
    adapter: root.MSPChatUIDefaultAdapter,
    planner: root.MSPChatUIRenderPlanner,
    store: root.MSPChatUITimelineStore,
    timeline: root.MSPChatUITimelineContract
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIProjection = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ adapter, planner, store, timeline }) {
  function projectTimeline(input, options = {}) {
    const validation = timeline.validateTimeline(input);
    if (!validation.ok) {
      const error = new Error(`Invalid MSPChatUI timeline: ${validation.errors.join("; ")}`);
      error.validation = validation;
      throw error;
    }
    return adapter.project(validation.value, options);
  }

  function planTimeline(previousProjection, input, options = {}) {
    const nextProjection = projectTimeline(input, options);
    return {
      projection: nextProjection,
      operation: planner.plan(previousProjection, nextProjection)
    };
  }

  return Object.freeze({
    applyRuntimeEvent: store.applyRuntimeEvent,
    applyRuntimeEvents: store.applyRuntimeEvents,
    projectTimeline,
    planTimeline
  });
});
