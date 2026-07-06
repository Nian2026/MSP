(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript command bridge dependency: ${name}`);
    }
    return value;
  }

  function optionalFunction(dependencies, name) {
    const value = dependencies?.[name];
    return typeof value === "function" ? value : null;
  }

  window.ChatTranscriptCommandBridgeFactory = function createChatTranscriptCommandBridge(dependencies = {}) {
    const windowObject = dependencies?.windowObject || window;
    const resolveRenderConversationPreservingScroll = optionalFunction(
      dependencies,
      "resolveRenderConversationPreservingScroll"
    );
    const resolveApplyPatchPreservingScroll = optionalFunction(
      dependencies,
      "resolveApplyPatchPreservingScroll"
    );
    const resolveUpdateStreamingMarkdownBlocks = optionalFunction(
      dependencies,
      "resolveUpdateStreamingMarkdownBlocks"
    );
    const resolveSetConversationPresentation = optionalFunction(
      dependencies,
      "resolveSetConversationPresentation"
    );
    const resolveScrollConversationToTop = optionalFunction(
      dependencies,
      "resolveScrollConversationToTop"
    );
    const resolveScrollConversationToBottom = optionalFunction(
      dependencies,
      "resolveScrollConversationToBottom"
    );
    const resolveScrollConversationToMessage = optionalFunction(
      dependencies,
      "resolveScrollConversationToMessage"
    );
    const resolveNativeStreamingIndicatorGeometry = optionalFunction(
      dependencies,
      "resolveNativeStreamingIndicatorGeometry"
    );
    const resolveRuntimeBridge = optionalFunction(dependencies, "resolveRuntimeBridge");

    function trimmed(text) {
      return String(text || "").trim();
    }

    function runtimeBridge() {
      if (typeof resolveRuntimeBridge !== "function") {
        return null;
      }
      const value = resolveRuntimeBridge();
      return value && typeof value === "object" ? value : null;
    }

    function resolveRuntimeBridgeMethod(name) {
      const bridge = runtimeBridge();
      const method = bridge?.[name];
      if (typeof method !== "function") {
        throw new Error(`${name} is not a function`);
      }
      return method.bind(bridge);
    }

    function resolveCommandMethod(name, directResolver, runtimeBridgeMethodName = name) {
      const directMethod = typeof directResolver === "function" ? directResolver() : null;
      if (typeof directMethod === "function") {
        return directMethod;
      }
      return resolveRuntimeBridgeMethod(runtimeBridgeMethodName);
    }

    function resolveRenderPayloadMutation() {
      return resolveCommandMethod(
        "renderConversationPreservingScroll",
        resolveRenderConversationPreservingScroll
      );
    }

    function resolveApplyPayloadPatchMutation() {
      return resolveCommandMethod(
        "applyPatchPreservingScroll",
        resolveApplyPatchPreservingScroll
      );
    }

    function resolveUpdateStreamingMarkdownBlocksMutation() {
      return resolveCommandMethod(
        "updateStreamingMarkdownBlocks",
        resolveUpdateStreamingMarkdownBlocks
      );
    }

    function resolveSetPresentationMutation() {
      return resolveCommandMethod(
        "setConversationPresentation",
        resolveSetConversationPresentation
      );
    }

    function resolveScrollToTopMutation() {
      return resolveCommandMethod(
        "scrollConversationToTop",
        resolveScrollConversationToTop
      );
    }

    function resolveScrollToBottomMutation() {
      return resolveCommandMethod(
        "scrollConversationToBottom",
        resolveScrollConversationToBottom
      );
    }

    function resolveScrollToMessageMutation() {
      return resolveCommandMethod(
        "scrollConversationToMessage",
        resolveScrollConversationToMessage
      );
    }

    function resolveNativeStreamingIndicatorGeometryMutation() {
      return resolveCommandMethod(
        "resolveNativeStreamingIndicatorGeometry",
        resolveNativeStreamingIndicatorGeometry
      );
    }

    function normalizedMutationOptions(options = {}, defaults = {}) {
      return {
        followBottomIfNearBottom: options?.followBottomIfNearBottom ?? defaults.followBottomIfNearBottom ?? false,
        forceImmediateRender: options?.forceImmediateRender ?? defaults.forceImmediateRender ?? false,
        preserveScrollAnchor: options?.preserveScrollAnchor ?? defaults.preserveScrollAnchor ?? true,
        focusEditorMessageId: trimmed(options?.focusEditorMessageId),
        initialScrollTarget: normalizedInitialScrollTarget(options?.initialScrollTarget ?? defaults.initialScrollTarget),
        debugReason: trimmed(options?.debugReason) || trimmed(defaults.debugReason)
      };
    }

    function normalizedInitialScrollTarget(value) {
      const target = trimmed(value).toLowerCase();
      if (target === "top" || target === "bottom") {
        return target;
      }
      return "";
    }

    function domPlatform() {
      const value = windowObject.__chatTranscriptDOMPlatform;
      return value && typeof value === "object" ? value : null;
    }

    function scrollRoot() {
      const platform = domPlatform();
      const method = platform?.scrollRoot;
      return typeof method === "function" ? method() : null;
    }

    function maximumScrollTop(root) {
      const platform = domPlatform();
      const method = platform?.maximumScrollTop;
      if (typeof method === "function") {
        return method(root);
      }
      return Math.max(
        (Number(root?.scrollHeight) || 0) - (Number(root?.clientHeight) || 0),
        0
      );
    }

    function clampScrollTop(root, value) {
      const platform = domPlatform();
      const method = platform?.clamp;
      const maximumTop = maximumScrollTop(root);
      if (typeof method === "function") {
        return method(value, 0, maximumTop);
      }
      return Math.min(Math.max(Number(value) || 0, 0), maximumTop);
    }

    function isNearConversationBottom(root, threshold = 64) {
      const platform = domPlatform();
      const method = platform?.isNearConversationBottom;
      if (typeof method === "function") {
        return method(root, threshold);
      }
      const distance = maximumScrollTop(root) - (Number(root?.scrollTop) || 0);
      return distance <= threshold;
    }

    function capturePresentationAnchor() {
      const platform = domPlatform();
      const method = platform?.capturePresentationAnchor;
      return typeof method === "function" ? method() : null;
    }

    function restorePresentationAnchor(anchor) {
      const platform = domPlatform();
      const method = platform?.restorePresentationAnchor;
      if (typeof method === "function") {
        method(anchor);
      }
    }

    function renderPayload(payload, options = {}) {
      windowObject.__chatTranscriptPayload = payload;
      return resolveRenderPayloadMutation()(normalizedMutationOptions(options, {
          followBottomIfNearBottom: true,
          forceImmediateRender: true,
          debugReason: "command_render_payload"
      }));
    }

    function applyPayloadPatch(patch, options = {}) {
      return resolveApplyPayloadPatchMutation()(
        patch,
        normalizedMutationOptions(options, {
          followBottomIfNearBottom: true,
          forceImmediateRender: true,
          debugReason: "command_apply_payload_patch"
        })
      );
    }

    function updateStreamingMarkdownBlocks(update, options = {}) {
      return resolveUpdateStreamingMarkdownBlocksMutation()(
        update,
        normalizedMutationOptions(options, {
          followBottomIfNearBottom: true,
          forceImmediateRender: true,
          debugReason: "command_update_streaming_markdown_blocks"
        })
      );
    }

    function setPresentation(presentation, options = {}) {
      const suppressConversationRerender = Boolean(options?.suppressConversationRerender);
      const preserveScrollAnchor = Boolean(options?.preserveScrollAnchor);
      const root = preserveScrollAnchor ? scrollRoot() : null;
      const fallbackOffset = Number(root?.scrollTop) || 0;
      const shouldFollowBottom = preserveScrollAnchor &&
        Boolean(options?.followBottomIfNearBottom) &&
        isNearConversationBottom(root);
      const anchor = preserveScrollAnchor && !shouldFollowBottom
        ? capturePresentationAnchor()
        : null;
      let result;
      try {
        if (suppressConversationRerender) {
          windowObject.__chatTranscriptSkipPresentationRerender = true;
        }
        result = resolveSetPresentationMutation()(presentation);
      } finally {
        windowObject.__chatTranscriptSkipPresentationRerender = false;
      }
      if (preserveScrollAnchor) {
        const nextRoot = scrollRoot();
        if (nextRoot && shouldFollowBottom) {
          nextRoot.scrollTop = maximumScrollTop(nextRoot);
        } else if (nextRoot && anchor) {
          restorePresentationAnchor(anchor);
        } else if (nextRoot) {
          nextRoot.scrollTop = clampScrollTop(nextRoot, fallbackOffset);
        }
      }
      return result;
    }

    function scrollToBottom() {
      return resolveScrollToBottomMutation()();
    }

    function scrollToTop() {
      return resolveScrollToTopMutation()();
    }

    function scrollToMessage(payload) {
      return resolveScrollToMessageMutation()(
        trimmed(payload?.messageID),
        trimmed(payload?.alignment)
      );
    }

    function resolveNativeStreamingIndicator() {
      return resolveNativeStreamingIndicatorGeometryMutation()();
    }

    function reasoningActivityPopoverBridgeState() {
      const existing = windowObject.__chatTranscriptReasoningActivityPopoverBridge;
      if (existing && typeof existing === "object") {
        if (!existing.lastPostedAtByBlockKey) {
          existing.lastPostedAtByBlockKey = {};
        }
        if (!existing.lastSignatureByBlockKey) {
          existing.lastSignatureByBlockKey = {};
        }
        if (!existing.pendingUpdateByBlockKey) {
          existing.pendingUpdateByBlockKey = {};
        }
        if (!existing.pendingTimerByBlockKey) {
          existing.pendingTimerByBlockKey = {};
        }
        return existing;
      }
      const state = {
        activeBlockKey: null,
        generation: 0,
        revision: 0,
        lastPostedAtByBlockKey: {},
        lastSignatureByBlockKey: {},
        pendingUpdateByBlockKey: {},
        pendingTimerByBlockKey: {}
      };
      windowObject.__chatTranscriptReasoningActivityPopoverBridge = state;
      return state;
    }

    function clearReasoningActivityPopoverPendingTimers(state) {
      Object.values(state.pendingTimerByBlockKey || {}).forEach((timer) => {
        if (timer) {
          windowObject.clearTimeout(timer);
        }
      });
      state.pendingTimerByBlockKey = {};
      state.pendingUpdateByBlockKey = {};
    }

    function setReasoningActivityPopoverSubscription(payload = {}) {
      const state = reasoningActivityPopoverBridgeState();
      const revision = Number(payload?.revision);
      if (Number.isFinite(revision) && revision < (Number(state.revision) || 0)) {
        return {
          activeBlockKey: state.activeBlockKey,
          generation: state.generation,
          revision: state.revision,
          ignored: true
        };
      }
      if (Number.isFinite(revision)) {
        state.revision = revision;
      }
      const blockKey = trimmed(payload?.blockKey);
      const nextBlockKey = blockKey || null;
      if (state.activeBlockKey !== nextBlockKey) {
        clearReasoningActivityPopoverPendingTimers(state);
        state.lastPostedAtByBlockKey = {};
        state.lastSignatureByBlockKey = {};
        state.generation = (Number(state.generation) || 0) + 1;
      }
      state.activeBlockKey = nextBlockKey;
      return {
        activeBlockKey: state.activeBlockKey,
        generation: state.generation
      };
    }

    const commandHandlers = Object.freeze({
      render_payload: renderPayload,
      apply_payload_patch: applyPayloadPatch,
      update_streaming_markdown_blocks: updateStreamingMarkdownBlocks,
      set_presentation: setPresentation,
      set_reasoning_activity_popover_subscription: setReasoningActivityPopoverSubscription,
      scroll_to_top: scrollToTop,
      scroll_to_bottom: scrollToBottom,
      scroll_to_message: scrollToMessage,
      resolve_native_streaming_indicator_geometry: resolveNativeStreamingIndicator
    });

    function execute(commandName, payload, options = {}) {
      const normalizedCommandName = trimmed(commandName);
      const handler = commandHandlers[normalizedCommandName];
      if (typeof handler !== "function") {
        throw new Error(`Unknown ChatTranscript command: ${normalizedCommandName}`);
      }
      return handler(payload, options);
    }

    function hasCommand(commandName) {
      return typeof commandHandlers[trimmed(commandName)] === "function";
    }

    function availableCommands() {
      return Object.keys(commandHandlers);
    }

    return Object.freeze({
      execute,
      hasCommand,
      availableCommands
    });
  };
})();
