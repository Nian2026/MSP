(function () {
  const moduleBindings = Object.freeze({
    statusModel: "__chatTranscriptMessageStatusModel",
    blockModel: "__chatTranscriptMessageBlockModel",
    hostBridge: "__chatTranscriptHostBridge",
    stylePlatform: "__chatTranscriptStylePlatform",
    messageDOM: "__chatTranscriptMessageDOM",
    scrollMetrics: "__chatTranscriptScrollMetrics",
    anchorPlatform: "__chatTranscriptAnchorPlatform",
    domPlatform: "__chatTranscriptDOMPlatform",
    runtimeModel: "__chatTranscriptMessageRuntimeModel",
    renderSupport: "__chatTranscriptRenderSupport",
    scrollCoordinator: "__chatTranscriptScrollCoordinator",
    conversationLayout: "__chatTranscriptConversationLayout",
    payloadModel: "__chatTranscriptPayloadModel",
    payloadPatcher: "__chatTranscriptPayloadPatcher",
    visualSupport: "__chatTranscriptVisualSupport",
    documentShell: "__chatTranscriptDocumentShell",
    documentRuntime: "__chatTranscriptDocumentRuntime",
    renderCoordinator: "__chatTranscriptRenderCoordinator",
    presentationController: "__chatTranscriptPresentationController",
    conversationController: "__chatTranscriptConversationController",
    interactionState: "__chatTranscriptInteractionState",
    overlayController: "__chatTranscriptOverlayController",
    messageBlockSupportRenderer: "__chatTranscriptMessageBlockSupportRenderer",
    messageBlockRenderer: "__chatTranscriptMessageBlockRenderer",
    messageUIRenderer: "__chatTranscriptMessageUIRenderer",
    messageArticleRenderer: "__chatTranscriptMessageArticleRenderer",
    rendererComponents: "__chatTranscriptRendererComponents",
    conversationRenderer: "__chatTranscriptConversationRenderer",
    runtime: "__chatTranscriptRuntime"
  });

  const legacyModuleBindings = Object.freeze({
    payloadStore: "__chatTranscriptPayloadStore"
  });

  function hasOwn(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
  }

  window.ChatTranscriptBootstrapBindingsFactory = function createChatTranscriptBootstrapBindings(dependencies = {}) {
    const windowObject = dependencies?.windowObject || window;

    function requiredGlobalFactory(name) {
      const value = windowObject?.[name];
      if (typeof value !== "function") {
        throw new Error(`Missing ChatTranscript bootstrap bindings dependency: ${name}`);
      }
      return value;
    }

    const createChatTranscriptBootstrapLegacyRuntimeBindings = requiredGlobalFactory(
      "ChatTranscriptBootstrapLegacyRuntimeBindingsFactory"
    );
    const createChatTranscriptCommandBridge = requiredGlobalFactory(
      "ChatTranscriptCommandBridgeFactory"
    );
    const legacyRuntimeBindings = createChatTranscriptBootstrapLegacyRuntimeBindings({
      windowObject
    });

    function runtimeObject() {
      const value = windowObject.__chatTranscriptRuntime;
      return value && typeof value === "object" ? value : null;
    }

    function resolvePublishedModule(name) {
      const bindingName = moduleBindings[name];
      if (!bindingName) {
        return null;
      }
      const value = windowObject[bindingName];
      return value && typeof value === "object" ? value : null;
    }

    function resolvePublishedMethod(moduleName, methodName) {
      const module = resolvePublishedModule(moduleName);
      const value = module?.[methodName];
      if (typeof value === "function") {
        return value.bind(module);
      }
      return null;
    }

    function resolveRuntimeMethod(name) {
      const runtime = runtimeObject();
      const value = runtime?.[name];
      if (typeof value === "function") {
        return value.bind(runtime);
      }
      return legacyRuntimeBindings.resolveLegacyRuntimeMethod(name);
    }

    function invokeRuntimeMethod(name, args) {
      const method = resolveRuntimeMethod(name);
      if (typeof method !== "function") {
        throw new Error(`Missing ChatTranscript runtime bridge method: ${name}`);
      }
      return method(...(Array.isArray(args) ? args : []));
    }

    const runtimeBridge = Object.freeze({
      hasMethod(name) {
        return typeof resolveRuntimeMethod(name) === "function";
      },
      resolveRuntimeMethod,
      renderConversationPreservingScroll(...args) {
        return invokeRuntimeMethod("renderConversationPreservingScroll", args);
      },
      renderConversationImmediately(...args) {
        return invokeRuntimeMethod("renderConversationImmediately", args);
      },
      setConversationPresentation(...args) {
        return invokeRuntimeMethod("setConversationPresentation", args);
      },
      scrollConversationToTop(...args) {
        return invokeRuntimeMethod("scrollConversationToTop", args);
      },
      scrollConversationToBottom(...args) {
        return invokeRuntimeMethod("scrollConversationToBottom", args);
      },
      scrollConversationToMessage(...args) {
        return invokeRuntimeMethod("scrollConversationToMessage", args);
      },
      applyPatchPreservingScroll(...args) {
        return invokeRuntimeMethod("applyPatchPreservingScroll", args);
      },
      updateStreamingMarkdownBlocks(...args) {
        return invokeRuntimeMethod("updateStreamingMarkdownBlocks", args);
      },
      renderConversation(...args) {
        return invokeRuntimeMethod("renderConversation", args);
      }
    });
    const commandBridge = createChatTranscriptCommandBridge({
      windowObject,
      resolveRuntimeBridge: () => runtimeBridge,
      resolveRenderConversationPreservingScroll: () => (
        resolvePublishedMethod("conversationController", "renderConversationPreservingScrollEntry")
          || resolveRuntimeMethod("renderConversationPreservingScroll")
      ),
      resolveApplyPatchPreservingScroll: () => (
        resolvePublishedMethod("renderCoordinator", "applyPatchPreservingScroll")
          || resolveRuntimeMethod("applyPatchPreservingScroll")
      ),
      resolveUpdateStreamingMarkdownBlocks: () => (
        resolvePublishedMethod("renderCoordinator", "updateStreamingMarkdownBlocks")
          || resolveRuntimeMethod("updateStreamingMarkdownBlocks")
      ),
      resolveSetConversationPresentation: () => (
        resolvePublishedMethod("presentationController", "setConversationPresentation")
          || resolveRuntimeMethod("setConversationPresentation")
      ),
      resolveScrollConversationToTop: () => (
        resolvePublishedMethod("conversationController", "scrollConversationToTop")
          || resolveRuntimeMethod("scrollConversationToTop")
      ),
      resolveScrollConversationToBottom: () => (
        resolvePublishedMethod("conversationController", "scrollConversationToBottom")
          || resolveRuntimeMethod("scrollConversationToBottom")
      ),
      resolveScrollConversationToMessage: () => (
        resolvePublishedMethod("conversationController", "scrollConversationToMessage")
          || resolveRuntimeMethod("scrollConversationToMessage")
      ),
      resolveNativeStreamingIndicatorGeometry: () => (
        resolvePublishedMethod("overlayController", "resolveNativeStreamingIndicatorGeometry")
      )
    });

    windowObject.__chatTranscriptRuntimeBridge = runtimeBridge;
    windowObject.__chatTranscriptCommandBridge = commandBridge;

    function publishBoundModules(bindings, modules = {}) {
      Object.entries(bindings).forEach(([moduleName, bindingName]) => {
        if (hasOwn(modules, moduleName)) {
          windowObject[bindingName] = modules[moduleName];
        }
      });
    }

    function publishModuleBindings(modules = {}) {
      publishBoundModules(moduleBindings, modules);
    }

    function publishLegacyModuleBindings(modules = {}) {
      publishBoundModules(legacyModuleBindings, modules);
    }

    function publishRuntimeBindings(runtime) {
      publishModuleBindings({ runtime });
      legacyRuntimeBindings.publishLegacyRuntimeBindings(runtime);
    }

    function resolveRuntimeBridge() {
      return runtimeBridge;
    }

    function resolveCommandBridge() {
      return commandBridge;
    }

    function resolveRenderConversation() {
      return resolvePublishedMethod("renderCoordinator", "renderConversation")
        || resolveRuntimeMethod("renderConversation");
    }

    function hasRenderConversation() {
      return typeof resolveRenderConversation() === "function";
    }

    function setBootstrapState(stage, details = {}) {
      windowObject.__chatTranscriptRuntimeBootstrap = {
        stage,
        source: "external",
        hasRenderConversation: hasRenderConversation(),
        ...details
      };
    }

    function setLastRuntimeBootstrapError(message) {
      windowObject.__chatTranscriptLastRuntimeBootstrapError = message;
    }

    return Object.freeze({
      publishModuleBindings,
      publishLegacyModuleBindings,
      publishRuntimeBindings,
      resolvePublishedModule,
      resolvePublishedMethod,
      resolveCommandBridge,
      resolveRuntimeBridge,
      resolveRuntimeMethod,
      resolveRenderConversation,
      hasRenderConversation,
      setBootstrapState,
      setLastRuntimeBootstrapError
    });
  };
})();
