(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript scroll coordinator dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript scroll coordinator dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptScrollCoordinatorFactory = function createChatTranscriptScrollCoordinator(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const transcriptUIState = requiredFunction(dependencies, "transcriptUIState");
    const transcriptPresentation = requiredFunction(dependencies, "transcriptPresentation");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const payloadModel = requiredObject(dependencies, "payloadModel");
    const resolvePayload = requiredFunction(payloadModel, "resolvePayload");
    const scrollRoot = requiredFunction(dependencies, "scrollRoot");
    const clamp = requiredFunction(dependencies, "clamp");
    const isNearConversationBottom = requiredFunction(dependencies, "isNearConversationBottom");
    const capturePresentationAnchor = requiredFunction(dependencies, "capturePresentationAnchor");
    const restorePresentationAnchor = requiredFunction(dependencies, "restorePresentationAnchor");
    const transcriptScrollSnapshot = requiredFunction(dependencies, "transcriptScrollSnapshot");
    const transcriptAnchorSnapshot = requiredFunction(dependencies, "transcriptAnchorSnapshot");
    const currentConversationDocumentHeight = requiredFunction(dependencies, "currentConversationDocumentHeight");
    const findMessageElement = requiredFunction(dependencies, "findMessageElement");
    const hasRenderedMessages = requiredFunction(dependencies, "hasRenderedMessages");
    const resolveMessageUIRenderer = requiredFunction(dependencies, "resolveMessageUIRenderer");
    const resolveSetConversationPresentation = requiredFunction(dependencies, "resolveSetConversationPresentation");
    const resolveRenderConversation = requiredFunction(dependencies, "resolveRenderConversation");
    const transcriptTopPinThreshold = Number(dependencies?.transcriptTopPinThreshold) || 24;
    const transcriptLiveEdgeThreshold = Number(dependencies?.transcriptLiveEdgeThreshold) || 64;
    const scrollToBottomButtonVisibilityThreshold = 24;
    const scrollToBottomAnimationDurationMs = 260;
    const scrollStateViewportHeightChangeThreshold = Number(dependencies?.scrollStateViewportHeightChangeThreshold) || 8;
    const scrollStateDocumentHeightChangeThreshold = Number(dependencies?.scrollStateDocumentHeightChangeThreshold) || 96;
    const scrollStateDistanceFromBottomChangeThreshold = Number(dependencies?.scrollStateDistanceFromBottomChangeThreshold) || 96;
    const transcriptDisplayWindowExpansionThreshold = Number(dependencies?.transcriptDisplayWindowExpansionThreshold) || 180;
    const transcriptDisplayWindowExpansionDebounceInterval = Number(dependencies?.transcriptDisplayWindowExpansionDebounceInterval) || 0.35;
    const transcriptDisplayWindowExpansionGestureGraceInterval = Number(dependencies?.transcriptDisplayWindowExpansionGestureGraceInterval) || 1.25;
    const transcriptDisplayWindowExpansionIdleDelay = Number(dependencies?.transcriptDisplayWindowExpansionIdleDelay) || 0.18;

    function transcriptNow() {
      const performanceNow = Number(window.performance?.now?.());
      if (Number.isFinite(performanceNow)) {
        return performanceNow / 1000;
      }
      return Date.now() / 1000;
    }

    function messageUIRenderer() {
      const value = resolveMessageUIRenderer();
      return value && typeof value === "object" ? value : null;
    }

    function setConversationPresentation() {
      const value = resolveSetConversationPresentation();
      return typeof value === "function" ? value : null;
    }

    function renderConversation() {
      const value = resolveRenderConversation();
      return typeof value === "function" ? value : null;
    }

    function normalizedDisplayWindow(payload) {
      const startIndex = Math.max(Number(payload?.displayWindow?.startIndex) || 0, 0);
      const displayCount = Math.max(Number(payload?.displayWindow?.displayCount) || 0, 0);
      if (displayCount <= 0) {
        return null;
      }
      return {
        startIndex,
        displayCount
      };
    }

    function noteUserScrollGesture() {
      cancelScrollToBottomAnimation();
      const state = transcriptUIState();
      state.lastUserScrollGestureAt = transcriptNow();
    }

    function maximumScrollOffset(root) {
      return Math.max((Number(root?.scrollHeight) || 0) - (Number(root?.clientHeight) || 0), 0);
    }

    function distanceFromBottom(root) {
      return Math.max(maximumScrollOffset(root) - (Number(root?.scrollTop) || 0), 0);
    }

    function setDistanceFromBottom(root, distance) {
      if (!root) {
        return 0;
      }
      const maximumOffset = maximumScrollOffset(root);
      const nextDistance = Math.max(Number(distance) || 0, 0);
      root.scrollTop = clamp(maximumOffset - nextDistance, 0, maximumOffset);
      return root.scrollTop || 0;
    }

    function cancelScrollToBottomAnimation() {
      const state = transcriptUIState();
      if (state.scrollToBottomAnimationFrame) {
        cancelAnimationFrame(state.scrollToBottomAnimationFrame);
      }
      state.scrollToBottomAnimationFrame = 0;
      state.isScrollToBottomAnimating = false;
    }

    function scrollStatePayload(root = scrollRoot(), source = "scroll") {
      const maximumOffset = maximumScrollOffset(root);
      const scrollTop = Math.min(Math.max(Number(root?.scrollTop) || 0, 0), maximumOffset);
      const distanceFromBottom = Math.max(maximumOffset - scrollTop, 0);
      return {
        source: trimmed(source) || "scroll",
        distanceFromBottom,
        viewportHeight: Number(root?.clientHeight) || 0,
        documentHeight: Number(root?.scrollHeight) || 0,
        maximumOffsetY: maximumOffset,
        showsScrollToBottomButton: distanceFromBottom > scrollToBottomButtonVisibilityThreshold,
        threshold: scrollToBottomButtonVisibilityThreshold
      };
    }

    function shouldPostScrollState(nextPayload, force = false) {
      if (force) {
        return true;
      }
      const state = transcriptUIState();
      const last = state.lastPostedScrollStatePayload;
      if (!last) {
        return true;
      }
      if (Boolean(last.showsScrollToBottomButton) !== Boolean(nextPayload.showsScrollToBottomButton)) {
        return true;
      }
      if (
        Math.abs((Number(last.viewportHeight) || 0) - (Number(nextPayload.viewportHeight) || 0)) >=
        scrollStateViewportHeightChangeThreshold
      ) {
        return true;
      }
      if (
        Math.abs((Number(last.documentHeight) || 0) - (Number(nextPayload.documentHeight) || 0)) >=
        scrollStateDocumentHeightChangeThreshold
      ) {
        return true;
      }
      return (
        Math.abs((Number(last.distanceFromBottom) || 0) - (Number(nextPayload.distanceFromBottom) || 0)) >=
        scrollStateDistanceFromBottomChangeThreshold
      );
    }

    function postScrollState(source = "scroll", options = {}) {
      const payload = scrollStatePayload(scrollRoot(), source);
      if (!shouldPostScrollState(payload, Boolean(options.force))) {
        return payload;
      }
      transcriptUIState().lastPostedScrollStatePayload = payload;
      postTranscriptProbe("scroll_state", "change", payload);
      return payload;
    }

    function scheduleScrollStatePost(source = "scroll") {
      const state = transcriptUIState();
      state.pendingScrollStateSource = trimmed(source) || "scroll";
      if (state.pendingScrollStateFrame) {
        return;
      }
      state.pendingScrollStateFrame = requestAnimationFrame(() => {
        const nextSource = state.pendingScrollStateSource || source;
        state.pendingScrollStateFrame = 0;
        state.pendingScrollStateSource = "";
        postScrollState(nextSource);
      });
    }

    function clearScheduledDisplayWindowExpansion() {
      const state = transcriptUIState();
      if (state.pendingDisplayWindowExpansionTimer) {
        clearTimeout(state.pendingDisplayWindowExpansionTimer);
      }
      state.pendingDisplayWindowExpansionTimer = 0;
      state.pendingDisplayWindowExpansionSource = "";
    }

    function scheduleDisplayWindowExpansionCheck(source = "scroll") {
      const state = transcriptUIState();
      const nextSource = trimmed(source) || "scroll";
      state.pendingDisplayWindowExpansionSource = nextSource;
      if (state.pendingDisplayWindowExpansionTimer) {
        clearTimeout(state.pendingDisplayWindowExpansionTimer);
      }
      state.pendingDisplayWindowExpansionTimer = setTimeout(() => {
        const scheduledSource = state.pendingDisplayWindowExpansionSource || nextSource;
        state.pendingDisplayWindowExpansionTimer = 0;
        state.pendingDisplayWindowExpansionSource = "";
        requestDisplayWindowExpansionIfNeeded(scheduledSource);
      }, Math.max(transcriptDisplayWindowExpansionIdleDelay, 0) * 1000);
    }

    function requestDisplayWindowExpansionIfNeeded(source = "scroll") {
      const root = scrollRoot();
      const payload = resolvePayload();
      const displayWindow = normalizedDisplayWindow(payload);
      const messages = Array.isArray(payload?.messages) ? payload.messages : [];
      const state = transcriptUIState();
      const now = transcriptNow();
      const scrollTop = Number(root?.scrollTop) || 0;
      const lastUserScrollGestureAt = Number(state.lastUserScrollGestureAt) || 0;
      const lastDisplayWindowExpansionRequestAt = Number(state.lastDisplayWindowExpansionRequestAt) || 0;
      const hasMoreHistoricalMessages = Boolean(displayWindow) && displayWindow.displayCount < messages.length;
      const withinGestureGraceInterval = lastUserScrollGestureAt > 0 &&
        (now - lastUserScrollGestureAt) <= transcriptDisplayWindowExpansionGestureGraceInterval;
      const passedDebounceInterval = (now - lastDisplayWindowExpansionRequestAt) >= transcriptDisplayWindowExpansionDebounceInterval;
      const isNearConversationTop = scrollTop <= transcriptDisplayWindowExpansionThreshold;

      if (
        !root ||
        state.isScrollToBottomAnimating ||
        !displayWindow ||
        !hasMoreHistoricalMessages ||
        !withinGestureGraceInterval ||
        !passedDebounceInterval ||
        !isNearConversationTop
      ) {
        return false;
      }

      clearScheduledDisplayWindowExpansion();
      state.lastDisplayWindowExpansionRequestAt = now;
      postTranscriptProbe("display_window", "request_expand", {
        source: trimmed(source) || "scroll",
        displayCount: displayWindow.displayCount,
        startIndex: displayWindow.startIndex,
        messageCount: messages.length,
        threshold: transcriptDisplayWindowExpansionThreshold,
        debounceInterval: transcriptDisplayWindowExpansionDebounceInterval,
        gestureGraceInterval: transcriptDisplayWindowExpansionGestureGraceInterval,
        ...transcriptScrollSnapshot(root)
      });
      return true;
    }

    function activeElementProbePayload() {
      const activeElement = document.activeElement;
      const className = typeof activeElement?.className === "string" ? activeElement.className : "";
      return {
        activeTag: trimmed(activeElement?.tagName).toLowerCase(),
        activeClass: trimmed(className),
        activeMessageId: trimmed(activeElement?.dataset?.messageId),
        activeIsTextarea: activeElement instanceof HTMLTextAreaElement
      };
    }

    function focusEditorProbePayload(messageID, textarea) {
      const root = scrollRoot();
      const rect = textarea instanceof HTMLTextAreaElement
        ? textarea.getBoundingClientRect()
        : null;
      return {
        messageID: trimmed(messageID),
        editingMessageId: trimmed(transcriptUIState().editingMessageId),
        documentHasFocus: typeof document.hasFocus === "function" ? document.hasFocus() : false,
        textareaFound: textarea instanceof HTMLTextAreaElement,
        textareaConnected: textarea instanceof HTMLTextAreaElement ? textarea.isConnected : false,
        textareaFocused: textarea instanceof HTMLTextAreaElement ? document.activeElement === textarea : false,
        textareaValueLength: textarea instanceof HTMLTextAreaElement ? textarea.value.length : -1,
        selectionStart: textarea instanceof HTMLTextAreaElement && typeof textarea.selectionStart === "number" ? textarea.selectionStart : -1,
        selectionEnd: textarea instanceof HTMLTextAreaElement && typeof textarea.selectionEnd === "number" ? textarea.selectionEnd : -1,
        textareaWidth: rect ? rect.width : 0,
        textareaHeight: rect ? rect.height : 0,
        scrollTop: Number(root?.scrollTop) || 0,
        ...activeElementProbePayload()
      };
    }

    function postEditorFocusProbe(event, messageID, textarea, extra = {}) {
      postTranscriptProbe("editor_focus", event, {
        source: "scroll_coordinator",
        ...focusEditorProbePayload(messageID, textarea),
        ...extra
      });
    }

    function focusEditorForMessage(messageID) {
      if (!messageID) {
        return;
      }
      const textarea = document.querySelector(`.message-editor-textarea[data-message-id="${messageID}"]`);
      if (!(textarea instanceof HTMLTextAreaElement)) {
        postEditorFocusProbe("focus_request_missing", messageID, null);
        return;
      }
      postEditorFocusProbe("focus_request_begin", messageID, textarea);
      textarea.focus();
      textarea.setSelectionRange(textarea.value.length, textarea.value.length);
      postEditorFocusProbe("focus_request_after", messageID, textarea);
      requestAnimationFrame(() => {
        postEditorFocusProbe("focus_request_raf", messageID, textarea);
      });
      const uiRenderer = messageUIRenderer();
      if (uiRenderer && typeof uiRenderer.autoResizeEditor === "function") {
        uiRenderer.autoResizeEditor(textarea);
      }
    }

    function normalizedRenderOptions(followBottomOrOptions) {
      const options = typeof followBottomOrOptions === "object" && followBottomOrOptions !== null
        ? followBottomOrOptions
        : { followBottomIfNearBottom: Boolean(followBottomOrOptions) };
      return {
        followBottomIfNearBottom: Boolean(options.followBottomIfNearBottom),
        forceImmediateRender: Boolean(options.forceImmediateRender),
        focusEditorMessageId: trimmed(options.focusEditorMessageId),
        initialScrollTarget: normalizedInitialScrollTarget(options.initialScrollTarget),
        debugReason: trimmed(options.debugReason)
      };
    }

    function normalizedInitialScrollTarget(value) {
      const target = trimmed(value).toLowerCase();
      if (target === "top" || target === "bottom") {
        return target;
      }
      return "";
    }

    function scheduleDeferredLiveRenderFlush() {
      const state = transcriptUIState();
      if (!state.hasDeferredLiveRender || state.deferredLiveRenderFrame) {
        return;
      }
      state.deferredLiveRenderFrame = requestAnimationFrame(() => {
        state.deferredLiveRenderFrame = 0;
        if (!state.hasDeferredLiveRender || !isNearConversationBottom(scrollRoot())) {
          return;
        }
        postTranscriptProbe("mutation", "deferred_flush", {
          reason: "deferred_live_render_flush",
          hasDeferredLiveRender: Boolean(state.hasDeferredLiveRender),
          ...transcriptScrollSnapshot(scrollRoot())
        });
        rerenderConversationPreservingScroll({
          followBottomIfNearBottom: true,
          forceImmediateRender: true,
          debugReason: "deferred_live_render_flush"
        });
      });
    }

    function handleConversationScroll(source = "scroll") {
      scheduleScrollStatePost(source);
      scheduleDeferredLiveRenderFlush();
      scheduleDisplayWindowExpansionCheck(source);
    }

    function performConversationMutationPreservingScroll(options, mutation) {
      const state = transcriptUIState();
      const root = scrollRoot();
      const debugReason = trimmed(options.debugReason) || "anonymous_mutation";
      const fallbackOffset = Number(root?.scrollTop) || 0;
      const presentation = transcriptPresentation();
      const hasExistingMessages = hasRenderedMessages();
      const shouldDeferLiveRender = !options.forceImmediateRender && Boolean(root) && hasExistingMessages && !isNearConversationBottom(root) && (
        Boolean(presentation?.isConversationGenerating) || state.hasDeferredLiveRender
      );
      const anchor = shouldDeferLiveRender ? null : capturePresentationAnchor();
      const wasAtConversationBottom = Boolean(root) && isNearConversationBottom(root);
      const shouldPinTop = fallbackOffset <= transcriptTopPinThreshold && !wasAtConversationBottom;
      const shouldFollowBottom = Boolean(options.followBottomIfNearBottom) && (
        wasAtConversationBottom ||
        (!shouldPinTop && (!anchor || ((Number(anchor.distanceFromBottom) || 0) <= transcriptLiveEdgeThreshold)))
      );
      postTranscriptProbe("mutation", "begin", {
        reason: debugReason,
        followBottomIfNearBottom: Boolean(options.followBottomIfNearBottom),
        forceImmediateRender: Boolean(options.forceImmediateRender),
        focusEditorMessageId: options.focusEditorMessageId || "",
        initialScrollTarget: options.initialScrollTarget || "",
        hasExistingMessages,
        hasDeferredLiveRender: Boolean(state.hasDeferredLiveRender),
        shouldDeferLiveRender,
        wasAtConversationBottom,
        shouldPinTop,
        shouldFollowBottom,
        fallbackOffset,
        ...transcriptScrollSnapshot(root),
        ...transcriptAnchorSnapshot(anchor)
      });
      if (shouldDeferLiveRender) {
        state.hasDeferredLiveRender = true;
        postTranscriptProbe("mutation", "deferred", {
          reason: debugReason,
          followBottomIfNearBottom: Boolean(options.followBottomIfNearBottom),
          forceImmediateRender: Boolean(options.forceImmediateRender),
          ...transcriptScrollSnapshot(root)
        });
        return currentConversationDocumentHeight();
      }

      state.hasDeferredLiveRender = false;
      const previousDebugReason = window.__chatTranscriptCurrentMutationReason;
      let result;
      try {
        window.__chatTranscriptCurrentMutationReason = debugReason;
        result = mutation();
      } catch (error) {
        postTranscriptProbe("mutation", "failed", {
          reason: debugReason,
          error: error instanceof Error ? `${error.name}: ${error.message}` : String(error),
          ...transcriptScrollSnapshot(root),
          ...transcriptAnchorSnapshot(anchor)
        });
        throw error;
      } finally {
        window.__chatTranscriptCurrentMutationReason = previousDebugReason;
      }

      const setPresentation = setConversationPresentation();
      if (presentation && setPresentation) {
        window.__chatTranscriptSkipPresentationRerender = true;
        setPresentation(presentation);
        window.__chatTranscriptSkipPresentationRerender = false;
      }

      const nextRoot = scrollRoot();
      let restoreStrategy = "none";
      if (options.initialScrollTarget === "top" && nextRoot) {
        restoreStrategy = "initial_top";
        nextRoot.scrollTop = 0;
      } else if (options.initialScrollTarget === "bottom" && nextRoot) {
        restoreStrategy = "initial_bottom";
        nextRoot.scrollTop = Math.max((Number(nextRoot.scrollHeight) || 0) - (Number(nextRoot.clientHeight) || 0), 0);
      } else if (shouldPinTop && nextRoot) {
        restoreStrategy = "pin_top";
        nextRoot.scrollTop = 0;
      } else if (shouldFollowBottom && nextRoot) {
        restoreStrategy = "follow_bottom";
        nextRoot.scrollTop = Math.max((Number(nextRoot.scrollHeight) || 0) - (Number(nextRoot.clientHeight) || 0), 0);
      } else if (anchor) {
        restoreStrategy = "anchor_restore";
        restorePresentationAnchor(anchor);
      } else if (nextRoot) {
        restoreStrategy = "fallback_offset";
        nextRoot.scrollTop = clamp(
          fallbackOffset,
          0,
          Math.max((Number(nextRoot.scrollHeight) || 0) - (Number(nextRoot.clientHeight) || 0), 0)
        );
      }

      if (options.focusEditorMessageId) {
        requestAnimationFrame(() => {
          focusEditorForMessage(options.focusEditorMessageId);
        });
      }

      postTranscriptProbe("mutation", "complete", {
        reason: debugReason,
        restoreStrategy,
        followBottomIfNearBottom: Boolean(options.followBottomIfNearBottom),
        forceImmediateRender: Boolean(options.forceImmediateRender),
        focusEditorMessageId: options.focusEditorMessageId || "",
        initialScrollTarget: options.initialScrollTarget || "",
        resultHeight: Number(result) || 0,
        hasDeferredLiveRender: Boolean(state.hasDeferredLiveRender),
        ...transcriptScrollSnapshot(nextRoot || root),
        ...transcriptAnchorSnapshot(anchor)
      });
      postScrollState(`mutation.${debugReason}`, { force: true });
      return result;
    }

    function rerenderConversationPreservingScroll(options = {}) {
      const normalizedOptions = normalizedRenderOptions(options);
      if (!normalizedOptions.debugReason) {
        normalizedOptions.debugReason = "rerender_conversation";
      }
      const render = renderConversation();
      if (typeof render !== "function") {
        return currentConversationDocumentHeight();
      }
      return performConversationMutationPreservingScroll(normalizedOptions, () => render());
    }

    function scrollConversationToBottom() {
      const root = scrollRoot();
      if (!root) {
        return 0;
      }
      cancelScrollToBottomAnimation();
      const initialDistanceFromBottom = distanceFromBottom(root);
      postTranscriptProbe("scroll", "bottom_begin", {
        reason: "scroll_to_bottom",
        distanceFromBottom: initialDistanceFromBottom,
        durationMs: scrollToBottomAnimationDurationMs,
        ...transcriptScrollSnapshot(root)
      });

      if (initialDistanceFromBottom <= scrollToBottomButtonVisibilityThreshold) {
        setDistanceFromBottom(root, 0);
        scheduleDeferredLiveRenderFlush();
        postTranscriptProbe("scroll", "bottom_complete", {
          reason: "scroll_to_bottom",
          animated: false,
          distanceFromBottom: distanceFromBottom(root),
          ...transcriptScrollSnapshot(root)
        });
        postScrollState("scroll_to_bottom", { force: true });
        return root.scrollTop || 0;
      }

      const state = transcriptUIState();
      const performanceStartedAt = Number(window.performance?.now?.());
      const animationStartedAt = Number.isFinite(performanceStartedAt) ? performanceStartedAt : Date.now();
      state.isScrollToBottomAnimating = true;

      const finish = (nextRoot) => {
        const finishRoot = nextRoot || scrollRoot();
        state.scrollToBottomAnimationFrame = 0;
        state.isScrollToBottomAnimating = false;
        setDistanceFromBottom(finishRoot, 0);
        scheduleDeferredLiveRenderFlush();
        postTranscriptProbe("scroll", "bottom_complete", {
          reason: "scroll_to_bottom",
          animated: true,
          distanceFromBottom: distanceFromBottom(finishRoot),
          ...transcriptScrollSnapshot(finishRoot)
        });
        postScrollState("scroll_to_bottom", { force: true });
      };

      const step = (timestamp) => {
        const nextRoot = scrollRoot();
        if (!nextRoot) {
          cancelScrollToBottomAnimation();
          return;
        }
        const elapsed = Math.min(1, Math.max(0, (timestamp - animationStartedAt) / scrollToBottomAnimationDurationMs));
        const remainingDistance = initialDistanceFromBottom * Math.pow(1 - elapsed, 3);
        setDistanceFromBottom(nextRoot, remainingDistance);
        scheduleDeferredLiveRenderFlush();
        scheduleScrollStatePost("scroll_to_bottom_animation");
        if (elapsed < 1 && distanceFromBottom(nextRoot) > scrollToBottomButtonVisibilityThreshold) {
          state.scrollToBottomAnimationFrame = requestAnimationFrame(step);
          return;
        }
        finish(nextRoot);
      };

      state.scrollToBottomAnimationFrame = requestAnimationFrame(step);
      scheduleDeferredLiveRenderFlush();
      return root.scrollTop || 0;
    }

    function scrollConversationToTop() {
      const root = scrollRoot();
      if (!root) {
        return 0;
      }
      cancelScrollToBottomAnimation();
      const initialScrollTop = Math.max(Number(root.scrollTop) || 0, 0);
      postTranscriptProbe("scroll", "top_begin", {
        reason: "scroll_to_top",
        scrollTop: initialScrollTop,
        durationMs: scrollToBottomAnimationDurationMs,
        ...transcriptScrollSnapshot(root)
      });

      if (initialScrollTop <= scrollToBottomButtonVisibilityThreshold) {
        root.scrollTop = 0;
        postTranscriptProbe("scroll", "top_complete", {
          reason: "scroll_to_top",
          animated: false,
          scrollTop: Number(root.scrollTop) || 0,
          ...transcriptScrollSnapshot(root)
        });
        postScrollState("scroll_to_top", { force: true });
        return root.scrollTop || 0;
      }

      const state = transcriptUIState();
      const performanceStartedAt = Number(window.performance?.now?.());
      const animationStartedAt = Number.isFinite(performanceStartedAt) ? performanceStartedAt : Date.now();
      state.isScrollToBottomAnimating = true;

      const finish = (nextRoot) => {
        const finishRoot = nextRoot || scrollRoot();
        state.scrollToBottomAnimationFrame = 0;
        state.isScrollToBottomAnimating = false;
        if (finishRoot) {
          finishRoot.scrollTop = 0;
        }
        postTranscriptProbe("scroll", "top_complete", {
          reason: "scroll_to_top",
          animated: true,
          scrollTop: Number(finishRoot?.scrollTop) || 0,
          ...transcriptScrollSnapshot(finishRoot)
        });
        postScrollState("scroll_to_top", { force: true });
      };

      const step = (timestamp) => {
        const nextRoot = scrollRoot();
        if (!nextRoot) {
          cancelScrollToBottomAnimation();
          return;
        }
        const elapsed = Math.min(1, Math.max(0, (timestamp - animationStartedAt) / scrollToBottomAnimationDurationMs));
        nextRoot.scrollTop = initialScrollTop * Math.pow(1 - elapsed, 3);
        scheduleScrollStatePost("scroll_to_top_animation");
        if (elapsed < 1 && (Number(nextRoot.scrollTop) || 0) > scrollToBottomButtonVisibilityThreshold) {
          state.scrollToBottomAnimationFrame = requestAnimationFrame(step);
          return;
        }
        finish(nextRoot);
      };

      state.scrollToBottomAnimationFrame = requestAnimationFrame(step);
      return root.scrollTop || 0;
    }

    function scrollConversationToMessage(messageID, alignment) {
      const root = scrollRoot();
      const messageElement = findMessageElement(messageID);
      if (!root || !messageElement) {
        postTranscriptProbe("scroll", "message_missing", {
          reason: "scroll_to_message",
          messageID: trimmed(messageID),
          alignment: trimmed(alignment),
          hasRoot: Boolean(root),
          hasMessageElement: Boolean(messageElement)
        });
        return null;
      }

      cancelScrollToBottomAnimation();
      const rootRect = root.getBoundingClientRect();
      const messageRect = messageElement.getBoundingClientRect();
      const currentOffset = root.scrollTop || 0;
      const messageTop = currentOffset + (messageRect.top - rootRect.top);
      const messageCenter = messageTop + messageRect.height / 2;

      let targetOffset = messageTop;
      switch (alignment) {
        case "center":
          targetOffset = messageCenter - root.clientHeight / 2;
          break;
        case "bottom":
          targetOffset = messageTop + messageRect.height - root.clientHeight;
          break;
        default:
          targetOffset = messageTop;
          break;
      }

      const maximumOffset = Math.max(root.scrollHeight - root.clientHeight, 0);
      postTranscriptProbe("scroll", "message_begin", {
        reason: "scroll_to_message",
        messageID: trimmed(messageID),
        alignment: trimmed(alignment),
        targetOffset,
        maximumOffset,
        messageTop,
        messageCenter,
        messageHeight: Number(messageRect.height) || 0,
        ...transcriptScrollSnapshot(root)
      });
      root.scrollTop = Math.max(0, Math.min(targetOffset, maximumOffset));
      postTranscriptProbe("scroll", "message_complete", {
        reason: "scroll_to_message",
        messageID: trimmed(messageID),
        alignment: trimmed(alignment),
        targetOffset,
        maximumOffset,
        ...transcriptScrollSnapshot(root)
      });
      postScrollState("scroll_to_message", { force: true });
      return root.scrollTop || 0;
    }

    return Object.freeze({
      noteUserScrollGesture,
      requestDisplayWindowExpansionIfNeeded,
      handleConversationScroll,
      scheduleDeferredLiveRenderFlush,
      postScrollState,
      normalizedRenderOptions,
      performConversationMutationPreservingScroll,
      rerenderConversationPreservingScroll,
      scrollConversationToTop,
      scrollConversationToBottom,
      scrollConversationToMessage
    });
  };
})();
