(function () {
	function installExplanationAnchorAPI() {
      const apiVersion = 9;
  if (
    window.AIReadingChatTranscriptExplanationAnchors
    && window.AIReadingChatTranscriptExplanationAnchors.version === apiVersion
  ) {
    return window.AIReadingChatTranscriptExplanationAnchors;
  }

  const anchorClassName = "ai-reading-chat-explanation-anchor";
  const containerClassName = "ai-reading-chat-explanation-anchor-container";
  const activeAnchorClassName = "is-active";
  const hoveredAnchorClassName = "is-hovered";
  const searchMatchClassName = "ai-reading-chat-search-match";
  const tooltipClassName = "ai-reading-chat-explanation-tooltip";
  const tooltipVisibleClassName = "is-visible";
  const tooltipDelayMs = 250;
  const excludedTags = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEXTAREA"]);
  const excludedClosestSelector = [
    "button",
    "textarea",
    ".message-actions",
    ".message-action-row",
    ".message-header",
    ".message-footer",
    ".message-expert-domain-badge",
    ".reference-chip",
    ".code-block-header",
    ".katex-mathml",
    "mark." + searchMatchClassName
  ].join(",");

  function rootElement() {
    return document.getElementById("messages");
  }

  let tooltipTimer = 0;
  let retryTimer = 0;
  let tooltipElement = null;
  let tooltipTarget = null;
  let lastAppliedActivationScopeID = "";
  let lastAppliedActivationSequence = -1;

  function cancelRetryTimer() {
    if (retryTimer) {
      window.clearTimeout(retryTimer);
      retryTimer = 0;
    }
  }

  function activationScopeIDForState(state) {
    return String(
      (state && (state.conversationID || state.scopeID))
      || ""
    );
  }

  function activationSequenceForState(state) {
    const rawSequence = Number(state && state.activationSequence);
    return Number.isFinite(rawSequence) ? Math.trunc(rawSequence) : null;
  }

  function highlightedAnchorElementCount() {
    const root = rootElement();
    if (!root) {
      return 0;
    }
    return root.querySelectorAll("mark." + anchorClassName + ", ." + containerClassName).length;
  }

  function staleApplyStatus(state, retryAttempt) {
    const anchors = Array.isArray(state && state.anchors) ? state.anchors : [];
    const activeAnchorID = String(state && state.activeAnchorID || "");
    return {
      highlightedCount: highlightedAnchorElementCount(),
      activeAnchorID: activeAnchorID || null,
      activeAnchorVisible: false,
      visibleAnchorCount: anchors.length,
      activeHighlightCount: 0,
      activeMarkFound: false,
      activeMissReason: "stale_activation_sequence",
      retryAttempt: retryAttempt
    };
  }

  function anchorTargetFromNode(node) {
    return node && node.closest
      ? node.closest("mark." + anchorClassName + ", ." + containerClassName)
      : null;
  }

  function anchorTargetFromEvent(event) {
    return event ? anchorTargetFromNode(event.target) : null;
  }

  function anchorElementsForID(anchorID) {
    const root = rootElement();
    const targetID = String(anchorID || "");
    if (!root || !targetID) {
      return [];
    }
    return Array.from(root.querySelectorAll("mark." + anchorClassName + ", ." + containerClassName))
      .filter(function(element) {
        return element && element.dataset && element.dataset.anchorId === targetID;
      });
  }

  function clearHoveredAnchors() {
    const root = rootElement();
    if (!root) {
      return;
    }
    Array.from(root.querySelectorAll("." + hoveredAnchorClassName)).forEach(function(element) {
      element.classList.remove(hoveredAnchorClassName);
    });
  }

  function setHoveredAnchor(anchorID) {
    clearHoveredAnchors();
    anchorElementsForID(anchorID).forEach(function(element) {
      element.classList.add(hoveredAnchorClassName);
    });
  }

  function clearTooltipTimer() {
    if (tooltipTimer) {
      window.clearTimeout(tooltipTimer);
      tooltipTimer = 0;
    }
  }

  function ensureTooltipElement() {
    if (tooltipElement && document.body && document.body.contains(tooltipElement)) {
      return tooltipElement;
    }
    tooltipElement = document.createElement("div");
    tooltipElement.className = tooltipClassName;
    tooltipElement.textContent = "查看 AI 解释";
    tooltipElement.setAttribute("role", "tooltip");
    if (document.body) {
      document.body.appendChild(tooltipElement);
    }
    return tooltipElement;
  }

  function removeNativeTooltipAttributes(element) {
    if (!element) {
      return;
    }
    if (element.removeAttribute) {
      element.removeAttribute("title");
    }
    if (element.querySelectorAll) {
      Array.from(element.querySelectorAll("[title]")).forEach(function(child) {
        child.removeAttribute("title");
      });
    }
  }

  function positionTooltip(target, tooltip) {
    if (!target || !tooltip) {
      return;
    }
    const rect = target.getBoundingClientRect();
    const viewportWidth = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 0);
    const tooltipWidth = tooltip.offsetWidth || 0;
    const halfWidth = tooltipWidth / 2;
    const left = Math.min(
      Math.max(rect.left + rect.width / 2, halfWidth + 8),
      Math.max(halfWidth + 8, viewportWidth - halfWidth - 8)
    );
    const top = Math.max(8, rect.top - tooltip.offsetHeight - 10);
    tooltip.style.left = left + "px";
    tooltip.style.top = top + "px";
  }

  function showAnchorTooltip(target) {
    clearTooltipTimer();
    if (!target || !document.body || !document.body.contains(target)) {
      return;
    }
    const tooltip = ensureTooltipElement();
    tooltip.textContent = String(target.dataset && target.dataset.aiReadingTooltip || "查看 AI 解释");
    tooltip.classList.remove(tooltipVisibleClassName);
    positionTooltip(target, tooltip);
    tooltipTarget = target;
    window.requestAnimationFrame(function() {
      if (tooltipTarget !== target || !document.body.contains(target)) {
        return;
      }
      positionTooltip(target, tooltip);
      tooltip.classList.add(tooltipVisibleClassName);
    });
  }

  function scheduleAnchorTooltip(target) {
    clearTooltipTimer();
    tooltipTarget = target;
    tooltipTimer = window.setTimeout(function() {
      tooltipTimer = 0;
      showAnchorTooltip(target);
    }, tooltipDelayMs);
  }

  function hideAnchorTooltip() {
    clearTooltipTimer();
    tooltipTarget = null;
    if (tooltipElement) {
      tooltipElement.classList.remove(tooltipVisibleClassName);
    }
  }

  function clearMarks() {
    const root = rootElement();
    if (!root) {
      return { highlightedCount: 0 };
    }
    const marks = Array.from(root.querySelectorAll("mark." + anchorClassName));
    for (const mark of marks) {
      const parent = mark.parentNode;
      if (!parent) {
        continue;
      }
      while (mark.firstChild) {
        parent.insertBefore(mark.firstChild, mark);
      }
      parent.removeChild(mark);
      parent.normalize();
    }
    const containers = Array.from(root.querySelectorAll("." + containerClassName));
    for (const container of containers) {
      container.classList.remove(containerClassName);
      container.classList.remove(activeAnchorClassName);
      container.classList.remove(hoveredAnchorClassName);
      if (container.dataset) {
        delete container.dataset.anchorId;
        delete container.dataset.aiReadingTooltip;
      }
      removeNativeTooltipAttributes(container);
    }
    hideAnchorTooltip();
    return { highlightedCount: 0 };
  }

  function articleForMessage(messageID) {
    const root = rootElement();
    if (!root || !messageID) {
      return null;
    }
    const targetID = String(messageID);
    return Array.from(root.querySelectorAll(".message")).find(function(article) {
      return article && article.dataset && article.dataset.messageId === targetID;
    }) || null;
  }

  function closestElement(node) {
    if (!node) {
      return null;
    }
    return node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
  }

  function makeWalker(root, options) {
    const includesAnchorMarks = Boolean(options && options.includesAnchorMarks);
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (!parent || !node.nodeValue) {
          return NodeFilter.FILTER_REJECT;
        }
        if (excludedTags.has(parent.tagName)) {
          return NodeFilter.FILTER_REJECT;
        }
        if (
          (!includesAnchorMarks && parent.closest("mark." + anchorClassName))
          || parent.closest(excludedClosestSelector)
        ) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
  }

  function highlightedText(anchor) {
    return String(anchor && anchor.selectedText || "").trim();
  }

  function decorateAnchorElement(element, anchor) {
    if (!element) {
      return element;
    }
    if (element.dataset) {
      element.dataset.anchorId = String(anchor && anchor.id || "");
      element.dataset.aiReadingTooltip = "查看 AI 解释";
    }
    element.setAttribute("aria-label", "查看 AI 解释");
    removeNativeTooltipAttributes(element);
    return element;
  }

  function comparableText(value) {
    return String(value || "").replace(/\s+/g, " ").trim().toLocaleLowerCase();
  }

  function sourceOffset(value) {
    const number = Number(value);
    return Number.isFinite(number) && number >= 0 ? Math.trunc(number) : null;
  }

  function sourceRangeForElement(element) {
    if (!element || !element.dataset) {
      return null;
    }
    const start = sourceOffset(element.dataset.aiReadingSourceStart);
    const end = sourceOffset(element.dataset.aiReadingSourceEnd);
    if (start === null || end === null || end <= start) {
      return null;
    }
    return {
      element: element,
      start: start,
      end: end,
      length: end - start,
      kind: String(element.dataset.aiReadingSourceKind || "")
    };
  }

  function messageForArticle(article) {
    if (!article) {
      return null;
    }
    if (article.__chatTranscriptMessage) {
      return article.__chatTranscriptMessage;
    }
    const payloadModel = window.__chatTranscriptPayloadModel;
    if (payloadModel && typeof payloadModel.messageByID === "function") {
      return payloadModel.messageByID(article.dataset && article.dataset.messageId);
    }
    return null;
  }

  function renderableMessageBlocks(message) {
    const runtimeModel = window.__chatTranscriptMessageRuntimeModel;
    if (runtimeModel && typeof runtimeModel.renderableMessageBlocks === "function") {
      return runtimeModel.renderableMessageBlocks(message);
    }
    return [];
  }

  function messageBlockKey(block, index) {
    const renderer = window.__chatTranscriptMessageBlockRenderer;
    if (renderer && typeof renderer.messageBlockKey === "function") {
      return String(renderer.messageBlockKey(block, index) || "").trim();
    }
    return String(block && block.id || "").trim() || "__message_block_" + String(index);
  }

  function blockText(block) {
    if (block && typeof block.text === "string") {
      return block.text;
    }
    if (block && typeof block.content === "string") {
      return block.content;
    }
    return "";
  }

  function mainTextBlockMetadataByKey(article) {
    const message = messageForArticle(article);
    const metadataByKey = new Map();
    let cursor = 0;

    renderableMessageBlocks(message).forEach(function(block, index) {
      if (!block || block.type !== "main_text") {
        return;
      }

      const text = blockText(block);
      if (!String(text || "").trim()) {
        return;
      }

      if (metadataByKey.size > 0) {
        cursor += 2;
      }

      const key = messageBlockKey(block, index);
      metadataByKey.set(key, {
        start: cursor,
        end: cursor + text.length,
        textLength: text.length
      });
      cursor += text.length;
    });

    return metadataByKey;
  }

  function sourceRangeForElementInArticle(article, element, metadataByKey) {
    const localRange = sourceRangeForElement(element);
    if (!localRange) {
      return null;
    }

    const blockElement = element.closest
      ? element.closest("[data-block-type='main_text']")
      : null;
    const blockKey = String(blockElement && blockElement.dataset && blockElement.dataset.blockKey || "").trim();
    const blockMetadata = metadataByKey && blockKey ? metadataByKey.get(blockKey) : null;
    if (metadataByKey && metadataByKey.size > 0 && blockKey && !blockMetadata) {
      return null;
    }
    const blockStart = blockMetadata ? blockMetadata.start : 0;

    return Object.assign(localRange, {
      start: blockStart + localRange.start,
      end: blockStart + localRange.end,
      localStart: localRange.start,
      localEnd: localRange.end,
      blockKey: blockKey
    });
  }

  function sourceRangeForAnchor(anchor) {
    const start = sourceOffset(anchor && anchor.sourceStartUTF16Offset);
    const length = sourceOffset(anchor && anchor.sourceUTF16Length);
    if (start === null || length === null || length <= 0) {
      return null;
    }
    return {
      start: start,
      end: start + length,
      length: length
    };
  }

  function sourceRangePriority(item) {
    return item && (item.kind === "math-inline" || item.kind === "math-display") ? 0 : 1;
  }

  function sourceElementIsMath(element) {
    if (!element || !element.matches) {
      return false;
    }
    const kind = String(element.dataset && element.dataset.aiReadingSourceKind || "");
    return kind === "math-inline"
      || kind === "math-display"
      || element.matches(".katex-display, .katex, mjx-container, .katex-error, .mathjax-error, .math-placeholder-block, .math-placeholder-inline");
  }

  function sourceElementsForAnchor(article, anchor) {
    const anchorRange = sourceRangeForAnchor(anchor);
    if (!article || !anchorRange) {
      return [];
    }

    const metadataByKey = mainTextBlockMetadataByKey(article);
    const mainTextBlockCount = article.querySelectorAll("[data-block-type='main_text']").length;
    if (metadataByKey.size === 0 && mainTextBlockCount > 1) {
      return [];
    }
    const candidates = Array.from(
      article.querySelectorAll("[data-ai-reading-source-start][data-ai-reading-source-end]")
    ).map(function(element) {
      return sourceRangeForElementInArticle(article, element, metadataByKey);
    }).filter(Boolean).map(function(candidate, index) {
      const overlap = Math.min(anchorRange.end, candidate.end) - Math.max(anchorRange.start, candidate.start);
      const contains = candidate.start <= anchorRange.start && candidate.end >= anchorRange.end;
      const exact = candidate.start === anchorRange.start && candidate.end === anchorRange.end;
      const coversStart = candidate.start <= anchorRange.start && candidate.end > anchorRange.start;
      const startDistance = Math.abs(candidate.start - anchorRange.start);
      const distance = Math.abs(candidate.start - anchorRange.start) + Math.abs(candidate.end - anchorRange.end);
      return Object.assign(candidate, {
        overlap: overlap,
        contains: contains,
        exact: exact,
        coversStart: coversStart,
        startDistance: startDistance,
        distance: distance,
        documentIndex: index
      });
    }).filter(function(candidate) {
      return candidate.contains || candidate.overlap > 0;
    });

    candidates.sort(function(lhs, rhs) {
      if (lhs.exact !== rhs.exact) {
        return lhs.exact ? -1 : 1;
      }
      if (lhs.coversStart !== rhs.coversStart) {
        return lhs.coversStart ? -1 : 1;
      }
      if (lhs.startDistance !== rhs.startDistance) {
        return lhs.startDistance - rhs.startDistance;
      }
      if (lhs.contains !== rhs.contains) {
        return lhs.contains ? -1 : 1;
      }
      const priorityDiff = sourceRangePriority(lhs) - sourceRangePriority(rhs);
      if (priorityDiff !== 0) {
        return priorityDiff;
      }
      if (lhs.overlap !== rhs.overlap) {
        return rhs.overlap - lhs.overlap;
      }
      if (lhs.length !== rhs.length) {
        return lhs.length - rhs.length;
      }
      if (lhs.distance !== rhs.distance) {
        return lhs.distance - rhs.distance;
      }
      return lhs.documentIndex - rhs.documentIndex;
    });

    return candidates.map(function(candidate) { return candidate.element; });
  }

  function mainTextBlockElementsForAnchor(article, anchor) {
    const anchorRange = sourceRangeForAnchor(anchor);
    if (!article || !anchorRange) {
      return [];
    }

    const metadataByKey = mainTextBlockMetadataByKey(article);
    if (!metadataByKey.size) {
      return [];
    }

    return Array.from(article.querySelectorAll("[data-block-type='main_text']")).filter(function(blockElement) {
      const blockKey = String(blockElement && blockElement.dataset && blockElement.dataset.blockKey || "").trim();
      const metadata = blockKey ? metadataByKey.get(blockKey) : null;
      if (!metadata) {
        return false;
      }
      return Math.min(anchorRange.end, metadata.end) - Math.max(anchorRange.start, metadata.start) > 0;
    });
	  }

  function renderedTextRangesForAnchor(anchor) {
    if (!Array.isArray(anchor && anchor.renderedTextRanges)) {
      return [];
    }

    const seen = new Set();
    return anchor.renderedTextRanges.map(function(range) {
      const blockKey = String(range && range.blockKey || "").trim();
      const start = sourceOffset(range && range.startUTF16Offset);
      const length = sourceOffset(range && range.utf16Length);
      if (!blockKey || start === null || length === null || length <= 0) {
        return null;
      }
      const normalized = {
        blockKey: blockKey,
        start: start,
        end: start + length,
        selectedText: String(range && range.selectedText || "")
      };
      const key = normalized.blockKey + ":" + String(normalized.start) + ":" + String(normalized.end);
      if (seen.has(key)) {
        return null;
      }
      seen.add(key);
      return normalized;
    }).filter(Boolean);
  }

  function anchorHasRenderedTextRanges(anchor) {
    return renderedTextRangesForAnchor(anchor).length > 0;
  }

  function mainTextBlockElementForKey(article, blockKey) {
    if (!article || !blockKey) {
      return null;
    }
    return Array.from(article.querySelectorAll("[data-block-type='main_text']")).find(function(blockElement) {
      return String(blockElement && blockElement.dataset && blockElement.dataset.blockKey || "").trim() === blockKey;
    }) || null;
  }

  function buildRawTextIndex(root, options) {
    const walker = makeWalker(root, options);
    const textParts = [];
    const entries = [];
    let cursor = 0;
    let currentNode = walker.nextNode();

    while (currentNode) {
      const textValue = currentNode.nodeValue || "";
      entries.push({
        node: currentNode,
        start: cursor,
        end: cursor + textValue.length
      });
      textParts.push(textValue);
      cursor += textValue.length;
      currentNode = walker.nextNode();
    }

    return {
      text: textParts.join(""),
      entries: entries
    };
  }

  function textIndexEntryAtOffset(textIndex, offset, usePrevious) {
    if (!textIndex || !textIndex.entries.length) {
      return null;
    }
    const targetOffset = Math.trunc(Number(offset));
    if (!Number.isFinite(targetOffset)) {
      return null;
    }
    for (const entry of textIndex.entries) {
      if (targetOffset >= entry.start && targetOffset < entry.end) {
        return {
          node: entry.node,
          offset: targetOffset - entry.start
        };
      }
      if (!usePrevious && targetOffset === entry.end) {
        return {
          node: entry.node,
          offset: entry.end - entry.start
        };
      }
    }
    if (usePrevious && targetOffset === textIndex.text.length) {
      const entry = textIndex.entries[textIndex.entries.length - 1];
      return {
        node: entry.node,
        offset: entry.end - entry.start
      };
    }
    return null;
  }

  function markRenderedTextRange(blockElement, renderedRange, anchor, isActive, options) {
    if (!blockElement || !renderedRange || renderedRange.end <= renderedRange.start) {
      return null;
    }
    const textIndex = buildRawTextIndex(blockElement, { includesAnchorMarks: true });
    if (!textIndex.text || renderedRange.end > textIndex.text.length) {
      return null;
    }
    if (String(textIndex.text.slice(renderedRange.start, renderedRange.end) || "").trim() === "") {
      return null;
    }

    const start = textIndexEntryAtOffset(textIndex, renderedRange.start, false);
    const end = textIndexEntryAtOffset(textIndex, renderedRange.end, true);
    if (!start || !end) {
      return null;
    }

    return markTextMatchByTextNodes(
      {
        startNode: start.node,
        startOffset: start.offset,
        endNode: end.node,
        endOffset: end.offset
      },
      anchor,
      isActive,
      options
    );
  }

  function markRenderedTextRanges(article, anchor, isActive, options) {
    const ranges = renderedTextRangesForAnchor(anchor);
    if (!ranges.length) {
      return [];
    }

    const marks = [];
    for (const renderedRange of ranges) {
      const blockElement = mainTextBlockElementForKey(article, renderedRange.blockKey);
      const marked = markRenderedTextRange(blockElement, renderedRange, anchor, isActive, options);
      const previousCount = marks.length;
      appendMarkedValue(marks, marked);
      if (marks.length === previousCount) {
        return [];
      }
    }
    return marks;
  }

	  function buildTextIndex(root) {
    const walker = makeWalker(root);
    const chars = [];
    const mappings = [];
    let previousWasSpace = true;
    let currentNode = walker.nextNode();

    while (currentNode) {
      const textValue = currentNode.nodeValue || "";
      for (let offset = 0; offset < textValue.length; offset += 1) {
        const char = textValue[offset];
        if (/\s/.test(char)) {
          if (!previousWasSpace) {
            chars.push(" ");
            mappings.push({
              node: currentNode,
              startOffset: offset,
              endOffset: offset + 1
            });
            previousWasSpace = true;
          }
          continue;
        }

        chars.push(char.toLocaleLowerCase());
        mappings.push({
          node: currentNode,
          startOffset: offset,
          endOffset: offset + 1
        });
        previousWasSpace = false;
      }
      currentNode = walker.nextNode();
    }

    if (chars.length > 0 && chars[chars.length - 1] === " ") {
      chars.pop();
      mappings.pop();
    }

    return {
      text: chars.join(""),
      mappings: mappings
    };
  }

  function textMatches(root, query) {
    const normalizedQuery = comparableText(query);
    if (!root || !normalizedQuery) {
      return [];
    }

    const textIndex = buildTextIndex(root);
    if (!textIndex.text || !textIndex.mappings.length) {
      return [];
    }

    const matches = [];
    let matchStart = textIndex.text.indexOf(normalizedQuery);
    while (matchStart !== -1) {
      const matchEnd = matchStart + normalizedQuery.length - 1;
      const startMapping = textIndex.mappings[matchStart];
      const endMapping = textIndex.mappings[matchEnd];
      if (startMapping && endMapping) {
        matches.push({
          startNode: startMapping.node,
          startOffset: startMapping.startOffset,
          endNode: endMapping.node,
          endOffset: endMapping.endOffset
        });
      }
      matchStart = textIndex.text.indexOf(normalizedQuery, matchStart + normalizedQuery.length);
    }
    return matches;
  }

  function targetOccurrence(anchor) {
    const preferredOccurrence = Number(anchor && anchor.selectedTextOccurrenceIndexInMessage);
    return Number.isFinite(preferredOccurrence) && preferredOccurrence >= 0
      ? Math.trunc(preferredOccurrence)
      : null;
  }

  function addUniqueTextSegment(segments, seen, value) {
    const text = String(value || "").trim();
    const comparable = comparableText(text);
    if (!comparable || seen.has(comparable) || !/[A-Za-z0-9\u4e00-\u9fff]/.test(comparable)) {
      return;
    }
    seen.add(comparable);
    segments.push(text);
  }

  function textLooksBlockSpanning(value) {
    return /[\r\n]/.test(String(value || ""));
  }

  function normalizedListSegment(value) {
    return String(value || "")
      .replace(/^\s*(?:[-*+•‣◦]|\d+[.)]|[（(]?\d+[）)])\s+/, "")
      .replace(/\s+/g, " ")
      .trim();
  }

  function splitBlockTextSegments(value) {
    return String(value || "")
      .split(/[\r\n]+/)
      .map(normalizedListSegment)
      .filter(Boolean);
  }

  function textSegmentsForAnchor(anchor, options) {
    const requiresTextMatch = Boolean(options && options.requiresTextMatch);
    const segments = [];
    const seen = new Set();
    if (requiresTextMatch && Array.isArray(anchor && anchor.renderedTextSegments)) {
      anchor.renderedTextSegments.forEach(function(segment) {
        addUniqueTextSegment(segments, seen, segment);
      });
    }
    const selectedText = highlightedText(anchor);
    const selectedComparable = comparableText(selectedText);
    const sourceMarkdown = String(anchor && anchor.sourceMarkdown || "").trim();
    const sourceComparable = comparableText(sourceMarkdown);
    const candidates = [selectedText];
    if (sourceComparable && sourceComparable.length <= selectedComparable.length + 12) {
      candidates.push(sourceMarkdown);
    }
    for (const candidate of candidates) {
      if (!requiresTextMatch || !textLooksBlockSpanning(candidate)) {
        addUniqueTextSegment(segments, seen, candidate);
      }
      splitBlockTextSegments(candidate).forEach(function(line) {
        addUniqueTextSegment(segments, seen, line);
      });
    }
    return segments;
  }

  function tableCellElementsForSourceElements(sourceElements) {
    const cells = [];
    const seen = new Set();

    function addCell(cell) {
      if (!cell || seen.has(cell)) {
        return;
      }
      seen.add(cell);
      cells.push(cell);
    }

    for (const sourceElement of sourceElements || []) {
      if (!sourceElement) {
        continue;
      }
      if (sourceElement.matches && sourceElement.matches("td, th")) {
        addCell(sourceElement);
      }
      if (sourceElement.querySelectorAll) {
        Array.from(sourceElement.querySelectorAll("td, th")).forEach(addCell);
      }
    }

    return cells;
  }

  function sourceElementUsesTableLayout(element) {
    return !!(
      element
      && (
        (element.matches && element.matches("table, thead, tbody, tfoot, tr, td, th"))
        || (element.querySelector && element.querySelector("table, td, th"))
      )
    );
  }

  function sourceElementsUseTableLayout(sourceElements) {
    return (sourceElements || []).some(sourceElementUsesTableLayout);
  }

  function normalizedTableCellMarkdown(value) {
    return String(value || "")
      .replace(/\\\|/g, "|")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/`([^`]*)`/g, "$1")
      .replace(/\*\*([^*]+)\*\*/g, "$1")
      .replace(/\*([^*]+)\*/g, "$1")
      .replace(/__([^_]+)__/g, "$1")
      .replace(/_([^_]+)_/g, "$1")
      .trim();
  }

  function splitMarkdownTableLine(line) {
    let text = String(line || "").trim();
    if (!text || !text.includes("|")) {
      return [];
    }
    if (text.startsWith("|")) {
      text = text.slice(1);
    }
    if (text.endsWith("|")) {
      text = text.slice(0, -1);
    }

    const cells = [];
    let current = "";
    let isEscaped = false;
    for (const character of text) {
      if (isEscaped) {
        current += character;
        isEscaped = false;
        continue;
      }
      if (character === "\\") {
        current += character;
        isEscaped = true;
        continue;
      }
      if (character === "|") {
        cells.push(current);
        current = "";
        continue;
      }
      current += character;
    }
    cells.push(current);

    return cells.map(normalizedTableCellMarkdown).filter(function(cell) {
      return cell && !/^:?-{2,}:?$/.test(cell.replace(/\s+/g, ""));
    });
  }

  function markdownTableCellTexts(markdown) {
    const cells = [];
    String(markdown || "")
      .split(/\r?\n+/)
      .forEach(function(line) {
        splitMarkdownTableLine(line).forEach(function(cell) {
          cells.push(cell);
        });
      });
    return cells;
  }

  function addTableTextSegment(segments, seen, value, selectedComparable, requiresSelectedOverlap) {
    const text = String(value || "").replace(/\s+/g, " ").trim();
    const comparable = comparableText(text);
    if (!comparable || seen.has(comparable) || !/[A-Za-z0-9\u4e00-\u9fff]/.test(comparable)) {
      return;
    }
    if (
      requiresSelectedOverlap
      && selectedComparable
      && comparable !== selectedComparable
      && !selectedComparable.includes(comparable)
      && !comparable.includes(selectedComparable)
    ) {
      return;
    }
    if (comparable.length < 2 && comparable !== selectedComparable) {
      return;
    }
    seen.add(comparable);
    segments.push(text);
  }

  function tableTextSegmentsForAnchor(anchor) {
    const segments = [];
    const seen = new Set();
    const selectedText = highlightedText(anchor);
    const selectedComparable = comparableText(selectedText);

    String(selectedText || "")
      .split(/[\r\n\t]+| {2,}/)
      .forEach(function(part) {
        addTableTextSegment(segments, seen, part, selectedComparable, false);
      });

    markdownTableCellTexts(anchor && anchor.sourceMarkdown).forEach(function(cell) {
      addTableTextSegment(segments, seen, cell, selectedComparable, true);
    });

    if (!segments.length) {
      addTableTextSegment(segments, seen, selectedText, selectedComparable, false);
    }

    return segments;
  }

  function tableCellForTextNode(node) {
    const parent = node && node.parentElement;
    return parent && parent.closest ? parent.closest("td, th") : null;
  }

  function matchIsInsideSingleTableCell(match) {
    if (!match) {
      return false;
    }
    const startCell = tableCellForTextNode(match.startNode);
    const endCell = tableCellForTextNode(match.endNode);
    return !!(startCell && startCell === endCell);
  }

  function appendMarkedValue(target, value) {
    if (!value) {
      return false;
    }
    if (Array.isArray(value)) {
      const marks = value.filter(Boolean);
      marks.forEach(function(mark) {
        target.push(mark);
      });
      return marks.length > 0;
    }
    target.push(value);
    return true;
  }

  function markTableCellSegmentMatches(sourceElements, anchor, isActive, options) {
    const cells = tableCellElementsForSourceElements(sourceElements);
    if (!cells.length) {
      return [];
    }

    const marks = [];
    const markedContainers = new Set();
    const segments = tableTextSegmentsForAnchor(anchor);
    for (const segment of segments) {
      let markedSegment = false;
      const segmentComparable = comparableText(segment);
      for (const cell of cells) {
        const localMatches = textMatches(cell, segment);
        for (const localMatch of localMatches) {
          const mark = markTextMatch(localMatch, anchor, isActive, options);
          if (appendMarkedValue(marks, mark)) {
            markedSegment = true;
            break;
          }
        }
        if (markedSegment) {
          break;
        }

        const cellComparable = comparableText(cell.textContent || "");
        if (
          segmentComparable
          && cellComparable
          && segmentComparable === cellComparable
          && !markedContainers.has(cell)
        ) {
          const container = markSourceContainer([cell], anchor, isActive);
          if (container) {
            markedContainers.add(cell);
            marks.push(container);
            markedSegment = true;
            break;
          }
        }
      }
    }
    return marks;
  }

  function matchIsInsideElement(match, element) {
    return !!(
      match
      && element
      && element.contains(match.startNode)
      && element.contains(match.endNode)
    );
  }

  function closestInlineMarkBoundary(node) {
    const element = closestElement(node);
    return element && element.closest
      ? element.closest("li, p, td, th, pre, blockquote, h1, h2, h3, h4, h5, h6, [data-block-type='thinking'], [data-block-type='main_text']")
      : null;
  }

  function matchCanUseInlineMark(match, options) {
    if (!options || !options.requiresTextMatch) {
      return true;
    }
    if (!match || !match.startNode || !match.endNode) {
      return false;
    }
    if (match.startNode === match.endNode) {
      return true;
    }
    const startBoundary = closestInlineMarkBoundary(match.startNode);
    const endBoundary = closestInlineMarkBoundary(match.endNode);
    return !!(startBoundary && startBoundary === endBoundary);
  }

  function textNodesIntersectingRange(range) {
    if (!range || !range.commonAncestorContainer) {
      return [];
    }

    const root = range.commonAncestorContainer.nodeType === Node.TEXT_NODE
      ? range.commonAncestorContainer.parentNode
      : range.commonAncestorContainer;
    if (!root) {
      return [];
    }

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (!node || !node.nodeValue || !range.intersectsNode(node)) {
          return NodeFilter.FILTER_REJECT;
        }
        if (!closestInlineMarkBoundary(node)) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    const nodes = [];
    let current = walker.nextNode();
    while (current) {
      nodes.push(current);
      current = walker.nextNode();
    }
    return nodes;
  }

  function markTextNodeSlice(node, startOffset, endOffset, anchor, isActive) {
    if (!node || endOffset <= startOffset) {
      return null;
    }
    const text = String(node.nodeValue || "").slice(startOffset, endOffset);
    if (!text.trim()) {
      return null;
    }

    try {
      const range = document.createRange();
      range.setStart(node, startOffset);
      range.setEnd(node, endOffset);
      const mark = document.createElement("mark");
      mark.className = anchorClassName + (isActive ? " " + activeAnchorClassName : "");
      decorateAnchorElement(mark, anchor);
      mark.appendChild(range.extractContents());
      range.insertNode(mark);
      return mark;
    } catch (_) {
      return null;
    }
  }

  function markTextMatchByTextNodes(match, anchor, isActive) {
    try {
      const range = document.createRange();
      range.setStart(match.startNode, match.startOffset);
      range.setEnd(match.endNode, match.endOffset);
      if (range.collapsed) {
        return [];
      }

      const nodes = textNodesIntersectingRange(range);
      const marks = [];
      nodes.reverse().forEach(function(node) {
        const startOffset = node === match.startNode ? match.startOffset : 0;
        const endOffset = node === match.endNode ? match.endOffset : String(node.nodeValue || "").length;
        const mark = markTextNodeSlice(node, startOffset, endOffset, anchor, isActive);
        if (mark) {
          marks.unshift(mark);
        }
      });
      return marks;
    } catch (_) {
      return [];
    }
  }

  function markTextMatch(match, anchor, isActive, options) {
    if (!match) {
      return null;
    }
    if (!matchCanUseInlineMark(match, options)) {
      if (options && options.requiresTextMatch) {
        const marks = markTextMatchByTextNodes(match, anchor, isActive);
        return marks.length ? marks : null;
      }
      return null;
    }

    try {
      const range = document.createRange();
      range.setStart(match.startNode, match.startOffset);
      range.setEnd(match.endNode, match.endOffset);
      if (range.collapsed) {
        return null;
      }

      const mark = document.createElement("mark");
      mark.className = anchorClassName + (isActive ? " " + activeAnchorClassName : "");
      decorateAnchorElement(mark, anchor);
      mark.appendChild(range.extractContents());
      range.insertNode(mark);
      return mark;
    } catch (_) {
      return null;
    }
  }

  function markSegmentMatches(sourceElements, anchor, isActive, options) {
    if (!sourceElements || !sourceElements.length) {
      return [];
    }
    const marks = [];
    const segments = textSegmentsForAnchor(anchor, options);
    for (const segment of segments) {
      let markedSegment = false;
      for (const sourceElement of sourceElements) {
        const localMatches = textMatches(sourceElement, segment);
        for (const localMatch of localMatches) {
          const mark = markTextMatch(localMatch, anchor, isActive, options);
          if (appendMarkedValue(marks, mark)) {
            markedSegment = true;
            break;
          }
        }
        if (markedSegment) {
          break;
        }
      }
    }
    return marks;
  }

  function markSourceContainer(sourceElements, anchor, isActive) {
    const container = sourceElements && sourceElements.length ? sourceElements[0] : null;
    if (!container || !container.classList) {
      return null;
    }
    container.classList.add(containerClassName);
    if (isActive) {
      container.classList.add(activeAnchorClassName);
    }
    return decorateAnchorElement(container, anchor);
  }

  function exactSourceContainerForAnchor(sourceElements, anchor) {
    const anchorRange = sourceRangeForAnchor(anchor);
    if (!anchorRange || !sourceElements || !sourceElements.length) {
      return null;
    }
    return sourceElements.find(function(element) {
      const article = articleForMessage(anchor && anchor.sourceMessageID);
      const sourceRange = sourceRangeForElementInArticle(
        article,
        element,
        mainTextBlockMetadataByKey(article)
      );
      return sourceRange
        && sourceRange.start === anchorRange.start
        && sourceRange.end === anchorRange.end;
    }) || null;
  }

  function markedElements(value) {
    if (value && Array.isArray(value.marks)) {
      return value.marks.filter(Boolean);
    }
    if (Array.isArray(value)) {
      return value.filter(Boolean);
    }
    return value ? [value] : [];
  }

  function scrollTargetForMarkedValue(value, marks) {
    if (value && value.scrollTarget) {
      return value.scrollTarget;
    }
    return marks && marks.length ? marks[0] : null;
  }

  function anchorMissReason(anchor, markedValue, marks) {
    if (marks && marks.length) {
      return "highlighted";
    }
    const article = articleForMessage(anchor && anchor.sourceMessageID);
    if (!article) {
      return "source_message_not_rendered";
    }
    if (!highlightedText(anchor)) {
      return "empty_selected_text";
    }
    if (markedValue && markedValue.scrollTarget) {
      return "located_without_visible_mark";
    }
    if (anchorHasRenderedTextRanges(anchor)) {
      return "rendered_range_miss";
    }
    const sourceElements = sourceElementsForAnchor(article, anchor);
    const sourceBlockElements = sourceElements.length ? [] : mainTextBlockElementsForAnchor(article, anchor);
    if (sourceElementsUseTableLayout(sourceElements) || sourceElementsUseTableLayout(sourceBlockElements)) {
      return "table_text_miss";
    }
    if (sourceElements.length || sourceBlockElements.length) {
      return "source_range_text_miss";
    }
    if (!textMatches(article, highlightedText(anchor)).length) {
      return "text_not_found";
    }
    return "mark_insertion_failed";
  }

  function markAnchor(anchor, isActive, options) {
    const requiresTextMatch = Boolean(options && options.requiresTextMatch);
    const article = articleForMessage(anchor && anchor.sourceMessageID);
    const query = highlightedText(anchor);
    if (!article || !query) {
      return null;
    }

    const anchorRange = sourceRangeForAnchor(anchor);
    const sourceElements = sourceElementsForAnchor(article, anchor);
    const sourceBlockElements = sourceElements.length ? [] : mainTextBlockElementsForAnchor(article, anchor);
    const mathSourceElements = sourceElements.filter(sourceElementIsMath);
    if (mathSourceElements.length) {
      const exactMathContainer = exactSourceContainerForAnchor(mathSourceElements, anchor) || mathSourceElements[0];
      const containerMark = markSourceContainer([exactMathContainer], anchor, isActive);
      if (containerMark) {
        return containerMark;
      }
    }
    const renderedRangeMarks = markRenderedTextRanges(article, anchor, isActive, { requiresTextMatch });
    if (renderedRangeMarks.length) {
      return renderedRangeMarks;
    }
    if (
      requiresTextMatch
      && Array.isArray(anchor && anchor.renderedTextSegments)
      && anchor.renderedTextSegments.length
    ) {
      const renderedSegmentMarks = markSegmentMatches([article], anchor, isActive, { requiresTextMatch });
      if (renderedSegmentMarks.length) {
        return renderedSegmentMarks;
      }
    }
    if (requiresTextMatch && anchorHasRenderedTextRanges(anchor)) {
      return [];
    }
    const articleMatches = textMatches(article, query);
    const occurrence = targetOccurrence(anchor);
    const targetMatch = occurrence !== null ? articleMatches[occurrence] : null;
    const sourceElementsAreTableLike = sourceElementsUseTableLayout(sourceElements);

    if (sourceElementsAreTableLike) {
      const tableCellMarks = markTableCellSegmentMatches(sourceElements, anchor, isActive, { requiresTextMatch });
      if (tableCellMarks.length) {
        return tableCellMarks;
      }
      if (targetMatch && matchIsInsideSingleTableCell(targetMatch)) {
        const mark = markTextMatch(targetMatch, anchor, isActive, { requiresTextMatch });
        if (mark) {
          return mark;
        }
      }
      if (!requiresTextMatch) {
        const fallbackTableCell = tableCellElementsForSourceElements(sourceElements)[0] || sourceElements[0];
        const containerMark = markSourceContainer([fallbackTableCell], anchor, isActive);
        if (containerMark) {
          return containerMark;
        }
      }
    }

    if (!sourceElementsAreTableLike && targetMatch && (!sourceElements.length || sourceElements.some(function(element) {
      return matchIsInsideElement(targetMatch, element);
    }))) {
      const mark = markTextMatch(targetMatch, anchor, isActive, { requiresTextMatch });
      if (mark) {
        return mark;
      }
    }

    if (sourceElements.length) {
      if (!sourceElementsAreTableLike) {
        const sourceMatch = articleMatches.find(function(match) {
          return sourceElements.some(function(element) {
            return matchIsInsideElement(match, element);
          });
        });
        if (sourceMatch) {
          const mark = markTextMatch(sourceMatch, anchor, isActive, { requiresTextMatch });
          if (mark) {
            return mark;
          }
        }

        for (const sourceElement of sourceElements) {
          const localMatches = textMatches(sourceElement, query);
          if (localMatches.length) {
            const mark = markTextMatch(localMatches[0], anchor, isActive, { requiresTextMatch });
            if (mark) {
              return mark;
            }
          }
        }

        const segmentMarks = markSegmentMatches(sourceElements, anchor, isActive, { requiresTextMatch });
        if (segmentMarks.length) {
          return segmentMarks;
        }
      }

      const exactContainer = exactSourceContainerForAnchor(sourceElements, anchor);
      if (!requiresTextMatch && exactContainer && !sourceElementUsesTableLayout(exactContainer)) {
        return markSourceContainer([exactContainer], anchor, isActive);
      }
      if (!requiresTextMatch && isActive && sourceElements[0] && !sourceElementUsesTableLayout(sourceElements[0])) {
        return markSourceContainer([sourceElements[0]], anchor, isActive);
      }
      if (!requiresTextMatch && sourceElements[0] && !sourceElementUsesTableLayout(sourceElements[0])) {
        return markSourceContainer([sourceElements[0]], anchor, isActive);
      }
      return {
        marks: [],
        scrollTarget: sourceElements[0] || null
      };
    }

    if (sourceBlockElements.length) {
      const sourceBlockElementsAreTableLike = sourceElementsUseTableLayout(sourceBlockElements);
      if (sourceBlockElementsAreTableLike) {
        const tableCellMarks = markTableCellSegmentMatches(sourceBlockElements, anchor, isActive, { requiresTextMatch });
        if (tableCellMarks.length) {
          return tableCellMarks;
        }
        if (!requiresTextMatch) {
          const fallbackTableCell = tableCellElementsForSourceElements(sourceBlockElements)[0] || sourceBlockElements[0];
          const containerMark = markSourceContainer([fallbackTableCell], anchor, isActive);
          if (containerMark) {
            return containerMark;
          }
        }
      }
      const blockSegmentMarks = markSegmentMatches(sourceBlockElements, anchor, isActive, { requiresTextMatch });
      if (blockSegmentMarks.length) {
        return blockSegmentMarks;
      }
      if (sourceBlockElementsAreTableLike) {
        return {
          marks: [],
          scrollTarget: tableCellElementsForSourceElements(sourceBlockElements)[0] || sourceBlockElements[0] || null
        };
      }
      if (requiresTextMatch) {
        return {
          marks: [],
          scrollTarget: sourceBlockElements[0] || null
        };
      }
      return markSourceContainer(sourceBlockElements, anchor, isActive);
    }

    if (targetMatch) {
      const mark = markTextMatch(targetMatch, anchor, isActive, { requiresTextMatch });
      if (mark) {
        return mark;
      }
    }
    if (anchorRange && !isActive) {
      return null;
    }
    if (articleMatches.length) {
      const mark = markTextMatch(articleMatches[0], anchor, isActive, { requiresTextMatch });
      if (mark) {
        return mark;
      }
    }
    const articleSegmentMarks = markSegmentMatches([article], anchor, isActive, { requiresTextMatch });
    if (articleSegmentMarks.length) {
      return articleSegmentMarks;
    }
    return null;
  }

  function scheduleRetry(state, retryAttempt) {
    cancelRetryTimer();
    retryTimer = window.setTimeout(function() {
      retryTimer = 0;
      apply(state, { retryAttempt: retryAttempt });
    }, retryAttempt <= 1 ? 60 : 140);
  }

  function apply(state, options) {
    const retryAttempt = Math.max(0, Math.trunc(Number(options && options.retryAttempt) || 0));
    const activationScopeID = activationScopeIDForState(state);
    const activationSequence = activationSequenceForState(state);
    if (activationScopeID && activationScopeID !== lastAppliedActivationScopeID) {
      lastAppliedActivationScopeID = activationScopeID;
      lastAppliedActivationSequence = -1;
    }
    if (activationSequence !== null && activationSequence < lastAppliedActivationSequence) {
      return staleApplyStatus(state, retryAttempt);
    }
    if (activationSequence !== null) {
      lastAppliedActivationSequence = activationSequence;
    }
    if (retryAttempt === 0) {
      cancelRetryTimer();
    }
    clearMarks();
    const anchors = Array.isArray(state && state.anchors) ? state.anchors : [];
    const activeAnchorID = String(state && state.activeAnchorID || "");
    let activeMark = null;
    let activeAnchorVisible = false;
    let activeHighlightCount = 0;
    let activeMissReason = "";
    let highlightedCount = 0;

    for (const anchor of anchors) {
      const anchorID = String(anchor && anchor.id || "");
      const markedValue = markAnchor(anchor, activeAnchorID && anchorID === activeAnchorID, state);
      const marks = markedElements(markedValue);
      if (marks.length) {
        highlightedCount += marks.length;
      }
      if (activeAnchorID && anchorID === activeAnchorID) {
        activeAnchorVisible = true;
        activeHighlightCount = marks.length;
        activeMissReason = anchorMissReason(anchor, markedValue, marks);
        activeMark = scrollTargetForMarkedValue(markedValue, marks);
      }
    }

    if (activeAnchorID && !activeAnchorVisible) {
      activeMissReason = anchors.length ? "active_anchor_not_visible" : "no_visible_anchors";
    }

    if (activeMark) {
      activeMark.scrollIntoView({ block: "center", inline: "nearest", behavior: "auto" });
    }
    if (activeAnchorID && !activeMark && retryAttempt < 4) {
      scheduleRetry(state, retryAttempt + 1);
    }
    return {
      highlightedCount: highlightedCount,
      activeAnchorID: activeAnchorID || null,
      activeAnchorVisible: activeAnchorVisible,
      visibleAnchorCount: anchors.length,
      activeHighlightCount: activeHighlightCount,
      activeMarkFound: Boolean(activeMark),
      activeMissReason: activeMissReason || null,
      retryAttempt: retryAttempt
    };
  }

  document.addEventListener("click", function(event) {
    const target = event.target && event.target.closest
      ? event.target.closest("mark." + anchorClassName + ", ." + containerClassName)
      : null;
    if (!target || !target.dataset.anchorId) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.explanationAnchor;
    if (bridge) {
      bridge.postMessage({ anchorID: target.dataset.anchorId });
    }
  }, true);

  document.addEventListener("mouseover", function(event) {
    const target = anchorTargetFromEvent(event);
    if (!target || !target.dataset.anchorId) {
      return;
    }
    const relatedTarget = event.relatedTarget;
    const relatedAnchor = anchorTargetFromNode(relatedTarget);
    if (
      relatedAnchor
      && relatedAnchor.dataset
      && relatedAnchor.dataset.anchorId === target.dataset.anchorId
    ) {
      return;
    }
    removeNativeTooltipAttributes(target);
    setHoveredAnchor(target.dataset.anchorId);
    scheduleAnchorTooltip(target);
  }, true);

  document.addEventListener("mouseout", function(event) {
    const target = anchorTargetFromEvent(event);
    if (!target || !target.dataset.anchorId) {
      return;
    }
    const relatedTarget = event.relatedTarget;
    const relatedAnchor = anchorTargetFromNode(relatedTarget);
    if (
      relatedAnchor
      && relatedAnchor.dataset
      && relatedAnchor.dataset.anchorId === target.dataset.anchorId
    ) {
      return;
    }
    clearHoveredAnchors();
    hideAnchorTooltip();
  }, true);

  function hideAnchorTooltipAndHover() {
    clearHoveredAnchors();
    hideAnchorTooltip();
  }

  document.addEventListener("scroll", hideAnchorTooltipAndHover, true);
  window.addEventListener("resize", hideAnchorTooltipAndHover);

  window.AIReadingChatTranscriptExplanationAnchors = {
    version: apiVersion,
    apply,
    clearMarks
  };
  return window.AIReadingChatTranscriptExplanationAnchors;
}

  installExplanationAnchorAPI();
})();
