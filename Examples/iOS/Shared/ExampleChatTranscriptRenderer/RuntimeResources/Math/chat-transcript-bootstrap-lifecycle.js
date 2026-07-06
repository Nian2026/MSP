(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript bootstrap lifecycle dependency: ${name}`);
    }
    return value;
  }

  function requiredNumber(dependencies, name) {
    const value = Number(dependencies?.[name]);
    if (!Number.isFinite(value)) {
      throw new Error(`Missing ChatTranscript bootstrap lifecycle dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript bootstrap lifecycle dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptBootstrapLifecycleFactory = function createChatTranscriptBootstrapLifecycle(dependencies = {}) {
    const windowObject = dependencies?.windowObject || window;
    const support = requiredObject(dependencies, "support");
    const transcriptTopPinThreshold = requiredNumber(dependencies, "transcriptTopPinThreshold");
    const transcriptLiveEdgeThreshold = requiredNumber(dependencies, "transcriptLiveEdgeThreshold");
    const requiredGlobalFactory = requiredFunction(support, "requiredGlobalFactory");
    const setBootstrapBindings = requiredFunction(support, "setBootstrapBindings");
    const setBootstrapState = requiredFunction(support, "setBootstrapState");
    const postTranscriptProbe = requiredFunction(support, "postTranscriptProbe");
    const hasRenderConversation = requiredFunction(support, "hasRenderConversation");
    const resolveRenderConversation = requiredFunction(support, "resolveRenderConversation");
    const failTranscriptBootstrap = requiredFunction(support, "failTranscriptBootstrap");
    const trimmed = requiredFunction(support, "trimmed");
    const blockText = requiredFunction(support, "blockText");

    function runBootstrap() {
      const createChatTranscriptBootstrapBindings = requiredGlobalFactory(
        "ChatTranscriptBootstrapBindingsFactory",
        "bootstrap_bindings"
      );
      let bootstrapBindings = null;
      try {
        bootstrapBindings = createChatTranscriptBootstrapBindings({
          windowObject
        });
        setBootstrapBindings(bootstrapBindings);
      } catch (error) {
        failTranscriptBootstrap("bootstrap_bindings", error);
      }

      const createChatTranscriptBootstrapComposer = requiredGlobalFactory(
        "ChatTranscriptBootstrapComposerFactory",
        "bootstrap_composer"
      );
      let bootstrapComposer = null;
      try {
        bootstrapComposer = createChatTranscriptBootstrapComposer({
          windowObject,
          trimmed,
          blockText,
          postTranscriptProbe,
          transcriptTopPinThreshold,
          transcriptLiveEdgeThreshold,
          resolveRenderConversation,
          bootstrapBindings
        });
      } catch (error) {
        failTranscriptBootstrap("bootstrap_composer", error);
      }

      setBootstrapState("initializing", {
        kind: "runtime"
      });

      let bootstrapResult = null;
      try {
        bootstrapResult = bootstrapComposer.compose();
      } catch (error) {
        failTranscriptBootstrap("runtime", error);
      }

      const renderConversationAvailable = hasRenderConversation();
      setBootstrapState("ready", {
        kind: "runtime",
        hasRenderConversation: renderConversationAvailable
      });
      postTranscriptProbe("runtime", "bootstrap_complete", {
        source: "external",
        hasRenderConversation: renderConversationAvailable
      });

      return bootstrapResult;
    }

    return Object.freeze({
      runBootstrap
    });
  };
})();
