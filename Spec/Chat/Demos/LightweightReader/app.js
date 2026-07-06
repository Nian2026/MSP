const state = {
  packageName: "",
  manifest: null,
  timelinePath: "timeline.ndjson",
  files: new Map(),
  events: [],
  projections: [],
  query: ""
};

const knownEventTypes = new Set([
  "message",
  "message_delta",
  "message_commit",
  "message_aborted",
  "message_superseded",
  "turn_started",
  "turn_completed",
  "turn_aborted",
  "status_changed",
  "command_call",
  "command_input",
  "command_output",
  "command_stage_started",
  "command_stage_output",
  "command_stage_completed",
  "command_complete",
  "command_error",
  "policy_request",
  "policy_decision",
  "tool_call",
  "tool_output",
  "artifact_ref",
  "durable_compaction_checkpoint",
  "conversation_fork",
  "timeline_rollback",
  "resume_capability_assessment",
  "resume_degraded",
  "error"
]);

const elements = {
  packageSelect: document.querySelector("#package-select"),
  directoryInput: document.querySelector("#directory-input"),
  searchInput: document.querySelector("#search-input"),
  eventCount: document.querySelector("#event-count"),
  matchCount: document.querySelector("#match-count"),
  unknownCount: document.querySelector("#unknown-count"),
  packageTitle: document.querySelector("#package-title"),
  packageSubtitle: document.querySelector("#package-subtitle"),
  packageMeta: document.querySelector("#package-meta"),
  capabilityStrip: document.querySelector("#capability-strip"),
  projectionWarning: document.querySelector("#projection-warning"),
  timeline: document.querySelector("#timeline"),
  composerInput: document.querySelector("#composer-input"),
  appendUser: document.querySelector("#append-user"),
  appendAssistant: document.querySelector("#append-assistant"),
  exportButton: document.querySelector("#export-button"),
  exportPanel: document.querySelector(".export-panel"),
  exportOutput: document.querySelector("#export-output"),
  downloadLink: document.querySelector("#download-link")
};

elements.packageSelect.addEventListener("change", () => {
  void loadPackageFromURL(elements.packageSelect.value);
});
elements.searchInput.addEventListener("input", () => {
  state.query = elements.searchInput.value.trim().toLowerCase();
  renderTimeline();
});
elements.directoryInput.addEventListener("change", () => {
  void loadPackageFromDirectoryInput(elements.directoryInput.files);
});
elements.appendUser.addEventListener("click", () => appendMessage("user"));
elements.appendAssistant.addEventListener("click", () => appendMessage("assistant"));
elements.exportButton.addEventListener("click", exportBundle);

void loadPackageFromURL(elements.packageSelect.value);

async function loadPackageFromURL(packagePath) {
  const files = new Map();
  const manifest = await fetchJSON(`${packagePath}/manifest.json`);
  const timelinePath = manifest.timeline?.path || "timeline.ndjson";
  files.set("manifest.json", JSON.stringify(manifest, null, 2));
  files.set(timelinePath, await fetchText(`${packagePath}/${timelinePath}`));

  for (const projectionPath of ["projections/chat-read.ndjson", "projections/model-context.ndjson"]) {
    try {
      files.set(projectionPath, await fetchText(`${packagePath}/${projectionPath}`));
    } catch {
      // Optional projection files are not canonical and may be absent.
    }
  }

  loadPackage({
    packageName: packagePath.split("/").pop(),
    files,
    manifest,
    timelinePath
  });
}

async function loadPackageFromDirectoryInput(fileList) {
  if (!fileList || fileList.length === 0) {
    return;
  }
  const files = new Map();
  let packageName = "local.chat";
  for (const file of Array.from(fileList)) {
    const pathParts = file.webkitRelativePath.split("/");
    packageName = pathParts[0] || packageName;
    const relativePath = pathParts.slice(1).join("/");
    if (relativePath) {
      files.set(relativePath, await file.text());
    }
  }
  const manifestText = files.get("manifest.json");
  if (!manifestText) {
    showLoadError("Selected directory is missing manifest.json.");
    return;
  }
  const manifest = JSON.parse(manifestText);
  const timelinePath = manifest.timeline?.path || "timeline.ndjson";
  if (!files.has(timelinePath)) {
    showLoadError(`Selected directory is missing ${timelinePath}.`);
    return;
  }
  loadPackage({ packageName, files, manifest, timelinePath });
}

function loadPackage({ packageName, files, manifest, timelinePath }) {
  const events = parseTimeline(files.get(timelinePath) || "");
  assertTimeline(events);
  state.packageName = packageName;
  state.files = files;
  state.manifest = manifest;
  state.timelinePath = timelinePath;
  state.events = events;
  state.projections = readProjections(files);
  state.query = "";
  elements.searchInput.value = "";
  renderPackage();
}

