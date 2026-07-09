(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIRendererRegistry = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function () {
  const renderers = new Map();

  function text(value) {
    return typeof value === "string" ? value.trim() : "";
  }

  function normalizeManifest(manifest) {
    const source = manifest && typeof manifest === "object" ? manifest : {};
    return {
      ...source,
      id: text(source.id),
      name: text(source.name),
      rendererAPIScripts: Array.isArray(source.rendererAPIScripts) ? source.rendererAPIScripts : [],
      capabilities: {
        timeline: true,
        runtimeEvents: true,
        streamingDelta: true,
        ...(source.capabilities || {})
      }
    };
  }

  function validateManifest(manifest) {
    const normalized = normalizeManifest(manifest);
    const errors = [];
    if (!normalized.id) errors.push("renderer manifest id is required");
    if (!normalized.name) errors.push("renderer manifest name is required");
    if (!normalized.rendererAPIScripts.length) errors.push("rendererAPIScripts must contain at least one script");
    return { ok: errors.length === 0, errors, value: normalized };
  }

  function registerRenderer(manifest) {
    const validation = validateManifest(manifest);
    if (!validation.ok) {
      throw new Error(`Invalid MSPChatUI renderer manifest: ${validation.errors.join("; ")}`);
    }
    renderers.set(validation.value.id, validation.value);
    return validation.value;
  }

  function getRenderer(id) {
    return renderers.get(text(id)) || null;
  }

  function listRenderers() {
    return Array.from(renderers.values());
  }

  return Object.freeze({
    validateManifest,
    registerRenderer,
    getRenderer,
    listRenderers
  });
});
