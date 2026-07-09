#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..", "..");

function load(relativePath) {
  return require(path.join(root, relativePath));
}

load("Contracts/runtime/status.js");
load("Contracts/runtime/timeline.js");
load("Contracts/runtime/events.js");
load("Projection/runtime/identity.js");
load("Projection/runtime/default/activity-adapter.js");
load("Projection/runtime/default/block-adapter.js");
load("Projection/runtime/default/message-adapter.js");
load("Projection/runtime/default/action-policy-adapter.js");
load("Projection/runtime/default/presentation-adapter.js");
load("Projection/runtime/default-adapter.js");
load("Projection/runtime/payload-diff.js");
load("Projection/runtime/render-planner.js");
load("Projection/runtime/stream-delta.js");
load("Projection/runtime/timeline-store.js");
const projection = load("Projection/runtime/index.js");
const registry = load("Registry/runtime/renderer-registry.js");

function readJSON(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(root, relativePath), "utf8"));
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function appendStreamingText(timeline) {
  const next = clone(timeline);
  next.revision += 1;
  const message = next.messages.find((entry) => entry.id === "assistant-2");
  const block = message.blocks.find((entry) => entry.id === "assistant-2:text");
  block.text += " 这是追加的一段流式内容。";
  return next;
}

function updateProcessingItemText(timeline) {
  const next = clone(timeline);
  next.revision += 1;
  const message = next.messages.find((entry) => entry.id === "assistant-rich");
  const block = message.blocks.find((entry) => entry.id === "assistant-rich:processing");
  const item = block.items.find((entry) => entry.id === "assistant-rich:processing-note");
  item.text += " 这是 processing item 的直接流式更新。";
  return next;
}

function finalizeStreamingText(timeline) {
  const next = clone(timeline);
  next.revision += 1;
  const message = next.messages.find((entry) => entry.id === "assistant-2");
  const block = message.blocks.find((entry) => entry.id === "assistant-2:text");
  message.status = "success";
  block.status = "success";
  return next;
}

const fixture = readJSON("Conformance/fixtures/default-basic.conversation.json");
const richFixture = readJSON("Conformance/fixtures/default-rich.conversation.json");
const emptyStreamingFixture = readJSON("Conformance/fixtures/default-empty-streaming.conversation.json");
const defaultManifest = readJSON("Renderers/Default/renderer.manifest.json");
const defaultOptions = { defaultPresentation: defaultManifest.defaultPresentation };
const supportRendererSource = fs.readFileSync(
  path.join(root, "Renderers/Default/runtime/assets/Math/chat-transcript-message-block-support-renderer.js"),
  "utf8"
);
const typeDeclarations = fs.readFileSync(path.join(root, "Contracts/types/msp-chat-ui.d.ts"), "utf8");
const first = projection.planTimeline(null, fixture, { defaultPresentation: {} });
const second = projection.planTimeline(first.projection, appendStreamingText(fixture), {
  defaultPresentation: {}
});
const focused = clone(fixture);
focused.presentation = { ...fixture.presentation, focusedMessageID: "assistant-1" };
const presentationOnly = projection.planTimeline(first.projection, focused, { defaultPresentation: {} });
const eventTimeline = projection.applyRuntimeEvent(fixture, {
  type: "stream.delta",
  messageID: "assistant-2",
  blockID: "assistant-2:text",
  textDelta: " 这是 runtime event 追加的流式内容。",
  status: "running"
});
const eventPlan = projection.planTimeline(first.projection, eventTimeline, { defaultPresentation: {} });
const finalizedPlan = projection.planTimeline(first.projection, finalizeStreamingText(fixture), {
  defaultPresentation: {}
});
const richFirst = projection.planTimeline(null, richFixture, defaultOptions);
const emptyStreamingFirst = projection.planTimeline(null, emptyStreamingFixture, { defaultPresentation: {} });
const richProcessingPlan = projection.planTimeline(richFirst.projection, updateProcessingItemText(richFixture), {
  defaultPresentation: defaultManifest.defaultPresentation
});
const toolTimeline = projection.applyRuntimeEvent(fixture, {
  type: "tool.lifecycle",
  messageID: "assistant-2",
  blockID: "assistant-2:tool-scan",
  status: "failed",
  toolCall: {
    toolName: "exec_command",
    title: "静态资源检查失败",
    errorText: "exit 1"
  }
});
const collapsedTimeline = projection.applyRuntimeEvent(fixture, {
  type: "interaction.collapse",
  messageID: "assistant-2",
  blockID: "assistant-2:tool-scan",
  collapsed: true
});
const manifestValidation = registry.validateManifest(defaultManifest);