function parseTimeline(text) {
  return text
    .split(/\n/u)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line, index) => {
      const event = JSON.parse(line);
      event.__line = index + 1;
      return event;
    })
    .sort((a, b) => a.seq - b.seq);
}

function assertTimeline(events) {
  let previous = 0;
  for (const event of events) {
    if (!event.id || !event.type || typeof event.seq !== "number" || !event.created_at || !event.payload) {
      throw new Error(`Invalid timeline event envelope near line ${event.__line || "unknown"}.`);
    }
    if (event.seq <= previous) {
      throw new Error(`Timeline seq is not strictly increasing at ${event.id}.`);
    }
    previous = event.seq;
  }
}

function readProjections(files) {
  const projections = [];
  for (const [path, text] of files.entries()) {
    if (!path.startsWith("projections/") || !path.endsWith(".ndjson")) {
      continue;
    }
    for (const line of text.split(/\n/u)) {
      const trimmed = line.trim();
      if (trimmed) {
        projections.push({ path, record: JSON.parse(trimmed) });
      }
    }
  }
  return projections;
}

function renderPackage() {
  const manifest = state.manifest;
  elements.packageTitle.textContent = state.packageName;
  elements.packageSubtitle.textContent = manifest.package_id || "No package id";
  elements.packageMeta.textContent = `${manifest.format} v${manifest.version} | ${state.timelinePath}`;
  elements.capabilityStrip.replaceChildren(
    ...[...(manifest.profiles || []), ...(manifest.capabilities || [])].map((name) => chip(name))
  );
  elements.projectionWarning.hidden = !state.projections.some(({ record }) => record.truncated === true);
  renderTimeline();
}

function renderTimeline() {
  const query = state.query;
  const cards = state.events.map((event) => renderEvent(event, query));
  elements.timeline.replaceChildren(...cards);

  const matches = cards.filter((card) => !card.hidden).length;
  const unknown = state.events.filter((event) => !knownEventTypes.has(event.type)).length;
  elements.eventCount.textContent = String(state.events.length);
  elements.matchCount.textContent = String(query ? matches : state.events.length);
  elements.unknownCount.textContent = String(unknown);
}

function renderEvent(event, query) {
  const item = document.createElement("li");
  item.className = `event-card ${eventClass(event)}`;
  item.dataset.eventId = event.id;
  item.dataset.eventType = event.type;
  item.dataset.seq = String(event.seq);

  const searchable = eventSearchText(event);
  item.hidden = Boolean(query) && !searchable.toLowerCase().includes(query);

  const header = document.createElement("div");
  header.className = "event-header";
  const left = document.createElement("div");
  left.className = "event-meta";
  left.append(chip(`#${event.seq}`, "event-seq"), chip(event.type, "event-kind"));
  const actor = actorLabel(event);
  if (actor) {
    left.append(chip(actor));
  }
  const right = document.createElement("div");
  right.className = "event-meta";
  right.append(chip(event.durability), chip(event.created_at));
  header.append(left, right);

  const body = document.createElement("div");
  body.className = "event-body";
  body.append(...eventBodyNodes(event, query));

  item.append(header, body);
  return item;
}

function eventBodyNodes(event, query) {
  switch (event.type) {
  case "message":
    return [textNodeWithHighlight(messageText(event), query)];
  case "message_delta":
    return [textNodeWithHighlight(`Intermediate: ${event.payload.text || event.payload.content || ""}`, query)];
  case "message_commit":
    return [textNodeWithHighlight(`Committed ${event.payload.message_id || event.correlation_id || ""}`, query)];
  case "tool_call":
    return [textNodeWithHighlight(`Tool call ${event.payload.tool_name || event.payload.call_id || event.call_id || ""}`, query), codeBlock(event.payload.input || event.payload.arguments || {})];
  case "tool_output":
    return [textNodeWithHighlight(`Tool output ${event.payload.call_id || event.call_id || ""}: ${event.payload.output || ""}`, query)];
  case "command_call":
    return [textNodeWithHighlight(`MSP command: ${event.payload.raw_command || ""}`, query), codeBlock({ command_id: event.payload.command_id, dialect: event.payload.dialect, cwd_before: event.payload.cwd_before, parse_status: event.payload.parse_status })];
  case "command_output":
  case "command_stage_output":
    return [textNodeWithHighlight(`${event.payload.stream || "stdout"}: ${event.payload.text || ""}`, query)];
  case "command_complete":
    return [textNodeWithHighlight(`Command completed with exit ${event.payload.exit_status}`, query), codeBlock({ stage_exit_codes: event.payload.stage_exit_codes, pipefail: event.payload.pipefail, negated: event.payload.negated })];
  case "command_error":
  case "error":
    return [textNodeWithHighlight(`${event.payload.code || "error"}: ${event.payload.message || ""}`, query)];
  case "artifact_ref":
    return [textNodeWithHighlight(`Artifact ${event.payload.display_name || event.payload.artifact_id || event.payload.blob_id || ""} | ${event.payload.status || "available"} | ${event.payload.media_type || event.payload.kind || ""}`, query)];
  case "policy_request":
  case "policy_decision":
    return [textNodeWithHighlight(JSON.stringify(event.payload), query)];
  default:
    return [unknownDetails(event)];
  }
}

