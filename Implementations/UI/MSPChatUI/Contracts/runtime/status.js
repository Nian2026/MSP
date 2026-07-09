(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIStatus = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function () {
  const RUNNING = new Set(["pending", "running", "streaming", "processing"]);
  const DONE = new Set(["success", "succeeded", "complete", "completed"]);
  const FAILED = new Set(["failed", "failure", "error"]);
  const CANCELLED = new Set(["cancelled", "canceled", "stopped", "interrupted"]);

  function text(value) {
    return typeof value === "string" ? value.trim() : "";
  }

  function normalizeStatus(value, fallback = "success") {
    const raw = text(value).toLowerCase();
    if (RUNNING.has(raw)) return raw === "pending" ? "pending" : "running";
    if (DONE.has(raw)) return "success";
    if (FAILED.has(raw)) return "failed";
    if (CANCELLED.has(raw)) return "cancelled";
    return fallback;
  }

  function isRunning(value) {
    return normalizeStatus(value, "success") === "running";
  }

  return Object.freeze({
    normalizeStatus,
    isRunning
  });
});
