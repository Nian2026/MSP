(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript bootstrap stage assembler dependency: ${name}`);
    }
    return value;
  }

  function requiredNumber(dependencies, name) {
    const value = Number(dependencies?.[name]);
    if (!Number.isFinite(value)) {
      throw new Error(`Missing ChatTranscript bootstrap stage assembler dependency: ${name}`);
    }
    return value;
  }

  function stageFailure(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    normalizedError.chatTranscriptBootstrapKind = kind;
    throw normalizedError;
  }

  function snapshot(modules, names) {
    const keys = Array.isArray(names) ? names : Object.keys(modules);
    const result = {};
    keys.forEach((name) => {
      if (Object.prototype.hasOwnProperty.call(modules, name)) {
        result[name] = modules[name];
      }
    });
    return Object.freeze(result);
  }

  window.ChatTranscriptBootstrapStageAssemblerFactory = function createChatTranscriptBootstrapStageAssembler(dependencies) {
    const windowObject = dependencies?.windowObject || window;
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const transcriptTopPinThreshold = requiredNumber(dependencies, "transcriptTopPinThreshold");
    const transcriptLiveEdgeThreshold = requiredNumber(dependencies, "transcriptLiveEdgeThreshold");
    const resolveRenderConversation = requiredFunction(dependencies, "resolveRenderConversation");
    const publishModuleBindings = requiredFunction(dependencies, "publishModuleBindings");
    const publishLegacyModuleBindings = requiredFunction(dependencies, "publishLegacyModuleBindings");
    const publishRuntimeBindings = requiredFunction(dependencies, "publishRuntimeBindings");
    const modules = {};

    function requiredGlobalFactory(name, kind) {
      const value = windowObject?.[name];
      if (typeof value !== "function") {
        stageFailure(kind, new Error(`Missing ChatTranscript factory: ${name}`));
      }
      return value;
    }

    function publishModule(name, value) {
      modules[name] = value;
      publishModuleBindings({
        [name]: value
      });
      return value;
    }

    function publishLegacyModule(name, value) {
      modules[name] = value;
      publishLegacyModuleBindings({
        [name]: value
      });
      return value;
    }

    function resolveOptionalModule(name) {
      return Object.prototype.hasOwnProperty.call(modules, name) ? modules[name] : null;
    }

    function requiredPublishedObject(name) {
      const value = modules[name];
      if (!value || typeof value !== "object") {
        throw new Error(`Missing ChatTranscript bootstrap module: ${name}`);
      }
      return value;
    }

    function requiredPublishedFunction(moduleName, name) {
      const value = modules[moduleName]?.[name];
      if (typeof value !== "function") {
        throw new Error(`Missing ChatTranscript bootstrap module method: ${moduleName}.${name}`);
      }
      return value;
    }

    function composeFoundationStage() {
      const createChatTranscriptBootstrapFoundationStage = requiredGlobalFactory(
        "ChatTranscriptBootstrapFoundationStageFactory",
        "foundation_stage"
      );
      let foundationStage = null;
      try {
        foundationStage = createChatTranscriptBootstrapFoundationStage({
          requiredGlobalFactory,
          publishModule,
          publishLegacyModule,
          requiredPublishedObject,
          requiredPublishedFunction,
          resolveOptionalModule,
          trimmed,
          blockText,
          postTranscriptProbe,
          transcriptLiveEdgeThreshold
        });
      } catch (error) {
        stageFailure("foundation_stage", error);
      }

      try {
        foundationStage.composeFoundationStage();
      } catch (error) {
        const stageKind = typeof error?.chatTranscriptBootstrapKind === "string"
          ? error.chatTranscriptBootstrapKind.trim()
          : "";
        stageFailure(stageKind || "foundation_stage", error);
      }

      return snapshot(modules, [
        "statusModel",
        "blockModel",
        "hostBridge",
        "stylePlatform",
        "messageDOM",
        "scrollMetrics",
        "anchorPlatform",
        "domPlatform",
        "runtimeModel",
        "renderSupport",
        "conversationLayout",
        "payloadModel",
        "payloadPatcher",
        "payloadStore",
        "visualSupport"
      ]);
    }

    function composeInteractionStage() {
      const createChatTranscriptBootstrapInteractionStage = requiredGlobalFactory(
        "ChatTranscriptBootstrapInteractionStageFactory",
        "interaction_stage"
      );
      let interactionStage = null;
      try {
        interactionStage = createChatTranscriptBootstrapInteractionStage({
          requiredGlobalFactory,
          publishModule,
          requiredPublishedObject,
          requiredPublishedFunction,
          resolveOptionalModule,
          trimmed,
          blockText,
          postTranscriptProbe,
          resolveRenderConversation,
          transcriptTopPinThreshold,
          transcriptLiveEdgeThreshold
        });
      } catch (error) {
        stageFailure("interaction_stage", error);
      }

      try {
        interactionStage.composeInteractionStage();
      } catch (error) {
        const stageKind = typeof error?.chatTranscriptBootstrapKind === "string"
          ? error.chatTranscriptBootstrapKind.trim()
          : "";
        stageFailure(stageKind || "interaction_stage", error);
      }

      return snapshot(modules, [
        "scrollCoordinator",
        "conversationController",
        "presentationController",
        "interactionState",
        "overlayController"
      ]);
    }

    function composeDocumentStage() {
      const createChatTranscriptBootstrapDocumentStage = requiredGlobalFactory(
        "ChatTranscriptBootstrapDocumentStageFactory",
        "document_stage"
      );
      let documentStage = null;
      try {
        documentStage = createChatTranscriptBootstrapDocumentStage({
          windowObject,
          documentObject: document,
          requiredGlobalFactory,
          publishModule,
          requiredPublishedObject,
          requiredPublishedFunction,
          trimmed,
          postTranscriptProbe
        });
      } catch (error) {
        stageFailure("document_stage", error);
      }

      try {
        documentStage.composeDocumentStage();
      } catch (error) {
        const stageKind = typeof error?.chatTranscriptBootstrapKind === "string"
          ? error.chatTranscriptBootstrapKind.trim()
          : "";
        stageFailure(stageKind || "document_stage", error);
      }

      return snapshot(modules, [
        "documentShell",
        "documentRuntime"
      ]);
    }

    function composeRenderStage() {
      const createChatTranscriptBootstrapRenderStage = requiredGlobalFactory(
        "ChatTranscriptBootstrapRenderStageFactory",
        "render_stage"
      );
      let renderStage = null;
      try {
        renderStage = createChatTranscriptBootstrapRenderStage({
          windowObject,
          requiredGlobalFactory,
          publishModule,
          requiredPublishedObject,
          requiredPublishedFunction,
          trimmed,
          blockText
        });
      } catch (error) {
        stageFailure("render_stage", error);
      }

      try {
        renderStage.composeRenderStage();
      } catch (error) {
        const stageKind = typeof error?.chatTranscriptBootstrapKind === "string"
          ? error.chatTranscriptBootstrapKind.trim()
          : "";
        stageFailure(stageKind || "render_stage", error);
      }

      return snapshot(modules, [
        "messageBlockSupportRenderer",
        "messageBlockRenderer",
        "messageUIRenderer",
        "messageArticleRenderer",
        "rendererComponents",
        "conversationRenderer",
        "renderCoordinator"
      ]);
    }

    function composeRuntimeStage() {
      const createChatTranscriptBootstrapRuntimeStage = requiredGlobalFactory(
        "ChatTranscriptBootstrapRuntimeStageFactory",
        "runtime_stage"
      );
      let runtimeStage = null;
      try {
        runtimeStage = createChatTranscriptBootstrapRuntimeStage({
          modules,
          publishRuntimeBindings,
          requiredGlobalFactory,
          requiredPublishedObject
        });
      } catch (error) {
        stageFailure("runtime_stage", error);
      }

      try {
        runtimeStage.composeRuntimeStage();
      } catch (error) {
        const stageKind = typeof error?.chatTranscriptBootstrapKind === "string"
          ? error.chatTranscriptBootstrapKind.trim()
          : "";
        stageFailure(stageKind || "runtime_stage", error);
      }

      return snapshot(modules, ["runtime"]);
    }

    function composeStages() {
      composeFoundationStage();
      composeInteractionStage();
      composeDocumentStage();
      composeRenderStage();
      composeRuntimeStage();
      return composedModules();
    }

    function composedModules() {
      return snapshot(modules);
    }

    return Object.freeze({
      composeFoundationStage,
      composeInteractionStage,
      composeDocumentStage,
      composeRenderStage,
      composeRuntimeStage,
      composeStages,
      composedModules
    });
  };
})();
