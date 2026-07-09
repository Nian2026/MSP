(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript overlay controller dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript overlay controller dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptOverlayControllerFactory = function createChatTranscriptOverlayController(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const postPresentationProbe = requiredFunction(dependencies, "postPresentationProbe");
    const transcriptUIState = requiredFunction(dependencies, "transcriptUIState");
    const displayTitleForReference = requiredFunction(dependencies, "displayTitleForReference");
    const hostnameForReference = requiredFunction(dependencies, "hostnameForReference");
    const populateReferenceAvatar = requiredFunction(dependencies, "populateReferenceAvatar");
    const renderableMessageBlocks = requiredFunction(dependencies, "renderableMessageBlocks");
    const messageBlockKey = requiredFunction(dependencies, "messageBlockKey");
    const messageDOMKey = requiredFunction(dependencies, "messageDOMKey");
    const messageIsStreaming = requiredFunction(dependencies, "messageIsStreaming");
    const findMessageElement = requiredFunction(dependencies, "findMessageElement");
    const noteUserScrollGesture = requiredFunction(dependencies, "noteUserScrollGesture");
    const handleConversationScroll = requiredFunction(dependencies, "handleConversationScroll");
    const rerenderConversationPreservingScroll = requiredFunction(dependencies, "rerenderConversationPreservingScroll");
    const transcriptScrollSnapshot = requiredFunction(dependencies, "transcriptScrollSnapshot");
    const scrollRoot = requiredFunction(dependencies, "scrollRoot");
    const payloadModel = requiredObject(dependencies, "payloadModel");
    const orderedMessages = requiredFunction(payloadModel, "orderedMessages");
    let pendingNativeOverlayScrollProbeFrame = 0;
    let pendingScrollPerfProbeFrame = 0;
    let pendingScrollPerfProbe = null;
    let lastScrollPerfPostAt = 0;
    let lastScrollPerfGestureAt = 0;
    let lastScrollPerfMutationSnapshot = null;

    function lockRootHorizontalScroll() {
      const root = scrollRoot();
      if (root && Number(root.scrollLeft) !== 0) {
        root.scrollLeft = 0;
      }
      if (Number(window.scrollX) !== 0) {
        window.scrollTo(0, window.scrollY || Number(root?.scrollTop) || 0);
      }
    }

    function hasStreamingMessage() {
      return orderedMessages().some((message) => messageIsStreaming(message));
    }

    function scheduleNativeOverlayScrollProbe() {
      if (!hasStreamingMessage()) {
        return;
      }
      if (pendingNativeOverlayScrollProbeFrame) {
        return;
      }

      pendingNativeOverlayScrollProbeFrame = window.requestAnimationFrame(() => {
        pendingNativeOverlayScrollProbeFrame = 0;
        if (!hasStreamingMessage()) {
          return;
        }
        postPresentationProbe({
          kind: "native_overlay",
          event: "scroll",
          source: "window_scroll",
          scrollTop: window.scrollY || window.pageYOffset || 0,
          clientHeight: window.innerHeight || document.documentElement?.clientHeight || 0,
          scrollHeight: document.documentElement?.scrollHeight || document.body?.scrollHeight || 0
        });
      });
    }

    function scrollPerfNow() {
      const performanceNow = Number(window.performance?.now?.());
      if (Number.isFinite(performanceNow)) {
        return performanceNow;
      }
      return Date.now();
    }

    function scrollPerfProbeEnabled() {
      return window.__chatTranscriptScrollPerfProbeEnabled === true;
    }

    function noteScrollPerfGesture() {
      if (!scrollPerfProbeEnabled()) {
        return;
      }
      lastScrollPerfGestureAt = scrollPerfNow();
      const snapshot = window.__chatTranscriptRenderPerfProbeSnapshot;
      lastScrollPerfMutationSnapshot = typeof snapshot === "function" ? snapshot() : null;
    }

    function scheduleScrollPerfProbe(source, handlerStartedAt, handlerElapsedMs) {
      if (!scrollPerfProbeEnabled()) {
        return;
      }

      const root = scrollRoot();
      const scrollSnapshot = transcriptScrollSnapshot(root);
      const eventSource = trimmed(source) || "scroll";
      if (!pendingScrollPerfProbe) {
        pendingScrollPerfProbe = {
          firstAt: handlerStartedAt,
          source: eventSource,
          eventCount: 0,
          handlerMaxMs: 0,
          handlerLastMs: 0,
          lastGestureAt: lastScrollPerfGestureAt,
          scrollSnapshot
        };
      }

      pendingScrollPerfProbe.eventCount += 1;
      pendingScrollPerfProbe.handlerLastMs = handlerElapsedMs;
      pendingScrollPerfProbe.handlerMaxMs = Math.max(
        pendingScrollPerfProbe.handlerMaxMs,
        handlerElapsedMs
      );
      pendingScrollPerfProbe.source = eventSource;
      pendingScrollPerfProbe.lastGestureAt = lastScrollPerfGestureAt;
      pendingScrollPerfProbe.scrollSnapshot = scrollSnapshot;

      if (pendingScrollPerfProbeFrame) {
        return;
      }

      pendingScrollPerfProbeFrame = window.requestAnimationFrame((timestamp) => {
        const pending = pendingScrollPerfProbe;
        pendingScrollPerfProbeFrame = 0;
        pendingScrollPerfProbe = null;
        if (!pending) {
          return;
        }

        const postedAt = scrollPerfNow();
        const frameDelayMs = Math.max(Number(timestamp) - pending.firstAt, 0);
        const wallDelayMs = Math.max(postedAt - pending.firstAt, 0);
        const sinceGestureMs = pending.lastGestureAt > 0
          ? Math.max(pending.firstAt - pending.lastGestureAt, 0)
          : -1;
        const shouldPost = pending.handlerMaxMs >= 4 ||
          frameDelayMs >= 20 ||
          postedAt - lastScrollPerfPostAt >= 500;
        if (!shouldPost) {
          return;
        }

        lastScrollPerfPostAt = postedAt;
        const mutationDelta = typeof window.__chatTranscriptRenderPerfProbeDelta === "function"
          ? window.__chatTranscriptRenderPerfProbeDelta(lastScrollPerfMutationSnapshot)
          : null;
        lastScrollPerfMutationSnapshot = mutationDelta?.after || null;
        postPresentationProbe({
          kind: "scroll_perf",
          event: "frame",
          source: pending.source,
          eventCount: pending.eventCount,
          handlerMaxMs: pending.handlerMaxMs,
          handlerLastMs: pending.handlerLastMs,
          frameDelayMs,
          wallDelayMs,
          sinceGestureMs,
          documentAfter: mutationDelta?.after || null,
          mutationDelta: mutationDelta?.delta || null,
          ...pending.scrollSnapshot
        });
      });
    }

    function escapeAttributeValue(value) {
      const text = String(value || "");
      if (!text) {
        return "";
      }
      if (typeof window.CSS?.escape === "function") {
        return window.CSS.escape(text);
      }
      return text.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    }

    function describeRect(rect) {
      if (!rect || rect.width <= 0 || rect.height <= 0) {
        return null;
      }
      return {
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height
      };
    }

    function fallbackRectForTitleRect(titleRect) {
      if (!titleRect || titleRect.width <= 0 || titleRect.height <= 0) {
        return null;
      }
      return {
        x: titleRect.right + 8,
        y: titleRect.top + ((titleRect.height - 14) / 2),
        width: 14,
        height: 14
      };
    }

    function nativeStreamingCandidateForElement(element, domIndex) {
      if (!(element instanceof HTMLElement)) {
        return null;
      }

      const title = element.querySelector(".message-role-row > .message-role");
      const indicator = element.querySelector(".message-role-row > .streaming-indicator");
      const titleRect = title instanceof HTMLElement ? title.getBoundingClientRect() : null;
      const indicatorRect = indicator instanceof HTMLElement ? indicator.getBoundingClientRect() : null;
      const resolvedTitleRect = describeRect(titleRect);
      const resolvedIndicatorRect = describeRect(indicatorRect);
      const fallbackRect = fallbackRectForTitleRect(titleRect);

      return {
        domIndex,
        messageId: element.dataset.messageId || "",
        messageKey: element.dataset.messageKey || "",
        role: element.dataset.messageRole || "",
        status: element.dataset.messageStatus || "",
        title: title ? (title.textContent || "") : "",
        titleRect: resolvedTitleRect,
        indicatorRect: resolvedIndicatorRect,
        fallbackRect,
        hasIndicatorRect: Boolean(resolvedIndicatorRect),
        hasFallbackRect: Boolean(fallbackRect)
      };
    }

    function streamingMessageElement(message, index) {
      const messageID = trimmed(message?.id);
      if (messageID) {
        const messageElement = findMessageElement(messageID);
        if (messageElement) {
          return messageElement;
        }
      }

      const key = messageDOMKey(message, index);
      if (!key) {
        return null;
      }

      return document.querySelector(
        `article.message[data-message-key="${escapeAttributeValue(key)}"]`
      );
    }

    function fallbackStreamingElements() {
      const selectors = [
        'article[data-message-status="pending"]',
        'article[data-message-status="processing"]',
        'article[data-message-status="streaming"]',
        'article[data-message-status="searching"]',
        'article[data-message-id="__chat-streaming-message__"]'
      ];
      return Array.from(document.querySelectorAll(selectors.join(",")));
    }

    function nativeStreamingCandidates() {
      const candidates = [];
      const seenKeys = new Set();
      const messages = orderedMessages();

      for (let index = messages.length - 1; index >= 0; index -= 1) {
        const message = messages[index];
        if (!messageIsStreaming(message)) {
          continue;
        }

        const element = streamingMessageElement(message, index);
        if (!(element instanceof HTMLElement)) {
          continue;
        }

        const key = trimmed(element.dataset.messageKey) || trimmed(element.dataset.messageId) || `dom_${candidates.length}`;
        if (seenKeys.has(key)) {
          continue;
        }
        seenKeys.add(key);

        const candidate = nativeStreamingCandidateForElement(element, candidates.length);
        if (candidate) {
          candidates.push(candidate);
        }
      }

      if (candidates.length) {
        return candidates;
      }

      return fallbackStreamingElements()
        .map((element, index) => nativeStreamingCandidateForElement(element, index))
        .filter(Boolean);
    }

    function resolveNativeStreamingIndicatorGeometry() {
      const candidates = nativeStreamingCandidates();
      const selected = [...candidates].reverse().find((candidate) => candidate.hasIndicatorRect || candidate.hasFallbackRect) || null;
      const selectedRect = selected?.indicatorRect || selected?.fallbackRect || null;

      return {
        candidateCount: candidates.length,
        candidates: candidates.slice(-6),
        selected,
        selectedRect,
        x: Number(selectedRect?.x) || 0,
        y: Number(selectedRect?.y) || 0,
        width: Number(selectedRect?.width) || 0,
        height: Number(selectedRect?.height) || 0,
        scrollSnapshot: transcriptScrollSnapshot(scrollRoot())
      };
    }

    function citationPreviewStateKey(message, blockKey) {
      return `${trimmed(message?.id) || trimmed(message?.patchKey) || "__message"}::${trimmed(blockKey)}`;
    }

    function citationPreviewReferenceSnippet(reference) {
      const normalized = String(reference?.content || "")
        .replace(/\r/g, " ")
        .replace(/\n/g, " ")
        .replace(/\t/g, " ")
        .trim();
      if (!normalized) {
        return displayTitleForReference(reference);
      }
      return normalized.length > 220 ? `${normalized.slice(0, 220)}…` : normalized;
    }

    function citationPreviewDataForStateKey(stateKey) {
      const normalizedStateKey = trimmed(stateKey);
      if (!normalizedStateKey) {
        return null;
      }

      const messages = orderedMessages();
      for (let messageIndex = 0; messageIndex < messages.length; messageIndex += 1) {
        const message = messages[messageIndex];
        const blocks = renderableMessageBlocks(message);
        for (let blockIndex = 0; blockIndex < blocks.length; blockIndex += 1) {
          const block = blocks[blockIndex];
          if (!block || (block.type !== "citation" && block.type !== "search_results")) {
            continue;
          }
          const blockKey = messageBlockKey(block, blockIndex);
          if (citationPreviewStateKey(message, blockKey) !== normalizedStateKey) {
            continue;
          }
          return {
            key: normalizedStateKey,
            message,
            block,
            blockKey,
            references: Array.isArray(block.searchReferences) ? block.searchReferences : []
          };
        }
      }

      return null;
    }

    function syncCitationPreviewChipStates() {
      const activeKey = trimmed(transcriptUIState().activeCitationPreviewBlockKey);
      Array.from(document.querySelectorAll(".reference-chip[data-citation-preview-key]")).forEach((element) => {
        if (!(element instanceof HTMLElement)) {
          return;
        }
        const isActive = trimmed(element.dataset.citationPreviewKey) === activeKey && !!activeKey;
        element.classList.toggle("is-active", isActive);
        element.setAttribute("aria-pressed", isActive ? "true" : "false");
      });
    }

    function renderCitationPreviewModal(data) {
      const modal = document.createElement("div");
      modal.className = "citation-preview-modal";

      const panel = document.createElement("div");
      panel.className = "citation-preview-panel";
      panel.setAttribute("role", "dialog");
      panel.setAttribute("aria-modal", "true");
      panel.setAttribute("aria-labelledby", "citation-preview-title");

      const header = document.createElement("div");
      header.className = "citation-preview-header";

      const heading = document.createElement("div");
      heading.className = "citation-preview-heading";

      const title = document.createElement("div");
      title.className = "citation-preview-title";
      title.id = "citation-preview-title";
      title.textContent = "引用内容";
      heading.appendChild(title);

      const subtitle = document.createElement("div");
      subtitle.className = "citation-preview-subtitle";
      subtitle.textContent = `${data.references.length} 个搜索结果`;
      heading.appendChild(subtitle);

      header.appendChild(heading);

      const closeButton = document.createElement("button");
      closeButton.type = "button";
      closeButton.className = "citation-preview-close";
      closeButton.setAttribute("aria-label", "关闭引用内容预览");
      closeButton.innerHTML = '<span aria-hidden="true">×</span>';
      closeButton.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        closeCitationPreview();
      });
      header.appendChild(closeButton);

      panel.appendChild(header);

      const body = document.createElement("div");
      body.className = "citation-preview-body";

      data.references.forEach((reference, index) => {
        const item = document.createElement("div");
        item.className = "citation-preview-item";

        const leading = document.createElement("div");
        leading.className = "citation-preview-leading";

        const avatar = document.createElement("span");
        avatar.className = "citation-preview-avatar";
        populateReferenceAvatar(avatar, reference);
        leading.appendChild(avatar);
        item.appendChild(leading);

        const content = document.createElement("div");
        content.className = "citation-preview-content";

        const link = document.createElement("a");
        link.className = "citation-preview-link";
        link.href = trimmed(reference?.url) || "#";
        link.textContent = displayTitleForReference(reference) || trimmed(reference?.url) || `引用 ${index + 1}`;
        if (!trimmed(reference?.url)) {
          link.removeAttribute("href");
        }
        content.appendChild(link);

        const host = hostnameForReference(reference);
        if (host) {
          const hostLabel = document.createElement("div");
          hostLabel.className = "citation-preview-host";
          hostLabel.textContent = host;
          content.appendChild(hostLabel);
        }

        const snippet = document.createElement("div");
        snippet.className = "citation-preview-snippet";
        snippet.textContent = citationPreviewReferenceSnippet(reference);
        content.appendChild(snippet);

        item.appendChild(content);

        const badge = document.createElement("div");
        badge.className = "citation-preview-index";
        badge.textContent = String(index + 1);
        item.appendChild(badge);

        body.appendChild(item);
      });

      panel.appendChild(body);
      modal.appendChild(panel);

      modal.addEventListener("click", (event) => {
        if (event.target !== modal) {
          return;
        }
        closeCitationPreview();
      });

      return modal;
    }

    function syncCitationPreviewModal() {
      const state = transcriptUIState();
      const activeKey = trimmed(state.activeCitationPreviewBlockKey);
      const existingModal = document.querySelector(".citation-preview-modal");
      if (!activeKey) {
        if (existingModal) {
          existingModal.remove();
        }
        return;
      }

      const data = citationPreviewDataForStateKey(activeKey);
      if (!data || !data.references.length) {
        state.activeCitationPreviewBlockKey = null;
        syncCitationPreviewChipStates();
        if (existingModal) {
          existingModal.remove();
        }
        return;
      }

      const nextModal = renderCitationPreviewModal(data);
      if (existingModal && existingModal.parentElement === document.body) {
        existingModal.replaceWith(nextModal);
      } else {
        if (existingModal) {
          existingModal.remove();
        }
        document.body.appendChild(nextModal);
      }
    }

    function closeCitationPreview() {
      const state = transcriptUIState();
      state.activeCitationPreviewBlockKey = null;
      syncCitationPreviewChipStates();
      syncCitationPreviewModal();
    }

    function toggleCitationPreview(stateKey) {
      const state = transcriptUIState();
      const normalizedStateKey = trimmed(stateKey);
      state.activeCitationPreviewBlockKey =
        trimmed(state.activeCitationPreviewBlockKey) === normalizedStateKey
          ? null
          : normalizedStateKey;
      syncCitationPreviewChipStates();
      syncCitationPreviewModal();
    }

    function installGlobalTranscriptHandlers() {
      if (window.__chatTranscriptGlobalHandlersInstalled) {
        return;
      }
      window.__chatTranscriptGlobalHandlersInstalled = true;

      document.addEventListener("mousedown", (event) => {
        const state = transcriptUIState();
        if (!state.activeModelPickerMessageId) {
          return;
        }
        const target = event.target;
        if (!(target instanceof Element)) {
          return;
        }
        if (target.closest(".assistant-model-picker") || target.closest('[aria-label="切换模型回答"]')) {
          return;
        }
        state.activeModelPickerMessageId = null;
        rerenderConversationPreservingScroll();
      });

      document.addEventListener("keydown", (event) => {
        if (event.key !== "Escape") {
          return;
        }

        const state = transcriptUIState();
        if (state.activeCitationPreviewBlockKey) {
          event.preventDefault();
          event.stopPropagation();
          closeCitationPreview();
          return;
        }

        if (state.activeModelPickerMessageId) {
          event.preventDefault();
          event.stopPropagation();
          state.activeModelPickerMessageId = null;
          rerenderConversationPreservingScroll();
        }
      });

      window.addEventListener("wheel", () => {
        noteUserScrollGesture();
        handleConversationScroll("wheel");
        noteScrollPerfGesture();
      }, { passive: true });

      window.addEventListener("scroll", () => {
        const shouldRecordScrollPerf = scrollPerfProbeEnabled();
        const handlerStartedAt = shouldRecordScrollPerf ? scrollPerfNow() : 0;
        lockRootHorizontalScroll();
        handleConversationScroll("window_scroll");
        scheduleNativeOverlayScrollProbe();
        if (shouldRecordScrollPerf) {
          scheduleScrollPerfProbe(
            "window_scroll",
            handlerStartedAt,
            scrollPerfNow() - handlerStartedAt
          );
        }
      }, { passive: true });
    }

    return Object.freeze({
      resolveNativeStreamingIndicatorGeometry,
      citationPreviewStateKey,
      syncCitationPreviewChipStates,
      syncCitationPreviewModal,
      closeCitationPreview,
      toggleCitationPreview,
      installGlobalTranscriptHandlers
    });
  };
})();