assert(first.operation.kind === "fullRender", "initial timeline must plan fullRender");
assert(first.projection.timeline.schema === "msp.chat-ui.timeline.v1", "fixture must use MSP timeline schema");
assert(first.projection.payload.messages.length === 3, "fixture should project 3 messages");
assert(first.projection.payload.blockCatalog.some((block) => block.type === "readex_tool_call"), "tool calls must adapt internally");
assert(second.operation.kind === "directStreamingUpdate", "text append must plan directStreamingUpdate");
assert(second.operation.update.updates.length === 1, "streaming update must contain one block update");
assert(second.operation.update.updates[0].messageKey === "assistant-2", "streaming update must target assistant-2");
assert(presentationOnly.operation.kind === "presentationOnlyUpdate", "focused presentation must plan presentationOnlyUpdate");
assert(eventPlan.operation.kind === "directStreamingUpdate", "stream.delta event must plan directStreamingUpdate");
assert(finalizedPlan.operation.kind === "directStreamingUpdate", "streaming finalization must use directStreamingUpdate");
assert(
  richFirst.projection.payload.blockCatalog.some((block) => block.type === "readex_processing"),
  "processing blocks must adapt to private readex_processing"
);
assert(
  emptyStreamingFirst.projection.payload.blockCatalog.some((block) => (
    block.type === "readex_processing" &&
    block.items?.some((item) => item.text === "正在思考")
  )),
  "empty running assistant messages must project a status processing line"
);
assert(
  richFirst.projection.payload.collapsedReadexToolActivityBlockIDs.includes("assistant-rich:tool-group"),
  "presentation.collapsedBlocks must map to Default tool activity expansion metadata"
);
assert(
  richFirst.projection.presentation.messageActionPolicy.assistantPlacement === "readexAssistantFooter" &&
    richFirst.projection.presentation.messageActionPolicy.assistantActions.includes("copyMessage") &&
    richFirst.projection.presentation.messageActionPolicy.userActions.includes("editUserMessage"),
  "presentation.messageActions must map to Default internal messageActionPolicy"
);
assert(
  richFirst.projection.payload.messageActionPolicy.assistantActions.includes("regenerateAssistantMessage"),
  "payload metadata must carry message action policy"
);
assert(
  richFirst.projection.presentation.pagePaddingBottom === 50,
  "bottomSlackPx must add to Default bottom padding without host-specific renderer forks"
);
assert(
  richFirst.projection.payload.messages.find((message) => message.id === "assistant-rich").memoryCitation?.count === 2,
  "message metadata must carry memory citations"
);
assert(
  richProcessingPlan.operation.kind === "directStreamingUpdate" &&
    richProcessingPlan.operation.update.updates[0].kind === "readex_processing",
  "processing item source changes must plan direct readex_processing updates"
);
assert(
  toolTimeline.messages.find((message) => message.id === "assistant-2")
    .blocks.find((block) => block.id === "assistant-2:tool-scan").status === "failed",
  "tool.lifecycle must update tool status"
);
assert(collapsedTimeline.presentation.collapsedBlocks["assistant-2:tool-scan"] === true, "collapse event must update presentation");
assert(manifestValidation.ok, `Default renderer manifest must be valid: ${manifestValidation.errors.join("; ")}`);
assert(defaultManifest.capabilities.runtimeEvents === true, "Default manifest must advertise runtimeEvents");
assert(
  defaultManifest.defaultPresentation.bodyFontSize === 15.5 &&
    defaultManifest.defaultPresentation.roleFontSize === 12 &&
    defaultManifest.defaultPresentation.metaFontSize === 11 &&
    defaultManifest.defaultPresentation.supportFontSize === 14 &&
    defaultManifest.defaultPresentation.messageGap === 12 &&
    defaultManifest.defaultPresentation.assistantContentMaxWidth === 640,
  "Default manifest must preserve Readex visual spacing and typography tokens"
);
assert(
  /codexShimmerSweepMilliseconds\s*=\s*1000/.test(supportRendererSource) &&
    /codexShimmerIntervalMilliseconds\s*=\s*4000/.test(supportRendererSource) &&
    /codexShimmerInitialDelayMilliseconds\s*=\s*600/.test(supportRendererSource),
  "Default shimmer cadence must preserve Readex timing constants"
);
assert(
  typeDeclarations.includes('type: "attachment"') &&
    typeDeclarations.includes('type: "searchProgress"'),
  "public TypeScript declarations must cover every runtime-supported timeline block"
);

console.log(JSON.stringify({
  ok: true,
  fixture: fixture.id,
  initialOperation: first.operation.kind,
  streamingOperation: second.operation.kind,
  eventStreamingOperation: eventPlan.operation.kind,
  finalizedOperation: finalizedPlan.operation.kind,
  processingOperation: richProcessingPlan.operation.kind,
  presentationOperation: presentationOnly.operation.kind,
  registeredRenderer: manifestValidation.value.id,
  projectedMessages: first.projection.payload.messages.length
}, null, 2));
