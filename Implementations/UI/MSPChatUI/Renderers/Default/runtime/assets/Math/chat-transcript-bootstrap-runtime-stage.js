(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript bootstrap runtime stage dependency: ${name}`);
    }
    return value;
  }

  function stageFailure(kind, error) {
    const normalizedError = error instanceof Error ? error : new Error(String(error));
    normalizedError.chatTranscriptBootstrapKind = kind;
    throw normalizedError;
  }

  window.ChatTranscriptBootstrapRuntimeStageFactory = function createChatTranscriptBootstrapRuntimeStage(dependencies) {
    const publishRuntimeBindings = requiredFunction(dependencies, "publishRuntimeBindings");
    const requiredGlobalFactory = requiredFunction(dependencies, "requiredGlobalFactory");
    const requiredPublishedObject = requiredFunction(dependencies, "requiredPublishedObject");
    const modules = dependencies?.modules;
    if (!modules || typeof modules !== "object") {
      throw new Error("Missing ChatTranscript bootstrap runtime stage dependency: modules");
    }

    function composeRuntimeStage() {
      const createChatTranscriptRuntime = requiredGlobalFactory(
        "ChatTranscriptRuntimeFactory",
        "runtime"
      );
      let runtime = null;
      try {
        runtime = createChatTranscriptRuntime({
          renderCoordinator: requiredPublishedObject("renderCoordinator"),
          conversationController: requiredPublishedObject("conversationController"),
          presentationController: requiredPublishedObject("presentationController")
        });
      } catch (error) {
        stageFailure("runtime", error);
      }

      modules.runtime = runtime;
      publishRuntimeBindings(runtime);
    }

    return Object.freeze({
      composeRuntimeStage
    });
  };
})();
