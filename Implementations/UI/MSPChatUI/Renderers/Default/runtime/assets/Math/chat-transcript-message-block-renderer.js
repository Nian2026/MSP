(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript message block renderer dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptMessageBlockRendererFactory = function createChatTranscriptMessageBlockRenderer(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const messageIsStreaming = requiredFunction(dependencies, "messageIsStreaming");
      const markdownRenderOptions = requiredFunction(dependencies, "markdownRenderOptions");
      const renderMarkdownIntoElement = requiredFunction(dependencies, "renderMarkdownIntoElement");
      const refreshRenderedMarkdownDecorators = requiredFunction(dependencies, "refreshRenderedMarkdownDecorators");
      const postMainTextRenderProbe = requiredFunction(dependencies, "postMainTextRenderProbe");
      const postPresentationProbe = typeof dependencies?.postPresentationProbe === "function"
        ? dependencies.postPresentationProbe
        : function () {};
    const renderThinkingBlock = requiredFunction(dependencies, "renderThinkingBlock");
    const updateThinkingBlockElement = requiredFunction(dependencies, "updateThinkingBlockElement");
    const renderReasoningSummaryBlock = requiredFunction(dependencies, "renderReasoningSummaryBlock");
    const updateReasoningSummaryBlockElement = requiredFunction(dependencies, "updateReasoningSummaryBlockElement");
    const renderReasoningActivityBlock = requiredFunction(dependencies, "renderReasoningActivityBlock");
    const updateReasoningActivityBlockElement = requiredFunction(dependencies, "updateReasoningActivityBlockElement");
    const renderReadexProcessingBlock = requiredFunction(dependencies, "renderReadexProcessingBlock");
    const updateReadexProcessingBlockElement = requiredFunction(dependencies, "updateReadexProcessingBlockElement");
    const renderReadexStoppedMarkerBlock = requiredFunction(dependencies, "renderReadexStoppedMarkerBlock");
    const updateReadexStoppedMarkerBlockElement = requiredFunction(dependencies, "updateReadexStoppedMarkerBlockElement");
    const renderReadexContextStatusBlock = requiredFunction(dependencies, "renderReadexContextStatusBlock");
    const updateReadexContextStatusBlockElement = requiredFunction(dependencies, "updateReadexContextStatusBlockElement");
    const renderReadexToolActivityBlock = requiredFunction(dependencies, "renderReadexToolActivityBlock");
    const updateReadexToolActivityBlockElement = requiredFunction(dependencies, "updateReadexToolActivityBlockElement");
    const renderSearchResultsBlock = requiredFunction(dependencies, "renderSearchResultsBlock");
    const renderReadexSourcesBlock = requiredFunction(dependencies, "renderReadexSourcesBlock");
    const updateReadexSourcesBlockElement = requiredFunction(dependencies, "updateReadexSourcesBlockElement");
    const renderSearchProgressBlock = requiredFunction(dependencies, "renderSearchProgressBlock");
    const renderAttachments = requiredFunction(dependencies, "renderAttachments");
    const renderReadexVideoProgressBlock = requiredFunction(dependencies, "renderReadexVideoProgressBlock");
    const renderableMessageBlocks = requiredFunction(dependencies, "renderableMessageBlocks");
    const makeIcon = requiredFunction(dependencies, "makeIcon");
    const isInteractiveTranscript = typeof dependencies?.isInteractiveTranscript === "function"
      ? dependencies.isInteractiveTranscript
      : () => false;
    const hasMessageActionHandler = typeof dependencies?.hasMessageActionHandler === "function"
      ? dependencies.hasMessageActionHandler
      : isInteractiveTranscript;
      const postMessageAction = typeof dependencies?.postMessageAction === "function"
        ? dependencies.postMessageAction
        : null;

      function shouldProbeDOMReconcileForMessage(message) {
        return message?.role === "assistant" ||
          Boolean(trimmed(message?.readexTurnID || message?.readexTurnId || message?.patchKey));
      }

      function messageProbePayload(message) {
        return {
          messageID: trimmed(message?.messageID || message?.id),
          patchKey: trimmed(message?.patchKey),
          readexTurnID: trimmed(message?.readexTurnID || message?.readexTurnId),
          role: trimmed(message?.role),
          status: trimmed(message?.status || message?.effectiveStatus || message?.messageStatus),
          isStreaming: messageIsStreaming(message)
        };
      }

      function metricsProbePayload(metrics) {
        return {
          engine: trimmed(metrics?.engine) || "unknown",
          displayedLength: Number(metrics?.displayedLength) || 0,
          targetLength: Number(metrics?.targetLength) || 0,
          queuedCharCount: Number(metrics?.queuedCharCount) || 0,
          renderedLength: Number(metrics?.renderedLength) || 0,
          liveTailMode: trimmed(metrics?.liveTailMode),
          stableBlockCount: Number(metrics?.stableBlockCount) || 0,
          replacedBlockCount: Number(metrics?.replacedBlockCount) || 0,
          sourceBlockCount: Number(metrics?.sourceBlockCount) || 0
        };
      }

      function postBlockDOMReconcileProbe(event, message, block, blockKey, extra = {}) {
        if (!shouldProbeDOMReconcileForMessage(message)) {
          return;
        }
        postPresentationProbe({
          kind: "dom_reconcile_probe",
          event,
          source: "message_block_renderer",
          ...messageProbePayload(message),
          blockKey: trimmed(blockKey),
          blockType: trimmed(block?.type),
          textLength: String(blockText(block) || "").length,
          ...extra
        });
      }

      function renderPerfProbeEnabled() {
        return window.__chatTranscriptRenderPerfProbeEnabled === true;
      }

      function renderPerfNow() {
        const value = Number(window.performance?.now?.());
        return Number.isFinite(value) ? value : Date.now();
      }

      function renderPerfDocumentSnapshot() {
        const snapshot = window.__chatTranscriptRenderPerfProbeSnapshot;
        return typeof snapshot === "function" ? snapshot() : null;
      }

      function renderPerfDocumentDelta(before) {
        const delta = window.__chatTranscriptRenderPerfProbeDelta;
        return typeof delta === "function" ? delta(before) : null;
      }

      function roundedProbeNumber(value) {
        const number = Number(value);
        return Number.isFinite(number) ? Math.round(number * 10) / 10 : 0;
      }

      function elementRenderPerfPayload(element) {
        if (!(element instanceof HTMLElement)) {
          return null;
        }
        const rect = element.getBoundingClientRect();
        return {
          className: String(element.className || ""),
          childElementCount: element.children?.length || 0,
          childNodeCount: element.childNodes?.length || 0,
          textLength: String(element.textContent || "").length,
          htmlLength: String(element.innerHTML || "").length,
          clientHeight: roundedProbeNumber(element.clientHeight),
          scrollHeight: roundedProbeNumber(element.scrollHeight),
          rectHeight: roundedProbeNumber(rect.height),
          isConnected: Boolean(element.isConnected)
        };
      }

      function shouldPostRenderPerfProbe(event, message, renderOptions, elapsedMs, mutationDelta) {
        if (!renderPerfProbeEnabled() || !shouldProbeDOMReconcileForMessage(message)) {
          return false;
        }
        if (renderOptions?.streamingFinalizeImmediate === true || !messageIsStreaming(message)) {
          return true;
        }
        if (elapsedMs >= 4) {
          return true;
        }
        const delta = mutationDelta?.delta || {};
        return (Number(delta.addedArticles) || 0) > 0
          || (Number(delta.removedArticles) || 0) > 0
          || (Number(delta.addedReadexProcessing) || 0) > 0
          || (Number(delta.removedReadexProcessing) || 0) > 0
          || (Number(delta.removedElements) || 0) > 0;
      }

      function postRenderPerfProbe(event, message, block, blockKey, text, payload = {}) {
        const elapsedMs = roundedProbeNumber(payload.elapsedMs);
        const mutationDelta = payload.mutationDelta || null;
        if (!shouldPostRenderPerfProbe(event, message, payload.renderOptions, elapsedMs, mutationDelta)) {
          return;
        }
        postPresentationProbe({
          kind: "render_perf",
          event,
          source: "message_block_renderer",
          ...messageProbePayload(message),
          blockKey: trimmed(blockKey),
          blockType: trimmed(block?.type),
          textLength: String(text || "").length,
          elapsedMs,
          previousTextLength: Number(payload.previousTextLength) || 0,
          renderPhase: trimmed(payload.renderPhase),
          renderOptions: payload.renderOptions || {},
          metrics: payload.metrics || null,
          beforeElement: payload.beforeElement || null,
          afterElement: payload.afterElement || null,
          documentAfter: mutationDelta?.after || null,
          mutationDelta: mutationDelta?.delta || null
        });
      }

      function readexMarkdownRemeasureProbeEnabled() {
        return window.__chatTranscriptReadexLayoutProbeEnabled === true;
      }

      function readexMarkdownElementProbePayload(element) {
        if (!(element instanceof HTMLElement)) {
          return null;
        }
        const markstreamRoots = Array.from(element.querySelectorAll?.(".readex-markstream-root") || []);
        return {
          ...elementRenderPerfPayload(element),
          blockKey: trimmed(element.dataset?.blockKey),
          blockType: trimmed(element.dataset?.blockType),
          rememberedTextLength: String(element.__chatTranscriptMarkdownSource || "").length,
          renderSignatureLength: String(element.__chatTranscriptMarkdownRenderSignature || "").length,
          markstreamRootCount: markstreamRoots.length,
          firstMarkstreamRoot: elementRenderPerfPayload(markstreamRoots[0])
        };
      }

      function scheduleReadexMarkdownLayoutOverlapProbe(element, renderOptions, source) {
        if (!readexMarkdownRemeasureProbeEnabled()) {
          return;
        }
        const scheduleOverlapProbe = window.__chatTranscriptScheduleMarkstreamLayoutOverlapProbe;
        if (typeof scheduleOverlapProbe !== "function") {
          return;
        }
        scheduleOverlapProbe(element, {
          ...(renderOptions || {}),
          source: trimmed(source) || "main_text",
          forceReadexLayoutProbe: true
        });
      }

      function postReadexMarkdownRemeasureProbe(event, message, block, blockKey, text, payload = {}) {
        if (!readexMarkdownRemeasureProbeEnabled() || !shouldProbeDOMReconcileForMessage(message)) {
          return;
        }
        try {
          postPresentationProbe({
            kind: "readex_markdown_remeasure_probe",
            event,
            source: "message_block_renderer",
            ...messageProbePayload(message),
            blockKey: trimmed(blockKey),
            blockType: trimmed(block?.type),
            textLength: String(text || "").length,
            previousTextLength: Number(payload.previousTextLength) || 0,
            renderPhase: trimmed(payload.renderPhase),
            reason: trimmed(payload.reason),
            renderOptions: payload.renderOptions || {},
            metrics: payload.metrics || null,
            beforeElement: payload.beforeElement || null,
            afterElement: payload.afterElement || null,
            signatureMatched: Boolean(payload.signatureMatched),
            markdownSourceMatched: Boolean(payload.markdownSourceMatched)
          });
        } catch (_) {}
      }

    function messageBlockKey(block, index) {
      return trimmed(block?.id) || `__message_block_${index}`;
    }

    function readexProcessingFoldGroupID(source) {
      return trimmed(source?.readexProcessingFoldGroupId || source?.readexProcessingFoldGroupID);
    }

    function readexProcessingMainTextCanJoinFold(block, blockKey = "") {
      if (block?.inlineTextSegment === true) {
        return true;
      }
      const blockID = trimmed(block?.id);
      const resolvedBlockKey = trimmed(blockKey);
      return blockID.startsWith("text_segment:")
        || blockID.includes(":text_segment:")
        || resolvedBlockKey.startsWith("text_segment:")
        || resolvedBlockKey.includes(":text_segment:");
    }

    function readexProcessingFoldEntryCanJoin(entry) {
      const block = entry?.block;
      if (block?.type !== "main_text") {
        return true;
      }
      return readexProcessingMainTextCanJoinFold(block, entry?.blockKey);
    }

    function readexProcessingChromeRole(block) {
      return trimmed(block?.readexProcessingChromeRole);
    }

    function readexProcessingBlockOwnsChrome(block) {
      return block?.type === "readex_processing" && readexProcessingChromeRole(block) !== "continuation";
    }

    function readexProcessingDetailsElement(element) {
      return Array.from(element?.children || []).find((child) => (
        child?.classList?.contains("readex-processing-details")
      )) || null;
    }

    function readexProcessingFoldOwnerEntries(entries) {
      const ownerByGroupID = new Map();
      entries.forEach((entry) => {
        const groupID = readexProcessingFoldGroupID(entry?.block);
        if (!groupID || ownerByGroupID.has(groupID) || !readexProcessingBlockOwnsChrome(entry?.block)) {
          return;
        }
        ownerByGroupID.set(groupID, entry);
      });
      return ownerByGroupID;
    }

    function readexProcessingVisualUnits(entries) {
      const ownerByGroupID = readexProcessingFoldOwnerEntries(entries);
      const entriesByGroupID = new Map();
      entries.forEach((entry) => {
        const groupID = readexProcessingFoldGroupID(entry?.block);
        if (!groupID || !ownerByGroupID.has(groupID) || !readexProcessingFoldEntryCanJoin(entry)) {
          return;
        }
        const groupEntries = entriesByGroupID.get(groupID) || [];
        groupEntries.push(entry);
        entriesByGroupID.set(groupID, groupEntries);
      });

      const emittedGroupIDs = new Set();
      const units = [];
      entries.forEach((entry) => {
        const groupID = readexProcessingFoldGroupID(entry?.block);
        const ownerEntry = groupID ? ownerByGroupID.get(groupID) : null;
        if (!groupID || !ownerEntry || !readexProcessingFoldEntryCanJoin(entry)) {
          units.push({ type: "entry", entry });
          return;
        }
        if (emittedGroupIDs.has(groupID)) {
          return;
        }
        emittedGroupIDs.add(groupID);
        units.push({
          type: "readex_processing_fold",
          groupID,
          ownerEntry,
          entries: entriesByGroupID.get(groupID) || [ownerEntry]
        });
      });
      return units;
    }

    function syncReadexProcessingFoldTarget(element) {
      const controller = window.ChatTranscriptReadexProcessingFoldController;
      if (controller && typeof controller.syncTarget === "function") {
        controller.syncTarget(element);
      }
    }

    function configureReadexProcessingFoldTarget(element, block) {
      if (!element) {
        return element;
      }
      const groupID = readexProcessingFoldGroupID(block);
      const blockKey = trimmed(element?.dataset?.blockKey);
      const canJoinFold = block?.type !== "main_text"
        || readexProcessingMainTextCanJoinFold(block, blockKey);
      if (groupID && canJoinFold) {
        element.dataset.readexProcessingFoldGroupId = groupID;
        element.classList.add("readex-processing-fold-target");
        syncReadexProcessingFoldTarget(element);
      } else {
        delete element.dataset.readexProcessingFoldGroupId;
        element.classList.remove("readex-processing-fold-target");
        element.classList.remove("is-readex-processing-fold-collapsed");
      }
      return element;
    }

    function isReadexStoppedMarkerBlock(block) {
      return block?.type === "readex_stopped_marker";
    }

    function isReadexCompletedGoalMarkerBlock(block) {
      return block?.type === "readex_completed_goal_marker";
    }

    function isReadexStatusBoundaryBlock(block) {
      return isReadexStoppedMarkerBlock(block);
    }

    function isTextSelectionBlock(block) {
      return block?.type === "text_selection";
    }

    function hasVisibleTextSelection(block) {
      return isTextSelectionBlock(block)
        && trimmed(block?.textSelection?.selectedText).length > 0;
    }

    function groupedTextSelectionBlock(entries, message) {
      const textSelectionEntries = entries.filter((entry) => hasVisibleTextSelection(entry.block));
      if (message?.role !== "user" || !textSelectionEntries.length) {
        return entries;
      }

      const firstEntry = textSelectionEntries[0];
      const groupBlock = {
        ...firstEntry.block,
        id: `${messageBlockKey(firstEntry.block, firstEntry.index)}:group`,
        type: "text_selection_group",
        textSelections: textSelectionEntries.map((entry) => entry.block.textSelection)
      };
      const groupEntry = {
        block: groupBlock,
        index: firstEntry.index,
        blockKey: messageBlockKey(groupBlock, firstEntry.index)
      };
      return [
        groupEntry,
        ...entries.filter((entry) => !isTextSelectionBlock(entry.block))
      ];
    }

    function bodyMessageBlockEntries(message) {
      const entries = renderableMessageBlocks(message)
        .map((block, index) => ({
          block,
          index,
          blockKey: messageBlockKey(block, index)
        }))
        .filter((entry) => !isReadexStatusBoundaryBlock(entry.block) && !isReadexCompletedGoalMarkerBlock(entry.block));
      return groupedTextSelectionBlock(entries, message);
    }

    function readexStatusBoundaryBlockEntry(message) {
      const blocks = renderableMessageBlocks(message);
      for (let index = blocks.length - 1; index >= 0; index -= 1) {
        const block = blocks[index];
        if (isReadexStatusBoundaryBlock(block)) {
          return {
            block,
            index,
            blockKey: messageBlockKey(block, index)
          };
        }
      }
      return null;
    }

    function isAssistantFragmentBlockKey(blockKey) {
      return /(^|:)text_segment:\d+$/.test(String(blockKey || ""));
    }

    function markdownRenderOptionsSnapshot(options) {
      const resolvedOptions = options && typeof options === "object" ? options : {};
      return {
        streaming: Boolean(resolvedOptions.streaming),
        streamingCommitImmediately: Boolean(resolvedOptions.streamingCommitImmediately),
        streamingFinalizeImmediate: Boolean(resolvedOptions.streamingFinalizeImmediate),
        progressive: Boolean(resolvedOptions.progressive),
        readexMarkdownRendererProfile: trimmed(resolvedOptions.readexMarkdownRendererProfile),
        readexMarkstreamCodeTheme: trimmed(resolvedOptions.readexMarkstreamCodeTheme),
        mathRenderer: trimmed(resolvedOptions.mathRenderer),
        mathFallbackRenderer: trimmed(resolvedOptions.mathFallbackRenderer)
      };
    }

    function markdownBlockRenderSignature(markdown, options) {
      return JSON.stringify({
        markdown: String(markdown || ""),
        ...markdownRenderOptionsSnapshot(options)
      });
    }

    function rememberMarkdownBlockRender(element, markdown, options) {
      if (!element) {
        return;
      }
      element.__chatTranscriptMarkdownSource = String(markdown || "");
      element.__chatTranscriptMarkdownRenderOptions = markdownRenderOptionsSnapshot(options);
      element.__chatTranscriptMarkdownRenderSignature = markdownBlockRenderSignature(markdown, options);
    }

    function markdownBlockRenderMatches(element, markdown, options) {
      return Boolean(element)
        && element.__chatTranscriptMarkdownRenderSignature === markdownBlockRenderSignature(markdown, options);
    }

    function rememberedMarkdownSource(element) {
      return typeof element?.__chatTranscriptMarkdownSource === "string"
        ? element.__chatTranscriptMarkdownSource
        : "";
    }

    function rememberedMarkdownRenderOptions(element) {
      const options = element?.__chatTranscriptMarkdownRenderOptions;
      return options && typeof options === "object" ? options : null;
    }

    function markdownRendererIdentityMatches(left, right) {
      if (!left || !right) {
        return false;
      }
      return trimmed(left.readexMarkdownRendererProfile) === trimmed(right.readexMarkdownRendererProfile)
        && trimmed(left.readexMarkstreamCodeTheme) === trimmed(right.readexMarkstreamCodeTheme)
        && trimmed(left.mathRenderer) === trimmed(right.mathRenderer)
        && trimmed(left.mathFallbackRenderer) === trimmed(right.mathFallbackRenderer)
        && Boolean(left.progressive) === Boolean(right.progressive);
    }

    function shouldSkipUnchangedFinalMainTextRender(element, message, text) {
      if (message?.role !== "assistant" || messageIsStreaming(message)) {
        return false;
      }
      const source = String(text || "");
      if (source !== rememberedMarkdownSource(element)) {
        return false;
      }
      return markdownRendererIdentityMatches(
        rememberedMarkdownRenderOptions(element),
        markdownRenderOptionsSnapshot(markdownRenderOptionsForBlock(message, element?.dataset?.blockKey))
      );
    }

    function shouldPatchMatchingMarkdownBlockForFinalState(element, block, message) {
      if (message?.role !== "assistant" || messageIsStreaming(message)) {
        return false;
      }
      const blockType = trimmed(block?.type);
      if (blockType !== "main_text" && blockType !== "readex_progress") {
        return false;
      }
      return rememberedMarkdownRenderOptions(element)?.streaming === true;
    }

    function shouldUseStreamingMainTextPatch(element, message, text) {
      if (message?.role !== "assistant") {
        return false;
      }
      if (!messageIsStreaming(message)) {
        return false;
      }
      const source = String(text || "");
      const previousSource = rememberedMarkdownSource(element);
      return Boolean(messageIsStreaming(message))
        || Boolean(element?.__smoothStreamingController)
        || (previousSource.length > 0 && source.startsWith(previousSource));
    }

    function shouldFinalizeStreamingMainTextPatch(element, message, text) {
      if (message?.role !== "assistant" || messageIsStreaming(message)) {
        return false;
      }
      const source = String(text || "");
      const previousSource = rememberedMarkdownSource(element);
      if (!previousSource || !source.startsWith(previousSource)) {
        return false;
      }
      return rememberedMarkdownRenderOptions(element)?.streaming === true
        || Boolean(element?.__smoothStreamingController);
    }

    function mainTextPatchRenderOptions(element, message, text) {
      const options = markdownRenderOptionsForBlock(message, element?.dataset?.blockKey);
      if (shouldUseStreamingMainTextPatch(element, message, text)) {
        options.streaming = true;
        options.streamingCommitImmediately = false;
        options.streamingFinalizeImmediate = !messageIsStreaming(message);
        options.readexStreamingLightweight = messageIsStreaming(message);
      } else if (shouldFinalizeStreamingMainTextPatch(element, message, text)) {
        options.streaming = true;
        options.streamingCommitImmediately = false;
        options.streamingFinalizeImmediate = true;
      }
      return options;
    }

    function refreshPreservedMarkdownBlockDecorators(element, block, message, renderer, blockKey) {
      const blockType = trimmed(block?.type);
      if (blockType !== "main_text" && blockType !== "readex_progress") {
        return;
      }
      if (!element || typeof element.querySelector !== "function" || !element.querySelector("a[href]")) {
        return;
      }
      refreshRenderedMarkdownDecorators(renderer, element, markdownRenderOptionsForBlock(message, blockKey));
    }

    function markdownRenderOptionsForBlock(message, blockKey) {
      const options = markdownRenderOptions(message);
      const messageKey = trimmed(message?.patchKey || message?.id || message?.messageID);
      const resolvedBlockKey = trimmed(blockKey);
      if (resolvedBlockKey) {
        options.blockKey = resolvedBlockKey;
      }
      if (messageKey || resolvedBlockKey) {
        options.readexVirtualSessionKey = [messageKey || "message", resolvedBlockKey || "block"].join(":");
      }
      const threadKey = trimmed(message?.readexTurnID || message?.readexTurnId || message?.askId || message?.askID || message?.requestId);
      if (threadKey) {
        options.readexVirtualThreadKey = threadKey;
      }
      return options;
    }

    function messageBlockSignature(block, message) {
      return JSON.stringify({
        block,
        role: message?.role
      });
    }

    function buildFooterBlock(text) {
      const footer = document.createElement("div");
      footer.className = "message-footer";
      footer.textContent = text || "";
      return footer;
    }

    function buildGoalFooterBlock(text) {
      const footer = document.createElement("div");
      footer.className = "message-footer message-goal-footer";
      const icon = document.createElement("span");
      icon.className = "message-goal-footer-icon";
      icon.setAttribute("aria-hidden", "true");
      icon.innerHTML = makeIcon("target");
      const label = document.createElement("span");
      label.className = "message-goal-footer-label";
      label.textContent = text || "设为目标";
      footer.appendChild(icon);
      footer.appendChild(label);
      return footer;
    }

    function buildPlaceholderBlock(text) {
      const placeholder = document.createElement("div");
      placeholder.className = "message-content";
      placeholder.textContent = trimmed(text) || "正在思考";
      return placeholder;
    }

    function textSelectionHighlightColor(selection) {
      const color = selection?.highlightColor || {};
      const red = Number.isFinite(Number(color.red)) ? Math.round(Number(color.red) * 255) : 255;
      const green = Number.isFinite(Number(color.green)) ? Math.round(Number(color.green) * 255) : 210;
      const blue = Number.isFinite(Number(color.blue)) ? Math.round(Number(color.blue) * 255) : 56;
      const alpha = Number.isFinite(Number(color.alpha)) ? Math.min(Math.max(Number(color.alpha), 0.12), 0.85) : 0.55;
      return `rgba(${red}, ${green}, ${blue}, ${alpha})`;
    }

    function sortedTextSelectionHighlights(selection) {
      const text = typeof selection?.selectedText === "string" ? selection.selectedText : "";
      const textLength = text.length;
      return (Array.isArray(selection?.highlightedRanges) ? selection.highlightedRanges : [])
        .map((range) => {
          const start = Math.max(0, Math.min(Number(range?.startUTF16Offset) || 0, textLength));
          const length = Math.max(0, Number(range?.utf16Length) || 0);
          const end = Math.max(start, Math.min(start + length, textLength));
          return { start, end };
        })
        .filter((range) => range.end > range.start)
        .sort((a, b) => a.start === b.start ? a.end - b.end : a.start - b.start);
    }

    function buildTextSelectionBody(selection) {
      const body = document.createElement("div");
      body.className = "text-selection-excerpt-body";
      const text = typeof selection?.selectedText === "string" ? selection.selectedText : "";
      const highlights = sortedTextSelectionHighlights(selection);
      const color = textSelectionHighlightColor(selection);
      let cursor = 0;

      highlights.forEach((range) => {
        if (range.start < cursor) {
          return;
        }
        if (range.start > cursor) {
          body.appendChild(document.createTextNode(text.slice(cursor, range.start)));
        }
        const highlight = document.createElement("mark");
        highlight.className = "text-selection-excerpt-highlight";
        highlight.style.backgroundColor = color;
        highlight.textContent = text.slice(range.start, range.end);
        body.appendChild(highlight);
        cursor = range.end;
      });

      if (cursor < text.length) {
        body.appendChild(document.createTextNode(text.slice(cursor)));
      }
      if (!body.childNodes.length) {
        body.textContent = "选中文本为空";
      }
      return body;
    }

    function normalizedTextSelectionSourceKind(selection) {
      return trimmed(selection?.sourceKind).toLowerCase();
    }

    function textSelectionSourceDisplayTitle(selection) {
      const contextName = trimmed(selection?.sourceContextDisplayName);
      if (contextName) {
        return contextName;
      }
      const displayName = trimmed(selection?.sourceDisplayName);
      const appName = trimmed(selection?.sourceApplicationName);
      switch (normalizedTextSelectionSourceKind(selection)) {
        case "pdf":
          return "文本摘录";
        case "externalapplication": {
          const name = displayName || appName;
          if (!name) {
            return "文本摘录";
          }
          const lowerName = name.toLowerCase();
          if (["safari", "google chrome", "chrome", "arc", "microsoft edge", "edge", "firefox"].includes(lowerName)) {
            return `${name}-文本摘录`;
          }
          if (lowerName === "preview" || name === "预览") {
            return "来自 Preview 的文本摘录";
          }
          return `来自 ${name} 的文本摘录`;
        }
        default:
          return displayName || "文本摘录";
      }
    }

    function textSelectionSourceMeta(selection) {
      const pageSummary = trimmed(selection?.sourcePageSummary);
      return pageSummary ? `关联页码：${pageSummary}` : "";
    }

    function buildTextSelectionAttachmentButton(block, message, blockKey) {
      const selection = block?.textSelection || {};
      const button = document.createElement("button");
      button.type = "button";
      button.className = "attachment text-selection-attachment";
      button.setAttribute("aria-label", `预览${textSelectionSourceDisplayTitle(selection)}`);

      const icon = document.createElement("span");
      icon.className = "attachment-icon";
      icon.innerHTML = makeIcon("doc");
      button.appendChild(icon);

      const label = document.createElement("span");
      label.className = "text-selection-attachment-label";
      label.textContent = textSelectionSourceDisplayTitle(selection);
      button.appendChild(label);

      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (typeof postMessageAction !== "function") {
          return;
        }
        postMessageAction({
          action: "openTextSelectionPreview",
          messageID: message?.id,
          blockKey,
          textSelectionID: selection?.id
        });
      });

      return button;
    }

    function buildTextSelectionBlock(block, message, blockKey) {
      const selection = block?.textSelection || {};
      if (hasMessageActionHandler()) {
        return buildTextSelectionAttachmentButton(block, message, blockKey);
      }

      const card = document.createElement("section");
      card.className = "text-selection-excerpt-card";

      const header = document.createElement("div");
      header.className = "text-selection-excerpt-header";

      const title = document.createElement("div");
      title.className = "text-selection-excerpt-title";
      title.textContent = textSelectionSourceDisplayTitle(selection);
      header.appendChild(title);

      const highlightCount = sortedTextSelectionHighlights(selection).length;
      const meta = document.createElement("div");
      meta.className = "text-selection-excerpt-meta";
      const sourceMeta = textSelectionSourceMeta(selection);
      const highlightMeta = highlightCount > 0 ? `${highlightCount} 处高亮` : "未高亮";
      meta.textContent = sourceMeta ? `${highlightMeta} · ${sourceMeta}` : highlightMeta;
      header.appendChild(meta);

      card.appendChild(header);
      card.appendChild(buildTextSelectionBody(selection));
      return card;
    }

    function normalizedTextSelectionPreviewText(selection) {
      const text = typeof selection?.selectedText === "string" ? selection.selectedText : "";
      const collapsed = text.split(/\s+/).filter(Boolean).join(" ").trim();
      return collapsed || "空文本";
    }

    function buildTextSelectionReferencePreview(selections) {
      const preview = document.createElement("div");
      preview.className = "selected-text-reference-preview";

      selections.forEach((selection) => {
        const item = document.createElement("div");
        item.className = "selected-text-reference-preview-item";
        item.textContent = `“${normalizedTextSelectionPreviewText(selection)}”`;
        preview.appendChild(item);
      });

      return preview;
    }

    function textSelectionReferencePreviewSegments(selections) {
      return selections
        .map(normalizedTextSelectionPreviewText)
        .map((text) => trimmed(text))
        .filter(Boolean);
    }

    function textSelectionReferencePreviewID(block, selections) {
      const blockID = trimmed(block?.id || block?.blockID || block?.key);
      if (blockID) {
        return blockID;
      }
      const selectionIDs = selections
        .map((selection) => trimmed(selection?.id || selection?.textSelectionID))
        .filter(Boolean)
        .join("|");
      if (selectionIDs) {
        return selectionIDs;
      }
      return `selected_text_reference_${textSelectionReferencePreviewSegments(selections).join("|").slice(0, 96)}`;
    }

    function viewportRectPayloadForElement(element) {
      const rect = element.getBoundingClientRect();
      return {
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height
      };
    }

    function postTextSelectionReferencePreviewEvent(action, previewID, chip, segments) {
      if (typeof postMessageAction !== "function" || !previewID) {
        return;
      }
      const payload = { action, previewID };
      if (action === "showTextSelectionReferencePreview") {
        payload.anchorRect = viewportRectPayloadForElement(chip);
        payload.segments = segments;
      }
      postMessageAction(payload);
    }

    function configureNativeTextSelectionReferencePreview(chip, block, selections) {
      if (typeof postMessageAction !== "function") {
        return false;
      }
      const segments = textSelectionReferencePreviewSegments(selections);
      if (!segments.length) {
        return false;
      }
      const previewID = textSelectionReferencePreviewID(block, selections);
      chip.dataset.nativePreview = "true";

      const showPreview = () => postTextSelectionReferencePreviewEvent(
        "showTextSelectionReferencePreview",
        previewID,
        chip,
        segments
      );
      const hidePreview = () => postTextSelectionReferencePreviewEvent(
        "hideTextSelectionReferencePreview",
        previewID,
        chip,
        segments
      );

      chip.addEventListener("mouseenter", showPreview);
      chip.addEventListener("mouseleave", hidePreview);
      chip.addEventListener("focusin", showPreview);
      chip.addEventListener("focusout", hidePreview);
      return true;
    }

    function buildTextSelectionGroupBlock(block) {
      const selections = (Array.isArray(block?.textSelections) ? block.textSelections : [])
        .filter((selection) => trimmed(selection?.selectedText).length > 0);
      if (!selections.length) {
        return null;
      }

      const root = document.createElement("div");
      root.className = "selected-text-reference-block";

      const chip = document.createElement("div");
      chip.className = "selected-text-reference-chip";

      const icon = document.createElement("span");
      icon.className = "selected-text-reference-icon";
      icon.innerHTML = makeIcon("bubble.left") || makeIcon("doc") || "";
      chip.appendChild(icon);

      const label = document.createElement("span");
      label.className = "selected-text-reference-label";
      label.textContent = `${selections.length} 个已选文本片段`;
      chip.appendChild(label);

      chip.appendChild(buildTextSelectionReferencePreview(selections));
      configureNativeTextSelectionReferencePreview(chip, block, selections);
      root.appendChild(chip);
      return root;
    }

    function generatedImageSource(image) {
      if (typeof image === "string") {
        return trimmed(image);
      }
      if (!image || typeof image !== "object") {
        return "";
      }

      const url = trimmed(image.url || image.uri || image.link || image.src);
      if (url) {
        return url;
      }

      const base64 = trimmed(image.base64 || image.b64_json || image.b64 || image.data);
      if (base64) {
        if (/^data:/i.test(base64)) {
          return base64;
        }
        return `data:${trimmed(image.mimeType || image.mediaType) || "image/png"};base64,${base64}`;
      }

      const filePath = trimmed(image.filePath || image.path);
      if (filePath) {
        if (/^file:/i.test(filePath)) {
          return filePath;
        }
        if (filePath.startsWith("/")) {
          return `file://${filePath}`;
        }
      }

      return "";
    }

    function openGeneratedImagePreview(image, src, index) {
      if (typeof postMessageAction !== "function") {
        return;
      }
      postMessageAction({
        action: "openGeneratedImagePreview",
        image,
        src,
        imageIndex: index
      });
    }

    function buildImageBlock(block) {
      const images = Array.isArray(block?.images) ? block.images : [];
      const container = document.createElement("div");
      container.className = "generated-image-block";

      if (!images.length) {
        const placeholder = document.createElement("div");
        placeholder.className = "generated-image-placeholder";
        placeholder.textContent = block?.status === "processing" ? "正在生成图片…" : "图片暂不可用";
        container.appendChild(placeholder);
        return container;
      }

      const grid = document.createElement("div");
      grid.className = "generated-image-grid";
      images.forEach((image, index) => {
        const src = generatedImageSource(image);
        if (!src) {
          return;
        }
        const element = document.createElement("img");
        element.className = "generated-image";
        element.src = src;
        element.alt = `生成的图片 ${index + 1}`;
        element.loading = "eager";
        element.decoding = "async";
        element.tabIndex = 0;
        element.setAttribute("role", "button");
        element.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          openGeneratedImagePreview(image, src, index);
        });
        element.addEventListener("keydown", (event) => {
          if (event.key !== "Enter" && event.key !== " ") {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          openGeneratedImagePreview(image, src, index);
        });
        grid.appendChild(element);
      });

      if (!grid.children.length) {
        const placeholder = document.createElement("div");
        placeholder.className = "generated-image-placeholder";
        placeholder.textContent = "图片暂不可用";
        container.appendChild(placeholder);
        return container;
      }

      container.appendChild(grid);
      return container;
    }

    function findArticleByMessageKey(messagesRoot, messageKey) {
      const key = trimmed(messageKey);
      if (!messagesRoot || !key) {
        return null;
      }
      return Array.from(messagesRoot.querySelectorAll?.("article.message") || [])
        .find((article) => trimmed(article?.dataset?.messageKey) === key) || null;
    }

    function findMainTextBlockElement(article, blockKey) {
      const key = trimmed(blockKey);
      if (!article || !key) {
        return null;
      }
      return Array.from(article.querySelectorAll?.("[data-block-type='main_text']") || [])
        .find((element) => trimmed(element?.dataset?.blockKey) === key) || null;
    }

    function findMessageBlockElement(article, blockKey, blockType) {
      const key = trimmed(blockKey);
      const type = trimmed(blockType);
      if (!article || !key) {
        return null;
      }
      return Array.from(article.querySelectorAll?.("[data-block-key]") || [])
        .find((element) => (
          trimmed(element?.dataset?.blockKey) === key
          && (!type || trimmed(element?.dataset?.blockType) === type)
        )) || null;
    }

    function applyMarkdownBlockSourceUpdate(update, renderer, messagesRoot) {
      const messageKey = trimmed(update?.messageKey);
      const block = update?.block && typeof update.block === "object" ? update.block : null;
      const blockKey = trimmed(update?.blockID || block?.id);
      const article = findArticleByMessageKey(messagesRoot, messageKey);
      const element = findMainTextBlockElement(article, blockKey);
      if (!article || !element || !block) {
        return {
          applied: false,
          reason: !article ? "missing_article" : (!element ? "missing_block_element" : "missing_block"),
          messageKey,
          blockKey
        };
      }

      const message = article.__chatTranscriptMessage || {};
      const text = blockText(block);
      const renderOptions = mainTextPatchRenderOptions(element, message, text);
      const previousTextLength = rememberedMarkdownSource(element).length;
      const shouldCaptureRenderPerf = renderOptions.readexStreamingLightweight !== true
        && renderPerfProbeEnabled();
      const renderStartedAt = renderPerfNow();
      const documentBefore = shouldCaptureRenderPerf ? renderPerfDocumentSnapshot() : null;
      const metrics = renderMarkdownIntoElement(renderer, element, text, renderOptions);
      const elapsedMs = renderPerfNow() - renderStartedAt;
      const mutationDelta = shouldCaptureRenderPerf ? renderPerfDocumentDelta(documentBefore) : null;
      const rememberedRenderOptions = metrics?.lightweightFinalizeUpdate === true
        ? markdownRenderOptionsForBlock(message, blockKey)
        : renderOptions;
      rememberMarkdownBlockRender(element, text, rememberedRenderOptions);
      element.__chatTranscriptSignature = messageBlockSignature(block, message);
      if (renderOptions.readexStreamingLightweight !== true) {
        postMainTextRenderProbe("main_text_streaming_direct", message, blockKey, text, metrics, renderOptions);
        postBlockDOMReconcileProbe("main_text_streaming_direct", message, block, blockKey, {
          renderPhase: "streaming_direct",
          previousTextLength,
          elapsedMs,
          renderOptions: markdownRenderOptionsSnapshot(renderOptions),
          metrics: metricsProbePayload(metrics)
        });
      }
      if (shouldCaptureRenderPerf) {
        postRenderPerfProbe("main_text_streaming_direct", message, block, blockKey, text, {
          renderPhase: "streaming_direct",
          elapsedMs,
          previousTextLength,
          renderOptions: markdownRenderOptionsSnapshot(renderOptions),
          metrics: metricsProbePayload(metrics),
          beforeElement: null,
          afterElement: elementRenderPerfPayload(element),
          mutationDelta
        });
      }
      return {
        applied: true,
        reason: "updated",
        messageKey,
        blockKey,
        previousTextLength,
        textLength: String(text || "").length
      };
    }

    function applyProcessingBlockSourceUpdate(update, renderer, messagesRoot) {
      const messageKey = trimmed(update?.messageKey);
      const block = update?.block && typeof update.block === "object" ? update.block : null;
      const blockKey = trimmed(update?.blockID || block?.id);
      const article = findArticleByMessageKey(messagesRoot, messageKey);
      const existing = findMessageBlockElement(article, blockKey, "readex_processing");
      if (!article || !existing || !block) {
        return {
          applied: false,
          reason: !article ? "missing_article" : (!existing ? "missing_block_element" : "missing_block"),
          messageKey,
          blockKey
        };
      }

      const message = article.__chatTranscriptMessage || {};
      const element = createOrPatchMessageBlockElement(
        existing,
        { block, blockKey },
        message,
        renderer
      );
      if (!element) {
        return {
          applied: false,
          reason: "patch_returned_null",
          messageKey,
          blockKey
        };
      }

      postBlockDOMReconcileProbe("readex_processing_direct", message, block, blockKey, {
        renderPhase: "streaming_direct"
      });
      return {
        applied: true,
        reason: "updated",
        messageKey,
        blockKey,
        textLength: 0
      };
    }

    function buildMainTextBlock(block, message, renderer, blockKey) {
      const resolvedBlockKey = trimmed(blockKey) || messageBlockKey(block, 0);
      const isAssistantFragment = message?.role === "assistant" && isAssistantFragmentBlockKey(resolvedBlockKey);
      const container = document.createElement("div");
      container.className = isAssistantFragment ? "assistant-fragment" : "message-content";
      const text = blockText(block);

        if (message?.role === "user") {
          container.innerHTML = renderer.renderUserHTML(text);
        } else {
          const renderOptions = markdownRenderOptionsForBlock(message, resolvedBlockKey);
          const renderStartedAt = renderPerfNow();
          const documentBefore = renderPerfDocumentSnapshot();
          const metrics = renderMarkdownIntoElement(renderer, container, text, renderOptions);
          const elapsedMs = renderPerfNow() - renderStartedAt;
          const mutationDelta = renderPerfDocumentDelta(documentBefore);
          rememberMarkdownBlockRender(container, text, renderOptions);
          postMainTextRenderProbe("main_text_build", message, resolvedBlockKey, text, metrics, renderOptions);
          postBlockDOMReconcileProbe("main_text_markdown_render", message, block, resolvedBlockKey, {
            renderPhase: "build",
            elapsedMs,
            renderOptions: markdownRenderOptionsSnapshot(renderOptions),
            metrics: metricsProbePayload(metrics)
          });
          postRenderPerfProbe("main_text_markdown_render", message, block, resolvedBlockKey, text, {
            renderPhase: "build",
            elapsedMs,
            renderOptions: markdownRenderOptionsSnapshot(renderOptions),
            metrics: metricsProbePayload(metrics),
            beforeElement: null,
            afterElement: elementRenderPerfPayload(container),
            mutationDelta
          });
        }

      return container;
    }

    function readexToolActivityBlockFromToolCall(block) {
      const items = Array.isArray(block?.items) && block.items.length > 0
        ? block.items
        : [{
          type: "tool",
          text: blockText(block),
          detailText: block?.detailText || "",
          previewItems: Array.isArray(block?.previewItems) ? block.previewItems : [],
          toolBatchId: block?.toolBatchId || block?.toolBatchID || block?.readexToolBatchID || block?.readexToolBatchId || "",
          status: block?.status,
          durationMilliseconds: block?.durationMilliseconds
        }];
      return {
        ...block,
        type: "readex_tool_activity",
        items
      };
    }

    function proposedPlanStateMap() {
      if (!(window.__readexProposedPlanCollapsedByKey instanceof Map)) {
        window.__readexProposedPlanCollapsedByKey = new Map();
      }
      return window.__readexProposedPlanCollapsedByKey;
    }

    function proposedPlanStateKey(block, blockKey) {
      return trimmed(block?.id || block?.blockID || block?.blockId || blockKey) || "proposed-plan";
    }

    function proposedPlanIsCollapsed(block, blockKey) {
      return proposedPlanStateMap().get(proposedPlanStateKey(block, blockKey)) === true;
    }

    function setProposedPlanCollapsed(block, blockKey, collapsed) {
      proposedPlanStateMap().set(proposedPlanStateKey(block, blockKey), Boolean(collapsed));
    }

    function proposedPlanActionButton(label, iconName, action, actionName) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "readex-proposed-plan-action";
      button.setAttribute("aria-label", label);
      button.title = label;
      if (actionName) {
        button.dataset.planAction = actionName;
      }
      button.innerHTML = makeIcon(iconName);
      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        action(button);
      });
      return button;
    }

    function copyProposedPlanText(text, button) {
      const copyText = String(text || "");
      const mark = (className) => {
        button.classList.add(className);
        window.setTimeout(() => button.classList.remove(className), 900);
      };
      if (navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(copyText).then(
          () => mark("is-copied"),
          () => mark("is-error")
        );
        return;
      }
      try {
        const textarea = document.createElement("textarea");
        textarea.value = copyText;
        textarea.setAttribute("readonly", "true");
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand("copy");
        textarea.remove();
        mark("is-copied");
      } catch (_) {
        mark("is-error");
      }
    }

    function downloadProposedPlanText(text) {
      try {
        const blob = new Blob([String(text || "")], { type: "text/markdown;charset=utf-8" });
        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = "PLAN.md";
        document.body.appendChild(link);
        link.click();
        link.remove();
        window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      } catch (_) {}
    }

    function proposedPlanCurrentData(source, fallback) {
      const card = source?.closest?.(".readex-proposed-plan-card");
      return card?.__readexProposedPlanData || fallback || {};
    }

    function openProposedPlanPreview(block, message, blockKey, text) {
      const markdown = String(text || "").trim();
      if (!markdown || typeof postMessageAction !== "function") {
        return;
      }
      const title = trimmed(block?.phaseTitle) || "计划";
      postMessageAction({
        action: "openReadexSupportPreview",
        preview: {
          kind: "markdown",
          title,
          documentName: title,
          markdown,
          payload: {
            source: "proposed_plan",
            messageID: trimmed(message?.id || message?.messageID),
            blockKey: trimmed(blockKey),
            blockID: trimmed(block?.id || block?.blockID || block?.blockId)
          }
        }
      });
    }

    function proposedPlanIsStreaming(block, message) {
      return trimmed(block?.status).toLowerCase() !== "completed" && messageIsStreaming(message);
    }

    function proposedPlanMarkdown(block, message) {
      const text = blockText(block);
      return text || (proposedPlanIsStreaming(block, message) ? "正在生成计划..." : "");
    }

    function proposedPlanMarkdownRenderOptions(message, blockKey, isStreaming) {
      const options = markdownRenderOptionsForBlock(message, blockKey);
      if (isStreaming) {
        options.streaming = true;
        options.streamingCommitImmediately = false;
        options.streamingFinalizeImmediate = false;
      }
      return options;
    }

    function renderProposedPlanMarkdown(body, block, message, renderer, blockKey) {
      const isStreaming = proposedPlanIsStreaming(block, message);
      const markdown = proposedPlanMarkdown(block, message);
      const renderOptions = proposedPlanMarkdownRenderOptions(message, blockKey, isStreaming);
      if (!markdownBlockRenderMatches(body, markdown, renderOptions)) {
        renderMarkdownIntoElement(renderer, body, markdown, renderOptions);
        rememberMarkdownBlockRender(body, markdown, renderOptions);
      }
    }

    function updateProposedPlanHeader(card, block, message, blockKey) {
      const isStreaming = proposedPlanIsStreaming(block, message);
      const collapsed = proposedPlanIsCollapsed(block, blockKey);
      card.classList.toggle("is-streaming", isStreaming);
      card.classList.toggle("is-collapsed", collapsed);

      const label = card.querySelector(".readex-proposed-plan-title-label");
      if (label) {
        label.textContent = trimmed(block?.phaseTitle) || "计划";
      }

      const collapseButton = card.querySelector("[data-plan-action='collapse']");
      if (collapseButton) {
        const labelText = collapsed ? "展开计划" : "折叠计划";
        collapseButton.setAttribute("aria-label", labelText);
        collapseButton.title = labelText;
        collapseButton.innerHTML = makeIcon(collapsed ? "chevron-right" : "chevron-down");
      }
    }

    function buildProposedPlanBlock(block, message, renderer, blockKey) {
      const text = blockText(block);
      const isStreaming = proposedPlanIsStreaming(block, message);
      const collapsed = proposedPlanIsCollapsed(block, blockKey);
      const card = document.createElement("section");
      card.className = "readex-proposed-plan-card";
      card.classList.toggle("is-streaming", isStreaming);
      card.classList.toggle("is-collapsed", collapsed);
      card.__readexProposedPlanData = { block, message, blockKey, text };

      const header = document.createElement("div");
      header.className = "readex-proposed-plan-header";
      const title = document.createElement("div");
      title.className = "readex-proposed-plan-title";
      const label = document.createElement("span");
      label.className = "readex-proposed-plan-title-label";
      label.textContent = trimmed(block?.phaseTitle) || "计划";
      title.appendChild(label);
      header.appendChild(title);

      const actions = document.createElement("div");
      actions.className = "readex-proposed-plan-actions";
      if (typeof postMessageAction === "function") {
        actions.appendChild(proposedPlanActionButton("打开计划", "doc.text.magnifyingglass", () => {
          const data = proposedPlanCurrentData(card, { block, message, blockKey, text });
          openProposedPlanPreview(data.block, data.message, data.blockKey, data.text);
        }, "open"));
      }
      actions.appendChild(proposedPlanActionButton("下载 PLAN.md", "doc", () => {
        downloadProposedPlanText(proposedPlanCurrentData(card, { text }).text);
      }, "download"));
      actions.appendChild(proposedPlanActionButton("复制计划", "doc.on.doc", (button) => {
        copyProposedPlanText(proposedPlanCurrentData(button, { text }).text, button);
      }, "copy"));
      actions.appendChild(proposedPlanActionButton(collapsed ? "展开计划" : "折叠计划", collapsed ? "chevron-right" : "chevron-down", () => {
        const nextCollapsed = !card.classList.contains("is-collapsed");
        const data = proposedPlanCurrentData(card, { block, blockKey });
        setProposedPlanCollapsed(data.block, data.blockKey, nextCollapsed);
        card.classList.toggle("is-collapsed", nextCollapsed);
        body.hidden = nextCollapsed;
        updateProposedPlanHeader(card, data.block, data.message || message, data.blockKey);
      }, "collapse"));
      header.appendChild(actions);
      card.appendChild(header);

      const body = document.createElement("div");
      body.className = "readex-proposed-plan-body markdown-body";
      body.hidden = collapsed;
      renderProposedPlanMarkdown(body, block, message, renderer, blockKey);
      card.appendChild(body);
      return card;
    }

    function updateProposedPlanBlockElement(element, block, message, renderer, blockKey) {
      const text = blockText(block);
      element.__readexProposedPlanData = { block, message, blockKey, text };
      updateProposedPlanHeader(element, block, message, blockKey);

      let body = element.querySelector(".readex-proposed-plan-body");
      if (!body) {
        body = document.createElement("div");
        body.className = "readex-proposed-plan-body markdown-body";
        element.appendChild(body);
      }
      body.hidden = proposedPlanIsCollapsed(block, blockKey);
      renderProposedPlanMarkdown(body, block, message, renderer, blockKey);
      return element;
    }

    function renderMessageBlock(block, message, renderer, blockKey) {
      if (!block || typeof block.type !== "string") {
        return null;
      }

      switch (block.type) {
        case "thinking":
          return renderThinkingBlock(block, renderer, message, blockKey);
        case "reasoning_summary":
          return renderReasoningSummaryBlock(block, renderer, message, blockKey);
        case "reasoning_activity":
          return renderReasoningActivityBlock(block, renderer, message, blockKey);
        case "readex_processing":
          return renderReadexProcessingBlock(block, renderer, message, blockKey);
        case "readex_stopped_marker":
          return renderReadexStoppedMarkerBlock(block, blockKey);
        case "readex_context_status":
          return renderReadexContextStatusBlock(block, renderer, message, blockKey);
        case "readex_progress":
          return buildMainTextBlock({ ...block, type: "main_text" }, message, renderer, blockKey);
        case "readex_video_progress":
          return renderReadexVideoProgressBlock(block, blockKey);
        case "proposed_plan":
          return buildProposedPlanBlock(block, message, renderer, blockKey);
        case "readex_tool_activity":
          return renderReadexToolActivityBlock(block, renderer, message, blockKey);
        case "readex_tool_call":
          return renderReadexToolActivityBlock(
            readexToolActivityBlockFromToolCall(block),
            renderer,
            message,
            blockKey
          );
        case "main_text":
          return buildMainTextBlock(block, message, renderer, blockKey);
        case "citation":
        case "search_results":
          return renderSearchResultsBlock(block.searchReferences || [], message, blockKey, block.searchQueries || [], block.status, block.webSearchActions || []);
        case "sources":
          return renderReadexSourcesBlock(block, message, blockKey);
        case "image":
          return buildImageBlock(block);
        case "search_progress":
          return renderSearchProgressBlock();
        case "attachments":
          return renderAttachments(block.attachments || message?.attachments || [], message?.id || "");
        case "text_selection_group":
          return buildTextSelectionGroupBlock(block);
        case "text_selection":
          return buildTextSelectionBlock(block, message, blockKey);
        case "footer":
          return buildFooterBlock(blockText(block));
        case "goal_footer":
          return buildGoalFooterBlock(blockText(block));
        case "placeholder":
          return buildPlaceholderBlock(blockText(block));
        default:
          return null;
      }
    }

    function updateStaticMessageBlockElement(element, signature, blockType, blockKey, buildElement) {
      if (element.__chatTranscriptSignature === signature) {
        return element;
      }
      const replacement = buildElement();
      if (!replacement) {
        element.remove();
        return null;
      }
      replacement.dataset.blockKey = blockKey;
      replacement.dataset.blockType = blockType;
      replacement.__chatTranscriptSignature = signature;
      element.replaceWith(replacement);
      return replacement;
    }

    function patchMessageBlockElement(element, block, message, renderer, blockKey) {
      const signature = messageBlockSignature(block, message);
      const blockType = block.type;

      switch (blockType) {
        case "thinking":
          updateThinkingBlockElement(element, block, renderer, message, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        case "reasoning_summary":
          updateReasoningSummaryBlockElement(element, block, renderer, message, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        case "reasoning_activity":
          updateReasoningActivityBlockElement(element, block, renderer, message, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        case "readex_processing":
          updateReadexProcessingBlockElement(element, block, renderer, message, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        case "readex_stopped_marker":
          updateReadexStoppedMarkerBlockElement(element, block, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        case "readex_context_status": {
          const nextElement = updateReadexContextStatusBlockElement(element, block, renderer, message, blockKey);
          if (!nextElement) {
            return null;
          }
          nextElement.dataset.blockKey = blockKey;
          nextElement.dataset.blockType = blockType;
          nextElement.__chatTranscriptSignature = signature;
          return nextElement;
        }
          case "readex_progress": {
            const progressBlock = { ...block, type: "main_text" };
            const isAssistantFragment = message?.role === "assistant" && isAssistantFragmentBlockKey(blockKey);
            element.className = isAssistantFragment ? "assistant-fragment" : "message-content";
            element.dataset.blockKey = blockKey;
            element.dataset.blockType = blockType;
            const text = blockText(progressBlock);
            const renderOptions = markdownRenderOptionsForBlock(message, blockKey);
            const previousTextLength = rememberedMarkdownSource(element).length;
            if (!markdownBlockRenderMatches(element, text, renderOptions)) {
              const metrics = renderMarkdownIntoElement(renderer, element, text, renderOptions);
              rememberMarkdownBlockRender(element, text, renderOptions);
              postBlockDOMReconcileProbe("readex_progress_markdown_render", message, block, blockKey, {
                renderPhase: "patch",
                previousTextLength,
                renderOptions: markdownRenderOptionsSnapshot(renderOptions),
                metrics: metricsProbePayload(metrics)
              });
            } else {
              postBlockDOMReconcileProbe("readex_progress_markdown_reuse", message, block, blockKey, {
                renderPhase: "patch",
                previousTextLength,
                renderOptions: markdownRenderOptionsSnapshot(renderOptions)
              });
            }
            element.__chatTranscriptSignature = signature;
            return element;
          }
        case "readex_video_progress":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => renderReadexVideoProgressBlock(block, blockKey)
          );
        case "proposed_plan":
          updateProposedPlanBlockElement(element, block, message, renderer, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        case "readex_tool_activity":
          updateReadexToolActivityBlockElement(element, block, renderer, message, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        case "readex_tool_call": {
          const activityBlock = readexToolActivityBlockFromToolCall(block);
          updateReadexToolActivityBlockElement(element, activityBlock, renderer, message, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        }
        case "main_text": {
          const isAssistantFragment = message?.role === "assistant" && isAssistantFragmentBlockKey(blockKey);
          element.className = isAssistantFragment ? "assistant-fragment" : "message-content";
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          const text = blockText(block);
          if (message?.role === "user") {
            const nextHTML = renderer.renderUserHTML(text);
            if (element.__chatTranscriptSignature !== signature || element.innerHTML !== nextHTML) {
              element.innerHTML = nextHTML;
            }
            } else {
              if (shouldSkipUnchangedFinalMainTextRender(element, message, text)) {
                const skipPreviousTextLength = rememberedMarkdownSource(element).length;
                const skipRenderOptions = markdownRenderOptionsForBlock(message, blockKey);
                const skipBeforeElement = readexMarkdownElementProbePayload(element);
                const skipSourceMatched = String(text || "") === rememberedMarkdownSource(element);
                const skipSignatureMatched = markdownBlockRenderMatches(element, text, skipRenderOptions);
                const documentBefore = renderPerfDocumentSnapshot();
                refreshRenderedMarkdownDecorators(renderer, element, skipRenderOptions);
                const mutationDelta = renderPerfDocumentDelta(documentBefore);
                rememberMarkdownBlockRender(element, text, markdownRenderOptionsForBlock(message, blockKey));
                element.__chatTranscriptSignature = signature;
                postBlockDOMReconcileProbe("main_text_skip_unchanged_final", message, block, blockKey, {
                  renderPhase: "patch",
                  previousTextLength: skipPreviousTextLength
                });
                postReadexMarkdownRemeasureProbe("main_text_skip_unchanged_final", message, block, blockKey, text, {
                  renderPhase: "patch",
                  reason: "unchanged_final_skip",
                  previousTextLength: skipPreviousTextLength,
                  renderOptions: markdownRenderOptionsSnapshot(skipRenderOptions),
                  beforeElement: skipBeforeElement,
                  afterElement: readexMarkdownElementProbePayload(element),
                  signatureMatched: skipSignatureMatched,
                  markdownSourceMatched: skipSourceMatched
                });
                scheduleReadexMarkdownLayoutOverlapProbe(element, skipRenderOptions, "main_text_skip_unchanged_final");
                postRenderPerfProbe("main_text_skip_unchanged_final", message, block, blockKey, text, {
                  renderPhase: "patch",
                  elapsedMs: 0,
                  previousTextLength: skipPreviousTextLength,
                  renderOptions: markdownRenderOptionsSnapshot(skipRenderOptions),
                  beforeElement: elementRenderPerfPayload(element),
                  afterElement: elementRenderPerfPayload(element),
                  mutationDelta
                });
                return element;
              }
              const renderOptions = mainTextPatchRenderOptions(element, message, text);
              const previousTextLength = rememberedMarkdownSource(element).length;
              if (!markdownBlockRenderMatches(element, text, renderOptions)) {
                const beforeElement = elementRenderPerfPayload(element);
                const beforeLayoutElement = readexMarkdownElementProbePayload(element);
                const documentBefore = renderPerfDocumentSnapshot();
                const renderStartedAt = renderPerfNow();
                const metrics = renderMarkdownIntoElement(renderer, element, text, renderOptions);
                const elapsedMs = renderPerfNow() - renderStartedAt;
                const mutationDelta = renderPerfDocumentDelta(documentBefore);
                rememberMarkdownBlockRender(element, text, renderOptions);
                postMainTextRenderProbe("main_text_patch", message, blockKey, text, metrics, renderOptions);
                postBlockDOMReconcileProbe("main_text_markdown_render", message, block, blockKey, {
                  renderPhase: "patch",
                  previousTextLength,
                  elapsedMs,
                  renderOptions: markdownRenderOptionsSnapshot(renderOptions),
                  metrics: metricsProbePayload(metrics)
                });
                postReadexMarkdownRemeasureProbe("main_text_markdown_render", message, block, blockKey, text, {
                  renderPhase: "patch",
                  reason: "signature_changed",
                  previousTextLength,
                  renderOptions: markdownRenderOptionsSnapshot(renderOptions),
                  metrics: metricsProbePayload(metrics),
                  beforeElement: beforeLayoutElement,
                  afterElement: readexMarkdownElementProbePayload(element),
                  signatureMatched: false,
                  markdownSourceMatched: String(text || "") === rememberedMarkdownSource(element)
                });
                scheduleReadexMarkdownLayoutOverlapProbe(element, renderOptions, "main_text_markdown_render");
                postRenderPerfProbe("main_text_markdown_render", message, block, blockKey, text, {
                  renderPhase: "patch",
                  elapsedMs,
                  previousTextLength,
                  renderOptions: markdownRenderOptionsSnapshot(renderOptions),
                  metrics: metricsProbePayload(metrics),
                  beforeElement,
                  afterElement: elementRenderPerfPayload(element),
                  mutationDelta
                });
              } else {
                const documentBefore = renderPerfDocumentSnapshot();
                const mutationDelta = renderPerfDocumentDelta(documentBefore);
                postBlockDOMReconcileProbe("main_text_markdown_reuse", message, block, blockKey, {
                  renderPhase: "patch",
                  previousTextLength,
                  renderOptions: markdownRenderOptionsSnapshot(renderOptions)
                });
                postReadexMarkdownRemeasureProbe("main_text_markdown_reuse", message, block, blockKey, text, {
                  renderPhase: "patch",
                  reason: "signature_match",
                  previousTextLength,
                  renderOptions: markdownRenderOptionsSnapshot(renderOptions),
                  beforeElement: readexMarkdownElementProbePayload(element),
                  afterElement: readexMarkdownElementProbePayload(element),
                  signatureMatched: true,
                  markdownSourceMatched: String(text || "") === rememberedMarkdownSource(element)
                });
                scheduleReadexMarkdownLayoutOverlapProbe(element, renderOptions, "main_text_markdown_reuse");
                postRenderPerfProbe("main_text_markdown_reuse", message, block, blockKey, text, {
                  renderPhase: "patch",
                  elapsedMs: 0,
                  previousTextLength,
                  renderOptions: markdownRenderOptionsSnapshot(renderOptions),
                  beforeElement: elementRenderPerfPayload(element),
                  afterElement: elementRenderPerfPayload(element),
                  mutationDelta
                });
              }
            }
          element.__chatTranscriptSignature = signature;
          return element;
        }
        case "citation":
        case "search_results":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => renderSearchResultsBlock(block.searchReferences || [], message, blockKey, block.searchQueries || [], block.status, block.webSearchActions || [])
          );
        case "sources":
          updateReadexSourcesBlockElement(element, block, message, blockKey);
          element.dataset.blockKey = blockKey;
          element.dataset.blockType = blockType;
          element.__chatTranscriptSignature = signature;
          return element;
        case "image":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => buildImageBlock(block)
          );
        case "search_progress":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => renderSearchProgressBlock()
          );
        case "attachments":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => renderAttachments(block.attachments || message?.attachments || [], message?.id || "")
          );
        case "text_selection_group":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => buildTextSelectionGroupBlock(block)
          );
        case "text_selection":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => buildTextSelectionBlock(block, message, blockKey)
          );
        case "footer":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => buildFooterBlock(blockText(block))
          );
        case "goal_footer":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => buildGoalFooterBlock(blockText(block))
          );
        case "placeholder":
          return updateStaticMessageBlockElement(
            element,
            signature,
            blockType,
            blockKey,
            () => buildPlaceholderBlock(blockText(block))
          );
        default:
          return null;
      }
    }

    function blockElementsOwnedByRoot(root) {
      return Array.from(root?.children || []).filter((element) => element?.dataset?.blockKey);
    }

    function nestedReadexProcessingFoldBlockElements(root) {
      return Array.from(root?.querySelectorAll?.(".readex-processing-details > [data-block-key]") || []);
    }

    function blockElementsOwnedByMessage(root) {
      const seen = new Set();
      return [
        ...blockElementsOwnedByRoot(root),
        ...nestedReadexProcessingFoldBlockElements(root)
      ].filter((element) => {
        if (!element || seen.has(element)) {
          return false;
        }
        seen.add(element);
        return true;
      });
    }

    function createOrPatchMessageBlockElement(existing, entry, message, renderer) {
      const block = entry.block;
      const blockKey = entry.blockKey;
      let element = existing || null;
      const signature = messageBlockSignature(block, message);
      if (!element || element.dataset.blockType !== block.type) {
        element = renderMessageBlock(block, message, renderer, blockKey);
        if (!element) {
          return null;
        }
      } else if (
        element.__chatTranscriptSignature !== signature ||
        shouldPatchMatchingMarkdownBlockForFinalState(element, block, message)
      ) {
        element = patchMessageBlockElement(element, block, message, renderer, blockKey);
        if (!element) {
          return null;
        }
      } else {
        refreshPreservedMarkdownBlockDecorators(element, block, message, renderer, blockKey);
      }
      element.dataset.blockKey = blockKey;
      element.dataset.blockType = block.type;
      element.__chatTranscriptSignature = signature;
      configureReadexProcessingFoldTarget(element, entry.block);
      return element;
    }

    function readexProcessingFoldDetailsIsExpanded(ownerElement) {
      return ownerElement?.__chatTranscriptReadexProcessingExpanded !== false;
    }

    function retargetReadexProcessingFoldDetailsOpenAnimation(ownerElement, reason) {
      const controller = window.ChatTranscriptReadexProcessingFoldController;
      if (controller && typeof controller.retargetOpenDetails === "function") {
        controller.retargetOpenDetails(ownerElement, reason);
      }
    }

    function ensureReadexProcessingFoldDetailsElement(ownerElement) {
      let details = readexProcessingDetailsElement(ownerElement);
      if (details) {
        details.className = "readex-processing-details";
        details.hidden = false;
        return details;
      }
      details = document.createElement("div");
      details.className = "readex-processing-details";
      details.hidden = false;
      ownerElement.appendChild(details);
      return details;
    }

    function readexProcessingOwnedDetailItemElements(details) {
      return Array.from(details?.children || []).filter((child) => (
        !child?.dataset?.blockKey && trimmed(child?.dataset?.readexProcessingItemKey)
      ));
    }

    function reconcileReadexProcessingFoldDetails(ownerElement, unit, existingByKey, message, renderer) {
      const nestedEntries = unit.entries.filter((entry) => entry !== unit.ownerEntry);
      let details = readexProcessingDetailsElement(ownerElement);
      if (!readexProcessingFoldDetailsIsExpanded(ownerElement)) {
        Array.from(details?.children || []).forEach((child) => {
          if (child?.dataset?.blockKey) {
            child.remove();
          }
        });
        return;
      }
      if (!nestedEntries.length && !details) {
        return;
      }

      details = ensureReadexProcessingFoldDetailsElement(ownerElement);
      const ownedDetailItems = readexProcessingOwnedDetailItemElements(details);
      const usedNestedElements = new Set();
      let cursor = details.firstChild;
      unit.entries.forEach((entry) => {
        if (entry === unit.ownerEntry) {
          ownedDetailItems.forEach((itemElement) => {
            cursor = insertBeforeOwnedCursor(details, itemElement, cursor);
          });
          return;
        }

        const { block, blockKey } = entry;
        const existing = existingByKey.get(blockKey) || null;
        const element = createOrPatchMessageBlockElement(existing, entry, message, renderer);
        if (!element) {
          postBlockDOMReconcileProbe("block_render_null", message, block, blockKey, {
            renderPhase: "readex_processing_fold",
            groupID: unit.groupID
          });
          existingByKey.delete(blockKey);
          return;
        }
        cursor = insertBeforeOwnedCursor(details, element, cursor);
        usedNestedElements.add(element);
        existingByKey.delete(blockKey);
      });

      Array.from(details.children || []).forEach((child) => {
        if (child?.dataset?.blockKey && !usedNestedElements.has(child)) {
          postBlockDOMReconcileProbe("block_remove_stale", message, {
            type: child?.dataset?.blockType || ""
          }, child?.dataset?.blockKey || "", {
            renderPhase: "readex_processing_fold",
            staleBlockType: trimmed(child?.dataset?.blockType),
            groupID: unit.groupID
          });
          child.remove();
        }
      });
      if (!details.children.length) {
        details.remove();
        return;
      }
      retargetReadexProcessingFoldDetailsOpenAnimation(ownerElement, "fold-details-reconcile");
    }

      function renderMessageBlocks(root, message, renderer) {
        readexProcessingVisualUnits(bodyMessageBlockEntries(message)).forEach((unit) => {
          const entry = unit.type === "readex_processing_fold" ? unit.ownerEntry : unit.entry;
          const { block, blockKey } = entry;
          const element = createOrPatchMessageBlockElement(null, entry, message, renderer);
          if (!element) {
            postBlockDOMReconcileProbe("block_render_null", message, block, blockKey, {
              renderPhase: "initial"
            });
            return;
          }
          root.appendChild(element);
          postBlockDOMReconcileProbe("block_render_initial", message, block, blockKey, {
            renderPhase: "initial",
            className: typeof element.className === "string" ? element.className : ""
          });
          if (unit.type === "readex_processing_fold") {
            const existingByKey = new Map();
            reconcileReadexProcessingFoldDetails(element, unit, existingByKey, message, renderer);
          }
        });
      }

    function insertBeforeOwnedCursor(root, element, cursor) {
      const ownedCursor = cursor && cursor.parentNode === root ? cursor : null;
      if (element === ownedCursor) {
        return element.nextSibling;
      }
      root.insertBefore(element, ownedCursor);
      return element.nextSibling;
    }

    function reconcileMessageBlocks(root, message, renderer) {
      const entries = bodyMessageBlockEntries(message);
      const units = readexProcessingVisualUnits(entries);
      const existingByKey = new Map(
        blockElementsOwnedByMessage(root).map((child) => [child.dataset.blockKey || "", child])
      );
      const usedRootElements = new Set();

        let cursor = root.firstChild;
        units.forEach((unit) => {
          const entry = unit.type === "readex_processing_fold" ? unit.ownerEntry : unit.entry;
          const { block, blockKey } = entry;
          let element = existingByKey.get(blockKey) || null;
          const previousBlockType = trimmed(element?.dataset?.blockType);
          const renderReason = element ? "type_mismatch" : "missing_existing";
          const hadElement = Boolean(element);
          const previousSignature = element?.__chatTranscriptSignature;
          element = createOrPatchMessageBlockElement(element, entry, message, renderer);
            if (!element) {
              postBlockDOMReconcileProbe("block_render_null", message, block, blockKey, {
                renderPhase: "reconcile",
                renderReason,
                previousBlockType
              });
              existingByKey.delete(blockKey);
              return;
            }
          if (!hadElement || previousBlockType !== block.type) {
            postBlockDOMReconcileProbe("block_render_create", message, block, blockKey, {
              renderPhase: "reconcile",
              renderReason,
              previousBlockType,
              className: typeof element.className === "string" ? element.className : ""
            });
          } else if (previousSignature === element.__chatTranscriptSignature) {
            postBlockDOMReconcileProbe("block_patch_skipped_unchanged", message, block, blockKey, {
              renderPhase: "reconcile",
              className: typeof element.className === "string" ? element.className : ""
            });
          } else {
            postBlockDOMReconcileProbe(
              "block_patch_preserved",
              message,
              block,
              blockKey,
              {
                renderPhase: "reconcile",
                className: typeof element.className === "string" ? element.className : ""
              }
            );
          }

          if (element !== cursor) {
            postBlockDOMReconcileProbe("block_move", message, block, blockKey, {
              renderPhase: "reconcile"
            });
            cursor = insertBeforeOwnedCursor(root, element, cursor);
          } else {
            cursor = element.nextSibling;
        }
        usedRootElements.add(element);
        existingByKey.delete(blockKey);
        if (unit.type === "readex_processing_fold") {
          reconcileReadexProcessingFoldDetails(element, unit, existingByKey, message, renderer);
        }
      });

        Array.from(root.children || []).forEach((element) => {
          if (!usedRootElements.has(element)) {
            postBlockDOMReconcileProbe("block_remove_stale", message, {
              type: element?.dataset?.blockType || ""
            }, element?.dataset?.blockKey || "", {
              renderPhase: "reconcile",
              staleBlockType: trimmed(element?.dataset?.blockType)
            });
            element.remove();
          }
        });
    }

    function directStoppedBoundary(root) {
      return Array.from(root?.children || []).find((child) => (
        child.classList?.contains("readex-stopped-marker-block") ||
        child.dataset?.blockType === "readex_stopped_marker"
      )) || null;
    }

    function reconcileStoppedBoundary(root, message) {
      const existing = directStoppedBoundary(root);
      const entry = readexStatusBoundaryBlockEntry(message);
      if (!entry) {
        if (existing) {
          existing.remove();
        }
        return;
      }

      let element = existing;
      if (!element || element.dataset.blockKey !== entry.blockKey || element.dataset.blockType !== entry.block.type) {
        const replacement = renderReadexStoppedMarkerBlock(entry.block, entry.blockKey);
        replacement.dataset.blockKey = entry.blockKey;
        replacement.dataset.blockType = entry.block.type;
        replacement.__chatTranscriptSignature = messageBlockSignature(entry.block, message);
        if (element) {
          element.replaceWith(replacement);
        }
        element = replacement;
      } else {
        updateReadexStoppedMarkerBlockElement(element, entry.block, entry.blockKey);
        element.dataset.blockKey = entry.blockKey;
        element.dataset.blockType = entry.block.type;
        element.__chatTranscriptSignature = messageBlockSignature(entry.block, message);
      }

      if (element.parentNode !== root || element.nextSibling !== null) {
        root.appendChild(element);
      }
    }

    return Object.freeze({
      messageBlockKey,
      messageBlockSignature,
      applyMarkdownBlockSourceUpdate,
      applyProcessingBlockSourceUpdate,
      renderMessageBlocks,
      reconcileMessageBlocks,
      reconcileStoppedBoundary
    });
  };
})();