function messageText(event) {
  const role = event.payload.role || "message";
  const phase = event.payload.phase ? ` ${event.payload.phase}` : "";
  const content = event.payload.content || JSON.stringify(event.payload.content_blocks || event.payload.content_refs || "");
  return `${role}${phase}: ${content}`;
}

function unknownDetails(event) {
  const details = document.createElement("details");
  details.open = false;
  const summary = document.createElement("summary");
  summary.textContent = `Unknown event preserved: ${event.type}`;
  const pre = codeBlock(event.payload);
  details.append(summary, pre);
  return details;
}

function eventClass(event) {
  if (event.type === "message") {
    return event.payload.role === "user" ? "event-message-user" : "event-message-assistant";
  }
  if (event.type.startsWith("command_") || event.type.startsWith("policy_")) {
    return "event-command";
  }
  if (event.type.startsWith("tool_")) {
    return "event-tool";
  }
  if (event.type === "error" || event.type === "command_error") {
    return "event-error";
  }
  if (!knownEventTypes.has(event.type)) {
    return "event-unknown";
  }
  return "";
}

function actorLabel(event) {
  if (event.payload?.role) {
    return event.payload.role;
  }
  if (event.actor) {
    return event.actor;
  }
  if (event.payload?.stream) {
    return event.payload.stream;
  }
  return "";
}

function appendMessage(role) {
  const content = elements.composerInput.value.trim();
  if (!content || !state.manifest) {
    return;
  }
  const nextSeq = Math.max(0, ...state.events.map((event) => event.seq)) + 1;
  const timestamp = new Date().toISOString();
  const event = {
    id: `evt_light_${Date.now()}_${nextSeq}`,
    type: "message",
    seq: nextSeq,
    created_at: timestamp,
    durability: "durable_replay",
    payload: {
      role,
      content,
      ...(role === "assistant" ? { phase: "final" } : {})
    }
  };
  state.events.push(event);
  state.manifest.updated_at = timestamp;
  state.files.set("manifest.json", JSON.stringify(state.manifest, null, 2));
  state.files.set(state.timelinePath, state.events.map((item) => JSON.stringify(stripRuntimeFields(item))).join("\n") + "\n");
  elements.composerInput.value = "";
  renderPackage();
}

function exportBundle() {
  const files = Object.fromEntries(state.files.entries());
  const bundle = {
    package_name: state.packageName,
    exported_at: new Date().toISOString(),
    note: "Text bundle preserves package files for lightweight demo export.",
    files
  };
  const text = JSON.stringify(bundle, null, 2);
  elements.exportPanel.hidden = false;
  elements.exportOutput.value = text;
  const blob = new Blob([text], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  elements.downloadLink.href = url;
}

async function fetchJSON(url) {
  return JSON.parse(await fetchText(url));
}

async function fetchText(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Could not load ${url}: ${response.status}`);
  }
  return response.text();
}

function showLoadError(message) {
  elements.packageTitle.textContent = "Could not open package";
  elements.packageMeta.textContent = message;
  elements.timeline.replaceChildren();
}

function chip(text, className = "chip") {
  const span = document.createElement("span");
  span.className = className;
  span.textContent = text;
  return span;
}

function codeBlock(value) {
  const pre = document.createElement("pre");
  pre.className = "code-block";
  pre.textContent = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return pre;
}

function textNodeWithHighlight(text, query) {
  const span = document.createElement("span");
  if (!query) {
    span.textContent = text;
    return span;
  }
  const lower = text.toLowerCase();
  const index = lower.indexOf(query);
  if (index < 0) {
    span.textContent = text;
    return span;
  }
  span.append(document.createTextNode(text.slice(0, index)));
  const mark = document.createElement("mark");
  mark.textContent = text.slice(index, index + query.length);
  span.append(mark, document.createTextNode(text.slice(index + query.length)));
  return span;
}

function eventSearchText(event) {
  return `${event.type} ${event.created_at} ${JSON.stringify(event.payload)}`;
}

function stripRuntimeFields(event) {
  const copy = { ...event };
  delete copy.__line;
  return copy;
}
