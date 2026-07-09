(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript message UI renderer dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript message UI renderer dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptMessageUIRendererFactory = function createChatTranscriptMessageUIRenderer(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const makeIcon = requiredFunction(dependencies, "makeIcon");
    const readexAccentColor = requiredFunction(dependencies, "readexAccentColor");
    const messageIsStreaming = requiredFunction(dependencies, "messageIsStreaming");
    const renderableMessageBlocks = requiredFunction(dependencies, "renderableMessageBlocks");
    const blockText = requiredFunction(dependencies, "blockText");
    const messagePrimaryTextContent = requiredFunction(dependencies, "messagePrimaryTextContent");
    const transcriptPresentation = requiredFunction(dependencies, "transcriptPresentation");
    const transcriptUIState = requiredFunction(dependencies, "transcriptUIState");
    const isInteractiveTranscript = requiredFunction(dependencies, "isInteractiveTranscript");
    const hasMessageActionHandler = requiredFunction(dependencies, "hasMessageActionHandler");
    const postMessageAction = requiredFunction(dependencies, "postMessageAction");
    const postPresentationProbe = requiredFunction(dependencies, "postPresentationProbe");
    const postLayoutLabComponentSelection = requiredFunction(dependencies, "postLayoutLabComponentSelection");
    const rerenderConversationPreservingScroll = requiredFunction(dependencies, "rerenderConversationPreservingScroll");
    const keepToolbarVisible = requiredFunction(dependencies, "keepToolbarVisible");
    const clearToolbarTimers = requiredFunction(dependencies, "clearToolbarTimers");
    const hideActiveTooltip = requiredFunction(dependencies, "hideActiveTooltip");
    const clearTooltipTimeout = requiredFunction(dependencies, "clearTooltipTimeout");
    const setCopiedMessage = requiredFunction(dependencies, "setCopiedMessage");
    const isMessageCopied = requiredFunction(dependencies, "isMessageCopied");
    let pendingReadexReferenceActivation = null;
    let lastReadexReferenceActivation = { key: "", at: 0 };
    const codexShimmerSweepMilliseconds = 1000;
    const codexShimmerIntervalMilliseconds = 4000;
    const codexShimmerInitialDelayMilliseconds = 600;
    const readexAssistantFooterActionProbeEvents = Object.freeze({
      mouseenter: { event: "mouseenter" },
      mouseleave: { event: "mouseleave" },
      buttonPatch: { event: "button_patch" }
    });

    function currentDraft(message) {
      const messageID = trimmed(message?.id);
      if (!messageID) {
        return messagePrimaryTextContent(message);
      }

      const draft = transcriptUIState().editDraftByMessageId[messageID];
      if (typeof draft === "string") {
        return draft;
      }
      return messagePrimaryTextContent(message);
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

    function editorFocusProbePayload(messageID, textarea) {
      const rect = textarea instanceof HTMLTextAreaElement
        ? textarea.getBoundingClientRect()
        : null;
      return {
        messageID: trimmed(messageID),
        editingMessageId: trimmed(transcriptUIState().editingMessageId),
        documentHasFocus: typeof document.hasFocus === "function" ? document.hasFocus() : false,
        textareaFound: textarea instanceof HTMLTextAreaElement,
        textareaConnected: textarea instanceof HTMLTextAreaElement ? textarea.isConnected : false,
        textareaDisabled: textarea instanceof HTMLTextAreaElement ? Boolean(textarea.disabled) : false,
        textareaReadOnly: textarea instanceof HTMLTextAreaElement ? Boolean(textarea.readOnly) : false,
        textareaFocused: textarea instanceof HTMLTextAreaElement ? document.activeElement === textarea : false,
        textareaValueLength: textarea instanceof HTMLTextAreaElement ? textarea.value.length : -1,
        selectionStart: textarea instanceof HTMLTextAreaElement && typeof textarea.selectionStart === "number" ? textarea.selectionStart : -1,
        selectionEnd: textarea instanceof HTMLTextAreaElement && typeof textarea.selectionEnd === "number" ? textarea.selectionEnd : -1,
        textareaWidth: rect ? rect.width : 0,
        textareaHeight: rect ? rect.height : 0,
        ...activeElementProbePayload()
      };
    }

    function probeNumber(value) {
      return typeof value === "number" && Number.isFinite(value)
        ? Math.round(value * 100) / 100
        : 0;
    }

    function elementRectProbePayload(element) {
      if (!(element instanceof HTMLElement)) {
        return null;
      }
      const rect = element.getBoundingClientRect();
      return {
        left: probeNumber(rect.left),
        top: probeNumber(rect.top),
        right: probeNumber(rect.right),
        bottom: probeNumber(rect.bottom),
        width: probeNumber(rect.width),
        height: probeNumber(rect.height)
      };
    }

    function elementMatchesHover(element) {
      if (!(element instanceof HTMLElement) || typeof element.matches !== "function") {
        return false;
      }
      try {
        return element.matches(":hover");
      } catch {
        return false;
      }
    }

    function readexAssistantFooterHoveredAction() {
      const hovered = document.querySelector(".readex-assistant-footer-actions .message-action-button:hover");
      return hovered instanceof HTMLElement ? trimmed(hovered.dataset.action) : "";
    }

    function readexAssistantFooterActiveAction() {
      const activeElement = document.activeElement;
      const activeButton = activeElement instanceof HTMLElement
        ? activeElement.closest(".readex-assistant-footer-actions .message-action-button")
        : null;
      return activeButton instanceof HTMLElement ? trimmed(activeButton.dataset.action) : "";
    }

    function readexAssistantFooterActionFromElement(element) {
      const actionButton = element instanceof HTMLElement
        ? element.closest(".readex-assistant-footer-actions .message-action-button")
        : null;
      return actionButton instanceof HTMLElement ? trimmed(actionButton.dataset.action) : "";
    }

    function readexAssistantFooterTagFromElement(element) {
      return element instanceof HTMLElement ? trimmed(element.tagName).toLowerCase() : "";
    }

    function readexAssistantFooterProbeDocumentID() {
      const root = document.documentElement;
      const existingID = trimmed(root?.dataset?.chatTranscriptProbeDocumentId);
      if (existingID) {
        return existingID;
      }
      const nextID = `doc-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
      if (root?.dataset) {
        root.dataset.chatTranscriptProbeDocumentId = nextID;
      }
      return nextID;
    }

    function readexAssistantFooterClosestGroup(element) {
      return element instanceof HTMLElement ? element.closest(".message-group") : null;
    }

    function readexAssistantFooterClosestArticle(element) {
      return element instanceof HTMLElement ? element.closest("article.message") : null;
    }

    function readexAssistantFooterDOMIndex(element) {
      if (!(element instanceof HTMLElement) || !element.parentElement) {
        return -1;
      }
      return Array.from(element.parentElement.children || []).indexOf(element);
    }

    function readexAssistantFooterElementLabel(element) {
      if (!(element instanceof HTMLElement)) {
        return "";
      }
      const tag = trimmed(element.tagName).toLowerCase();
      const classes = Array.from(element.classList || []).slice(0, 4).join(".");
      const action = trimmed(element.dataset?.action);
      const messageID = trimmed(element.dataset?.messageId);
      const messageKey = trimmed(element.dataset?.messageKey);
      const groupKey = trimmed(element.dataset?.groupKey);
      const attrs = [
        action ? `action=${action}` : "",
        messageID ? `msg=${messageID}` : "",
        messageKey ? `key=${messageKey}` : "",
        groupKey ? `group=${groupKey}` : ""
      ].filter(Boolean).join(",");
      return `${tag}${classes ? `.${classes}` : ""}${attrs ? `[${attrs}]` : ""}`;
    }

    function readexAssistantFooterAncestorChain(element) {
      const chain = [];
      let cursor = element instanceof HTMLElement ? element : null;
      while (cursor && cursor !== document.body && cursor !== document.documentElement && chain.length < 9) {
        chain.push(readexAssistantFooterElementLabel(cursor));
        if (cursor.classList?.contains("message-group")) {
          break;
        }
        cursor = cursor.parentElement;
      }
      return chain.filter(Boolean).join(" < ");
    }

    function readexAssistantFooterOwnerProbe(element) {
      const article = readexAssistantFooterClosestArticle(element);
      const group = article instanceof HTMLElement
        ? readexAssistantFooterClosestGroup(article)
        : readexAssistantFooterClosestGroup(element);
      const actionButton = element instanceof HTMLElement
        ? element.closest(".readex-assistant-footer-actions .message-action-button")
        : null;
      return {
        action: actionButton instanceof HTMLElement ? trimmed(actionButton.dataset.action) : "",
        tag: readexAssistantFooterTagFromElement(element),
        messageID: trimmed(article?.dataset?.messageId),
        messageKey: trimmed(article?.dataset?.messageKey),
        messageRole: trimmed(article?.dataset?.messageRole),
        messageStatus: trimmed(article?.dataset?.messageStatus),
        groupKey: trimmed(group?.dataset?.groupKey),
        groupRole: trimmed(group?.dataset?.groupRole),
        groupDOMIndex: readexAssistantFooterDOMIndex(group),
        articleDOMIndex: readexAssistantFooterDOMIndex(article)
      };
    }

    function readexAssistantFooterRectsMatch(left, right, epsilon = 0.75) {
      if (!left || !right) {
        return false;
      }
      return Math.abs(left.left - right.left) <= epsilon &&
        Math.abs(left.top - right.top) <= epsilon &&
        Math.abs(left.right - right.right) <= epsilon &&
        Math.abs(left.bottom - right.bottom) <= epsilon;
    }

    function readexAssistantFooterRectSummary(rect) {
      if (!rect) {
        return "";
      }
      return `${rect.left},${rect.top},${rect.right},${rect.bottom}`;
    }

    function readexAssistantFooterButtonOwnerSummary(button) {
      const owner = readexAssistantFooterOwnerProbe(button);
      return {
        action: owner.action,
        messageID: owner.messageID,
        messageKey: owner.messageKey,
        readexTurnID: trimmed(button?.__chatTranscriptActionProbeMessage?.readexTurnID),
        groupKey: owner.groupKey,
        groupDOMIndex: owner.groupDOMIndex,
        articleDOMIndex: owner.articleDOMIndex,
        rect: readexAssistantFooterRectSummary(elementRectProbePayload(button))
      };
    }

    function readexAssistantFooterSurfaceOwnerSummary(surface) {
      const owner = readexAssistantFooterOwnerProbe(surface);
      const actions = Array.from(surface?.querySelectorAll?.(".message-action-button") || [])
        .map((button) => trimmed(button.dataset.action))
        .filter(Boolean)
        .join(",");
      return {
        messageID: owner.messageID,
        messageKey: owner.messageKey,
        groupKey: owner.groupKey,
        groupDOMIndex: owner.groupDOMIndex,
        articleDOMIndex: owner.articleDOMIndex,
        actions,
        rect: readexAssistantFooterRectSummary(elementRectProbePayload(surface))
      };
    }

    function readexAssistantFooterSameRectButtons(button) {
      const targetRect = elementRectProbePayload(button);
      if (!targetRect) {
        return [];
      }
      return Array.from(document.querySelectorAll(".readex-assistant-footer-surface .message-action-button"))
        .filter((candidate) => readexAssistantFooterRectsMatch(
          targetRect,
          elementRectProbePayload(candidate)
        ))
        .slice(0, 12)
        .map(readexAssistantFooterButtonOwnerSummary);
    }

    function readexAssistantFooterSameRectSurfaces(surface) {
      const targetRect = elementRectProbePayload(surface);
      if (!targetRect) {
        return [];
      }
      return Array.from(document.querySelectorAll(".readex-assistant-footer-surface"))
        .filter((candidate) => readexAssistantFooterRectsMatch(
          targetRect,
          elementRectProbePayload(candidate)
        ))
        .slice(0, 12)
        .map(readexAssistantFooterSurfaceOwnerSummary);
    }

    function readexAssistantFooterSurfaceCounts() {
      const surfaces = Array.from(document.querySelectorAll(".readex-assistant-footer-surface"));
      return {
        total: surfaces.length
      };
    }

    function readexAssistantFooterActionFromPoint(clientX, clientY) {
      if (
        !Number.isFinite(clientX) ||
        !Number.isFinite(clientY) ||
        typeof document.elementFromPoint !== "function"
      ) {
        return "";
      }
      return readexAssistantFooterActionFromElement(document.elementFromPoint(clientX, clientY));
    }

    function readexAssistantFooterTagFromPoint(clientX, clientY) {
      if (
        !Number.isFinite(clientX) ||
        !Number.isFinite(clientY) ||
        typeof document.elementFromPoint !== "function"
      ) {
        return "";
      }
      return readexAssistantFooterTagFromElement(document.elementFromPoint(clientX, clientY));
    }

    function readexAssistantFooterPointerProbePayload(domEvent) {
      if (!domEvent || typeof domEvent.clientX !== "number" || typeof domEvent.clientY !== "number") {
        return {};
      }
      const pointElement = typeof document.elementFromPoint === "function"
        ? document.elementFromPoint(domEvent.clientX, domEvent.clientY)
        : null;
      return {
        clientX: probeNumber(domEvent.clientX),
        clientY: probeNumber(domEvent.clientY),
        movementX: probeNumber(domEvent.movementX),
        movementY: probeNumber(domEvent.movementY),
        relatedAction: readexAssistantFooterActionFromElement(domEvent.relatedTarget),
        relatedTag: readexAssistantFooterTagFromElement(domEvent.relatedTarget),
        relatedOwner: readexAssistantFooterOwnerProbe(domEvent.relatedTarget),
        relatedAncestry: readexAssistantFooterAncestorChain(domEvent.relatedTarget),
        pointAction: readexAssistantFooterActionFromPoint(domEvent.clientX, domEvent.clientY),
        pointTag: readexAssistantFooterTagFromPoint(domEvent.clientX, domEvent.clientY),
        pointOwner: readexAssistantFooterOwnerProbe(pointElement),
        pointAncestry: readexAssistantFooterAncestorChain(pointElement)
      };
    }

    function readexAssistantFooterActionProbeMessage(message) {
      return {
        messageID: trimmed(message?.messageID || message?.id),
        role: trimmed(message?.role),
        patchKey: trimmed(message?.patchKey),
        readexTurnID: trimmed(message?.readexTurnID || message?.readexTurnId)
      };
    }

    function postReadexAssistantFooterActionProbe(event, message, button, extra = {}) {
      const footerSurface = button instanceof HTMLElement
        ? button.closest(".readex-assistant-footer-surface")
        : null;
      const sameRectButtons = readexAssistantFooterSameRectButtons(button);
      const sameRectSurfaces = readexAssistantFooterSameRectSurfaces(footerSurface);
      postPresentationProbe({
        kind: "readex_assistant_footer_action_probe",
        event,
        source: "message_ui_renderer",
        probeDocumentID: readexAssistantFooterProbeDocumentID(),
        ...readexAssistantFooterActionProbeMessage(message),
        action: button instanceof HTMLElement ? trimmed(button.dataset.action) : "",
        buttonConnected: button instanceof HTMLElement ? button.isConnected === true : false,
        buttonHovered: elementMatchesHover(button),
        buttonFocused: button instanceof HTMLElement ? document.activeElement === button : false,
        buttonRect: elementRectProbePayload(button),
        buttonOwner: readexAssistantFooterOwnerProbe(button),
        buttonAncestry: readexAssistantFooterAncestorChain(button),
        footerConnected: footerSurface instanceof HTMLElement ? footerSurface.isConnected === true : false,
        footerRect: elementRectProbePayload(footerSurface),
        footerOwner: readexAssistantFooterOwnerProbe(footerSurface),
        footerSameRectCount: sameRectSurfaces.length,
        footerSameRectOwners: sameRectSurfaces,
        buttonSameRectCount: sameRectButtons.length,
        buttonSameRectOwners: sameRectButtons,
        footerSurfaceCounts: readexAssistantFooterSurfaceCounts(),
        hoveredAction: readexAssistantFooterHoveredAction(),
        activeAction: readexAssistantFooterActiveAction(),
        ...extra
      });
    }

    function messageHasReadexToolActivity(message) {
      const renderableBlocks = renderableMessageBlocks(message);
      if (Array.isArray(renderableBlocks) && renderableBlocks.some((block) => (
        block?.type === "readex_tool_call" ||
        block?.type === "readex_tool_activity"
      ))) {
        return true;
      }

      const blocks = Array.isArray(message?.blocks) ? message.blocks : [];
      if (blocks.some((block) => (
        block?.type === "readex_tool_call" ||
        block?.type === "readex_tool_activity"
      ))) {
        return true;
      }

      const supportBlocks = Array.isArray(message?.supportBlocks) ? message.supportBlocks : [];
      return supportBlocks.some((block) => (
        block?.kind === "readex_tool_call" ||
        block?.type === "readex_tool_call" ||
        block?.type === "readex_tool_activity"
      ));
    }

    function messageHasRenderableBody(message) {
      const blocks = renderableMessageBlocks(message);
      return Array.isArray(blocks) && blocks.length > 0;
    }

    function readexProcessingFoldGroupID(source) {
      return trimmed(source?.readexProcessingFoldGroupId || source?.readexProcessingFoldGroupID);
    }

    function messageHasFinalMainTextOutsideReadexProcessing(message) {
      const blocks = renderableMessageBlocks(message);
      if (!Array.isArray(blocks) || !blocks.length) {
        return Boolean(trimmed(message?.content));
      }
      return blocks.some((block) => (
        block?.type === "main_text" &&
        !readexProcessingFoldGroupID(block) &&
        Boolean(trimmed(blockText(block)))
      ));
    }

    function shouldShowStreamingHeaderStatus(message) {
      return messageIsStreaming(message)
        && !messageHasRenderableBody(message)
        && !messageHasReadexToolActivity(message);
    }

    function isPlaceholderStreamingTimeText(value) {
      const text = trimmed(value);
      return text === "正在思考" ||
        text === "正在思考中..." ||
        text === "生成中" ||
        text === "正在生成中";
    }

    function renderSequentialShimmerText(element, text) {
      if (!element) {
        return;
      }

      const displayText = trimmed(text) || "正在思考";
      if (element.classList.contains("readex-tool-shimmer") &&
        element.dataset.shimmerText === displayText &&
        element.querySelector(":scope > .readex-tool-shimmer-sweep")) {
        return;
      }

      stopCodexShimmerText(element);
      clearReadexShimmerPresentation(element);
      element.textContent = "";
      element.dataset.shimmerText = displayText;
      element.classList.add("readex-tool-shimmer");
      element.appendChild(document.createTextNode(displayText));

      const sweep = document.createElement("span");
      sweep.setAttribute("aria-hidden", "true");
      sweep.className = "readex-tool-shimmer-sweep";
      const highlight = document.createElement("span");
      highlight.className = "readex-tool-shimmer-highlight";
      highlight.textContent = displayText;
      sweep.appendChild(highlight);
      element.appendChild(sweep);
      startCodexShimmerText(element);
    }

    function clearReadexShimmerPresentation(element) {
      element.classList.remove("readex-tool-shimmer");
      element.classList.remove("readex-tool-shimmer-active");
      Array.from(element.classList).forEach((className) => {
        if (className.startsWith("readex-tool-shimmer-key-")) {
          element.classList.remove(className);
        }
      });
      element.style.removeProperty("--readex-tool-shimmer-cycle");
      delete element.dataset.shimmerText;
    }

    function startCodexShimmerText(element) {
      stopCodexShimmerText(element);
      const reducedMotion = typeof window.matchMedia === "function"
        && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      if (reducedMotion) {
        return;
      }

      let activeTimeout = null;
      let initialTimeout = null;
      let interval = null;
      const clearActiveTimeout = () => {
        if (activeTimeout !== null) {
          window.clearTimeout(activeTimeout);
          activeTimeout = null;
        }
      };
      const activate = () => {
        clearActiveTimeout();
        element.classList.remove("readex-tool-shimmer-active");
        void element.offsetWidth;
        element.classList.add("readex-tool-shimmer-active");
        activeTimeout = window.setTimeout(() => {
          element.classList.remove("readex-tool-shimmer-active");
          activeTimeout = null;
        }, codexShimmerSweepMilliseconds);
      };

      initialTimeout = window.setTimeout(() => {
        activate();
        interval = window.setInterval(activate, codexShimmerIntervalMilliseconds);
      }, codexShimmerInitialDelayMilliseconds);

      element.__chatTranscriptCodexShimmerCleanup = () => {
        clearActiveTimeout();
        if (initialTimeout !== null) {
          window.clearTimeout(initialTimeout);
          initialTimeout = null;
        }
        if (interval !== null) {
          window.clearInterval(interval);
          interval = null;
        }
        element.classList.remove("readex-tool-shimmer-active");
      };
    }

    function stopCodexShimmerText(element) {
      const cleanup = element?.__chatTranscriptCodexShimmerCleanup;
      if (typeof cleanup === "function") {
        cleanup();
      }
      if (element) {
        element.__chatTranscriptCodexShimmerCleanup = null;
      }
    }

    function postEditorFocusProbe(event, messageID, textarea, extra = {}) {
      postPresentationProbe({
        kind: "editor_focus",
        event,
        source: "message_ui_renderer",
        ...editorFocusProbePayload(messageID, textarea),
        ...extra
      });
    }

    function expertRoutingFailureMessage(message) {
      const explicitMessage = trimmed(message?.expertRoutingFailureMessage);
      if (explicitMessage) {
        return explicitMessage;
      }
      const modelName = trimmed(message?.expertRoutingModelName);
      if (modelName) {
        return `识别模型 ${modelName} 暂时请求失败。回答已继续使用默认提示词生成。`;
      }
      return "按需提示词识别暂时失败。回答已继续使用默认提示词生成。";
    }

    function expertRoutingFailureDetail(message) {
      return trimmed(message?.expertRoutingDetail);
    }

    function expertRoutingUnmatchedMessage(message) {
      const reason = trimmed(message?.expertRoutingReason);
      if (reason) {
        return reason;
      }
      const modelName = trimmed(message?.expertRoutingModelName);
      if (modelName) {
        return `识别模型 ${modelName} 没有找到合适的提示词预设。本次回答已继续使用默认提示词生成。`;
      }
      return "没有匹配到合适的提示词预设。本次回答已继续使用默认提示词生成。";
    }

    function expertRoutingMatchedMessage(message) {
      const reason = trimmed(message?.expertRoutingReason);
      if (reason) {
        return reason;
      }
      const domainName = trimmed(message?.expertDomainName);
      if (domainName) {
        return `识别模型判断当前消息适合使用“${domainName}”提示词预设。`;
      }
      return "识别模型判断当前消息适合使用这个提示词预设。";
    }

    function expertRoutingStatusLabel(status) {
      if (status === "matched") {
        return "已套用";
      }
      if (status === "unmatched") {
        return "未命中";
      }
      if (status === "failed") {
        return "识别失败";
      }
      if (status === "matching") {
        return "匹配中";
      }
      return "";
    }

    function expertRoutingPopoverDetail(message) {
      const status = trimmed(message?.expertRoutingStatus);
      const lines = [];
      const statusLabel = expertRoutingStatusLabel(status);
      const summary = trimmed(message?.expertRoutingSummary);
      const domainName = trimmed(message?.expertDomainName);
      const modelName = trimmed(message?.expertRoutingModelName);
      const failureDetail = expertRoutingFailureDetail(message);

      if (statusLabel) {
        lines.push(`状态：${statusLabel}`);
      }
      if (summary) {
        lines.push(`摘要：${summary}`);
      }
      if (domainName) {
        lines.push(`预设：${domainName}`);
      }
      if (modelName) {
        lines.push(`识别模型：${modelName}`);
      }
      if (typeof message?.expertRoutingConfidence === "number") {
        lines.push(`置信度：${Math.round(message.expertRoutingConfidence * 100)}%`);
      }
      if (failureDetail) {
        if (lines.length > 0) {
          lines.push("");
        }
        lines.push(failureDetail);
      }
      return lines.join("\n");
    }

    function expertRoutingPopoverTitle(message) {
      const status = trimmed(message?.expertRoutingStatus);
      if (status === "failed") {
        return "识别失败";
      }
      if (status === "unmatched") {
        return "未命中原因";
      }
      if (status === "matched") {
        return "已套用原因";
      }
      return "按需提示词";
    }

    function expertRoutingPopoverMessage(message) {
      const status = trimmed(message?.expertRoutingStatus);
      if (status === "failed") {
        return expertRoutingFailureMessage(message);
      }
      if (status === "unmatched") {
        return expertRoutingUnmatchedMessage(message);
      }
      if (status === "matched") {
        return expertRoutingMatchedMessage(message);
      }
      return trimmed(message?.expertRoutingReason);
    }

    function toggleExpertRoutingStatusPopover(message, badge) {
      if (!(badge instanceof HTMLElement)) {
        return;
      }
      const rect = badge.getBoundingClientRect();
      postMessageAction({
        action: "toggleExpertRoutingStatusPopover",
        status: trimmed(message?.expertRoutingStatus),
        title: expertRoutingPopoverTitle(message),
        message: expertRoutingPopoverMessage(message),
        detailTitle: "识别详情",
        detail: expertRoutingPopoverDetail(message),
        actionTitle: trimmed(message?.expertDomainID) ? "编辑提示词预设" : "",
        domainID: trimmed(message?.expertDomainID),
        domainName: trimmed(message?.expertDomainName),
        anchorRect: {
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height
        }
      });
    }

    function renderMessageHeader(message) {
      const header = document.createElement("div");
      header.className = "message-header";

      const roleRow = document.createElement("div");
      roleRow.className = "message-role-row";

      const title = document.createElement("span");
      title.className = "message-role";
      title.textContent = message.title || "";
      roleRow.appendChild(title);

      let streamingStatus = null;
      if (shouldShowStreamingHeaderStatus(message)) {
        streamingStatus = document.createElement("div");
        streamingStatus.className = "message-streaming-status readex-tool-shimmer";
        renderSequentialShimmerText(streamingStatus, message.timeText);
        header.classList.add("has-streaming-status");
      } else if (!messageIsStreaming(message) &&
        trimmed(message.timeText) &&
        !isPlaceholderStreamingTimeText(message.timeText)) {
        const time = document.createElement("span");
        time.className = "message-time";
        time.textContent = message.timeText;
        roleRow.appendChild(time);
      }

      if (trimmed(message.headerPageSummary)) {
        const pages = document.createElement("span");
        pages.className = "message-pages";
        pages.textContent = `页码 ${message.headerPageSummary}`;
        roleRow.appendChild(pages);
      }

      const routingSummary = trimmed(message.expertRoutingSummary)
        || (trimmed(message.expertDomainName) ? `已套用：${trimmed(message.expertDomainName)}` : "");
      if (message.role === "assistant" && routingSummary) {
        const needsNativeStreamingIndicatorClearance = messageIsStreaming(message);
        const domainID = trimmed(message.expertDomainID);
        const domainName = trimmed(message.expertDomainName);
        const routingStatus = trimmed(message.expertRoutingStatus);
        const isFailureBadge = routingStatus === "failed";
        const isUnmatchedBadge = routingStatus === "unmatched";
        const isMatchedBadge = routingStatus === "matched";
        const canOpenRoutingPopover = isFailureBadge || isUnmatchedBadge || isMatchedBadge;
        const canDismissRoutingBadge = isFailureBadge || isUnmatchedBadge;
        const dismissRoutingBadgeTitle = isFailureBadge ? "隐藏识别失败提示" : "隐藏未命中提示";
        const badgeShell = (canOpenRoutingPopover || canDismissRoutingBadge) ? document.createElement("span") : null;
        if (badgeShell) {
          badgeShell.className = "message-expert-domain-badge-shell";
          if (needsNativeStreamingIndicatorClearance) {
            badgeShell.classList.add("has-native-streaming-indicator-clearance");
          }
          if (canDismissRoutingBadge) {
            badgeShell.classList.add("has-dismiss-button");
          }
          if (routingStatus) {
            badgeShell.dataset.routingStatus = routingStatus;
          }
        }
        const domainBadge = document.createElement(domainID || canOpenRoutingPopover ? "button" : "span");
        if (domainID || canOpenRoutingPopover) {
          domainBadge.type = "button";
        }
        domainBadge.className = "message-expert-domain-badge";
        if (needsNativeStreamingIndicatorClearance && !badgeShell) {
          domainBadge.classList.add("has-native-streaming-indicator-clearance");
        }
        if (routingStatus) {
          domainBadge.dataset.routingStatus = routingStatus;
        }
        if (canOpenRoutingPopover) {
          domainBadge.setAttribute("aria-haspopup", "dialog");
          domainBadge.setAttribute("aria-expanded", "false");
        }
        domainBadge.textContent = routingSummary;
        const titleParts = [];
        if (isFailureBadge || isUnmatchedBadge) {
          titleParts.push(expertRoutingPopoverMessage(message));
          if (expertRoutingFailureDetail(message)) {
            titleParts.push("点击查看详情");
          }
        } else if (trimmed(message.expertRoutingModelName)) {
          titleParts.push(`识别模型：${trimmed(message.expertRoutingModelName)}`);
        }
        if (!isFailureBadge && !isUnmatchedBadge && trimmed(message.expertRoutingReason)) {
          titleParts.push(trimmed(message.expertRoutingReason));
        }
        if (!isFailureBadge && !isUnmatchedBadge && typeof message.expertRoutingConfidence === "number") {
          titleParts.push(`置信度：${Math.round(message.expertRoutingConfidence * 100)}%`);
        }
        if (titleParts.length === 0 && domainName) {
          titleParts.push(message.expertDomainUsesGlobalPrompt ? "已叠加当前模式系统提示词" : "仅使用预设系统提示词");
        }
        if (canOpenRoutingPopover) {
          titleParts.push(domainID ? "左键查看原因，右键编辑预设" : "点击查看原因");
        }
        domainBadge.title = titleParts.join("\n");
        if (canOpenRoutingPopover && badgeShell) {
          domainBadge.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            toggleExpertRoutingStatusPopover(message, domainBadge);
          });
        } else if (domainID) {
          domainBadge.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            postMessageAction({
              action: "openExpertDomainSettings",
              domainID,
              domainName
            });
          });
        }
        if (domainID) {
          domainBadge.addEventListener("contextmenu", (event) => {
            event.preventDefault();
            event.stopPropagation();
            postMessageAction({
              action: "openExpertDomainSettings",
              domainID,
              domainName
            });
          });
        }
        if (badgeShell) {
          badgeShell.appendChild(domainBadge);
          if (canDismissRoutingBadge) {
            const dismissButton = document.createElement("button");
            dismissButton.type = "button";
            dismissButton.className = "message-expert-domain-dismiss-button";
            dismissButton.setAttribute("aria-label", dismissRoutingBadgeTitle);
            dismissButton.title = dismissRoutingBadgeTitle;
            dismissButton.innerHTML = makeIcon("xmark") || "×";
            dismissButton.addEventListener("click", (event) => {
              event.preventDefault();
              event.stopPropagation();
              postMessageAction({
                action: "hideExpertRoutingBadge",
                messageID: trimmed(message.id),
                patchKey: trimmed(message.patchKey),
                status: routingStatus
              });
            });
            badgeShell.appendChild(dismissButton);
          }
          roleRow.appendChild(badgeShell);
        } else {
          roleRow.appendChild(domainBadge);
        }
      }

      header.appendChild(roleRow);
      if (streamingStatus) {
        header.appendChild(streamingStatus);
      }
      return header;
    }

    function headerSignature(message) {
      return JSON.stringify({
        role: message.role,
        replyToMessageID: message.replyToMessageID,
        title: message.title,
        isStreaming: messageIsStreaming(message),
        hasRenderableBody: messageHasRenderableBody(message),
        hasReadexToolActivity: messageHasReadexToolActivity(message),
        showsStreamingHeaderStatus: shouldShowStreamingHeaderStatus(message),
        timeText: message.timeText,
        headerPageSummary: message.headerPageSummary,
        expertDomainID: message.expertDomainID,
        expertDomainName: message.expertDomainName,
        expertDomainUsesGlobalPrompt: message.expertDomainUsesGlobalPrompt,
        expertRoutingStatus: message.expertRoutingStatus,
        expertRoutingSummary: message.expertRoutingSummary,
        expertRoutingReason: message.expertRoutingReason,
        expertRoutingFailureMessage: message.expertRoutingFailureMessage,
        expertRoutingDetail: message.expertRoutingDetail,
        expertRoutingConfidence: message.expertRoutingConfidence,
        expertRoutingModelName: message.expertRoutingModelName
      });
    }

    function scheduleTooltip(button, label, canShowTooltip) {
      const state = transcriptUIState();
      hideActiveTooltip();
      if (!button || !canShowTooltip()) {
        return;
      }

      state.tooltipTimeout = setTimeout(() => {
        const tooltip = button.querySelector(".message-action-tooltip");
        if (!tooltip || !canShowTooltip()) {
          return;
        }
        tooltip.textContent = label();
        button.classList.add("show-tooltip");
        state.tooltipButton = button;
        state.tooltipTimeout = null;
      }, 250);
    }

    function footerOverlayHost(element) {
      const host = element?.closest?.(".readex-assistant-footer-surface");
      return host instanceof HTMLElement ? host : null;
    }

    function positionFooterOverlayElement(button, element, center = false) {
      const host = footerOverlayHost(element);
      if (!(button instanceof HTMLElement) || !host) {
        return false;
      }
      const buttonRect = button.getBoundingClientRect();
      const hostRect = host.getBoundingClientRect();
      const x = buttonRect.left - hostRect.left;
      const y = buttonRect.top - hostRect.top;
      if (center) {
        element.style.left = `${x + buttonRect.width / 2}px`;
      } else {
        element.style.left = `${x}px`;
        element.style.top = `${y}px`;
        element.style.width = `${buttonRect.width}px`;
        element.style.height = `${buttonRect.height}px`;
      }
      return true;
    }

    function scheduleFooterOverlayTooltip(button, overlay, label, canShowTooltip) {
      const tooltip = overlay?.tooltip;
      const state = transcriptUIState();
      hideActiveTooltip();
      if (!button || !(tooltip instanceof HTMLElement) || !canShowTooltip()) {
        return;
      }

      state.tooltipTimeout = setTimeout(() => {
        if (!canShowTooltip()) {
          return;
        }
        tooltip.textContent = label();
        if (!positionFooterOverlayElement(button, tooltip, true)) {
          return;
        }
        tooltip.classList.add("show-tooltip");
        state.tooltipButton = tooltip;
        state.tooltipTimeout = null;
      }, 250);
    }

    function clearTooltip(button) {
      clearTooltipTimeout();
      if (button) {
        button.classList.remove("show-tooltip");
      }
      const state = transcriptUIState();
      if (state.tooltipButton === button) {
        state.tooltipButton = null;
      }
    }

    function clearFloatingTooltip(tooltip) {
      clearTooltipTimeout();
      if (tooltip) {
        tooltip.classList.remove("show-tooltip");
      }
      const state = transcriptUIState();
      if (state.tooltipButton === tooltip) {
        state.tooltipButton = null;
      }
    }

    function actionButtonLabel(messageID, defaultLabel) {
      return defaultLabel === "复制" && isMessageCopied(messageID) ? "已复制" : defaultLabel;
    }

    function actionButtonIcon(messageID, defaultIcon) {
      const isCopyIcon = defaultIcon === "doc.on.doc" ||
        defaultIcon === "doc-on-doc" ||
        defaultIcon === "readex.copy.c1";
      if (!isCopyIcon || !isMessageCopied(messageID)) {
        return defaultIcon;
      }
      return defaultIcon === "readex.copy.c1" ? "readex.check.c1" : "checkmark";
    }

    function messageHasRenderPatches(message) {
      return Boolean(message?.hasRenderPatches);
    }

    function messageHasEnabledRenderPatches(message) {
      return Boolean(message?.hasEnabledRenderPatches);
    }

    function renderPatchToggleTitle(message) {
      return messageHasEnabledRenderPatches(message) ? "撤回渲染补丁" : "恢复渲染补丁";
    }

    function formatAssistantFooterDuration(milliseconds) {
      const totalSeconds = Math.max(0, Math.floor((Number(milliseconds) || 0) / 1000));
      if (totalSeconds < 60) {
        return `${Math.max(1, totalSeconds)}s`;
      }
      const hours = Math.floor(totalSeconds / 3600);
      const minutes = Math.floor((totalSeconds % 3600) / 60);
      const seconds = totalSeconds % 60;
      if (hours > 0) {
        const parts = [`${hours}h`];
        if (minutes > 0) {
          parts.push(`${minutes}m`);
        }
        if (seconds > 0) {
          parts.push(`${seconds}s`);
        }
        return parts.join(" ");
      }
      if (seconds === 0) {
        return `${minutes}m`;
      }
      return `${minutes}m ${seconds}s`;
    }

    function renderCompletedGoalFooterLabel(message) {
      const durationMilliseconds = Number(message?.completedGoalDurationMilliseconds);
      if (!Number.isFinite(durationMilliseconds)) {
        return null;
      }

      const label = document.createElement("span");
      label.className = "readex-assistant-footer-goal-achieved";
      const divider = document.createElement("span");
      divider.className = "readex-assistant-footer-goal-divider";
      label.appendChild(divider);
      const icon = document.createElement("span");
      icon.className = "readex-assistant-footer-goal-icon";
      icon.setAttribute("aria-hidden", "true");
      icon.innerHTML = makeIcon("target") || "";
      label.appendChild(icon);
      const text = document.createElement("span");
      text.className = "readex-assistant-footer-goal-text";
      text.textContent = `已在 ${formatAssistantFooterDuration(durationMilliseconds)} 内达成目标`;
      label.appendChild(text);
      return label;
    }

    const legacyMessageActionPolicy = Object.freeze({
      assistantActions: Object.freeze([
        "copyMessage",
        "branchConversation",
        "regenerateAssistantMessage",
        "toggleAssistantModelPicker",
        "openRenderPatchInspection",
        "setRenderPatchesEnabled",
        "deleteAssistantMessage"
      ]),
      userActions: Object.freeze([
        "regenerateUserMessage",
        "editUserMessage",
        "branchConversation",
        "copyMessage",
        "deleteUserMessage"
      ])
    });

    function currentMessageActionPolicy() {
      const policy = transcriptPresentation()?.messageActionPolicy;
      return policy && typeof policy === "object" ? policy : legacyMessageActionPolicy;
    }

    function actionListForRole(role) {
      const policy = currentMessageActionPolicy();
      const values = role === "assistant" ? policy.assistantActions : policy.userActions;
      return Array.isArray(values) ? values.filter((value) => typeof value === "string") : [];
    }

    function assistantActionPlacement() {
      const placement = currentMessageActionPolicy()?.assistantPlacement;
      return typeof placement === "string" ? placement : "";
    }

    function usesReadexAssistantFooterActions() {
      return assistantActionPlacement() === "readexAssistantFooter";
    }

    function messageActionAllowed(role, action) {
      return actionListForRole(role).includes(action);
    }

    function messageRoleForActions(message) {
      return message?.role === "assistant" ? "assistant" : "user";
    }

    function renderAllowedMessageAction(root, message, action, options) {
      if (!messageActionAllowed(messageRoleForActions(message), action)) {
        return;
      }
      root.appendChild(renderMessageActionButton(message, {
        ...options,
        action
      }));
    }

    function canShowUserToolbar(message) {
      const presentation = transcriptPresentation();
      const state = transcriptUIState();
      return Boolean(
        isInteractiveTranscript() &&
        message &&
        message.role === "user" &&
        actionListForRole("user").length > 0 &&
        !messageIsStreaming(message) &&
        !presentation?.isConversationGenerating &&
        state.editingMessageId !== message.id
      );
    }

    function autoResizeEditor(textarea) {
      if (!(textarea instanceof HTMLTextAreaElement)) {
        return;
      }
      const maxHeight = parseFloat(window.getComputedStyle(textarea).maxHeight) || Number.POSITIVE_INFINITY;
      textarea.style.height = "auto";
      const nextHeight = Math.min(textarea.scrollHeight, maxHeight);
      textarea.style.height = `${nextHeight}px`;
      textarea.style.overflowY = textarea.scrollHeight > maxHeight ? "auto" : "hidden";
    }

    function applyMessageActionButtonState(button, message, options) {
      button.className = "message-action-button";
      button.dataset.action = trimmed(options.action);
      if (options.disabled) {
        button.classList.add("disabled");
      }
      button.setAttribute("aria-label", options.helpText);
      button.__chatTranscriptActionDisabled = Boolean(options.disabled);
      button.__chatTranscriptActionHandler = options.onClick;
      button.__chatTranscriptActionLabel = options.label;
      button.__chatTranscriptActionProbeMessage = readexAssistantFooterActionProbeMessage(message);
    }

    function messageActionButtonLabel(button) {
      const label = button?.__chatTranscriptActionLabel;
      return typeof label === "function" ? label() : "";
    }

    function renderMessageActionButton(message, options) {
      const button = document.createElement("button");
      button.type = "button";
      applyMessageActionButtonState(button, message, options);

      const inner = document.createElement("span");
      inner.className = "message-action-button-inner";
      inner.innerHTML = makeIcon(options.iconName);
      button.appendChild(inner);

      const footerOverlay = options.footerOverlay && typeof options.footerOverlay === "object"
        ? options.footerOverlay
        : null;
      if (!footerOverlay) {
        const tooltip = document.createElement("span");
        tooltip.className = "message-action-tooltip";
        tooltip.textContent = options.helpText;
        button.appendChild(tooltip);
      }

      const canShowTooltip = () => {
        if (message.role === "assistant") {
          return true;
        }
        const article = button.closest(".message");
        return Boolean(article?.classList.contains("actions-visible"));
      };

      button.addEventListener("mouseenter", (event) => {
        if (!button.__chatTranscriptActionDisabled) {
          if (!footerOverlay) {
            button.classList.add("is-highlighted");
          }
        }
        if (footerOverlay) {
          scheduleFooterOverlayTooltip(button, footerOverlay, () => messageActionButtonLabel(button), canShowTooltip);
        } else {
          scheduleTooltip(button, () => messageActionButtonLabel(button), canShowTooltip);
        }
        if (footerOverlay) {
          postReadexAssistantFooterActionProbe(
            readexAssistantFooterActionProbeEvents.mouseenter.event,
            message,
            button,
            {
              disabled: Boolean(button.__chatTranscriptActionDisabled),
              ...readexAssistantFooterPointerProbePayload(event)
            }
          );
        }
      });

      button.addEventListener("mouseleave", (event) => {
        if (footerOverlay) {
          clearFloatingTooltip(footerOverlay.tooltip);
        } else {
          button.classList.remove("is-highlighted");
        }
        if (footerOverlay) {
          postReadexAssistantFooterActionProbe(
            readexAssistantFooterActionProbeEvents.mouseleave.event,
            message,
            button,
            {
              disabled: Boolean(button.__chatTranscriptActionDisabled),
              ...readexAssistantFooterPointerProbePayload(event)
            }
          );
          return;
        }
        clearTooltip(button);
      });

      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        hideActiveTooltip();
        if (button.__chatTranscriptActionDisabled) {
          return;
        }
        const handler = button.__chatTranscriptActionHandler;
        if (typeof handler !== "function") {
          return;
        }
        handler({
          button,
          event
        });
      });

      return button;
    }

    function patchMessageActionButton(existingButton, nextButton) {
      if (!(existingButton instanceof HTMLElement) || !(nextButton instanceof HTMLElement)) {
        return false;
      }
      existingButton.replaceChildren(...Array.from(nextButton.childNodes));
      existingButton.className = nextButton.className;
      existingButton.dataset.action = nextButton.dataset.action || "";
      existingButton.setAttribute("aria-label", nextButton.getAttribute("aria-label") || "");
      existingButton.__chatTranscriptActionDisabled = Boolean(nextButton.__chatTranscriptActionDisabled);
      existingButton.__chatTranscriptActionHandler = nextButton.__chatTranscriptActionHandler;
      existingButton.__chatTranscriptActionLabel = nextButton.__chatTranscriptActionLabel;
      existingButton.__chatTranscriptActionProbeMessage =
        nextButton.__chatTranscriptActionProbeMessage ||
        existingButton.__chatTranscriptActionProbeMessage ||
        null;
      postReadexAssistantFooterActionProbe(
        readexAssistantFooterActionProbeEvents.buttonPatch.event,
        existingButton.__chatTranscriptActionProbeMessage,
        existingButton,
        {
          nextAction: trimmed(nextButton.dataset.action),
          disabled: Boolean(existingButton.__chatTranscriptActionDisabled)
        }
      );
      return true;
    }

    function patchReadexAssistantFooterActions(existingRoot, nextRoot) {
      if (
        !existingRoot?.classList?.contains("readex-assistant-footer-surface") ||
        !nextRoot?.classList?.contains("readex-assistant-footer-surface")
      ) {
        return false;
      }

      const existingControls = existingRoot.querySelector(".readex-assistant-footer-controls");
      const nextControls = nextRoot.querySelector(".readex-assistant-footer-controls");
      if (!(existingControls instanceof HTMLElement) || !(nextControls instanceof HTMLElement)) {
        return false;
      }

      existingRoot.className = nextRoot.className;
      existingControls.className = nextControls.className;
      const existingButtonsByAction = new Map(
        Array.from(existingControls.children || [])
          .filter((child) => child?.classList?.contains("message-action-button"))
          .map((button) => [button.dataset.action || "", button])
          .filter(([action]) => Boolean(action))
      );
      const nextChildren = Array.from(nextControls.children || []);
      const wantedChildren = new Set();

      let cursor = existingControls.firstChild;
      nextChildren.forEach((nextChild) => {
        let child = nextChild;
        const nextButton = nextChild?.classList?.contains("message-action-button")
          ? nextChild
          : null;
        if (nextButton) {
          const action = nextChild.dataset.action || "";
          const existingButton = existingButtonsByAction.get(action);
          if (existingButton) {
            patchMessageActionButton(existingButton, nextChild);
            existingButtonsByAction.delete(action);
            child = existingButton;
          }
        }

        if (child !== cursor) {
          if (cursor) {
            existingControls.insertBefore(child, cursor);
          } else if (nextButton) {
            existingControls.appendChild(nextButton);
          } else {
            existingControls.appendChild(child);
          }
        } else {
          cursor = child.nextSibling;
        }
        wantedChildren.add(child);
        if (child !== cursor) {
          cursor = child.nextSibling;
        }
      });
      Array.from(existingControls.children || []).forEach((child) => {
        if (!wantedChildren.has(child)) {
          child.remove();
        }
      });

      const existingActionsRow = existingRoot.querySelector(".readex-assistant-footer-actions");
      const nextActionsRow = nextRoot.querySelector(".readex-assistant-footer-actions");
      if (existingActionsRow instanceof HTMLElement && nextActionsRow instanceof HTMLElement) {
        existingActionsRow.className = nextActionsRow.className;
      }

      const existingTime = existingRoot.querySelector(".readex-assistant-footer-time");
      const nextTime = nextRoot.querySelector(".readex-assistant-footer-time");
      if (existingTime instanceof HTMLElement && nextTime instanceof HTMLElement) {
        existingTime.textContent = nextTime.textContent || "";
      } else if (existingTime instanceof HTMLElement && !nextTime) {
        existingTime.remove();
      } else if (!existingTime && nextTime instanceof HTMLElement) {
        const existingActionsRow = existingRoot.querySelector(".readex-assistant-footer-actions");
        if (existingActionsRow instanceof HTMLElement) {
          existingActionsRow.appendChild(nextTime);
        }
      }

      return true;
    }

    function syncAssistantModelPickerModal() {
      const existingModal = document.querySelector(".assistant-model-picker-modal");
      if (existingModal instanceof HTMLElement) {
        existingModal.remove();
      }

      const state = transcriptUIState();
      if (state.activeModelPickerMessageId) {
        state.activeModelPickerMessageId = null;
      }
    }

    function renderAssistantActionControls(actionsRoot, message, options = {}) {
      const presentation = transcriptPresentation();
      const usesFooter = options?.usesFooter === true;
      const footerOverlayOptions = options?.footerOverlayOptions || {};
      const hasCompletedGoal = Number.isFinite(Number(message?.completedGoalDurationMilliseconds));
      if (usesFooter && hasCompletedGoal) {
        actionsRoot.classList.add("has-completed-goal");
      }

      const copyIconName = usesFooter ? "readex.copy.c1" : "doc.on.doc";
      renderAllowedMessageAction(actionsRoot, message, "copyMessage", {
        ...footerOverlayOptions,
        iconName: actionButtonIcon(message.id, copyIconName),
        helpText: "复制",
        label: () => actionButtonLabel(message.id, "复制"),
        disabled: false,
        onClick: () => {
          postMessageAction({ action: "copyMessage", messageID: message.id, text: messagePrimaryTextContent(message) });
          setCopiedMessage(message.id);
        }
      });

      renderAllowedMessageAction(actionsRoot, message, "branchConversation", {
        ...footerOverlayOptions,
        iconName: usesFooter ? "readex.fork.c1" : "arrow.triangle.branch",
        helpText: usesFooter ? "分叉" : "在新聊天中创建分支对话",
        label: () => usesFooter ? "分叉" : "创建分支",
        disabled: usesFooter ? false : Boolean(presentation?.isConversationGenerating),
        onClick: () => {
          const readexTurnID = trimmed(message.readexTurnID || message.readexTurnId);
          const targetTurnID = usesFooter ? "" : trimmed(message.readexCodexTurnID || message.readexCodexTurnId);
          const payload = usesFooter
            ? { action: "branchConversation", messageID: message.id, readexBranchAction: true }
            : { action: "branchConversation", messageID: message.id };
          if (readexTurnID) {
            payload.readexTurnID = readexTurnID;
          }
          if (!usesFooter && targetTurnID) {
            payload.targetTurnID = targetTurnID;
          }
          postMessageAction(payload);
        }
      });

      if (usesFooter) {
        const completedGoal = renderCompletedGoalFooterLabel(message);
        if (completedGoal) {
          actionsRoot.appendChild(completedGoal);
        }
      }

      renderAllowedMessageAction(actionsRoot, message, "regenerateAssistantMessage", {
        ...footerOverlayOptions,
        iconName: "arrow.clockwise",
        helpText: "重新生成",
        label: () => "重新生成",
        disabled: Boolean(presentation?.isConversationGenerating),
        onClick: () => {
          postMessageAction({ action: "regenerateAssistantMessage", messageID: message.id });
        }
      });

      renderAllowedMessageAction(actionsRoot, message, "toggleAssistantModelPicker", {
        ...footerOverlayOptions,
        iconName: "cpu",
        helpText: "切换模型回答",
        label: () => "切换模型回答",
        disabled: Boolean(presentation?.isConversationGenerating) || !(presentation?.assistantModelOptions || []).length,
        onClick: ({ button }) => {
          if (!(button instanceof HTMLElement)) {
            return;
          }
          const rect = button.getBoundingClientRect();
          postMessageAction({
            action: "toggleAssistantModelPicker",
            messageID: message.id,
            currentModelName: message.title || "",
            anchorRect: {
              x: rect.left,
              y: rect.top,
              width: rect.width,
              height: rect.height
            }
          });
        }
      });

      if (messageHasRenderPatches(message)) {
        renderAllowedMessageAction(actionsRoot, message, "openRenderPatchInspection", {
          ...footerOverlayOptions,
          iconName: "doc.text.magnifyingglass",
          helpText: "查看渲染修复对比",
          label: () => "查看渲染修复对比",
          disabled: false,
          onClick: () => {
            postMessageAction({
              action: "openRenderPatchInspection",
              messageID: message.id
            });
          }
        });

        renderAllowedMessageAction(actionsRoot, message, "setRenderPatchesEnabled", {
          ...footerOverlayOptions,
          iconName: messageHasEnabledRenderPatches(message) ? "eye.slash" : "eye",
          helpText: renderPatchToggleTitle(message),
          label: () => renderPatchToggleTitle(message),
          disabled: false,
          onClick: () => {
            const currentEnabled = messageHasEnabledRenderPatches(message);
            const nextEnabled = !currentEnabled;
            postPresentationProbe({
              kind: "render_patch_toggle",
              event: "click",
              messageID: message.id || "",
              patchKey: message.patchKey || "",
              role: message.role || "",
              title: message.title || "",
              hasRenderPatches: messageHasRenderPatches(message),
              currentEnabled,
              nextEnabled
            });
            postMessageAction({
              action: "setRenderPatchesEnabled",
              messageID: message.id,
              isEnabled: nextEnabled
            });
          }
        });
      }

      renderAllowedMessageAction(actionsRoot, message, "deleteAssistantMessage", {
        ...footerOverlayOptions,
        iconName: "trash",
        helpText: "删除",
        label: () => "删除",
        disabled: Boolean(presentation?.isConversationGenerating),
        onClick: () => {
          postMessageAction({ action: "deleteAssistantMessage", messageID: message.id });
        }
      });

      return Boolean(actionsRoot.children.length);
    }

    function renderReadexAssistantFooterSurface(message, options = {}) {
      if (!isInteractiveTranscript() || !message.id || !actionListForRole("assistant").length) {
        return null;
      }

      const includeControls = options?.includeControls !== false;
      const root = document.createElement("div");
      root.className = "readex-assistant-footer-surface";

      const overlayLayer = document.createElement("div");
      overlayLayer.className = "readex-assistant-footer-overlay";
      const tooltip = document.createElement("span");
      tooltip.className = "readex-assistant-footer-tooltip";
      overlayLayer.appendChild(tooltip);
      root.appendChild(overlayLayer);

      const actionsRow = document.createElement("div");
      actionsRow.className = "readex-assistant-footer-actions";
      const actionsRoot = document.createElement("div");
      actionsRoot.className = "readex-assistant-footer-controls";
      actionsRow.appendChild(actionsRoot);
      root.appendChild(actionsRow);

      if (includeControls) {
        renderAssistantActionControls(actionsRoot, message, {
          usesFooter: true,
          footerOverlayOptions: { footerOverlay: { tooltip } }
        });
        const time = document.createElement("span");
        time.className = "readex-assistant-footer-time";
        time.textContent = trimmed(message.timeText);
        actionsRow.appendChild(time);
      }

      return root;
    }

    function renderAssistantActions(message) {
      if (!isInteractiveTranscript() || !message.id) {
        return null;
      }

      const usesFooter = usesReadexAssistantFooterActions();
      if (usesFooter) {
        const hasCompletedGoal = Number.isFinite(Number(message?.completedGoalDurationMilliseconds));
        if (!hasCompletedGoal && !messageHasFinalMainTextOutsideReadexProcessing(message)) {
          return null;
        }
        return renderReadexAssistantFooterSurface(message, {
          includeControls: !messageIsStreaming(message) || hasCompletedGoal
        });
      }

      if (messageIsStreaming(message)) {
        return null;
      }

      const root = document.createElement("div");
      root.className = "message-actions";
      return renderAssistantActionControls(root, message, { usesFooter: false })
        ? root
        : null;
    }

    function memoryCitationStateKey(message) {
      return trimmed(message?.patchKey)
        || trimmed(message?.id)
        || trimmed(message?.readexTurnID || message?.readexTurnId)
        || trimmed(message?.readexCodexTurnID || message?.readexCodexTurnId);
    }

    function memoryCitationExpansionState() {
      const state = transcriptUIState();
      if (!state.readexMemoryCitationExpandedMessageIDs || typeof state.readexMemoryCitationExpandedMessageIDs !== "object") {
        state.readexMemoryCitationExpandedMessageIDs = {};
      }
      return state.readexMemoryCitationExpandedMessageIDs;
    }

    function memoryCitationIsExpanded(message) {
      const key = memoryCitationStateKey(message);
      return Boolean(key && memoryCitationExpansionState()[key]);
    }

    function setMemoryCitationExpanded(message, isExpanded) {
      const key = memoryCitationStateKey(message);
      if (!key) {
        return;
      }
      const state = memoryCitationExpansionState();
      if (isExpanded) {
        state[key] = true;
      } else {
        delete state[key];
      }
    }

    function positiveMemoryCitationLine(value) {
      const number = Number(value);
      if (!Number.isFinite(number)) {
        return null;
      }
      const lineNumber = Math.floor(number);
      return lineNumber > 0 ? lineNumber : null;
    }

    function memoryCitationEntries(message) {
      if (message?.role !== "assistant") {
        return [];
      }
      const rawEntries = Array.isArray(message?.memoryCitation?.entries)
        ? message.memoryCitation.entries
        : [];
      return rawEntries.map((entry, index) => {
        const path = trimmed(entry?.path);
        if (!path) {
          return null;
        }
        const lineStart = positiveMemoryCitationLine(entry?.lineStart ?? entry?.line_start);
        const rawLineEnd = positiveMemoryCitationLine(entry?.lineEnd ?? entry?.line_end);
        const lineEnd = lineStart && rawLineEnd ? Math.max(lineStart, rawLineEnd) : lineStart;
        return {
          index,
          path,
          lineStart,
          lineEnd,
          note: trimmed(entry?.note)
        };
      }).filter(Boolean);
    }

    function memoryCitationDisplayPath(path) {
      const rawPath = trimmed(path);
      if (!rawPath) {
        return "MEMORY.md";
      }
      const withoutTrailingSlash = rawPath.replace(/\/+$/g, "");
      const segments = withoutTrailingSlash.split(/[\\/]/).filter(Boolean);
      return segments[segments.length - 1] || withoutTrailingSlash || rawPath;
    }

    function memoryCitationLineLabel(entry) {
      const displayPath = memoryCitationDisplayPath(entry?.path);
      const lineStart = positiveMemoryCitationLine(entry?.lineStart);
      if (!lineStart) {
        return displayPath;
      }
      const lineEnd = positiveMemoryCitationLine(entry?.lineEnd);
      const range = lineEnd && lineEnd !== lineStart
        ? `${lineStart}-${lineEnd}`
        : `${lineStart}`;
      return `${displayPath} ${range} 行`;
    }

    function memoryCitationAccent(entry) {
      return readexAccentColor([
        "memoryCitation",
        trimmed(entry?.path),
        entry?.lineStart || "",
        entry?.lineEnd || "",
        trimmed(entry?.note)
      ].join("|"));
    }

    function memoryCitationSummaryAccent(entries, message) {
      return readexAccentColor([
        "memoryCitationSummary",
        memoryCitationStateKey(message),
        ...entries.map((entry) => [
          trimmed(entry?.path),
          entry?.lineStart || "",
          entry?.lineEnd || "",
          trimmed(entry?.note)
        ].join(":"))
      ].join("|"));
    }

    function memoryCitationPayload(entry) {
      const payload = {
        action: "openReadexContentReference",
        referenceKind: "memoryCitation",
        path: trimmed(entry?.path)
      };
      const lineStart = positiveMemoryCitationLine(entry?.lineStart);
      if (lineStart) {
        payload.lineNumber = lineStart;
      }
      const lineEnd = positiveMemoryCitationLine(entry?.lineEnd);
      if (lineEnd && (!lineStart || lineEnd > lineStart)) {
        payload.endLineNumber = lineEnd;
      }
      return payload;
    }

    function openMemoryCitationEntry(entry, event) {
      event?.preventDefault?.();
      event?.stopPropagation?.();
      const payload = memoryCitationPayload(entry);
      if (!payload.path) {
        return false;
      }
      postMessageAction(payload);
      return true;
    }

    function memoryCitationStripSignature(message) {
      const entries = memoryCitationEntries(message);
      if (!entries.length) {
        return "";
      }
      return JSON.stringify({
        key: memoryCitationStateKey(message),
        expanded: memoryCitationIsExpanded(message),
        entries
      });
    }

    function renderMemoryCitationEntry(entry) {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "readex-memory-citation-entry has-preview-content-accent";
      row.style.setProperty("--readex-extracted-pdf-accent", memoryCitationAccent(entry));
      row.setAttribute("aria-label", `打开 ${memoryCitationLineLabel(entry)}`);

      const location = document.createElement("span");
      location.className = "readex-memory-citation-entry-location";
      location.textContent = memoryCitationLineLabel(entry);
      row.appendChild(location);

      if (entry.note) {
        const note = document.createElement("span");
        note.className = "readex-memory-citation-entry-note";
        note.textContent = entry.note;
        row.appendChild(note);
      }

      row.addEventListener("click", (event) => {
        openMemoryCitationEntry(entry, event);
      });
      return row;
    }

    function renderMemoryCitationList(entries) {
      const list = document.createElement("div");
      list.className = "readex-memory-citation-list";
      entries.forEach((entry) => {
        list.appendChild(renderMemoryCitationEntry(entry));
      });
      return list;
    }

    function memoryCitationListElement(root) {
      if (!(root instanceof HTMLElement)) {
        return null;
      }
      return Array.from(root.children).find((child) => (
        child instanceof HTMLElement
        && child.classList.contains("readex-memory-citation-list")
      )) || null;
    }

    function renderMemoryCitationStrip(message) {
      const entries = memoryCitationEntries(message);
      if (!entries.length) {
        return null;
      }

      const isExpanded = memoryCitationIsExpanded(message);
      const root = document.createElement("div");
      root.className = [
        "readex-memory-citation-strip",
        isExpanded ? "is-expanded" : ""
      ].filter(Boolean).join(" ");
      root.__chatTranscriptSignature = memoryCitationStripSignature(message);
      root.style.setProperty(
        "--readex-memory-citation-summary-accent",
        memoryCitationSummaryAccent(entries, message)
      );

      const summary = document.createElement("button");
      summary.type = "button";
      summary.className = "readex-memory-citation-summary";
      summary.setAttribute("aria-expanded", isExpanded ? "true" : "false");
      summary.setAttribute("aria-label", `${isExpanded ? "收起" : "展开"}${entries.length} 条记忆引用`);

      const chevron = document.createElement("span");
      chevron.className = "readex-memory-citation-summary-chevron";
      chevron.setAttribute("aria-hidden", "true");
      chevron.innerHTML = makeIcon("chevron-right");
      summary.appendChild(chevron);

      const label = document.createElement("span");
      label.className = "readex-memory-citation-summary-label";
      label.textContent = `${entries.length} 条记忆引用`;
      summary.appendChild(label);

      summary.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        const nextExpanded = !memoryCitationIsExpanded(message);
        setMemoryCitationExpanded(message, nextExpanded);
        root.classList.toggle("is-expanded", nextExpanded);
        summary.setAttribute("aria-expanded", nextExpanded ? "true" : "false");
        summary.setAttribute("aria-label", `${nextExpanded ? "收起" : "展开"}${entries.length} 条记忆引用`);
        root.__chatTranscriptSignature = memoryCitationStripSignature(message);

        const existingList = memoryCitationListElement(root);
        if (nextExpanded) {
          if (!existingList) {
            root.appendChild(renderMemoryCitationList(entries));
          }
        } else if (existingList) {
          existingList.remove();
        }
      });
      root.appendChild(summary);

      if (isExpanded) {
        root.appendChild(renderMemoryCitationList(entries));
      }

      return root;
    }

    function patchMemoryCitationStrip(element, message) {
      const signature = memoryCitationStripSignature(message);
      if (!signature) {
        element?.remove?.();
        return null;
      }
      if (element instanceof HTMLElement && element.__chatTranscriptSignature === signature) {
        return element;
      }
      const replacement = renderMemoryCitationStrip(message);
      if (element instanceof HTMLElement && replacement) {
        element.replaceWith(replacement);
      }
      return replacement;
    }

    function renderUserActions(message) {
      const presentation = transcriptPresentation();
      if (!isInteractiveTranscript() || !message.id || messageIsStreaming(message)) {
        return null;
      }
      if (Boolean(presentation?.isConversationGenerating) || transcriptUIState().editingMessageId === message.id) {
        return null;
      }

      const root = document.createElement("div");
      root.className = "message-actions";

      renderAllowedMessageAction(root, message, "regenerateUserMessage", {
        iconName: "arrow.clockwise",
        helpText: "重新生成",
        label: () => "重新生成",
        disabled: false,
        onClick: () => {
          postMessageAction({ action: "regenerateUserMessage", messageID: message.id });
        }
      });

      renderAllowedMessageAction(root, message, "editUserMessage", {
        iconName: "square.and.pencil",
        helpText: "编辑",
        label: () => "编辑",
        disabled: false,
        onClick: () => {
          const state = transcriptUIState();
          keepToolbarVisible(message.id, false);
          state.editDraftByMessageId[message.id] = messagePrimaryTextContent(message);
          state.editingMessageId = message.id;
          postEditorFocusProbe("edit_begin", message.id, null, {
            draftLength: state.editDraftByMessageId[message.id]?.length || 0,
            messageTextLength: messagePrimaryTextContent(message).length
          });
          rerenderConversationPreservingScroll({ focusEditorMessageId: message.id });
        }
      });

      renderAllowedMessageAction(root, message, "branchConversation", {
        iconName: "arrow.triangle.branch",
        helpText: "在新聊天中创建分支对话",
        label: () => "创建分支",
        disabled: false,
        onClick: () => {
          postMessageAction({ action: "branchConversation", messageID: message.id });
        }
      });

      renderAllowedMessageAction(root, message, "copyMessage", {
        iconName: actionButtonIcon(message.id, "doc.on.doc"),
        helpText: "复制",
        label: () => actionButtonLabel(message.id, "复制"),
        disabled: false,
        onClick: () => {
          postMessageAction({ action: "copyMessage", messageID: message.id, text: messagePrimaryTextContent(message) });
          setCopiedMessage(message.id);
        }
      });

      renderAllowedMessageAction(root, message, "deleteUserMessage", {
        iconName: "trash",
        helpText: "删除",
        label: () => "删除",
        disabled: false,
        onClick: () => {
          postMessageAction({ action: "deleteUserMessage", messageID: message.id });
        }
      });

      return root.children.length ? root : null;
    }

    function renderUserEditor(message) {
      const shell = document.createElement("div");
      shell.className = "message-editor-shell";

      const editor = document.createElement("div");
      editor.className = "message-editor";

      const textarea = document.createElement("textarea");
      textarea.className = "message-editor-textarea";
      textarea.placeholder = "编辑消息";
      textarea.value = currentDraft(message);
      textarea.dataset.messageId = message.id || "";
      textarea.addEventListener("click", (event) => {
        event.stopPropagation();
        postEditorFocusProbe("textarea_click", message.id, textarea);
      });
      textarea.addEventListener("focus", () => {
        postEditorFocusProbe("textarea_focus", message.id, textarea);
      });
      textarea.addEventListener("blur", () => {
        postEditorFocusProbe("textarea_blur", message.id, textarea);
      });
      textarea.addEventListener("input", () => {
        transcriptUIState().editDraftByMessageId[message.id] = textarea.value;
        autoResizeEditor(textarea);
        const saveButton = document.querySelector(`.message[data-message-id="${message.id}"] .message-edit-footer-button.save`);
        if (saveButton instanceof HTMLButtonElement) {
          const presentation = transcriptPresentation();
          saveButton.disabled = !trimmed(textarea.value) || Boolean(presentation?.isConversationGenerating);
        }
      });

      editor.appendChild(textarea);
      shell.appendChild(editor);
      requestAnimationFrame(() => {
        autoResizeEditor(textarea);
        postEditorFocusProbe("editor_mount_raf", message.id, textarea, {
          shellConnected: shell.isConnected
        });
      });
      return shell;
    }

    function renderUserEditFooter(message) {
      const presentation = transcriptPresentation();
      const footer = document.createElement("div");
      footer.className = "message-edit-footer";

      const cancelButton = document.createElement("button");
      cancelButton.type = "button";
      cancelButton.className = "message-edit-footer-button";
      cancelButton.textContent = "取消";
      cancelButton.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        const state = transcriptUIState();
        state.editDraftByMessageId[message.id] = messagePrimaryTextContent(message);
        state.editingMessageId = null;
        rerenderConversationPreservingScroll();
      });
      footer.appendChild(cancelButton);

      const saveButton = document.createElement("button");
      saveButton.type = "button";
      saveButton.className = "message-edit-footer-button save";
      saveButton.textContent = "保存并重跑";
      saveButton.disabled = !trimmed(currentDraft(message)) || Boolean(presentation?.isConversationGenerating);
      saveButton.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        const state = transcriptUIState();
        const updatedContent = currentDraft(message);
        state.editingMessageId = null;
        rerenderConversationPreservingScroll();
        if (trimmed(updatedContent) === trimmed(messagePrimaryTextContent(message))) {
          postMessageAction({ action: "regenerateUserMessage", messageID: message.id });
        } else {
          postMessageAction({
            action: "saveEditedUserMessage",
            messageID: message.id,
            content: updatedContent
          });
        }
      });
      footer.appendChild(saveButton);

      return footer;
    }

    function currentMessageForArticle(article) {
      return article && typeof article === "object" ? article.__chatTranscriptMessage || null : null;
    }

    function readexExplicitReferenceURLFromHref(href) {
      const rawHref = trimmed(href);
      if (!rawHref) {
        return null;
      }
      try {
        return new URL(rawHref);
      } catch (_) {
        return null;
      }
    }

    function readexPageReferencePayloadFromHref(href, label) {
      const rawHref = trimmed(href);
      const url = readexExplicitReferenceURLFromHref(rawHref);
      if (!url) {
        return null;
      }
      const isReadexPageURL = url.protocol === "readex:" &&
        ["page", "page-ref", "open-page"].includes(trimmed(url.hostname).toLowerCase());
      if (!isReadexPageURL) {
        return null;
      }
      const documentID = trimmed(
        url.searchParams.get("document_id") ||
        url.searchParams.get("documentID") ||
        url.searchParams.get("document")
      );
      const contentID = trimmed(
        url.searchParams.get("content_id") ||
        url.searchParams.get("contentID") ||
        url.searchParams.get("content")
      );
      const rawPageNumber = trimmed(
        url.searchParams.get("page_number") ||
        url.searchParams.get("pageNumber") ||
        url.searchParams.get("page")
      );
      const pageNumber = Number.parseInt(rawPageNumber, 10);
      const pageLabel = trimmed(
        url.searchParams.get("page_label") ||
        url.searchParams.get("pageLabel") ||
        url.searchParams.get("label") ||
        label
      );
      const path = trimmed(
        url.searchParams.get("path") ||
        url.searchParams.get("file_path") ||
        url.searchParams.get("filePath")
      );
      if (!contentID && !documentID && !path) {
        return null;
      }
      if ((!Number.isFinite(pageNumber) || pageNumber <= 0) && !pageLabel) {
        return null;
      }
      return {
        action: "openReadexContentReference",
        contentID: contentID || undefined,
        documentID: documentID || undefined,
        pageNumber: Number.isFinite(pageNumber) && pageNumber > 0 ? pageNumber : undefined,
        pageLabel: pageLabel || undefined,
        path: path || undefined,
        url: rawHref
      };
    }

    function readexPDFPageLabelFromHash(hash) {
      const fragment = trimmed(hash).replace(/^#/u, "");
      if (!fragment) {
        return "";
      }
      const params = new URLSearchParams(fragment);
      return trimmed(
        params.get("p") ||
        params.get("page_label") ||
        params.get("pageLabel") ||
        params.get("label")
      );
    }

    function readexVideoTimeSecondsFromValue(value) {
      const rawValue = trimmed(value).replace(",", ".");
      if (!rawValue) {
        return null;
      }
      const numericSeconds = Number(rawValue);
      if (Number.isFinite(numericSeconds) && numericSeconds >= 0) {
        return numericSeconds;
      }
      const parts = rawValue.split(":").map((part) => trimmed(part));
      if (parts.length !== 2 && parts.length !== 3) {
        return null;
      }
      const seconds = Number(parts[parts.length - 1]);
      if (!Number.isFinite(seconds) || seconds < 0 || seconds >= 60) {
        return null;
      }
      if (parts.length === 3) {
        const hours = Number(parts[0]);
        const minutes = Number(parts[1]);
        if (!Number.isFinite(hours) || !Number.isFinite(minutes) || hours < 0 || minutes < 0 || minutes >= 60) {
          return null;
        }
        return hours * 3600 + minutes * 60 + seconds;
      }
      const minutes = Number(parts[0]);
      if (!Number.isFinite(minutes) || minutes < 0) {
        return null;
      }
      return minutes * 60 + seconds;
    }

    function readexVideoTimeValueFromHash(hash) {
      const fragment = trimmed(hash).replace(/^#/u, "");
      if (!fragment) {
        return "";
      }
      const params = new URLSearchParams(fragment);
      return trimmed(
        params.get("t") ||
        params.get("time") ||
        params.get("timestamp") ||
        params.get("range") ||
        params.get("start") ||
        params.get("start_seconds") ||
        params.get("startSeconds")
      );
    }

    function readexVideoTimeRangeFromParams(params) {
      if (!params) {
        return null;
      }
      const range = firstReadexVideoTimeRangeFromValue(
        params.get("t") ||
        params.get("time") ||
        params.get("timestamp") ||
        params.get("range")
      );
      if (range) {
        return range;
      }
      const startSeconds = readexVideoTimeSecondsFromValue(
        params.get("start") ||
        params.get("start_seconds") ||
        params.get("startSeconds")
      );
      if (startSeconds === null) {
        return null;
      }
      const endSeconds = readexVideoTimeSecondsFromValue(
        params.get("end") ||
        params.get("end_seconds") ||
        params.get("endSeconds")
      );
      if (endSeconds !== null && endSeconds < startSeconds) {
        return null;
      }
      return { startSeconds, endSeconds };
    }

    function readexVideoTimeRangeFromHash(hash) {
      const fragment = trimmed(hash).replace(/^#/u, "");
      if (!fragment) {
        return null;
      }
      return readexVideoTimeRangeFromParams(new URLSearchParams(fragment));
    }

    function readexVideoTimeRangeFromSearch(search) {
      const query = trimmed(search).replace(/^\?/u, "");
      if (!query) {
        return null;
      }
      return readexVideoTimeRangeFromParams(new URLSearchParams(query));
    }

    function readexVideoTimeRangeFromValue(value) {
      const text = trimmed(value);
      if (!text) {
        return null;
      }
      const separatorMatch = text.match(/\s*[-–—~～至到]\s*/u);
      if (separatorMatch && typeof separatorMatch.index === "number") {
        const startText = trimmed(text.slice(0, separatorMatch.index));
        const endText = trimmed(text.slice(separatorMatch.index + separatorMatch[0].length));
        const startSeconds = readexVideoTimeSecondsFromValue(startText);
        const endSeconds = readexVideoTimeSecondsFromValue(endText);
        if (startSeconds === null || endSeconds === null || endSeconds < startSeconds) {
          return null;
        }
        return { startSeconds, endSeconds };
      }
      const startSeconds = readexVideoTimeSecondsFromValue(text);
      return startSeconds === null ? null : { startSeconds, endSeconds: null };
    }

    function firstReadexVideoTimeRangeFromValue(value) {
      const items = trimmed(value)
        .split(/[，,、；;]/u)
        .map((item) => trimmed(item))
        .filter(Boolean);
      if (!items.length) {
        return null;
      }
      return readexVideoTimeRangeFromValue(items[0]);
    }

    function readexVideoTimeReferencePayloadFromHref(href) {
      const rawHref = trimmed(href);
      const url = readexExplicitReferenceURLFromHref(rawHref);
      if (!url) {
        return null;
      }
      const isReadexURL = url.protocol === "readex:";
      const host = trimmed(url.hostname).toLowerCase();
      const isReadexVideoURL = isReadexURL &&
        (host === "video-time" || host === "video-timestamp" || host === "open-video-time");
      if (!isReadexVideoURL) {
        return null;
      }
      const documentID = trimmed(
        url.searchParams.get("document_id") ||
        url.searchParams.get("documentID") ||
        url.searchParams.get("document")
      );
      const contentID = trimmed(
        url.searchParams.get("content_id") ||
        url.searchParams.get("contentID") ||
        url.searchParams.get("content")
      );
      const path = trimmed(
        url.searchParams.get("path") ||
        url.searchParams.get("file_path") ||
        url.searchParams.get("filePath")
      );
      const startSeconds = readexVideoTimeSecondsFromValue(
        url.searchParams.get("start") ||
        url.searchParams.get("start_seconds") ||
        url.searchParams.get("startSeconds") ||
        url.searchParams.get("time") ||
        url.searchParams.get("timestamp")
      );
      const endSeconds = readexVideoTimeSecondsFromValue(
        url.searchParams.get("end") ||
        url.searchParams.get("end_seconds") ||
        url.searchParams.get("endSeconds")
      );
      if ((!contentID && !documentID && !path) || startSeconds === null || (endSeconds !== null && endSeconds < startSeconds)) {
        return null;
      }
      return {
        action: "openReadexContentReference",
        contentID: contentID || undefined,
        documentID: documentID || undefined,
        startSeconds,
        endSeconds: endSeconds === null ? undefined : endSeconds,
        path: path || undefined,
        url: rawHref
      };
    }

    function readexContentReferencePayloadFromHref(href, label) {
      const pagePayload = readexPageReferencePayloadFromHref(href, label);
      if (pagePayload) {
        return pagePayload;
      }
      const videoPayload = readexVideoTimeReferencePayloadFromHref(href);
      if (videoPayload) {
        return videoPayload;
      }

      const rawHref = trimmed(href);
      const url = readexExplicitReferenceURLFromHref(rawHref);
      if (!url) {
        return null;
      }

      if (url.protocol === "http:" || url.protocol === "https:") {
        return {
          action: "openReadexContentReference",
          url: rawHref
        };
      }

      const isReadexContentURL = url.protocol === "readex:" &&
        ["content", "file", "open", "reference", "content-reference"].includes(trimmed(url.hostname).toLowerCase());
      if (isReadexContentURL) {
        const rawPageNumber = trimmed(
          url.searchParams.get("page_number") ||
          url.searchParams.get("pageNumber") ||
          url.searchParams.get("page")
        );
        const pageNumber = Number.parseInt(rawPageNumber, 10);
        const timeRange = readexVideoTimeRangeFromSearch(url.search);
        const pathReference = readexPathWithLineLocation(trimmed(
          url.searchParams.get("path") ||
          url.searchParams.get("file_path") ||
          url.searchParams.get("filePath")
        ));
        const payload = {
          action: "openReadexContentReference",
          contentID: trimmed(
            url.searchParams.get("content_id") ||
            url.searchParams.get("contentID") ||
            url.searchParams.get("content")
          ) || undefined,
          documentID: trimmed(
            url.searchParams.get("document_id") ||
            url.searchParams.get("documentID") ||
            url.searchParams.get("document")
          ) || undefined,
          path: pathReference.path || undefined,
          pageNumber: Number.isFinite(pageNumber) && pageNumber > 0 ? pageNumber : undefined,
          pageLabel: trimmed(
            url.searchParams.get("page_label") ||
            url.searchParams.get("pageLabel") ||
            url.searchParams.get("label")
          ) || undefined,
          startSeconds: timeRange?.startSeconds,
          endSeconds: timeRange?.endSeconds ?? undefined,
          lineNumber: readexPositiveIntegerFromValue(
            url.searchParams.get("line_number") ||
            url.searchParams.get("lineNumber") ||
            url.searchParams.get("line")
          ) ?? pathReference.lineNumber ?? undefined,
          columnNumber: readexPositiveIntegerFromValue(
            url.searchParams.get("column_number") ||
            url.searchParams.get("columnNumber") ||
            url.searchParams.get("column")
          ) ?? pathReference.columnNumber ?? undefined,
          url: rawHref
        };
        return payload.contentID || payload.documentID || payload.path || payload.url ? payload : null;
      }

      return null;
    }

    function readexPositiveIntegerFromValue(value) {
      const number = Number.parseInt(trimmed(value), 10);
      return Number.isFinite(number) && number > 0 ? number : null;
    }

    function readexPathWithLineLocation(path) {
      const normalizedPath = trimmed(path);
      const match = normalizedPath.match(/^(.*):(\d+)(?::(\d+))?$/u);
      if (!match || !trimmed(match[1])) {
        return { path: normalizedPath, lineNumber: null, columnNumber: null };
      }
      return {
        path: trimmed(match[1]),
        lineNumber: readexPositiveIntegerFromValue(match[2]),
        columnNumber: readexPositiveIntegerFromValue(match[3])
      };
    }

    function readexValidatedReferencePayloadFromAnchor(anchor) {
      const rawPayload = trimmed(anchor?.dataset?.readexContentReferencePayload);
      if (!rawPayload) {
        return null;
      }
      try {
        const payload = JSON.parse(rawPayload);
        if (payload && payload.action === "openReadexContentReference") {
          return payload;
        }
      } catch (_) {
        return null;
      }
      return null;
    }

    function elementFromEventTarget(target) {
      if (target instanceof Element) {
        return target;
      }
      if (target instanceof Node) {
        return target.parentElement || null;
      }
      return null;
    }

    function readexReferencePayloadFromTarget(target) {
      const element = elementFromEventTarget(target);
      if (!hasMessageActionHandler() || !element) {
        return null;
      }
      const anchor = element.closest("a[href]");
      const validatedPayload = readexValidatedReferencePayloadFromAnchor(anchor);
      if (validatedPayload) {
        return validatedPayload;
      }
      const href = anchor?.getAttribute("href");
      return readexContentReferencePayloadFromHref(
        href,
        anchor?.textContent
      );
    }

    function readexReferenceNumberKey(value) {
      return typeof value === "number" && Number.isFinite(value) ? String(value) : "";
    }

    function readexReferenceActivationKey(payload) {
      if (!payload) {
        return "";
      }
      return [
        trimmed(payload.action),
        trimmed(payload.contentID),
        trimmed(payload.documentID),
        payload.pageNumber ?? "",
        payload.pageLabel ?? "",
        readexReferenceNumberKey(payload.startSeconds),
        readexReferenceNumberKey(payload.endSeconds),
        payload.lineNumber ?? "",
        payload.columnNumber ?? "",
        trimmed(payload.path),
        payload.url ?? ""
      ].join("|");
    }

    function readexPointerEventCanActivate(event) {
      if (!event) {
        return false;
      }
      if (typeof event.button === "number" && event.button !== 0) {
        return false;
      }
      return !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
    }

    function readexPointerMovedTooFar(pending, event) {
      if (!pending || typeof event?.clientX !== "number" || typeof event?.clientY !== "number") {
        return false;
      }
      return Math.abs(event.clientX - pending.clientX) > 8 || Math.abs(event.clientY - pending.clientY) > 8;
    }

    function readexReferenceDuplicateWasJustSent(payload) {
      const key = readexReferenceActivationKey(payload);
      const now = Date.now();
      return key && key === lastReadexReferenceActivation.key && now - lastReadexReferenceActivation.at < 700;
    }

    function rememberReadexReferenceActivation(payload) {
      lastReadexReferenceActivation = {
        key: readexReferenceActivationKey(payload),
        at: Date.now()
      };
    }

    function activateReadexReference(event, payload) {
      event.preventDefault();
      event.stopPropagation();
      postMessageAction(payload);
      rememberReadexReferenceActivation(payload);
      return true;
    }

    function handleReadexReferenceClick(event, target) {
      const payload = readexReferencePayloadFromTarget(target);
      if (!payload) {
        return false;
      }
      if (readexReferenceDuplicateWasJustSent(payload)) {
        event.preventDefault();
        event.stopPropagation();
        return true;
      }
      return activateReadexReference(event, payload);
    }

    function handleReadexReferencePointerDown(event, target) {
      if (!readexPointerEventCanActivate(event)) {
        pendingReadexReferenceActivation = null;
        return;
      }
      const payload = readexReferencePayloadFromTarget(target);
      if (!payload) {
        pendingReadexReferenceActivation = null;
        return;
      }
      pendingReadexReferenceActivation = {
        payload,
        pointerId: typeof event.pointerId === "number" ? event.pointerId : null,
        clientX: typeof event.clientX === "number" ? event.clientX : 0,
        clientY: typeof event.clientY === "number" ? event.clientY : 0,
        at: Date.now()
      };
    }

    function handleReadexReferencePointerUp(event) {
      const pending = pendingReadexReferenceActivation;
      pendingReadexReferenceActivation = null;
      if (!pending || !readexPointerEventCanActivate(event)) {
        return false;
      }
      if (
        pending.pointerId !== null &&
        typeof event.pointerId === "number" &&
        event.pointerId !== pending.pointerId
      ) {
        return false;
      }
      if (Date.now() - pending.at > 1500 || readexPointerMovedTooFar(pending, event)) {
        return false;
      }
      return activateReadexReference(event, pending.payload);
    }

    function attachMessageInteractions(article) {
      if (!article || article.__chatTranscriptInteractionsInstalled) {
        return;
      }
      article.__chatTranscriptInteractionsInstalled = true;

      article.addEventListener("pointerdown", (event) => {
        handleReadexReferencePointerDown(event, event.target);
      }, true);

      article.addEventListener("pointerup", (event) => {
        handleReadexReferencePointerUp(event);
      }, true);

      article.addEventListener("click", (event) => {
        const target = event.target;
        if (handleReadexReferenceClick(event, target)) {
          return;
        }
        const message = currentMessageForArticle(article);
        if (!message || !message.id) {
          return;
        }
        const root = document.documentElement;
        if (!root?.hasAttribute("data-layout-lab-interactive")) {
          return;
        }
        if (!(target instanceof Element)) {
          return;
        }
        if (target.closest("a") || target.closest("button") || target.closest("textarea")) {
          return;
        }
        if (window.getSelection && String(window.getSelection() || "").trim()) {
          return;
        }
        if (message.role === "steered") {
          return;
        }
        postLayoutLabComponentSelection(message.role === "assistant" ? "assistant" : "user");
      });

      article.addEventListener("mouseenter", () => {
        const message = currentMessageForArticle(article);
        if (!message || message.role !== "user" || !message.id) {
          return;
        }
        if (!canShowUserToolbar(message)) {
          return;
        }
        clearToolbarTimers(message.id);
        const state = transcriptUIState();
        state.toolbarShowTimeouts[message.id] = setTimeout(() => {
          keepToolbarVisible(message.id, true);
          article.classList.add("actions-visible");
          delete state.toolbarShowTimeouts[message.id];
        }, 250);
      });

      article.addEventListener("mouseleave", () => {
        const message = currentMessageForArticle(article);
        if (!message || message.role !== "user" || !message.id) {
          return;
        }
        hideActiveTooltip();
        clearToolbarTimers(message.id);
        const state = transcriptUIState();
        if (!state.visibleUserToolbarMessageIDs[message.id]) {
          return;
        }
        state.toolbarHideTimeouts[message.id] = setTimeout(() => {
          keepToolbarVisible(message.id, false);
          article.classList.remove("actions-visible");
          delete state.toolbarHideTimeouts[message.id];
        }, 180);
      });
    }

    return Object.freeze({
      autoResizeEditor,
      canShowUserToolbar,
      headerSignature,
      renderMessageHeader,
      renderUserEditor,
      renderUserEditFooter,
      renderAssistantActions,
      renderMemoryCitationStrip,
      patchMemoryCitationStrip,
      renderUserActions,
      patchReadexAssistantFooterActions,
      currentMessageForArticle,
      attachMessageInteractions,
      syncAssistantModelPickerModal
    });
  };
})();
