(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript bootstrap composer dependency: ${name}`);
    }
    return value;
  }

  function requiredNumber(dependencies, name) {
    const value = Number(dependencies?.[name]);
    if (!Number.isFinite(value)) {
      throw new Error(`Missing ChatTranscript bootstrap composer dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript bootstrap composer dependency: ${name}`);
    }
    return value;
  }

  function stageFailure(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    normalizedError.chatTranscriptBootstrapKind = kind;
    throw normalizedError;
  }

  function requiredGlobalFactory(windowObject, name, kind) {
    const value = windowObject?.[name];
    if (typeof value !== "function") {
      stageFailure(kind, new Error(`Missing ChatTranscript factory: ${name}`));
    }
    return value;
  }

  window.ChatTranscriptBootstrapComposerFactory = function createChatTranscriptBootstrapComposer(dependencies) {
    const windowObject = dependencies?.windowObject || window;
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const transcriptTopPinThreshold = requiredNumber(dependencies, "transcriptTopPinThreshold");
    const transcriptLiveEdgeThreshold = requiredNumber(dependencies, "transcriptLiveEdgeThreshold");
    const resolveRenderConversation = requiredFunction(dependencies, "resolveRenderConversation");
    const bootstrapBindings = requiredObject(dependencies, "bootstrapBindings");
    const publishModuleBindings = requiredFunction(bootstrapBindings, "publishModuleBindings");
    const publishLegacyModuleBindings = requiredFunction(bootstrapBindings, "publishLegacyModuleBindings");
    const publishRuntimeBindings = requiredFunction(bootstrapBindings, "publishRuntimeBindings");

    function compose() {
      const createChatTranscriptBootstrapStageAssembler = requiredGlobalFactory(
        windowObject,
        "ChatTranscriptBootstrapStageAssemblerFactory",
        "bootstrap_stage_assembler"
      );

      let ChatTranscriptBootstrapStageAssembler = null;
      try {
        ChatTranscriptBootstrapStageAssembler = createChatTranscriptBootstrapStageAssembler({
          windowObject,
          trimmed,
          blockText,
          postTranscriptProbe,
          transcriptTopPinThreshold,
          transcriptLiveEdgeThreshold,
          resolveRenderConversation,
          publishModuleBindings,
          publishLegacyModuleBindings,
          publishRuntimeBindings
        });
      } catch (error) {
        stageFailure("bootstrap_stage_assembler", error);
      }

      try {
        ChatTranscriptBootstrapStageAssembler.composeStages();
      } catch (error) {
        const stageKind = typeof error?.chatTranscriptBootstrapKind === "string"
          ? error.chatTranscriptBootstrapKind.trim()
          : "";
        stageFailure(stageKind || "runtime", error);
      }

      return Object.freeze({
        thresholds: Object.freeze({
          transcriptTopPinThreshold,
          transcriptLiveEdgeThreshold
        }),
        modules: ChatTranscriptBootstrapStageAssembler.composedModules()
      });
    }

    return Object.freeze({
      compose
    });
  };
})();
