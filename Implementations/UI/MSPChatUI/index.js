require("./Contracts/runtime/status.js");
require("./Contracts/runtime/timeline.js");
require("./Contracts/runtime/events.js");
require("./Projection/runtime/identity.js");
require("./Projection/runtime/default/activity-adapter.js");
require("./Projection/runtime/default/block-adapter.js");
require("./Projection/runtime/default/message-adapter.js");
require("./Projection/runtime/default/action-policy-adapter.js");
require("./Projection/runtime/default/presentation-adapter.js");
require("./Projection/runtime/default-adapter.js");
require("./Projection/runtime/payload-diff.js");
require("./Projection/runtime/render-planner.js");
require("./Projection/runtime/stream-delta.js");
require("./Projection/runtime/timeline-store.js");
require("./Projection/runtime/index.js");
require("./Registry/runtime/renderer-registry.js");

module.exports = Object.freeze({
  contracts: Object.freeze({
    status: globalThis.MSPChatUIStatus,
    timeline: globalThis.MSPChatUITimelineContract,
    events: globalThis.MSPChatUIRuntimeEvents
  }),
  projection: globalThis.MSPChatUIProjection,
  registry: globalThis.MSPChatUIRendererRegistry,
  defaultRendererManifest: require("./Renderers/Default/renderer.manifest.json")
});
