(function () {
  window.ChatTranscriptBootstrapSupportFactory = function createChatTranscriptBootstrapSupport(dependencies = {}) {
    const windowObject = dependencies?.windowObject || window;
    let bootstrapBindings = null;

    function trimmed(text) {
      return String(text || "").trim();
    }

    function blockText(block) {
      if (typeof block?.text === "string") {
        return block.text;
      }
      if (typeof block?.content === "string") {
        return block.content;
      }
      return "";
    }

    const alwaysPostTranscriptProbeKinds = new Set([
      "display_window",
      "scroll_state"
    ]);

    function transcriptDebugProbeEnabled() {
      return windowObject.__chatTranscriptDebugPresentationProbesEnabled === true ||
        windowObject.__chatTranscriptScrollPerfProbeEnabled === true ||
        windowObject.__chatTranscriptRenderPerfProbeEnabled === true ||
        windowObject.__chatTranscriptReadexLayoutProbeEnabled === true ||
        windowObject.__chatTranscriptReadexReferenceProbeEnabled === true;
    }

    function shouldPostTranscriptProbe(kind) {
      const normalizedKind = trimmed(kind);
      if (alwaysPostTranscriptProbeKinds.has(normalizedKind)) {
        return true;
      }
      return transcriptDebugProbeEnabled();
    }

    function postTranscriptProbe(kind, event, payload = {}) {
      const hostBridge = windowObject.__chatTranscriptHostBridge;
      if (!hostBridge || typeof hostBridge.postPresentationProbe !== "function") {
        return;
      }
      if (!shouldPostTranscriptProbe(kind)) {
        return;
      }
      const probe = {
        kind,
        event,
        ...payload
      };
      if (!trimmed(probe.reason)) {
        probe.reason = trimmed(windowObject.__chatTranscriptCurrentMutationReason);
      }
      hostBridge.postPresentationProbe(probe);
    }

    function describedTranscriptBootstrapError(error) {
      if (error instanceof Error) {
        return `${error.name}: ${error.message}`;
      }
      return String(error);
    }

    function setBootstrapBindings(bindings) {
      bootstrapBindings = bindings && typeof bindings === "object" ? bindings : null;
      return bootstrapBindings;
    }

    function setBootstrapState(stage, details = {}) {
      if (
        bootstrapBindings &&
        typeof bootstrapBindings.setBootstrapState === "function"
      ) {
        bootstrapBindings.setBootstrapState(stage, details);
        return;
      }
      windowObject.__chatTranscriptRuntimeBootstrap = {
        stage,
        source: "external",
        hasRenderConversation: false,
        ...details
      };
    }

    function setBootstrapError(message) {
      if (
        bootstrapBindings &&
        typeof bootstrapBindings.setLastRuntimeBootstrapError === "function"
      ) {
        bootstrapBindings.setLastRuntimeBootstrapError(message);
        return;
      }
      windowObject.__chatTranscriptLastRuntimeBootstrapError = message;
    }

    function resolvePublishedModule(name) {
      if (
        bootstrapBindings &&
        typeof bootstrapBindings.resolvePublishedModule === "function"
      ) {
        return bootstrapBindings.resolvePublishedModule(name);
      }
      return null;
    }

    function resolvePublishedMethod(moduleName, methodName) {
      if (
        bootstrapBindings &&
        typeof bootstrapBindings.resolvePublishedMethod === "function"
      ) {
        return bootstrapBindings.resolvePublishedMethod(moduleName, methodName);
      }
      const module = resolvePublishedModule(moduleName);
      const value = module?.[methodName];
      if (typeof value === "function") {
        return value.bind(module);
      }
      return null;
    }

    function resolveRenderConversation() {
      const publishedRenderConversation = resolvePublishedMethod(
        "renderCoordinator",
        "renderConversation"
      );
      if (typeof publishedRenderConversation === "function") {
        return publishedRenderConversation;
      }
      if (
        bootstrapBindings &&
        typeof bootstrapBindings.resolveRenderConversation === "function"
      ) {
        return bootstrapBindings.resolveRenderConversation();
      }
      return windowObject.__renderConversation;
    }

    function hasRenderConversation() {
      if (typeof resolvePublishedMethod("renderCoordinator", "renderConversation") === "function") {
        return true;
      }
      if (
        bootstrapBindings &&
        typeof bootstrapBindings.hasRenderConversation === "function"
      ) {
        return bootstrapBindings.hasRenderConversation();
      }
      return typeof resolveRenderConversation() === "function";
    }

    function failTranscriptBootstrap(kind, error) {
      const normalizedError = error instanceof Error ? error : new Error(String(error));
      const resolvedKind = trimmed(normalizedError?.chatTranscriptBootstrapKind) || kind;
      const message = describedTranscriptBootstrapError(normalizedError);
      setBootstrapError(message);
      setBootstrapState("failed", {
        kind: resolvedKind,
        error: message
      });
      postTranscriptProbe(resolvedKind, "bootstrap_failed", {
        source: "external",
        error: message
      });
      throw normalizedError;
    }

    function requiredGlobalFactory(name, kind) {
      const value = windowObject[name];
      if (typeof value === "function") {
        return value;
      }
      failTranscriptBootstrap(kind, new Error(`Missing ChatTranscript factory: ${name}`));
    }

    return Object.freeze({
      trimmed,
      blockText,
      postTranscriptProbe,
      setBootstrapBindings,
      setBootstrapState,
      setBootstrapError,
      resolvePublishedModule,
      resolvePublishedMethod,
      hasRenderConversation,
      resolveRenderConversation,
      failTranscriptBootstrap,
      requiredGlobalFactory
    });
  };
})();
