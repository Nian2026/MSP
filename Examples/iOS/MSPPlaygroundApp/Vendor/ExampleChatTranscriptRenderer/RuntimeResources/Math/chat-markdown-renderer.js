(function () {
  function detectRenderFeatures(markdown) {
    const source = String(markdown || "");
    return {
      hasCodeBlocks: source.includes("```"),
      hasCodeLikeContent: source.includes("```") || source.includes("`")
    };
  }

  function hydrateMarkdownStyleShadows(root) {
    if (!root || typeof root.querySelectorAll !== "function") {
      return;
    }

    root.querySelectorAll(".markdown-style-shadow[data-style-css]").forEach((host) => {
      if (!host || host.dataset.exampleChatStyleShadowHydrated === "true") {
        return;
      }

      let cssText = "";
      try {
        cssText = decodeURIComponent(host.dataset.styleCss || "");
      } catch (error) {
        cssText = host.dataset.styleCss || "";
      }

      host.dataset.exampleChatStyleShadowHydrated = "true";
      host.setAttribute("aria-hidden", "true");
      host.style.display = "none";

      if (!cssText || typeof host.attachShadow !== "function") {
        return;
      }

      try {
        const shadow = host.shadowRoot || host.attachShadow({ mode: "open" });
        shadow.replaceChildren();
        const style = document.createElement("style");
        style.textContent = cssText;
        shadow.appendChild(style);
      } catch (error) {
        // Some embedded HTML contexts may not allow shadow roots; keeping the inert host is still safer than
        // allowing message-provided styles to leak into the document.
      }
    });
  }

  function unifiedMarkdownEngine() {
    const engine = window.ChatUnifiedMarkdown;
    if (!engine || typeof engine.renderToHtml !== "function") {
      return null;
    }
    return engine;
  }

  function hasRenderableMarkdownEngine() {
    return Boolean(unifiedMarkdownEngine());
  }

  function activeMarkdownEngineName() {
    return unifiedMarkdownEngine() ? "unified" : "plain-text";
  }

  let headingPrefixSequence = 0;

  function ensureHeadingIdPrefixForContent(content) {
    if (!content) {
      return "content";
    }

    if (typeof content.__exampleChatHeadingIdPrefix === "string" && content.__exampleChatHeadingIdPrefix) {
      return content.__exampleChatHeadingIdPrefix;
    }

    headingPrefixSequence += 1;
    const prefix = `content-${headingPrefixSequence}`;
    content.__exampleChatHeadingIdPrefix = prefix;
    return prefix;
  }

  function renderBlockHtmlWithPreferredEngine(markdown, options) {
    const resolvedOptions = options && typeof options === "object" ? options : {};
    const engine = unifiedMarkdownEngine();
    if (!engine) {
      return {
        html: renderUserHTML(markdown),
        engine: "plain-text"
      };
    }

    const primaryMathRenderer =
      typeof resolvedOptions.mathRenderer === "string" && resolvedOptions.mathRenderer.trim()
        ? resolvedOptions.mathRenderer.trim().toLowerCase()
        : "katex";
    const fallbackMathRenderer =
      typeof resolvedOptions.mathFallbackRenderer === "string"
        ? resolvedOptions.mathFallbackRenderer.trim().toLowerCase()
        : (primaryMathRenderer === "mathjax" ? "none" : "mathjax");

    return {
      html: engine.renderToHtml(markdown, {
        allowRawHtml: true,
        headingIdPrefix: resolvedOptions.headingIdPrefix,
        mathRenderer: primaryMathRenderer,
        mathFallbackRenderer: fallbackMathRenderer,
        mathEnableSingleDollar: true,
        renderMath: resolvedOptions.renderMath !== false
      }),
      engine: "unified"
    };
  }

  function renderDocumentWithUnifiedEngine(markdown, options) {
    const resolvedOptions = options && typeof options === "object" ? options : {};
    const engine = unifiedMarkdownEngine();
    if (!engine || typeof engine.renderMarkdownDocument !== "function") {
      return null;
    }

    const primaryMathRenderer =
      typeof resolvedOptions.mathRenderer === "string" && resolvedOptions.mathRenderer.trim()
        ? resolvedOptions.mathRenderer.trim().toLowerCase()
        : "katex";
    const fallbackMathRenderer =
      typeof resolvedOptions.mathFallbackRenderer === "string"
        ? resolvedOptions.mathFallbackRenderer.trim().toLowerCase()
        : (primaryMathRenderer === "mathjax" ? "none" : "mathjax");

    const renderedDocument = engine.renderMarkdownDocument(markdown, {
      allowRawHtml: true,
      headingIdPrefix: resolvedOptions.headingIdPrefix,
      mathRenderer: primaryMathRenderer,
      mathFallbackRenderer: fallbackMathRenderer,
      mathEnableSingleDollar: true,
      renderMath: resolvedOptions.renderMath !== false
    });

    if (!renderedDocument || typeof renderedDocument.html !== "string") {
      return null;
    }

    return {
      html: renderedDocument.html,
      blocks: Array.isArray(renderedDocument.blocks) ? renderedDocument.blocks : [],
      mathSpans: Array.isArray(renderedDocument.mathSpans) ? renderedDocument.mathSpans : []
    };
  }

  function markdownLineRanges(source) {
    const text = String(source || "");
    const lines = [];
    let index = 0;

    while (index < text.length) {
      const start = index;
      const newlineIndex = text.indexOf("\n", index);
      const contentEnd = newlineIndex === -1 ? text.length : newlineIndex;
      const end = newlineIndex === -1 ? text.length : newlineIndex + 1;
      lines.push({
        start,
        end,
        contentEnd,
        text: text.slice(start, contentEnd)
      });
      index = end;
    }

    return lines;
  }

  function isBlankMarkdownLine(line) {
    return !line || !line.text || !line.text.trim();
  }

  function isMarkdownFenceLine(line) {
    return /^\s*(```|~~~)/.test(line.text || "");
  }

  function isMarkdownHeadingLine(line) {
    return /^\s{0,3}#{1,6}\s+/.test(line.text || "");
  }

  function markdownListItemIndent(line) {
    const match = /^(\s{0,12})(?:[-*+]\s+|\d+[.)]\s+)/.exec(line.text || "");
    return match ? match[1].length : null;
  }

  function markdownLineIndent(line) {
    const match = /^(\s*)/.exec(line.text || "");
    return match ? match[1].replace(/\t/g, "    ").length : 0;
  }

  function isMarkdownBlockquoteLine(line) {
    return /^\s{0,3}>/.test(line.text || "");
  }

  function nextNonBlankMarkdownLineIndex(lines, startIndex) {
    for (let index = startIndex; index < lines.length; index += 1) {
      if (!isBlankMarkdownLine(lines[index])) {
        return index;
      }
    }
    return -1;
  }

  function trimmedSourceBlockRange(source, start, end) {
    let lower = Math.max(0, start);
    let upper = Math.min(source.length, end);

    while (lower < upper && /\s/.test(source[lower])) {
      lower += 1;
    }
    while (lower < upper && /\s/.test(source[upper - 1])) {
      upper -= 1;
    }

    return lower < upper ? { start: lower, end: upper } : null;
  }

  function markdownSourceBlocks(markdown) {
    const source = String(markdown || "");
    const lines = markdownLineRanges(source);
    const blocks = [];
    let lineIndex = 0;

    while (lineIndex < lines.length) {
      const line = lines[lineIndex];
      if (isBlankMarkdownLine(line)) {
        lineIndex += 1;
        continue;
      }

      if (isMarkdownFenceLine(line)) {
        const start = line.start;
        const fence = /^\s*(```|~~~)/.exec(line.text || "")?.[1] || "```";
        lineIndex += 1;
        while (lineIndex < lines.length && !lines[lineIndex].text.trimStart().startsWith(fence)) {
          lineIndex += 1;
        }
        if (lineIndex < lines.length) {
          lineIndex += 1;
        }
        const end = lines[lineIndex - 1]?.contentEnd ?? line.contentEnd;
        const range = trimmedSourceBlockRange(source, start, end);
        if (range) {
          blocks.push(range);
        }
        continue;
      }

      if (isMarkdownHeadingLine(line)) {
        const range = trimmedSourceBlockRange(source, line.start, line.contentEnd);
        if (range) {
          blocks.push(range);
        }
        lineIndex += 1;
        continue;
      }

      const listIndent = markdownListItemIndent(line);
      if (listIndent !== null) {
        const start = line.start;
        lineIndex += 1;
        while (lineIndex < lines.length) {
          const nextLine = lines[lineIndex];
          if (isBlankMarkdownLine(nextLine)) {
            break;
          }
          const nextListIndent = markdownListItemIndent(nextLine);
          if (nextListIndent !== null && nextListIndent <= listIndent) {
            break;
          }
          lineIndex += 1;
        }
        const end = lines[lineIndex - 1]?.contentEnd ?? line.contentEnd;
        const range = trimmedSourceBlockRange(source, start, end);
        if (range) {
          blocks.push(range);
        }
        continue;
      }

      const start = line.start;
      lineIndex += 1;
      while (lineIndex < lines.length) {
        const nextLine = lines[lineIndex];
        if (
          isBlankMarkdownLine(nextLine)
          || isMarkdownHeadingLine(nextLine)
          || markdownListItemIndent(nextLine) !== null
          || isMarkdownFenceLine(nextLine)
        ) {
          break;
        }
        lineIndex += 1;
      }
      const end = lines[lineIndex - 1]?.contentEnd ?? line.contentEnd;
      const range = trimmedSourceBlockRange(source, start, end);
      if (range) {
        blocks.push(range);
      }
    }

    return blocks;
  }

  function markdownSourceRenderBlocks(markdown) {
    const source = String(markdown || "");
    const lines = markdownLineRanges(source);
    const blocks = [];
    let lineIndex = 0;

    while (lineIndex < lines.length) {
      const line = lines[lineIndex];
      if (isBlankMarkdownLine(line)) {
        lineIndex += 1;
        continue;
      }

      if (isMarkdownFenceLine(line)) {
        const start = line.start;
        const fence = /^\s*(```|~~~)/.exec(line.text || "")?.[1] || "```";
        lineIndex += 1;
        while (lineIndex < lines.length && !lines[lineIndex].text.trimStart().startsWith(fence)) {
          lineIndex += 1;
        }
        if (lineIndex < lines.length) {
          lineIndex += 1;
        }
        const end = lines[lineIndex - 1]?.contentEnd ?? line.contentEnd;
        const range = trimmedSourceBlockRange(source, start, end);
        if (range) {
          blocks.push(range);
        }
        continue;
      }

      if (isMarkdownHeadingLine(line)) {
        const range = trimmedSourceBlockRange(source, line.start, line.contentEnd);
        if (range) {
          blocks.push(range);
        }
        lineIndex += 1;
        continue;
      }

      const listIndent = markdownListItemIndent(line);
      if (listIndent !== null) {
        const start = line.start;
        lineIndex += 1;
        while (lineIndex < lines.length) {
          const nextLine = lines[lineIndex];
          if (isBlankMarkdownLine(nextLine)) {
            const lookaheadIndex = nextNonBlankMarkdownLineIndex(lines, lineIndex + 1);
            if (lookaheadIndex === -1) {
              break;
            }
            const lookaheadLine = lines[lookaheadIndex];
            const lookaheadListIndent = markdownListItemIndent(lookaheadLine);
            const lookaheadIndent = markdownLineIndent(lookaheadLine);
            if (lookaheadListIndent !== null || lookaheadIndent > listIndent) {
              lineIndex += 1;
              continue;
            }
            break;
          }

          const nextListIndent = markdownListItemIndent(nextLine);
          if (nextListIndent !== null || markdownLineIndent(nextLine) > listIndent) {
            lineIndex += 1;
            continue;
          }
          if (
            isMarkdownHeadingLine(nextLine)
            || isMarkdownFenceLine(nextLine)
            || isMarkdownBlockquoteLine(nextLine)
          ) {
            break;
          }
          lineIndex += 1;
        }
        const end = lines[lineIndex - 1]?.contentEnd ?? line.contentEnd;
        const range = trimmedSourceBlockRange(source, start, end);
        if (range) {
          blocks.push(range);
        }
        continue;
      }

      if (isMarkdownBlockquoteLine(line)) {
        const start = line.start;
        lineIndex += 1;
        while (lineIndex < lines.length) {
          const nextLine = lines[lineIndex];
          if (isBlankMarkdownLine(nextLine)) {
            const lookaheadIndex = nextNonBlankMarkdownLineIndex(lines, lineIndex + 1);
            if (lookaheadIndex !== -1 && isMarkdownBlockquoteLine(lines[lookaheadIndex])) {
              lineIndex += 1;
              continue;
            }
            break;
          }
          if (!isMarkdownBlockquoteLine(nextLine)) {
            break;
          }
          lineIndex += 1;
        }
        const end = lines[lineIndex - 1]?.contentEnd ?? line.contentEnd;
        const range = trimmedSourceBlockRange(source, start, end);
        if (range) {
          blocks.push(range);
        }
        continue;
      }

      const start = line.start;
      lineIndex += 1;
      while (lineIndex < lines.length) {
        const nextLine = lines[lineIndex];
        if (
          isBlankMarkdownLine(nextLine)
          || isMarkdownHeadingLine(nextLine)
          || markdownListItemIndent(nextLine) !== null
          || isMarkdownFenceLine(nextLine)
          || isMarkdownBlockquoteLine(nextLine)
        ) {
          break;
        }
        lineIndex += 1;
      }
      const end = lines[lineIndex - 1]?.contentEnd ?? line.contentEnd;
      const range = trimmedSourceBlockRange(source, start, end);
      if (range) {
        blocks.push(range);
      }
    }

    return blocks;
  }

  function applyMarkdownSourceRange(element, block, index) {
    if (!element || !element.dataset || !block) {
      return;
    }

    if (Number.isFinite(index)) {
      element.dataset.exampleChatSourceIndex = String(index);
    }
    element.dataset.exampleChatSourceStart = String(block.start);
    element.dataset.exampleChatSourceEnd = String(block.end);
    if (typeof block.kind === "string" && block.kind) {
      element.dataset.exampleChatSourceKind = block.kind;
    }
  }

  function normalizeMarkdownSourceBlock(block) {
    if (!block || typeof block !== "object") {
      return null;
    }

    const start = Number(block.start);
    const end = Number(block.end);
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
      return null;
    }

    return {
      start: Math.trunc(start),
      end: Math.trunc(end),
      kind: typeof block.kind === "string" && block.kind ? block.kind : ""
    };
  }

  function shiftMarkdownSourceSpans(spans, offset) {
    const sourceSpans = Array.isArray(spans) ? spans : [];
    const delta = Number(offset);
    return sourceSpans.map((span) => {
      const normalized = normalizeMarkdownSourceBlock(span);
      if (!normalized) {
        return null;
      }
      if (!Number.isFinite(delta) || delta === 0) {
        return normalized;
      }
      return {
        start: normalized.start + Math.trunc(delta),
        end: normalized.end + Math.trunc(delta),
        kind: normalized.kind
      };
    }).filter(Boolean);
  }

  function annotateTopLevelMarkdownSourceNodes(root, block, index) {
    if (!root || !block) {
      return;
    }

    Array.from(root.children).forEach((element) => {
      applyMarkdownSourceRange(element, block, index);
    });
  }

  function annotateRenderedTopLevelSourceBlocks(root, blocks) {
    const elements = Array.from(root?.children || []);
    const sourceBlocks = Array.isArray(blocks)
      ? blocks.map((block) => normalizeMarkdownSourceBlock(block)).filter(Boolean)
      : [];

    if (!elements.length && !sourceBlocks.length) {
      return {
        ok: true,
        blocks: []
      };
    }

    if (!elements.length || elements.length !== sourceBlocks.length) {
      return {
        ok: false,
        blocks: []
      };
    }

    elements.forEach((element, index) => {
      applyMarkdownSourceRange(element, sourceBlocks[index], index);
    });

    return {
      ok: true,
      blocks: sourceBlocks
    };
  }

  function mathSourceElements(root) {
    if (!root) {
      return [];
    }

    return Array.from(root.querySelectorAll([
      ".katex-display",
      ".katex",
      "mjx-container",
      ".katex-error",
      ".mathjax-error",
      ".math-placeholder-block",
      ".math-placeholder-inline"
    ].join(","))).filter((element) => {
      if (element.classList?.contains("katex") && element.closest(".katex-display")) {
        return false;
      }
      return true;
    });
  }

  function annotateRenderedMathSourceSpans(root, spans) {
    const elements = mathSourceElements(root);
    const sourceSpans = Array.isArray(spans)
      ? spans.map((span) => normalizeMarkdownSourceBlock(span)).filter(Boolean)
      : [];
    const count = Math.min(elements.length, sourceSpans.length);

    for (let index = 0; index < count; index += 1) {
      applyMarkdownSourceRange(elements[index], sourceSpans[index]);
    }

    return {
      elementCount: elements.length,
      spanCount: sourceSpans.length,
      annotatedCount: count
    };
  }

  function sourceBlockElements(root) {
    if (!root) {
      return [];
    }

    return Array.from(root.querySelectorAll([
      "p",
      "h1",
      "h2",
      "h3",
      "h4",
      "h5",
      "h6",
      "li",
      "pre",
      "blockquote",
      "table",
      "hr",
      ".katex-display",
      "mjx-container[display='true']",
      ".math-placeholder-block"
    ].join(","))).filter((element) => {
      if (
        (
          element.classList?.contains("katex-display")
          || element.tagName === "MJX-CONTAINER"
        )
        && element.parentElement !== root
      ) {
        return false;
      }
      if (element.closest("li") && element.tagName !== "LI") {
        return false;
      }
      if (element.closest("blockquote") && element.tagName !== "BLOCKQUOTE") {
        return false;
      }
      return true;
    });
  }

  function annotateMarkdownSourceBlocks(root, markdown) {
    if (!root) {
      return;
    }

    const source = String(markdown || "");
    const blocks = markdownSourceBlocks(source);
    const elements = sourceBlockElements(root);
    const count = Math.min(blocks.length, elements.length);

    for (let index = 0; index < count; index += 1) {
      const block = blocks[index];
      const element = elements[index];
      element.dataset.exampleChatSourceIndex = String(index);
      element.dataset.exampleChatSourceStart = String(block.start);
      element.dataset.exampleChatSourceEnd = String(block.end);
    }
  }

  const STREAMING_RENDER_STATE_VERSION = 1;

  function renderOptionsFingerprint(options) {
    const resolvedOptions = options && typeof options === "object" ? options : {};
    return [
      resolvedOptions.renderMath !== false ? "math:1" : "math:0",
      resolvedOptions.highlightCode !== false ? "highlight:1" : "highlight:0",
      resolvedOptions.codeChrome !== false ? "chrome:1" : "chrome:0",
      resolvedOptions.formatCode !== false ? "format:1" : "format:0",
      resolvedOptions.autoDetectLanguages !== false ? "auto:1" : "auto:0"
    ].join("|");
  }

  function rememberStreamingRenderState(content, markdown, blocks, options) {
    if (!content) {
      return;
    }

    content.__streamingMarkdownState = {
      version: STREAMING_RENDER_STATE_VERSION,
      markdown: String(markdown || ""),
      blocks: Array.isArray(blocks) ? blocks.map((block) => ({
        start: block.start,
        end: block.end
      })) : [],
      optionsFingerprint: renderOptionsFingerprint(options)
    };
  }

  function clearStreamingRenderState(content) {
    if (content) {
      content.__streamingMarkdownState = null;
    }
  }

  const STREAMING_SMOOTH_SEGMENTER_LANGUAGES = [
    "en-US",
    "de-DE",
    "es-ES",
    "zh-CN",
    "zh-TW",
    "ja-JP",
    "ru-RU",
    "el-GR",
    "fr-FR",
    "pt-PT",
    "ro-RO"
  ];
  const streamingSmoothSegmenter = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
    ? new Intl.Segmenter(STREAMING_SMOOTH_SEGMENTER_LANGUAGES)
    : null;

  function segmentStreamingText(text) {
    const source = String(text || "");
    if (!source) {
      return [];
    }

    if (!streamingSmoothSegmenter) {
      return Array.from(source);
    }

    return Array.from(streamingSmoothSegmenter.segment(source), (segment) => segment.segment);
  }

  function clearSmoothStreamingController(content) {
    if (!content || !content.__smoothStreamingController) {
      return;
    }

    const controller = content.__smoothStreamingController;
    if (controller.frameId !== null) {
      window.cancelAnimationFrame(controller.frameId);
      controller.frameId = null;
    }
    controller.pendingSegments = [];
    controller.displayedMarkdown = "";
    controller.targetMarkdown = "";
    controller.lastPumpTime = 0;
    content.dataset.exampleChatSmoothStreaming = "false";
    content.dataset.exampleChatStreamingLayoutSource = "content";
    content.__smoothStreamingController = null;
  }

  function equivalentRenderedTopLevelNode(currentNode, nextNode) {
    if (!currentNode || !nextNode) {
      return false;
    }

    if (typeof currentNode.isEqualNode === "function") {
      return currentNode.isEqualNode(nextNode);
    }

    return (currentNode.outerHTML || "") === (nextNode.outerHTML || "");
  }

  function canPatchRenderedNode(currentNode, nextNode) {
    if (!currentNode || !nextNode) {
      return false;
    }

    if (currentNode.nodeType !== nextNode.nodeType) {
      return false;
    }

    if (currentNode.nodeType === Node.ELEMENT_NODE) {
      return currentNode.tagName === nextNode.tagName && currentNode.namespaceURI === nextNode.namespaceURI;
    }

    return true;
  }

  function syncRenderedElementAttributes(currentElement, nextElement, patchMetrics) {
    const currentAttributeNames = typeof currentElement.getAttributeNames === "function"
      ? currentElement.getAttributeNames()
      : Array.from(currentElement.attributes || [], (attribute) => attribute.name);
    const nextAttributes = Array.from(nextElement.attributes || []);
    const nextAttributeNames = new Set(nextAttributes.map((attribute) => attribute.name));

    currentAttributeNames.forEach((attributeName) => {
      if (!nextAttributeNames.has(attributeName)) {
        currentElement.removeAttribute(attributeName);
        patchMetrics.attributeMutationCount += 1;
      }
    });

    nextAttributes.forEach((attribute) => {
      if (currentElement.getAttribute(attribute.name) !== attribute.value) {
        currentElement.setAttribute(attribute.name, attribute.value);
        patchMetrics.attributeMutationCount += 1;
      }
    });
  }

  function patchRenderedChildren(currentParent, nextParent, patchMetrics) {
    const nextChildren = Array.from(nextParent?.childNodes || []);
    let currentIndex = 0;

    for (let nextIndex = 0; nextIndex < nextChildren.length; nextIndex += 1) {
      const nextChild = nextChildren[nextIndex];
      const currentChild = currentParent.childNodes[currentIndex] || null;

      if (!currentChild) {
        currentParent.appendChild(nextChild.cloneNode(true));
        patchMetrics.appendedNodeCount += 1;
        currentIndex += 1;
        continue;
      }

      if (!canPatchRenderedNode(currentChild, nextChild)) {
        currentParent.replaceChild(nextChild.cloneNode(true), currentChild);
        patchMetrics.replacedNodeCount += 1;
        currentIndex += 1;
        continue;
      }

      patchRenderedNode(currentChild, nextChild, patchMetrics);
      currentIndex += 1;
    }

    while (currentParent.childNodes.length > nextChildren.length) {
      currentParent.lastChild?.remove();
      patchMetrics.removedNodeCount += 1;
    }
  }

  function patchRenderedNode(currentNode, nextNode, patchMetrics) {
    if (!canPatchRenderedNode(currentNode, nextNode)) {
      return false;
    }

    patchMetrics.patchedNodeCount += 1;

    if (currentNode.nodeType === Node.TEXT_NODE || currentNode.nodeType === Node.COMMENT_NODE) {
      if (currentNode.nodeValue !== nextNode.nodeValue) {
        currentNode.nodeValue = nextNode.nodeValue;
        patchMetrics.textMutationCount += 1;
      }
      return true;
    }

    if (currentNode.nodeType === Node.ELEMENT_NODE) {
      syncRenderedElementAttributes(currentNode, nextNode, patchMetrics);
      patchRenderedChildren(currentNode, nextNode, patchMetrics);
      return true;
    }

    if (currentNode.textContent !== nextNode.textContent) {
      currentNode.textContent = nextNode.textContent || "";
      patchMetrics.textMutationCount += 1;
    }

    return true;
  }

  function patchRenderedTreeIntoContent(content, renderedSource) {
    const currentChildren = Array.from(content?.children || []);
    const renderedChildren = Array.from(renderedSource?.children || []);
    const maxPrefix = Math.min(currentChildren.length, renderedChildren.length);
    let stableRenderedChildCount = 0;

    while (
      stableRenderedChildCount < maxPrefix
      && equivalentRenderedTopLevelNode(
        currentChildren[stableRenderedChildCount],
        renderedChildren[stableRenderedChildCount]
      )
    ) {
      stableRenderedChildCount += 1;
    }

    const patchMetrics = {
      stableRenderedChildCount,
      replacedRenderedChildCount: Math.max(
        currentChildren.length - stableRenderedChildCount,
        renderedChildren.length - stableRenderedChildCount
      ),
      removedNodeCount: 0,
      appendedNodeCount: 0,
      replacedNodeCount: 0,
      patchedNodeCount: 0,
      textMutationCount: 0,
      attributeMutationCount: 0
    };

    patchRenderedChildren(content, renderedSource, patchMetrics);
    renderedSource.replaceChildren();
    return patchMetrics;
  }

  function notifyObservedLayoutChange(reason) {
    const layoutHandler = window.webkit?.messageHandlers?.codeBlockLayoutChanged;
    if (!layoutHandler || typeof layoutHandler.postMessage !== "function") {
      return;
    }

    layoutHandler.postMessage({
      reason: String(reason || "content_layout")
    });
  }

  function runAfterRenderHook(content, options) {
    const hook = options && typeof options.afterRender === "function" ? options.afterRender : null;
    if (!hook) {
      return;
    }

    try {
      hook(content);
    } catch (_) {
      // Rendering should not fail because a post-render decoration hook failed.
    }
  }

  function renderDisplayedMarkdownIntoContent(content, markdown, options) {
    const resolvedOptions = Object.assign({}, options || {}, {
      streaming: false,
      progressive: false,
      headingIdPrefix: ensureHeadingIdPrefixForContent(content)
    });
    const source = String(markdown || "");
    const previousState = content?.__streamingMarkdownState || null;
    const canReusePreviousBlocks = Boolean(
      previousState
      && previousState.version === STREAMING_RENDER_STATE_VERSION
      && previousState.optionsFingerprint === renderOptionsFingerprint(resolvedOptions)
      && typeof previousState.markdown === "string"
      && Array.isArray(previousState.blocks)
    );
    const canPatchTail = canReusePreviousBlocks && source.startsWith(previousState.markdown);
    if (!canPatchTail) {
      const renderedSource = content?.ownerDocument?.createElement("div") || document.createElement("div");
      const renderedMetrics = renderMarkdownInto(renderedSource, source, resolvedOptions);
      const patchMetrics = patchRenderedTreeIntoContent(content, renderedSource);
      const blocks = Array.isArray(renderedSource?.__streamingMarkdownState?.blocks)
        ? renderedSource.__streamingMarkdownState.blocks
        : markdownSourceRenderBlocks(source);
      decorateRenderedMarkdown(content, Object.assign({}, resolvedOptions, { sourceMarkdown: source }));
      rememberStreamingRenderState(content, source, blocks, resolvedOptions);
      content.style.whiteSpace = "normal";
      runAfterRenderHook(content, resolvedOptions);

      return Object.assign({}, renderedMetrics, patchMetrics, {
        sourceBlockCount: blocks.length
      });
    }

    const blocks = markdownSourceRenderBlocks(source);
    const stableBlockCount = stablePrefixBlockCount(previousState.markdown, previousState.blocks, source, blocks);
    const replacementStartBlockIndex = Math.min(stableBlockCount, blocks.length);
    const removedNodeCount = removeRenderedBlocksFrom(content, replacementStartBlockIndex);
    const stableRenderedChildCount = Array.from(content?.children || []).filter((child) => {
      const sourceIndex = topLevelSourceIndex(child);
      return sourceIndex !== null && sourceIndex < replacementStartBlockIndex;
    }).length;
    const fragment = renderSourceMappedMarkdownFragment(
      source,
      blocks,
      replacementStartBlockIndex,
      resolvedOptions
    );
    const appendedNodeCount = fragment.childNodes.length;
    content.appendChild(fragment);
    decorateRenderedMarkdown(content, Object.assign({}, resolvedOptions, { sourceMarkdown: source }));
    rememberStreamingRenderState(content, source, blocks, resolvedOptions);
    content.style.whiteSpace = "normal";
    runAfterRenderHook(content, resolvedOptions);

    return {
      renderedLength: measureRenderedLength(content, resolvedOptions),
      renderDurationMs: 0,
      engine: replacementStartBlockIndex > 0 ? "streaming-source-mapped-tail" : "streaming-source-mapped-root",
      stableRenderedChildCount,
      replacedRenderedChildCount: Math.max(removedNodeCount, appendedNodeCount),
      removedNodeCount,
      appendedNodeCount,
      replacedNodeCount: 0,
      patchedNodeCount: 0,
      textMutationCount: 0,
      attributeMutationCount: 0,
      sourceBlockCount: blocks.length
    };
  }

  function createSmoothStreamingController(content, options) {
    if (content && content.dataset) {
      content.dataset.exampleChatSmoothStreaming = "false";
      content.dataset.exampleChatStreamingLayoutSource = "content";
    }

    return {
      version: 1,
      content,
      optionsFingerprint: renderOptionsFingerprint(options),
      resolvedOptions: Object.assign({}, options || {}),
      targetMarkdown: "",
      displayedMarkdown: "",
      pendingSegments: [],
      frameId: null,
      lastPumpTime: 0,
      lastCommittedMetrics: null
    };
  }

  function ensureSmoothStreamingController(content, options) {
    const optionsFingerprint = renderOptionsFingerprint(options);
    let controller = content?.__smoothStreamingController || null;

    if (
      !controller
      || controller.version !== 1
      || controller.optionsFingerprint !== optionsFingerprint
      || controller.content !== content
    ) {
      clearSmoothStreamingController(content);
      controller = createSmoothStreamingController(content, options);
      content.__smoothStreamingController = controller;
    } else {
      controller.optionsFingerprint = optionsFingerprint;
      controller.resolvedOptions = Object.assign({}, options || {});
    }

    return controller;
  }

  function smoothStreamingCharsPerFrame(controller, options) {
    const queuedCount = controller?.pendingSegments?.length || 0;
    if (queuedCount <= 0) {
      return 0;
    }

    const resolvedOptions = options && typeof options === "object" ? options : {};
    const divisor = Math.max(2, Number(resolvedOptions.streamingCatchUpDivisor) || 5);
    const minimumBatch = Math.max(1, Number(resolvedOptions.streamingMinimumBatch) || 1);
    return Math.max(minimumBatch, Math.floor(queuedCount / divisor));
  }

  function updateSmoothStreamingState(controller) {
    if (!controller || !controller.content) {
      return;
    }

    const isSmoothing =
      controller.pendingSegments.length > 0 || controller.displayedMarkdown !== controller.targetMarkdown;
    controller.content.dataset.exampleChatSmoothStreaming = isSmoothing ? "true" : "false";
    controller.content.dataset.exampleChatStreamingLayoutSource = "content";
  }

  function commitSmoothStreamingFrame(controller) {
    if (!controller) {
      return {
        renderedLength: 0,
        renderDurationMs: 0,
        engine: "streaming-smooth-missing-controller",
        stableRenderedChildCount: 0,
        replacedRenderedChildCount: 0,
        removedNodeCount: 0,
        appendedNodeCount: 0
      };
    }

    const commitStart = performance.now();
    const metrics = renderDisplayedMarkdownIntoContent(
      controller.content,
      controller.displayedMarkdown,
      controller.resolvedOptions
    );
    controller.lastCommittedMetrics = Object.assign({}, metrics, {
      renderDurationMs: performance.now() - commitStart
    });
    updateSmoothStreamingState(controller);
    return controller.lastCommittedMetrics;
  }

  function scheduleSmoothStreamingController(controller) {
    if (!controller || controller.frameId !== null) {
      return;
    }

    controller.frameId = window.requestAnimationFrame((timestamp) => {
      controller.frameId = null;
      pumpSmoothStreamingController(controller, timestamp, false);
    });
  }

  function pumpSmoothStreamingController(controller, timestamp, forceImmediate) {
    if (!controller) {
      return null;
    }

    if ((controller.pendingSegments?.length || 0) <= 0) {
      updateSmoothStreamingState(controller);
      return controller.lastCommittedMetrics;
    }

    const resolvedOptions = controller.resolvedOptions && typeof controller.resolvedOptions === "object"
      ? controller.resolvedOptions
      : {};
    const minDelay = Math.max(8, Number(resolvedOptions.streamingMinDelayMs) || 10);
    if (!forceImmediate && timestamp - controller.lastPumpTime < minDelay) {
      scheduleSmoothStreamingController(controller);
      return controller.lastCommittedMetrics;
    }

    controller.lastPumpTime = timestamp;
    const charsToRenderCount = smoothStreamingCharsPerFrame(controller, resolvedOptions);
    if (charsToRenderCount <= 0) {
      updateSmoothStreamingState(controller);
      return controller.lastCommittedMetrics;
    }

    const renderedSegments = controller.pendingSegments.splice(0, charsToRenderCount);
    controller.displayedMarkdown += renderedSegments.join("");
    const metrics = commitSmoothStreamingFrame(controller);

    if (controller.pendingSegments.length > 0) {
      scheduleSmoothStreamingController(controller);
    } else {
      updateSmoothStreamingState(controller);
    }

    return metrics;
  }

  function flushSmoothStreamingController(controller) {
    if (!controller) {
      return null;
    }

    if ((controller.pendingSegments?.length || 0) > 0) {
      controller.displayedMarkdown += controller.pendingSegments.join("");
      controller.pendingSegments = [];
      controller.lastPumpTime = performance.now();
      return commitSmoothStreamingFrame(controller);
    }

    updateSmoothStreamingState(controller);
    return controller.lastCommittedMetrics;
  }

  function resetSmoothStreamingController(controller, markdown, options, mode) {
    if (!controller) {
      return {
        renderedLength: 0,
        renderDurationMs: 0,
        engine: "streaming-smooth-reset-missing-controller"
      };
    }

    controller.targetMarkdown = String(markdown || "");
    controller.displayedMarkdown = controller.targetMarkdown;
    controller.pendingSegments = [];
    controller.lastPumpTime = performance.now();
    controller.resolvedOptions = Object.assign({}, options || {});
    const metrics = commitSmoothStreamingFrame(controller);
    return Object.assign({}, metrics, {
      engine: mode || "streaming-smooth-reset",
      displayedLength: controller.displayedMarkdown.length,
      targetLength: controller.targetMarkdown.length,
      queuedCharCount: 0,
      liveTailMode: "smooth-reset"
    });
  }

  function renderSourceMappedMarkdownFragment(source, blocks, startIndex, options) {
    const fragment = document.createDocumentFragment();
    const resolvedOptions = options && typeof options === "object" ? options : {};

    for (let index = startIndex; index < blocks.length; index += 1) {
      const block = blocks[index];
      const holder = document.createElement("div");
      const blockMarkdown = source.slice(block.start, block.end);
      const renderedBlockDocument = renderDocumentWithUnifiedEngine(blockMarkdown, resolvedOptions);
      if (renderedBlockDocument) {
        holder.innerHTML = renderedBlockDocument.html;
      } else {
        const renderedBlock = renderBlockHtmlWithPreferredEngine(blockMarkdown, resolvedOptions);
        holder.innerHTML = renderedBlock.html;
      }
      annotateTopLevelMarkdownSourceNodes(holder, block, index);
      if (renderedBlockDocument) {
        annotateRenderedMathSourceSpans(
          holder,
          shiftMarkdownSourceSpans(renderedBlockDocument.mathSpans, block.start)
        );
      }

      while (holder.firstChild) {
        fragment.appendChild(holder.firstChild);
      }
    }

    return fragment;
  }

  function renderSourceMappedMarkdownInto(content, markdown, options) {
    const source = String(markdown || "");
    const resolvedOptions = Object.assign({}, options || {}, {
      headingIdPrefix: ensureHeadingIdPrefixForContent(content)
    });
    const unifiedDocument = renderDocumentWithUnifiedEngine(source, resolvedOptions);
    if (unifiedDocument) {
      content.innerHTML = unifiedDocument.html;
      hydrateMarkdownStyleShadows(content);
      const annotatedDocument = annotateRenderedTopLevelSourceBlocks(content, unifiedDocument.blocks);
      if (annotatedDocument.ok) {
        annotateRenderedMathSourceSpans(content, unifiedDocument.mathSpans);
        return { blocks: annotatedDocument.blocks };
      }
      content.replaceChildren();
    }

    const blocks = markdownSourceRenderBlocks(source);
    const fragment = renderSourceMappedMarkdownFragment(source, blocks, 0, resolvedOptions);

    content.replaceChildren(fragment);
    hydrateMarkdownStyleShadows(content);
    return { blocks };
  }

  function stablePrefixBlockCount(previousSource, previousBlocks, source, blocks) {
    const count = Math.min(previousBlocks.length, blocks.length);
    let stableCount = 0;

    for (let index = 0; index < count; index += 1) {
      const previousBlock = previousBlocks[index];
      const block = blocks[index];
      if (
        !previousBlock
        || !block
        || previousBlock.start !== block.start
        || previousBlock.end !== block.end
      ) {
        break;
      }

      if (previousSource.slice(previousBlock.start, previousBlock.end) !== source.slice(block.start, block.end)) {
        break;
      }

      stableCount += 1;
    }

    return stableCount;
  }

  function topLevelSourceIndex(element) {
    if (!element) {
      return null;
    }

    const sourceElement = element.dataset && element.dataset.exampleChatSourceIndex !== undefined
      ? element
      : element.querySelector?.("[data-chat-transcript-source-index]");
    const rawValue = sourceElement?.dataset?.exampleChatSourceIndex;
    if (rawValue === undefined || rawValue === null || rawValue === "") {
      return null;
    }

    const index = Number(rawValue);
    return Number.isInteger(index) && index >= 0 ? index : null;
  }

  function renderedTopLevelSourceIndexes(content) {
    return Array.from(content?.children || []).map((child) => topLevelSourceIndex(child));
  }

  function removeRenderedBlocksFrom(content, startingBlockIndex) {
    let removedNodeCount = 0;
    const children = Array.from(content.children || []);

    if (startingBlockIndex <= 0) {
      children.forEach((child) => {
        child.remove();
        removedNodeCount += 1;
      });
      return removedNodeCount;
    }

    children.forEach((child) => {
      const sourceIndex = topLevelSourceIndex(child);
      if (sourceIndex !== null && sourceIndex >= startingBlockIndex) {
        child.remove();
        removedNodeCount += 1;
      }
    });

    return removedNodeCount;
  }

  function streamingFallbackMetrics(content, markdown, options, renderStart, fallbackReason) {
    const metrics = renderMarkdownInto(content, markdown, Object.assign({}, options || {}, {
      streaming: false,
      progressive: false
    }));
    return Object.assign({}, metrics, {
      engine: "streaming-fallback",
      fallbackEngine: metrics.engine,
      fallbackReason,
      stableBlockCount: 0,
      replacementStartBlockIndex: -1,
      liveTailMode: "fallback",
      replacedBlockCount: 0,
      removedNodeCount: 0,
      appendedNodeCount: content?.children?.length || 0,
      sourceBlockCount: content?.__streamingMarkdownState?.blocks?.length || 0,
      renderDurationMs: performance.now() - renderStart
    });
  }

  function renderMarkdownStreamingInto(content, markdown, options) {
    if (!content) {
      return { renderedLength: 0, renderDurationMs: 0, engine: "missing-content" };
    }

    const renderStart = performance.now();
    const resolvedOptions = options && typeof options === "object" ? options : {};
    const source = String(markdown || "");

    try {
      if (!hasRenderableMarkdownEngine()) {
        clearSmoothStreamingController(content);
        clearStreamingRenderState(content);
        return renderPlainTextPreviewInto(content, source, resolvedOptions);
      }

      const controller = ensureSmoothStreamingController(content, resolvedOptions);
      let previousTarget = String(controller.targetMarkdown || "");
      if (!previousTarget) {
        const seededState = content.__streamingMarkdownState;
        if (
          seededState
          && seededState.version === STREAMING_RENDER_STATE_VERSION
          && seededState.optionsFingerprint === renderOptionsFingerprint(resolvedOptions)
          && typeof seededState.markdown === "string"
        ) {
          controller.targetMarkdown = seededState.markdown;
          controller.displayedMarkdown = seededState.markdown;
          controller.lastCommittedMetrics = {
            renderedLength: measureRenderedLength(content, resolvedOptions),
            renderDurationMs: 0,
            stableRenderedChildCount: content?.children?.length || 0,
            replacedRenderedChildCount: 0,
            removedNodeCount: 0,
            appendedNodeCount: 0
          };
          previousTarget = controller.targetMarkdown;
        }
      }

      if (!previousTarget) {
        controller.targetMarkdown = source;
        controller.displayedMarkdown = "";
        controller.pendingSegments = segmentStreamingText(source);
        controller.lastPumpTime = 0;
        const bootstrapMetrics = controller.pendingSegments.length > 0
          ? (resolvedOptions.streamingCommitImmediately === true
            ? flushSmoothStreamingController(controller)
            : pumpSmoothStreamingController(controller, performance.now(), true))
          : commitSmoothStreamingFrame(controller);
        if (controller.pendingSegments.length > 0) {
          scheduleSmoothStreamingController(controller);
        }
        return Object.assign({}, bootstrapMetrics, {
          renderDurationMs: performance.now() - renderStart,
          engine: "streaming-smooth-bootstrap",
          fallbackReason: "",
          stableBlockCount: bootstrapMetrics?.stableRenderedChildCount || 0,
          replacementStartBlockIndex: Math.max(0, bootstrapMetrics?.stableRenderedChildCount || 0),
          liveTailMode: "smooth-bootstrap",
          replacedBlockCount: bootstrapMetrics?.replacedRenderedChildCount || 0,
          removedNodeCount: bootstrapMetrics?.removedNodeCount || 0,
          appendedNodeCount: bootstrapMetrics?.appendedNodeCount || 0,
          sourceBlockCount: bootstrapMetrics?.sourceBlockCount || content?.__streamingMarkdownState?.blocks?.length || 0,
          displayedLength: controller.displayedMarkdown.length,
          targetLength: controller.targetMarkdown.length,
          queuedCharCount: controller.pendingSegments.length
        });
      }

      if (source === previousTarget) {
        if (
          (resolvedOptions.streamingFinalizeImmediate === true || resolvedOptions.streamingCommitImmediately === true)
          && (controller.pendingSegments?.length || 0) > 0
        ) {
          const finalizeMetrics = flushSmoothStreamingController(controller);
          return Object.assign({}, finalizeMetrics || {
            renderedLength: measureRenderedLength(content, resolvedOptions),
            stableRenderedChildCount: content?.children?.length || 0,
            replacedRenderedChildCount: 0,
            removedNodeCount: 0,
            appendedNodeCount: 0
          }, {
            renderDurationMs: performance.now() - renderStart,
            engine: resolvedOptions.streamingFinalizeImmediate === true
              ? "streaming-smooth-finalize"
              : "streaming-smooth-commit",
            fallbackReason: "",
            stableBlockCount: finalizeMetrics?.stableRenderedChildCount || content?.children?.length || 0,
            replacementStartBlockIndex: Math.max(0, finalizeMetrics?.stableRenderedChildCount || content?.children?.length || 0),
            liveTailMode: resolvedOptions.streamingFinalizeImmediate === true
              ? "smooth-finalize"
              : (finalizeMetrics?.stableRenderedChildCount || 0) > 0 ? "smooth-dom-prefix" : "smooth-dom-root",
            replacedBlockCount: finalizeMetrics?.replacedRenderedChildCount || 0,
            removedNodeCount: finalizeMetrics?.removedNodeCount || 0,
            appendedNodeCount: finalizeMetrics?.appendedNodeCount || 0,
            sourceBlockCount:
              finalizeMetrics?.sourceBlockCount
              || content?.__streamingMarkdownState?.blocks?.length
              || content?.children?.length
              || 0,
            displayedLength: controller.displayedMarkdown.length,
            targetLength: controller.targetMarkdown.length,
            queuedCharCount: controller.pendingSegments.length
          });
        }
        return Object.assign({}, controller.lastCommittedMetrics || {
          renderedLength: measureRenderedLength(content, resolvedOptions),
          stableRenderedChildCount: content?.children?.length || 0,
          replacedRenderedChildCount: 0,
          removedNodeCount: 0,
          appendedNodeCount: 0
        }, {
          renderDurationMs: performance.now() - renderStart,
          engine: "streaming-smooth-noop",
          fallbackReason: "",
          stableBlockCount: content?.children?.length || 0,
          replacementStartBlockIndex: content?.children?.length || 0,
          liveTailMode: "smooth-noop",
          replacedBlockCount: 0,
          sourceBlockCount:
            controller.lastCommittedMetrics?.sourceBlockCount
            || content?.__streamingMarkdownState?.blocks?.length
            || content?.children?.length
            || 0,
          displayedLength: controller.displayedMarkdown.length,
          targetLength: controller.targetMarkdown.length,
          queuedCharCount: controller.pendingSegments.length
        });
      }

      if (!source.startsWith(previousTarget)) {
        const resetMetrics = resetSmoothStreamingController(
          controller,
          source,
          resolvedOptions,
          "streaming-smooth-reset"
        );
        return Object.assign({}, resetMetrics, {
          renderDurationMs: performance.now() - renderStart,
          fallbackReason: "non-append-reset",
          stableBlockCount: 0,
          replacementStartBlockIndex: 0,
          replacedBlockCount: content?.children?.length || 0,
          sourceBlockCount: content?.children?.length || 0
        });
      }

      const deltaSegments = segmentStreamingText(source.slice(previousTarget.length));
      controller.targetMarkdown = source;
      if (deltaSegments.length > 0) {
        controller.pendingSegments = controller.pendingSegments.concat(deltaSegments);
      }

      const pumpedMetrics = (
          resolvedOptions.streamingFinalizeImmediate === true ||
          resolvedOptions.streamingCommitImmediately === true
        )
        ? flushSmoothStreamingController(controller)
        : (deltaSegments.length > 0
          ? pumpSmoothStreamingController(controller, performance.now(), true)
          : controller.lastCommittedMetrics);

      if (controller.pendingSegments.length > 0) {
        scheduleSmoothStreamingController(controller);
      } else {
        updateSmoothStreamingState(controller);
      }

      const committedMetrics = pumpedMetrics || controller.lastCommittedMetrics || {
        renderedLength: measureRenderedLength(content, resolvedOptions),
        stableRenderedChildCount: 0,
        replacedRenderedChildCount: content?.children?.length || 0,
        removedNodeCount: 0,
        appendedNodeCount: content?.children?.length || 0
      };

      return Object.assign({}, committedMetrics, {
        renderDurationMs: performance.now() - renderStart,
        engine: "streaming-smooth",
        fallbackReason: "",
        stableBlockCount: committedMetrics.stableRenderedChildCount || 0,
        replacementStartBlockIndex: Math.max(0, committedMetrics.stableRenderedChildCount || 0),
        liveTailMode: (committedMetrics.stableRenderedChildCount || 0) > 0 ? "smooth-dom-prefix" : "smooth-dom-root",
        replacedBlockCount: committedMetrics.replacedRenderedChildCount || 0,
        removedNodeCount: committedMetrics.removedNodeCount || 0,
        appendedNodeCount: committedMetrics.appendedNodeCount || 0,
        sourceBlockCount:
          committedMetrics.sourceBlockCount
          || content?.__streamingMarkdownState?.blocks?.length
          || content?.children?.length
          || 0,
        displayedLength: controller.displayedMarkdown.length,
        targetLength: controller.targetMarkdown.length,
        queuedCharCount: controller.pendingSegments.length
      });
    } catch (error) {
      clearSmoothStreamingController(content);
      clearStreamingRenderState(content);
      const previewMetrics = renderPlainTextPreviewInto(content, source, resolvedOptions);
      return {
        renderedLength: previewMetrics.renderedLength,
        renderDurationMs: performance.now() - renderStart,
        engine: "streaming-error-fallback",
        fallbackReason: error && error.message ? String(error.message) : "unknown-error",
        stableBlockCount: 0,
        replacementStartBlockIndex: -1,
        liveTailMode: "error-fallback",
        replacedBlockCount: 0,
        removedNodeCount: 0,
        appendedNodeCount: 0,
        sourceBlockCount: 0
      };
    }
  }

  const HIGHLIGHT_LANGUAGE_ALIASES = {
    cjs: "javascript",
    cs: "csharp",
    html: "xml",
    htm: "xml",
    js: "javascript",
    jsx: "javascript",
    md: "markdown",
    objc: "objectivec",
    "obj-c": "objectivec",
    "objective-c": "objectivec",
    py: "python",
    rb: "ruby",
    rs: "rust",
    sh: "bash",
    shell: "bash",
    text: "plaintext",
    plain: "plaintext",
    txt: "plaintext",
    ts: "typescript",
    tsx: "typescript",
    vb: "vbnet",
    vba: "vbnet",
    yml: "yaml",
    zsh: "bash"
  };

  const LANGUAGE_LABEL_OVERRIDES = {
    cpp: "c++",
    csharp: "c#",
    objectivec: "objective-c",
    plaintext: "text",
    typescript: "typescript",
    vbnet: "vb.net"
  };

  function normalizeLanguageName(language) {
    return String(language || "").trim().toLowerCase();
  }

  function extractDeclaredLanguage(codeElement) {
    const classes = String(codeElement.className || "")
      .split(/\s+/)
      .filter(Boolean);

    for (const className of classes) {
      if (className.startsWith("language-")) {
        return className.slice("language-".length);
      }
      if (className.startsWith("lang-")) {
        return className.slice("lang-".length);
      }
    }

    return "";
  }

  function resolveHighlightLanguage(language) {
    const normalized = normalizeLanguageName(language);
    return HIGHLIGHT_LANGUAGE_ALIASES[normalized] || normalized;
  }

  function formatLanguageLabel(language) {
    const normalized = normalizeLanguageName(language);
    if (!normalized) {
      return "code";
    }
    return LANGUAGE_LABEL_OVERRIDES[normalized] || normalized;
  }

  function isWrappingTextCodeLanguage(language) {
    const normalized = normalizeLanguageName(language);
    return normalized === "text"
      || normalized === "plain"
      || normalized === "plaintext"
      || normalized === "txt";
  }

  const PRETTIER_LANGUAGE_PARSERS = {
    css: "css",
    html: "html",
    htm: "html",
    javascript: "babel",
    js: "babel",
    jsx: "babel",
    json: "json-stringify",
    less: "less",
    scss: "scss",
    ts: "typescript",
    tsx: "typescript",
    typescript: "typescript",
    vue: "html",
    xml: "html"
  };

  function resolveFormatterParser(language) {
    const normalized = normalizeLanguageName(language);
    return PRETTIER_LANGUAGE_PARSERS[normalized] || "";
  }

  function inferFormatterParser(text) {
    const source = String(text || "").trim();
    if (!source) {
      return "";
    }

    if (isLikelyCollapsedHTML(source)) {
      return "html";
    }

    if (isLikelyCollapsedJSON(source)) {
      return "json-stringify";
    }

    if (isLikelyCollapsedCSS(source)) {
      return "css";
    }

    if (isLikelyCollapsedTypeScript(source)) {
      return "typescript";
    }

    if (isLikelyCollapsedJavaScript(source)) {
      return "babel";
    }

    return "";
  }

  function isLikelyCollapsedHTML(text) {
    return /<([A-Za-z][\w:-]*)(?:\s[^<>]*?)?>/.test(text) && /<\/[A-Za-z][\w:-]*>/.test(text);
  }

  function isLikelyCollapsedCSS(text) {
    return /{[^{}]*}/.test(text) && /:[^;{}]+;?/.test(text);
  }

  function isLikelyCollapsedJSON(text) {
    if (!/^[\[{]/.test(text)) {
      return false;
    }

    try {
      const parsed = JSON.parse(text);
      return typeof parsed === "object" && parsed !== null;
    } catch (error) {
      return false;
    }
  }

  function isLikelyCollapsedJavaScript(text) {
    return /[{};]/.test(text)
      && (/\b(function|const|let|var|class|import|export|return|if|for|while|switch|try|catch|new)\b/.test(text)
        || /=>/.test(text));
  }

  function isLikelyCollapsedTypeScript(text) {
    return isLikelyCollapsedJavaScript(text)
      || /:\s*[A-Za-z_$][\w<>{}\[\]|&?, ]*/.test(text)
      || /\b(interface|type|enum|implements|readonly)\b/.test(text);
  }

  function shouldFormatCollapsedCode(text, parser) {
    if (!text || text.length < 60 || /\n/.test(text)) {
      return false;
    }

    switch (parser) {
      case "html":
        return isLikelyCollapsedHTML(text);
      case "css":
      case "scss":
      case "less":
        return isLikelyCollapsedCSS(text);
      case "json-stringify":
        return isLikelyCollapsedJSON(text);
      case "babel":
        return isLikelyCollapsedJavaScript(text);
      case "typescript":
        return isLikelyCollapsedTypeScript(text);
      default:
        return false;
    }
  }

  function isScriptLikeParser(parser) {
    return parser === "babel" || parser === "typescript";
  }

  function isWhitespaceCharacter(char) {
    return char === " " || char === "\t";
  }

  function isLikelyCommentSuccessor(text, startIndex) {
    const next = text[startIndex] || "";
    if (/[{}\[(]/.test(next)) {
      return true;
    }

    const preview = text.slice(startIndex, startIndex + 48);
    return /^(?:const|let|var|function|class|if|for|while|switch|try|catch|return|else|document|window|this|new|await|import|export|throw|break|continue|[A-Za-z_$][\w$]*)\b/.test(preview)
      && /[=.;([{]/.test(preview);
  }

  function findCollapsedLineCommentBoundary(text, startIndex) {
    for (let index = startIndex; index < text.length; index += 1) {
      const current = text[index];

      if (current === "\n") {
        return { index, synthetic: false };
      }

      if (!isWhitespaceCharacter(current) || !isWhitespaceCharacter(text[index + 1])) {
        continue;
      }

      let nextIndex = index + 2;
      while (nextIndex < text.length && isWhitespaceCharacter(text[nextIndex])) {
        nextIndex += 1;
      }

      if (isLikelyCommentSuccessor(text, nextIndex)) {
        return { index, synthetic: true };
      }
    }

    return null;
  }

  function restoreCollapsedLineComments(source, parser) {
    if (!isScriptLikeParser(parser) || !source || !source.includes("//")) {
      return source;
    }

    const text = String(source).replace(/\r\n?/g, "\n");
    let output = "";
    let index = 0;
    let state = "normal";

    while (index < text.length) {
      const current = text[index];
      const next = text[index + 1];

      if (state === "single-quote") {
        output += current;
        if (current === "\\" && index + 1 < text.length) {
          output += text[index + 1];
          index += 2;
          continue;
        }
        if (current === "'") {
          state = "normal";
        }
        index += 1;
        continue;
      }

      if (state === "double-quote") {
        output += current;
        if (current === "\\" && index + 1 < text.length) {
          output += text[index + 1];
          index += 2;
          continue;
        }
        if (current === "\"") {
          state = "normal";
        }
        index += 1;
        continue;
      }

      if (state === "template-string") {
        output += current;
        if (current === "\\" && index + 1 < text.length) {
          output += text[index + 1];
          index += 2;
          continue;
        }
        if (current === "`") {
          state = "normal";
        }
        index += 1;
        continue;
      }

      if (state === "block-comment") {
        output += current;
        if (current === "*" && next === "/") {
          output += "/";
          index += 2;
          state = "normal";
          continue;
        }
        index += 1;
        continue;
      }

      if (current === "'") {
        output += current;
        state = "single-quote";
        index += 1;
        continue;
      }

      if (current === "\"") {
        output += current;
        state = "double-quote";
        index += 1;
        continue;
      }

      if (current === "`") {
        output += current;
        state = "template-string";
        index += 1;
        continue;
      }

      if (current === "/" && next === "*") {
        output += "/*";
        index += 2;
        state = "block-comment";
        continue;
      }

      if (current === "/" && next === "/") {
        const boundary = findCollapsedLineCommentBoundary(text, index + 2);
        if (!boundary) {
          output += text.slice(index);
          break;
        }

        output += text.slice(index, boundary.index).replace(/[ \t]+$/g, "");
        output += "\n";

        if (boundary.synthetic) {
          index = boundary.index;
          while (index < text.length && isWhitespaceCharacter(text[index])) {
            index += 1;
          }
        } else {
          index = boundary.index + 1;
        }
        continue;
      }

      output += current;
      index += 1;
    }

    return output;
  }

  function formatCodeWithParser(source, parser) {
    const prettier = window.prettier;
    const prettierPlugins = window.prettierPlugins;

    if (
      !parser
      || !source
      || !prettier
      || typeof prettier.format !== "function"
      || !prettierPlugins
      || typeof prettierPlugins !== "object"
    ) {
      return source;
    }

    const options = {
      parser,
      plugins: prettierPlugins,
      tabWidth: 2
    };

    if (parser === "html") {
      options.htmlWhitespaceSensitivity = "ignore";
    }

    const tryFormat = (input) => {
      const formatted = prettier.format(input, options);
      if (typeof formatted === "string" && formatted.trim()) {
        return formatted.replace(/\r\n?/g, "\n");
      }
      return "";
    };

    try {
      const formatted = tryFormat(source);
      if (formatted) {
        return formatted;
      }
    } catch (error) {
      const recoveredSource = restoreCollapsedLineComments(source, parser);
      if (recoveredSource !== source) {
        try {
          const recoveredFormatted = tryFormat(recoveredSource);
          if (recoveredFormatted) {
            return recoveredFormatted;
          }
        } catch (recoveryError) {
          return source;
        }
      }
      return source;
    }

    return source;
  }

  function resolveEmbeddedScriptParser(attributes) {
    const attrs = String(attributes || "");
    const typeMatch = attrs.match(/\btype\s*=\s*["']?([^"'\s>]+)/i);
    const type = String(typeMatch?.[1] || "").toLowerCase();

    if (!type || type.includes("javascript") || type === "module") {
      return "babel";
    }
    if (type.includes("typescript")) {
      return "typescript";
    }
    if (type.includes("json") || type.includes("importmap")) {
      return "json-stringify";
    }

    return "";
  }

  function indentBlock(text, indent) {
    return String(text || "")
      .replace(/\n+$/g, "")
      .split("\n")
      .map((line) => `${indent}${line}`)
      .join("\n");
  }

  function formatEmbeddedHTMLBlocks(html) {
    return String(html || "").replace(
      /(^|\n)([ \t]*)<(script|style)\b([^>]*)>([\s\S]*?)<\/\3>/gi,
      (match, leadingBoundary, indent, tagName, attributes, body) => {
        const normalizedTag = String(tagName || "").toLowerCase();
        const parser = normalizedTag === "style"
          ? "css"
          : resolveEmbeddedScriptParser(attributes);
        const innerSource = String(body || "").replace(/\r\n?/g, "\n").trim();

        if (!parser || !shouldFormatCollapsedCode(innerSource, parser)) {
          return match;
        }

        const formattedInner = formatCodeWithParser(innerSource, parser).trimEnd();
        if (!formattedInner || formattedInner === innerSource) {
          return match;
        }

        const indentedInner = indentBlock(formattedInner, `${indent}  `);
        return `${leadingBoundary}${indent}<${tagName}${attributes}>\n${indentedInner}\n${indent}</${tagName}>`;
      }
    );
  }

  function formatCollapsedCodeText(text, language) {
    const source = String(text || "").replace(/\r\n?/g, "\n").trim();
    const parser = resolveFormatterParser(language) || inferFormatterParser(source);

    if (!parser || !shouldFormatCollapsedCode(source, parser)) {
      return text;
    }

    let formatted = formatCodeWithParser(source, parser);
    if (parser === "html") {
      formatted = formatEmbeddedHTMLBlocks(formatted);
    }

    if (typeof formatted === "string" && formatted.trim() && formatted.trim() !== source) {
      return formatted;
    }

    return text;
  }

  const OUTLINE_CODE_LANGUAGES = new Set([
    "",
    "md",
    "markdown",
    "outline",
    "plain",
    "plaintext",
    "text",
    "txt"
  ]);

  function hasCodeBlockMindmapRenderer() {
    return Boolean(window.d3 && window.markmap?.Markmap);
  }

  function isCodeBlockMindmapExportRenderContext() {
    return Boolean(window.__chatLongImagePayload);
  }

  function waitForNextAnimationFrame() {
    return new Promise((resolve) => {
      let resolved = false;
      const finish = () => {
        if (resolved) {
          return;
        }
        resolved = true;
        resolve();
      };
      window.requestAnimationFrame(finish);
      window.setTimeout(finish, 24);
    });
  }

  async function waitForCodeBlockMindmapPaint(frameCount = 1) {
    const totalFrames = Math.max(1, Number(frameCount) || 1);
    for (let index = 0; index < totalFrames; index += 1) {
      await waitForNextAnimationFrame();
    }
  }

  function isCodeBlockMindmapRenderReady(shell) {
    const svg = shell?.querySelector?.(".code-block-mindmap svg");
    if (!svg) {
      return false;
    }
    if (!shell?.__codeBlockMindmapInstance && !shell?.__codeBlockMindmapExportSnapshotRendered) {
      return false;
    }
    return Boolean(
      svg.querySelector("g.markmap-node")
      || svg.querySelector("path.markmap-link")
    );
  }

  async function waitForCodeBlockMindmapReady(shell, maxFrames = 6) {
    const frameCount = Math.max(1, Number(maxFrames) || 1);
    for (let index = 0; index < frameCount; index += 1) {
      if (isCodeBlockMindmapRenderReady(shell)) {
        return true;
      }
      await waitForCodeBlockMindmapPaint();
    }
    return isCodeBlockMindmapRenderReady(shell);
  }

  function codeLanguageAllowsLooseMindmap(language) {
    const normalized = normalizeLanguageName(language);
    return OUTLINE_CODE_LANGUAGES.has(normalized)
      || OUTLINE_CODE_LANGUAGES.has(resolveHighlightLanguage(normalized));
  }

  function escapeMindmapHTML(value) {
    return String(value || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function makeCodeMindmapNode(label, payload = {}) {
    return {
      content: `<span class="code-block-mindmap-node-label">${escapeMindmapHTML(label)}</span>`,
      payload,
      children: []
    };
  }

  function normalizedCodeOutlineLines(text) {
    return String(text || "")
      .replace(/\r\n?/g, "\n")
      .split("\n")
      .map((line) => line.replace(/\s+$/g, ""));
  }

  function cleanOutlineLabel(label) {
    return String(label || "")
      .replace(/^\s{0,3}#{1,6}\s+/, "")
      .replace(/^\s*(?:[-*+]\s+|\d+[.)]\s+)/, "")
      .trim();
  }

  function appendMindmapNodeAtDepth(stack, depth, label, payload) {
    const node = makeCodeMindmapNode(label, payload);
    const parent = stack[depth - 1] || stack[0];
    if (!parent) {
      stack[0] = node;
      return node;
    }
    parent.children.push(node);
    stack[depth] = node;
    stack.length = depth + 1;
    return node;
  }

  function treeConnectorMatch(line) {
    const normalizedLine = String(line || "").replace(/\t/g, "    ");
    const connectorRegex = /├──|└──|├─|└─|\+--|\|--|`--|\\--|\+-|`-/g;
    let match = null;
    let current = connectorRegex.exec(normalizedLine);
    while (current) {
      match = current;
      current = connectorRegex.exec(normalizedLine);
    }
    if (!match) {
      return null;
    }
    return {
      index: match.index,
      labelStart: match.index + match[0].length
    };
  }

  function parseAsciiTreeMindmap(text) {
    const lines = normalizedCodeOutlineLines(text);
    const stack = [];
    let connectorLineCount = 0;
    let nodeCount = 0;
    let maxDepth = 0;
    let sawConnector = false;

    lines.forEach((line) => {
      if (!line.trim() || /^[\s│|]+$/.test(line)) {
        return;
      }

      const match = treeConnectorMatch(line);
      if (!match) {
        if (!sawConnector && !stack[0]) {
          const label = cleanOutlineLabel(line);
          if (label) {
            stack[0] = makeCodeMindmapNode(label);
            nodeCount += 1;
          }
        }
        return;
      }

      sawConnector = true;
      const label = cleanOutlineLabel(line.slice(match.labelStart));
      if (!label) {
        return;
      }

      connectorLineCount += 1;
      const depth = Math.max(1, Math.floor(match.index / 4) + 1);
      maxDepth = Math.max(maxDepth, depth);
      if (!stack[0]) {
        stack[0] = makeCodeMindmapNode("思维导图");
        nodeCount += 1;
      }
      appendMindmapNodeAtDepth(stack, depth, label);
      nodeCount += 1;
    });

    const root = stack[0];
    if (!root || connectorLineCount < 2 || nodeCount < 3 || maxDepth < 1 || !root.children.length) {
      return null;
    }
    return root;
  }

  function parseMarkdownListMindmap(text) {
    const lines = normalizedCodeOutlineLines(text);
    const items = [];
    let listLineCount = 0;
    let headingLineCount = 0;
    let plainLineCount = 0;

    lines.forEach((line) => {
      if (!line.trim()) {
        return;
      }

      const headingMatch = /^(\s{0,3})(#{1,6})\s+(.+)$/.exec(line);
      if (headingMatch) {
        const label = cleanOutlineLabel(headingMatch[3]);
        if (label) {
          headingLineCount += 1;
          items.push({
            type: "heading",
            level: headingMatch[2].length,
            indent: 0,
            label
          });
        }
        return;
      }

      const listMatch = /^(\s*)(?:[-*+]\s+|\d+[.)]\s+)(.+)$/.exec(line.replace(/\t/g, "    "));
      if (listMatch) {
        const label = cleanOutlineLabel(listMatch[2]);
        if (label) {
          listLineCount += 1;
          items.push({
            type: "list",
            level: 0,
            indent: listMatch[1].length,
            label
          });
        }
        return;
      }

      plainLineCount += 1;
      items.push({
        type: "plain",
        level: 0,
        indent: (/^\s*/.exec(line.replace(/\t/g, "    ")) || [""])[0].length,
        label: cleanOutlineLabel(line)
      });
    });

    if (items.length < 3 || (listLineCount < 2 && headingLineCount < 2)) {
      return null;
    }
    if (plainLineCount > 1) {
      return null;
    }

    const firstPlainRoot = items[0]?.type === "plain" && plainLineCount === 1 ? items[0] : null;
    const root = firstPlainRoot
      ? makeCodeMindmapNode(firstPlainRoot.label)
      : makeCodeMindmapNode("思维导图");
    const stack = [root];
    const listIndents = Array.from(new Set(items.filter((item) => item.type === "list").map((item) => item.indent))).sort((a, b) => a - b);
    const headingLevels = items.filter((item) => item.type === "heading").map((item) => item.level);
    const minHeadingLevel = headingLevels.length ? Math.min(...headingLevels) : 1;
    let nodeCount = 1;
    let maxDepth = 0;

    items.forEach((item, index) => {
      if (item === firstPlainRoot || !item.label) {
        return;
      }

      let depth = 1;
      if (item.type === "heading") {
        depth = Math.max(1, item.level - minHeadingLevel + 1);
      } else if (item.type === "list") {
        const indentDepth = Math.max(0, listIndents.indexOf(item.indent));
        depth = indentDepth + 1;
      } else if (index > 0) {
        return;
      }

      maxDepth = Math.max(maxDepth, depth);
      appendMindmapNodeAtDepth(stack, depth, item.label);
      nodeCount += 1;
    });

    if (!root.children.length || nodeCount < 3 || maxDepth < 1) {
      return null;
    }
    return root;
  }

  function parseIndentedOutlineMindmap(text) {
    const rawLines = normalizedCodeOutlineLines(text).filter((line) => line.trim());
    if (rawLines.length < 3) {
      return null;
    }

    const normalizedLines = rawLines.map((line) => line.replace(/\t/g, "    "));
    const hasCodePunctuation = normalizedLines.some((line) => /[{};=<>]/.test(line));
    if (hasCodePunctuation) {
      return null;
    }

    const items = normalizedLines.map((line) => {
      const indent = (/^\s*/.exec(line) || [""])[0].length;
      return {
        indent,
        label: cleanOutlineLabel(line)
      };
    }).filter((item) => item.label);

    if (items.length < 3 || items[0].indent !== 0) {
      return null;
    }

    const indents = Array.from(new Set(items.map((item) => item.indent))).sort((a, b) => a - b);
    if (indents.length < 2) {
      return null;
    }

    const root = makeCodeMindmapNode(items[0].label);
    const stack = [root];
    let nodeCount = 1;
    let maxDepth = 0;

    items.slice(1).forEach((item) => {
      const indentDepth = Math.max(1, indents.indexOf(item.indent));
      maxDepth = Math.max(maxDepth, indentDepth);
      appendMindmapNodeAtDepth(stack, indentDepth, item.label);
      nodeCount += 1;
    });

    if (!root.children.length || nodeCount < 3 || maxDepth < 1) {
      return null;
    }
    return root;
  }

  function countMindmapNodes(node) {
    if (!node) {
      return 0;
    }
    return 1 + (Array.isArray(node.children) ? node.children.reduce((total, child) => total + countMindmapNodes(child), 0) : 0);
  }

  function parseCodeBlockMindmap(text, language) {
    const source = String(text || "").replace(/\r\n?/g, "\n").trim();
    if (!source || source.length > 20000) {
      return null;
    }

    const asciiTree = parseAsciiTreeMindmap(source);
    if (asciiTree) {
      return {
        root: asciiTree,
        nodeCount: countMindmapNodes(asciiTree)
      };
    }

    if (!codeLanguageAllowsLooseMindmap(language)) {
      return null;
    }

    const markdownList = parseMarkdownListMindmap(source);
    if (markdownList) {
      return {
        root: markdownList,
        nodeCount: countMindmapNodes(markdownList)
      };
    }

    const indentedOutline = parseIndentedOutlineMindmap(source);
    if (indentedOutline) {
      return {
        root: indentedOutline,
        nodeCount: countMindmapNodes(indentedOutline)
      };
    }

    return null;
  }

  function ensureCodeBlockMindmapElement(shell, nodeCount) {
    let container = shell?.querySelector(".code-block-mindmap");
    if (container) {
      return container;
    }

    const pre = shell?.querySelector("pre");
    if (!pre) {
      return null;
    }

    container = document.createElement("div");
    container.className = "code-block-mindmap";
    container.style.height = `${Math.min(Math.max(260, Number(nodeCount || 0) * 38), 520)}px`;

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", "代码块思维导图");
    container.appendChild(svg);
    pre.after(container);
    return container;
  }

  function codeBlockMindmapStyle() {
    return `
      .markmap {
        --markmap-font: 650 13px/1.35 "Avenir Next", "PingFang SC", sans-serif;
        --markmap-text-color: var(--title);
        color: var(--title);
        background: transparent;
      }
      .markmap-foreign > div {
        text-align: left;
      }
      .markmap-foreign > div > div {
        display: inline-block;
        max-width: min(var(--markmap-max-width, 280px), 46vw);
        white-space: normal;
        overflow-wrap: anywhere;
      }
      .markmap-node .code-block-mindmap-node-label {
        font-size: 13px;
        font-weight: 650;
        color: var(--title);
      }
      .markmap-node[data-depth="1"] .code-block-mindmap-node-label {
        font-size: 15px;
        font-weight: 800;
      }
      .markmap-link {
        opacity: 0.72;
      }
    `;
  }

  function constrainCodeBlockMindmapZoom(markmapInstance, svg) {
    if (!markmapInstance?.zoom || !window.d3?.zoomTransform || !svg) {
      return;
    }

    const fittedScale = window.d3.zoomTransform(svg).k || 1;
    const minScale = Math.max(0.02, fittedScale * 0.7);
    const maxScale = Math.min(3, Math.max(fittedScale * 2.4, fittedScale + 0.35));
    if (minScale < maxScale) {
      markmapInstance.zoom.scaleExtent([minScale, maxScale]);
      svg.__codeBlockMindmapScaleExtent = [minScale, maxScale];
    }
  }

  function clampCodeBlockMindmapScale(svg, scale) {
    const extent = Array.isArray(svg?.__codeBlockMindmapScaleExtent)
      ? svg.__codeBlockMindmapScaleExtent
      : [0.02, 3];
    return Math.min(extent[1], Math.max(extent[0], scale));
  }

  function applyCodeBlockMindmapScale(markmapInstance, svg, scaleDelta) {
    if (!markmapInstance?.zoom || !window.d3?.zoomTransform || !svg || !Number.isFinite(scaleDelta) || scaleDelta <= 0) {
      return false;
    }

    const svgNode = svg;
    const bounds = svgNode.getBoundingClientRect();
    if (!bounds.width || !bounds.height) {
      return false;
    }

    const transform = window.d3.zoomTransform(svgNode);
    const targetScale = clampCodeBlockMindmapScale(svg, transform.k * scaleDelta);
    const appliedScale = targetScale / transform.k;
    if (!Number.isFinite(appliedScale) || Math.abs(appliedScale - 1) < 0.001) {
      return false;
    }

    const halfWidth = bounds.width / 2;
    const halfHeight = bounds.height / 2;
    const nextTransform = transform.translate(
      (halfWidth - transform.x) * (1 - appliedScale) / transform.k,
      (halfHeight - transform.y) * (1 - appliedScale) / transform.k
    ).scale(appliedScale);
    markmapInstance.svg.call(markmapInstance.zoom.transform, nextTransform);
    return true;
  }

  function bindCodeBlockMindmapZoomControls(shell, markmapInstance, svg) {
    if (!shell || !markmapInstance || !svg) {
      return;
    }
    if (shell.__codeBlockMindmapZoomSvg === svg) {
      return;
    }

    if (typeof shell.__codeBlockMindmapZoomCleanup === "function") {
      shell.__codeBlockMindmapZoomCleanup();
    }

    let gestureScale = 1;
    const stopPinchEvent = (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (typeof event.stopImmediatePropagation === "function") {
        event.stopImmediatePropagation();
      }
    };

    const handleWheel = (event) => {
      if (!event.ctrlKey) {
        return;
      }
      stopPinchEvent(event);
      const modeFactor = event.deltaMode === 1 ? 0.05 : 0.002;
      applyCodeBlockMindmapScale(shell.__codeBlockMindmapInstance || markmapInstance, svg, Math.pow(2, -event.deltaY * modeFactor));
    };

    const handleGestureStart = (event) => {
      gestureScale = Number.isFinite(event.scale) && event.scale > 0 ? event.scale : 1;
      stopPinchEvent(event);
    };

    const handleGestureChange = (event) => {
      const nextScale = Number.isFinite(event.scale) && event.scale > 0 ? event.scale : gestureScale;
      const scaleDelta = nextScale / gestureScale;
      gestureScale = nextScale;
      stopPinchEvent(event);
      applyCodeBlockMindmapScale(shell.__codeBlockMindmapInstance || markmapInstance, svg, scaleDelta);
    };

    const handleGestureEnd = (event) => {
      gestureScale = 1;
      stopPinchEvent(event);
    };

    svg.addEventListener("wheel", handleWheel, { capture: true, passive: false });
    svg.addEventListener("gesturestart", handleGestureStart, { passive: false });
    svg.addEventListener("gesturechange", handleGestureChange, { passive: false });
    svg.addEventListener("gestureend", handleGestureEnd, { passive: false });
    shell.__codeBlockMindmapZoomSvg = svg;
    shell.__codeBlockMindmapZoomCleanup = () => {
      svg.removeEventListener("wheel", handleWheel, { capture: true });
      svg.removeEventListener("gesturestart", handleGestureStart);
      svg.removeEventListener("gesturechange", handleGestureChange);
      svg.removeEventListener("gestureend", handleGestureEnd);
      shell.__codeBlockMindmapZoomSvg = null;
    };
  }

  let activeCodeBlockMindmapMagnificationShell = null;
  let activeCodeBlockMindmapMagnificationAt = 0;

  function resolveCodeBlockMindmapShellAtPoint(clientX, clientY) {
    const target = document.elementFromPoint(clientX, clientY);
    return target?.closest?.(".code-block-shell.is-mindmap-visible") || null;
  }

  function activeCodeBlockMindmapMagnificationTarget() {
    const shell = activeCodeBlockMindmapMagnificationShell;
    const elapsed = performance.now() - activeCodeBlockMindmapMagnificationAt;
    if (!shell || elapsed > 900 || !document.contains(shell) || !shell.classList.contains("is-mindmap-visible")) {
      activeCodeBlockMindmapMagnificationShell = null;
      activeCodeBlockMindmapMagnificationAt = 0;
      return null;
    }
    return shell;
  }

  function endCodeBlockMindmapMagnification() {
    activeCodeBlockMindmapMagnificationShell = null;
    activeCodeBlockMindmapMagnificationAt = 0;
    return true;
  }

  function magnifyCodeBlockMindmapAtPoint(clientX, clientY, magnification) {
    const x = Number(clientX);
    const y = Number(clientY);
    const delta = Number(magnification);
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(delta) || Math.abs(delta) < 0.0001) {
      return false;
    }

    const shell = activeCodeBlockMindmapMagnificationTarget()
      || resolveCodeBlockMindmapShellAtPoint(x, y);
    const svg = shell?.querySelector?.(".code-block-mindmap svg");
    const instance = shell?.__codeBlockMindmapInstance;
    if (!shell || !svg || !instance) {
      return false;
    }

    activeCodeBlockMindmapMagnificationShell = shell;
    activeCodeBlockMindmapMagnificationAt = performance.now();
    return applyCodeBlockMindmapScale(instance, svg, Math.exp(delta));
  }

  async function renderCodeBlockMindmap(shell) {
    if (!shell || !hasCodeBlockMindmapRenderer()) {
      return false;
    }

    const mindmapData = shell.__codeBlockMindmapData;
    if (!mindmapData?.root) {
      return false;
    }

    const container = ensureCodeBlockMindmapElement(shell, mindmapData.nodeCount);
    const svg = container?.querySelector("svg");
    if (!container || !svg) {
      return false;
    }

    if (isCodeBlockMindmapExportRenderContext()) {
      svg.style.display = "block";
    }

    await waitForCodeBlockMindmapPaint();

    const isExportContext = isCodeBlockMindmapExportRenderContext();
    shell.__codeBlockMindmapExportSnapshotRendered = false;

    const options = {
      autoFit: false,
      duration: isExportContext ? 0 : 180,
      fitRatio: 0.92,
      maxInitialScale: 1.8,
      maxWidth: 280,
      nodeMinHeight: 22,
      pan: false,
      paddingX: 12,
      scrollForPan: true,
      spacingHorizontal: 84,
      spacingVertical: 16,
      style: codeBlockMindmapStyle
    };

    if (!shell.__codeBlockMindmapInstance) {
      shell.__codeBlockMindmapInstance = window.markmap.Markmap.create(svg, options);
    }

    await shell.__codeBlockMindmapInstance.setData(mindmapData.root, options);
    await shell.__codeBlockMindmapInstance.fit();
    await waitForCodeBlockMindmapPaint(isExportContext ? 2 : 1);
    constrainCodeBlockMindmapZoom(shell.__codeBlockMindmapInstance, svg);
    bindCodeBlockMindmapZoomControls(shell, shell.__codeBlockMindmapInstance, svg);
    if (isExportContext) {
      shell.__codeBlockMindmapExportRendered = await waitForCodeBlockMindmapReady(shell);
      return shell.__codeBlockMindmapExportRendered;
    }
    return true;
  }

  function setMindmapButtonState(button, state) {
    if (!button) {
      return;
    }

    const isActive = state === "active";
    const label = button.querySelector(".code-block-mindmap-toggle-label");
    button.classList.toggle("is-active", isActive);
    button.classList.toggle("is-error", state === "error");
    button.setAttribute("aria-pressed", String(isActive));
    button.setAttribute("aria-label", isActive ? "切回代码" : "渲染为思维导图");
    if (label) {
      label.textContent = isActive ? "源码" : "思维导图";
    }
    if (state === "error") {
      window.setTimeout(() => setMindmapButtonState(button, "idle"), 1400);
    }
  }

  function codeBlockMindmapTextHash(text) {
    const value = String(text || "");
    let hash = 0;
    for (let index = 0; index < value.length; index += 1) {
      hash = ((hash << 5) - hash + value.charCodeAt(index)) | 0;
    }
    return (hash >>> 0).toString(36);
  }

  function numberFromSVGAttribute(element, name, fallback = 0) {
    const value = Number(element?.getAttribute?.(name));
    return Number.isFinite(value) ? value : fallback;
  }

  function replaceCodeBlockMindmapSnapshotLabels(svg, clone) {
    const originalNodes = Array.from(svg.querySelectorAll("g.markmap-node"));
    const clonedNodes = Array.from(clone.querySelectorAll("g.markmap-node"));

    clonedNodes.forEach((clonedNode, index) => {
      const clonedForeignObject = clonedNode.querySelector("foreignObject");
      const originalNode = originalNodes[index];
      const originalLabel = originalNode?.querySelector(".code-block-mindmap-node-label")
        || originalNode?.querySelector("foreignObject");
      const text = (originalLabel?.textContent || clonedForeignObject?.textContent || "")
        .replace(/\s+/g, " ")
        .trim();
      if (!clonedForeignObject || !text) {
        clonedForeignObject?.remove();
        return;
      }

      const labelStyle = originalLabel ? window.getComputedStyle(originalLabel) : null;
      const fontSize = Number.parseFloat(labelStyle?.fontSize || "") || (clonedNode.dataset.depth === "1" ? 15 : 13);
      const fontWeight = labelStyle?.fontWeight || (clonedNode.dataset.depth === "1" ? "800" : "650");
      const fontFamily = labelStyle?.fontFamily || "\"Avenir Next\", \"PingFang SC\", sans-serif";
      const color = labelStyle?.color || "currentColor";
      const x = numberFromSVGAttribute(clonedForeignObject, "x", 0);
      const y = numberFromSVGAttribute(clonedForeignObject, "y", 0);
      const height = Math.max(fontSize, numberFromSVGAttribute(clonedForeignObject, "height", fontSize * 1.35));
      const baselineY = y + Math.min(height - 3, fontSize * 1.08);
      const textElement = document.createElementNS("http://www.w3.org/2000/svg", "text");

      textElement.setAttribute("class", "code-block-mindmap-static-label");
      textElement.setAttribute("x", String(x));
      textElement.setAttribute("y", String(Math.max(y + fontSize, baselineY)));
      textElement.setAttribute("fill", color);
      textElement.setAttribute("font-family", fontFamily);
      textElement.setAttribute("font-size", `${fontSize}px`);
      textElement.setAttribute("font-weight", fontWeight);
      textElement.setAttribute("letter-spacing", "0");
      textElement.setAttribute("text-rendering", "geometricPrecision");
      textElement.textContent = text;
      clonedForeignObject.replaceWith(textElement);
    });
  }

  function measureCodeBlockMindmapSnapshotBounds(clone, fallbackWidth, fallbackHeight) {
    const fallbackBounds = {
      x: 0,
      y: 0,
      width: Math.max(1, fallbackWidth),
      height: Math.max(1, fallbackHeight)
    };
    if (!clone || typeof clone.getBBox !== "function") {
      return fallbackBounds;
    }

    const host = document.createElement("div");
    host.style.position = "absolute";
    host.style.left = "-10000px";
    host.style.top = "0";
    host.style.width = `${fallbackBounds.width}px`;
    host.style.height = `${fallbackBounds.height}px`;
    host.style.visibility = "hidden";
    host.style.pointerEvents = "none";
    host.appendChild(clone);
    document.body.appendChild(host);

    try {
      const measured = clone.getBBox();
      const padding = Math.max(18, Math.round(Math.min(fallbackBounds.width, fallbackBounds.height) * 0.05));
      if (measured && measured.width > 0 && measured.height > 0) {
        return {
          x: measured.x - padding,
          y: measured.y - padding,
          width: measured.width + padding * 2,
          height: measured.height + padding * 2
        };
      }
    } catch (error) {
      // Fall back to the original viewport if SVG geometry is not measurable in this WebView.
    } finally {
      host.remove();
    }

    return fallbackBounds;
  }

  function codeBlockMindmapSnapshotForShell(shell) {
    if (!shell || !shell.classList.contains("is-mindmap-visible") || !isCodeBlockMindmapRenderReady(shell)) {
      return null;
    }

    const container = shell.querySelector(".code-block-mindmap");
    const svg = container?.querySelector("svg");
    if (!container || !svg) {
      return null;
    }

    const clone = svg.cloneNode(true);
    const bounds = container.getBoundingClientRect();
    const renderedWidth = Math.max(1, Math.round(bounds.width || svg.clientWidth || svg.getBoundingClientRect?.().width || 0));
    const renderedHeight = Math.max(1, Math.round(bounds.height || svg.clientHeight || svg.getBoundingClientRect?.().height || 0));

    clone.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    clone.setAttribute("role", "img");
    clone.setAttribute("aria-label", "代码块思维导图");
    clone.setAttribute("width", String(renderedWidth));
    clone.setAttribute("height", String(renderedHeight));
    clone.setAttribute("viewBox", `0 0 ${renderedWidth} ${renderedHeight}`);
    clone.setAttribute("preserveAspectRatio", "xMidYMid meet");
    clone.setAttribute("shape-rendering", "geometricPrecision");
    clone.setAttribute("text-rendering", "geometricPrecision");
    clone.style.display = "block";
    clone.style.width = "100%";
    clone.style.height = "100%";
    replaceCodeBlockMindmapSnapshotLabels(svg, clone);
    const contentBounds = measureCodeBlockMindmapSnapshotBounds(clone, renderedWidth, renderedHeight);
    const contentWidth = Math.max(1, Math.ceil(contentBounds.width));
    const contentHeight = Math.max(1, Math.ceil(contentBounds.height));
    clone.setAttribute("width", String(contentWidth));
    clone.setAttribute("height", String(contentHeight));
    clone.setAttribute(
      "viewBox",
      `${contentBounds.x} ${contentBounds.y} ${contentWidth} ${contentHeight}`
    );

    return {
      svgMarkup: clone.outerHTML,
      renderedWidth: contentWidth,
      renderedHeight: contentHeight
    };
  }

  function applyCodeBlockMindmapExportSnapshot(shell, state) {
    const svgMarkup = String(state?.svgMarkup || "").trim();
    if (!shell || !svgMarkup || !isCodeBlockMindmapExportRenderContext()) {
      return false;
    }

    const container = ensureCodeBlockMindmapElement(shell, shell.__codeBlockMindmapData?.nodeCount);
    if (!container) {
      return false;
    }

    const template = document.createElement("template");
    template.innerHTML = svgMarkup;
    const svg = template.content.firstElementChild;
    if (!svg || svg.tagName?.toLowerCase() !== "svg") {
      return false;
    }

    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", "代码块思维导图");
    const renderedWidth = Number(state?.renderedWidth);
    svg.style.display = "block";
    svg.style.width = "100%";
    svg.style.height = "100%";
    if (Number.isFinite(renderedWidth) && renderedWidth > 0 && !svg.getAttribute("viewBox")) {
      const renderedHeight = Number(state?.renderedHeight);
      if (Number.isFinite(renderedHeight) && renderedHeight > 0) {
        svg.setAttribute("viewBox", `0 0 ${Math.round(renderedWidth)} ${Math.round(renderedHeight)}`);
        svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
      }
    }
    container.replaceChildren(svg);
    if (svg.querySelector("foreignObject")) {
      replaceCodeBlockMindmapSnapshotLabels(svg, svg);
    }

    const snapshotWidth = Number(state?.renderedWidth);
    const snapshotHeight = Number(state?.renderedHeight);
    if (Number.isFinite(snapshotWidth) && snapshotWidth > 0 && Number.isFinite(snapshotHeight) && snapshotHeight > 0) {
      const containerWidth = Math.max(
        1,
        Math.round(container.getBoundingClientRect().width || shell.getBoundingClientRect().width || snapshotWidth)
      );
      container.style.height = `${Math.max(240, Math.round(containerWidth * snapshotHeight / snapshotWidth))}px`;
    }

    shell.__codeBlockMindmapInstance = null;
    shell.__codeBlockMindmapExportSnapshotRendered = true;
    shell.__codeBlockMindmapExportRendered = isCodeBlockMindmapRenderReady(shell);
    return shell.__codeBlockMindmapExportRendered;
  }

  function codeBlockMindmapStateForShell(shell) {
    if (!shell || !shell.__codeBlockMindmapData) {
      return null;
    }

    const blockElement = shell.closest("[data-block-key]");
    const messageElement = shell.closest("article.message[data-message-id], .message[data-message-id]");
    const scope = blockElement || shell.parentElement || document;
    const shellsInScope = Array.from(scope.querySelectorAll(".code-block-shell.has-code-mindmap"));
    const codeElement = shell.querySelector("pre > code");
    const state = {
      messageId: messageElement?.dataset?.messageId || "",
      blockKey: blockElement?.dataset?.blockKey || "",
      codeBlockIndex: Math.max(0, shellsInScope.indexOf(shell)),
      isMindmapVisible: shell.classList.contains("is-mindmap-visible"),
      codeTextHash: codeBlockMindmapTextHash(codeElement?.textContent || "")
    };

    const snapshot = codeBlockMindmapSnapshotForShell(shell);
    if (snapshot) {
      state.svgMarkup = snapshot.svgMarkup;
      state.renderedWidth = snapshot.renderedWidth;
      state.renderedHeight = snapshot.renderedHeight;
    }

    return state;
  }

  function collectCodeBlockMindmapExportStates(root = document) {
    return Array.from(root.querySelectorAll(".code-block-shell.has-code-mindmap"))
      .map(codeBlockMindmapStateForShell)
      .filter((state) => state && state.messageId && state.blockKey && Number.isInteger(state.codeBlockIndex));
  }

  function postCodeBlockMindmapExportStates(root = document) {
    const handler = window.webkit?.messageHandlers?.presentationProbe;
    if (!handler || typeof handler.postMessage !== "function") {
      return;
    }

    try {
      handler.postMessage({
        kind: "code_block_mindmap_state",
        event: "change",
        states: collectCodeBlockMindmapExportStates(root)
      });
    } catch (error) {
      // Export state sync is best-effort; the visible code block interaction still succeeds.
    }
  }

  function scheduleCodeBlockMindmapExportStatePost(root = document) {
    window.requestAnimationFrame(() => {
      postCodeBlockMindmapExportStates(root);
    });
  }

  function stateMatchesCodeBlockMindmapShell(state, shell) {
    const current = codeBlockMindmapStateForShell(shell);
    if (!current) {
      return false;
    }

    const codeBlockIndex = Number(state?.codeBlockIndex);
    if (String(state?.messageId || state?.messageID || "") !== current.messageId) {
      return false;
    }
    if (String(state?.blockKey || "") !== current.blockKey) {
      return false;
    }
    if (!Number.isFinite(codeBlockIndex) || Math.trunc(codeBlockIndex) !== current.codeBlockIndex) {
      return false;
    }

    const expectedHash = String(state?.codeTextHash || "");
    return !expectedHash || expectedHash === current.codeTextHash;
  }

  function applyCodeBlockMindmapExportStates(states) {
    const desiredStates = Array.isArray(states) ? states : [];
    const renderPromises = [];
    let appliedCount = 0;
    let requestedCount = 0;
    let readyCount = 0;

    window.__chatTranscriptCodeBlockMindmapExportPendingCount = 0;

    document.querySelectorAll(".code-block-shell.has-code-mindmap").forEach((shell) => {
      const state = desiredStates.find((candidate) => stateMatchesCodeBlockMindmapShell(candidate, shell));
      if (!state) {
        return;
      }

      requestedCount += 1;
      const button = shell.querySelector(".code-block-mindmap-toggle");
      if (state.isMindmapVisible === true) {
        setCodeBlockCollapsed(shell, false);
        shell.classList.add("is-mindmap-visible");
        setMindmapButtonState(button, "active");
        appliedCount += 1;

        const exportContext = isCodeBlockMindmapExportRenderContext();
        const exportReady = exportContext && Boolean(shell.__codeBlockMindmapExportRendered && isCodeBlockMindmapRenderReady(shell));
        if (exportReady) {
          readyCount += 1;
        }
        if (exportContext && !exportReady && applyCodeBlockMindmapExportSnapshot(shell, state)) {
          readyCount += 1;
          return;
        }
        if ((exportContext && !exportReady) || (!exportContext && !shell.__codeBlockMindmapInstance)) {
          renderPromises.push(
            renderCodeBlockMindmap(shell).then((rendered) => {
              if (!rendered) {
                shell.classList.remove("is-mindmap-visible");
                setMindmapButtonState(button, "idle");
              } else if (exportContext && shell.__codeBlockMindmapExportRendered && isCodeBlockMindmapRenderReady(shell)) {
                readyCount += 1;
              }
              return rendered;
            }).catch(() => {
              shell.classList.remove("is-mindmap-visible");
              setMindmapButtonState(button, "idle");
              return false;
            })
          );
        }
      } else {
        shell.classList.remove("is-mindmap-visible");
        setMindmapButtonState(button, "idle");
        appliedCount += 1;
      }
    });

    if (renderPromises.length) {
      window.__chatTranscriptCodeBlockMindmapExportPendingCount = renderPromises.length;
      Promise.allSettled(renderPromises).then(() => {
        window.__chatTranscriptCodeBlockMindmapExportPendingCount = 0;
        notifyCodeBlockLayoutChanged();
      });
    }

    notifyCodeBlockLayoutChanged();
    return {
      requestedCount,
      appliedCount,
      readyCount,
      pendingCount: window.__chatTranscriptCodeBlockMindmapExportPendingCount || 0
    };
  }

  function copyCodeText(text) {
    const value = typeof text === "string" ? text : String(text || "");
    const nativeCopyHandler = window.webkit?.messageHandlers?.copyCode;

    if (nativeCopyHandler && typeof nativeCopyHandler.postMessage === "function") {
      nativeCopyHandler.postMessage(value);
      return Promise.resolve();
    }

    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      return navigator.clipboard.writeText(value);
    }

    return new Promise((resolve, reject) => {
      try {
        const textarea = document.createElement("textarea");
        textarea.value = value;
        textarea.setAttribute("readonly", "readonly");
        textarea.style.position = "fixed";
        textarea.style.opacity = "0";
        textarea.style.pointerEvents = "none";
        document.body.appendChild(textarea);
        textarea.select();
        textarea.setSelectionRange(0, textarea.value.length);
        const success = document.execCommand("copy");
        textarea.remove();

        if (success) {
          resolve();
        } else {
          reject(new Error("Copy command failed."));
        }
      } catch (error) {
        reject(error);
      }
    });
  }

  function setCopyButtonState(button, state) {
    const label = button.querySelector(".code-block-copy-label");
    if (!label) {
      return;
    }

    window.clearTimeout(button.__resetTimer);
    button.classList.remove("is-copied", "is-error");

    if (state === "copied") {
      label.textContent = "已复制";
      button.classList.add("is-copied");
    } else if (state === "error") {
      label.textContent = "复制失败";
      button.classList.add("is-error");
    } else {
      label.textContent = "复制";
    }

    if (state !== "idle") {
      button.__resetTimer = window.setTimeout(() => {
        setCopyButtonState(button, "idle");
      }, 1600);
    }
  }

  function notifyCodeBlockLayoutChanged() {
    window.requestAnimationFrame(() => {
      notifyObservedLayoutChange("code_block_layout");
    });
  }

  function setCodeBlockCollapsed(shell, collapsed) {
    if (!shell) {
      return;
    }

    shell.classList.toggle("is-collapsed", collapsed);

    const toggleButton = shell.querySelector(".code-block-toggle");
    const label = toggleButton?.querySelector(".code-block-toggle-label");

    if (toggleButton) {
      toggleButton.setAttribute("aria-expanded", String(!collapsed));
      toggleButton.setAttribute("aria-label", collapsed ? "展开代码" : "折叠代码");
    }

    if (label) {
      label.textContent = collapsed ? "展开" : "折叠";
    }
  }

  function bindCodeBlockActions(root) {
    if (!root || root.dataset.codeBlockActionsBound === "true") {
      return;
    }

    root.dataset.codeBlockActionsBound = "true";
    root.addEventListener("click", async (event) => {
      const toggleButton = event.target.closest(".code-block-toggle");
      if (toggleButton) {
        const shell = toggleButton.closest(".code-block-shell");
        const collapsed = !(shell?.classList.contains("is-collapsed"));
        setCodeBlockCollapsed(shell, collapsed);
        notifyCodeBlockLayoutChanged();
        return;
      }

      const mindmapButton = event.target.closest(".code-block-mindmap-toggle");
      if (mindmapButton) {
        const shell = mindmapButton.closest(".code-block-shell");
        const nextVisible = !shell?.classList.contains("is-mindmap-visible");
        if (!shell || !nextVisible) {
          shell?.classList.remove("is-mindmap-visible");
          setMindmapButtonState(mindmapButton, "idle");
          postCodeBlockMindmapExportStates();
          notifyCodeBlockLayoutChanged();
          return;
        }

        setCodeBlockCollapsed(shell, false);
        shell.classList.add("is-mindmap-visible");
        setMindmapButtonState(mindmapButton, "active");
        try {
          const rendered = await renderCodeBlockMindmap(shell);
          if (!rendered) {
            shell.classList.remove("is-mindmap-visible");
            setMindmapButtonState(mindmapButton, "error");
          } else {
            await waitForCodeBlockMindmapReady(shell, 3);
          }
        } catch (error) {
          shell.classList.remove("is-mindmap-visible");
          setMindmapButtonState(mindmapButton, "error");
        }
        postCodeBlockMindmapExportStates();
        notifyCodeBlockLayoutChanged();
        return;
      }

      const button = event.target.closest(".code-block-copy");
      if (!button) {
        return;
      }

      const shell = button.closest(".code-block-shell");
      const codeElement = shell?.querySelector("pre > code");
      if (!codeElement) {
        setCopyButtonState(button, "error");
        return;
      }

      try {
        await copyCodeText(codeElement.textContent || "");
        setCopyButtonState(button, "copied");
      } catch (error) {
        setCopyButtonState(button, "error");
      }
    });
  }

  function highlightCodeElement(codeElement, declaredLanguage, options) {
    if (!window.hljs) {
      return declaredLanguage;
    }

    if (!window.__exampleChatHighlightConfigured && typeof window.hljs.configure === "function") {
      window.hljs.configure({ ignoreUnescapedHTML: true });
      window.__exampleChatHighlightConfigured = true;
    }

    const language = resolveHighlightLanguage(declaredLanguage);
    const codeText = codeElement.textContent || "";
    const allowAutoDetect = !(options && options.autoDetectLanguages === false);

    try {
      if (language && typeof window.hljs.getLanguage === "function" && window.hljs.getLanguage(language)) {
        codeElement.classList.add(`language-${language}`);
        window.hljs.highlightElement(codeElement);
        return declaredLanguage || language;
      }

      if (allowAutoDetect && typeof window.hljs.highlightAuto === "function") {
        const result = window.hljs.highlightAuto(codeText);
        codeElement.classList.add("hljs");
        codeElement.innerHTML = result.value;
        return declaredLanguage || result.language || "";
      }
    } catch (error) {
      return declaredLanguage;
    }

    return declaredLanguage;
  }

  function decorateCodeBlocks(root, options) {
    if (!root) {
      return;
    }

    const resolvedOptions = options && typeof options === "object" ? options : {};
    const shouldFormatCode = resolvedOptions.formatCode !== false;
    const shouldHighlightCode = resolvedOptions.highlightCode !== false;
    const shouldUseCodeChrome = resolvedOptions.codeChrome !== false;

    const codeBlocks = root.querySelectorAll("pre > code");
    codeBlocks.forEach((codeElement) => {
      const pre = codeElement.parentElement;
      if (!pre || pre.parentElement?.classList.contains("code-block-shell")) {
        return;
      }

      const declaredLanguage = extractDeclaredLanguage(codeElement);
      const originalCode = codeElement.textContent || "";
      const formattedCode = shouldFormatCode
        ? formatCollapsedCodeText(originalCode, declaredLanguage)
        : originalCode;
      if (formattedCode !== originalCode) {
        codeElement.textContent = formattedCode;
      }
      const codeText = codeElement.textContent || "";
      const lineCount = codeText.replace(/\n+$/g, "").split("\n").length;
      const supportsCollapse = lineCount > 8;
      const effectiveLanguage = shouldHighlightCode
        ? highlightCodeElement(codeElement, declaredLanguage, resolvedOptions)
        : declaredLanguage;

      if (!shouldUseCodeChrome) {
        return;
      }

      const wrapper = document.createElement("div");
      wrapper.className = "code-block-shell";
      if (isWrappingTextCodeLanguage(declaredLanguage || effectiveLanguage)) {
        wrapper.classList.add("is-wrapping-text-block");
      }

      const header = document.createElement("div");
      header.className = "code-block-header";

      const languageTag = document.createElement("span");
      languageTag.className = "code-block-language";
      languageTag.textContent = formatLanguageLabel(declaredLanguage || effectiveLanguage);

      const headerActions = document.createElement("div");
      headerActions.className = "code-block-header-actions";

      const mindmapData = hasCodeBlockMindmapRenderer()
        ? parseCodeBlockMindmap(codeText, declaredLanguage)
        : null;
      if (mindmapData) {
        wrapper.classList.add("has-code-mindmap");
        wrapper.__codeBlockMindmapData = mindmapData;
      }

      if (supportsCollapse) {
        const toggleButton = document.createElement("button");
        toggleButton.type = "button";
        toggleButton.className = "code-block-toggle";
        toggleButton.setAttribute("aria-expanded", "true");
        toggleButton.setAttribute("aria-label", "折叠代码");
        toggleButton.innerHTML = "<span class=\"code-block-toggle-label\">折叠</span>";
        headerActions.appendChild(toggleButton);
      }

      if (mindmapData) {
        const mindmapButton = document.createElement("button");
        mindmapButton.type = "button";
        mindmapButton.className = "code-block-mindmap-toggle";
        mindmapButton.setAttribute("aria-pressed", "false");
        mindmapButton.setAttribute("aria-label", "渲染为思维导图");
        mindmapButton.innerHTML = "<span class=\"code-block-mindmap-toggle-label\">思维导图</span>";
        headerActions.appendChild(mindmapButton);
      }

      const copyButton = document.createElement("button");
      copyButton.type = "button";
      copyButton.className = "code-block-copy";
      copyButton.setAttribute("aria-label", "复制代码");
      copyButton.innerHTML = "<span class=\"code-block-copy-icon\" aria-hidden=\"true\"></span><span class=\"code-block-copy-label\">复制</span>";

      header.appendChild(languageTag);
      headerActions.appendChild(copyButton);
      header.appendChild(headerActions);
      wrapper.appendChild(header);
      pre.before(wrapper);
      wrapper.appendChild(pre);
    });

    if (shouldUseCodeChrome) {
      bindCodeBlockActions(root);
      scheduleCodeBlockMindmapExportStatePost(root);
    }
  }

  function measureRenderedLength(content, options) {
    if (!content) {
      return 0;
    }

    if (options && options.measureTextLength === false) {
      return 0;
    }

    return content.innerText.length;
  }

  function renderPlainTextPreviewInto(content, markdown, options) {
    if (!content) {
      return { renderedLength: 0, renderDurationMs: 0, engine: "missing-content" };
    }

    const renderStart = performance.now();
    const resolvedOptions = options && typeof options === "object" ? options : {};
    clearSmoothStreamingController(content);
    clearStreamingRenderState(content);
    content.textContent = String(markdown || "");
    content.style.whiteSpace = "pre-wrap";
    return {
      renderedLength: measureRenderedLength(content, resolvedOptions),
      renderDurationMs: performance.now() - renderStart,
      engine: "plain-text-preview"
    };
  }

  function decorateImages(root) {
    if (!root) {
      return;
    }

    root.querySelectorAll("img").forEach((image) => {
      image.setAttribute("loading", "lazy");
      image.setAttribute("decoding", "async");
    });
  }

  function externalHTTPURLForLink(link) {
    const rawHref = String(link?.getAttribute?.("href") || "").trim();
    if (!rawHref) {
      return null;
    }

    try {
      const normalizedHref = /^www\./i.test(rawHref) ? `https://${rawHref}` : rawHref;
      const url = new URL(normalizedHref, window.location.href);
      if (url.protocol !== "http:" && url.protocol !== "https:") {
        return null;
      }
      return url;
    } catch (_) {
      return null;
    }
  }

  function faviconURLForHTTPURL(url) {
    if (!url || !url.origin || url.origin === "null") {
      return "";
    }

    return `${url.origin}/favicon.ico`;
  }

  const knownExternalLinkSources = [
    { appId: "google-calendar", hostnames: ["calendar.google.com"] },
    { appId: "google-drive", hostnames: ["docs.google.com"] },
    { appId: "google-drive", hostnames: ["drive.google.com"] },
    { appId: "figma", hostnames: ["figma.com"] },
    { appId: "github", hostnames: ["github.com"] },
    { appId: "linear", hostnames: ["linear.app"] },
    { appId: "gmail", hostnames: ["mail.google.com"] },
    { appId: "notion", hostnames: ["notion.so"] },
    { appId: "google-drive", hostnames: ["sheets.google.com"] },
    { appId: "slack", hostnames: ["slack.com"] },
    { appId: "google-drive", hostnames: ["slides.google.com"] }
  ];

  const knownExternalLinkIconSVG = {
    figma: '<svg class="message-link-brand-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M4.65723 15.3333C4.65723 13.8605 5.85326 12.6666 7.32862 12.6666H10V15.3333C10 16.806 8.80398 18 7.32862 18C5.85326 18 4.65723 16.806 4.65723 15.3333Z" fill="#24CB71"/><path d="M10 2V7.33333H12.6714C14.1468 7.33333 15.3428 6.13941 15.3428 4.66666C15.3428 3.19392 14.1468 2 12.6714 2H10Z" fill="#FF7237"/><path d="M12.6489 12.6666C14.1243 12.6666 15.3203 11.4727 15.3203 9.99998C15.3203 8.52722 14.1243 7.33331 12.6489 7.33331C11.1736 7.33331 9.97754 8.52722 9.97754 9.99998C9.97754 11.4727 11.1736 12.6666 12.6489 12.6666Z" fill="#00B6FF"/><path d="M4.65723 4.66666C4.65723 6.13941 5.85326 7.33333 7.32862 7.33333H10V2H7.32862C5.85326 2 4.65723 3.19392 4.65723 4.66666Z" fill="#FF3737"/><path d="M4.65723 9.99998C4.65723 11.4727 5.85326 12.6666 7.32862 12.6666H10V7.33331H7.32862C5.85326 7.33331 4.65723 8.52723 4.65723 9.99998Z" fill="#874FFF"/></svg>',
    github: '<svg class="message-link-brand-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M9.99996 2.08002C14.373 2.08002 17.915 5.62198 17.915 9.99502C17.9145 11.6534 17.3941 13.2699 16.4268 14.617C15.4595 15.9641 14.0941 16.9739 12.5229 17.5044C12.1271 17.5835 11.9787 17.3362 11.9787 17.1284C11.9787 16.8613 11.9886 16.0104 11.9886 14.9518C11.9886 14.2098 11.7413 13.7349 11.4543 13.4875C13.2154 13.2896 15.0656 12.6169 15.0656 9.57948C15.0656 8.70883 14.7589 8.00637 14.2543 7.45232C14.3334 7.25445 14.6104 6.44316 14.1751 5.35485C14.1751 5.35485 13.5122 5.13719 11.9985 6.16614C11.3653 5.98805 10.6925 5.899 10.0197 5.899C9.34697 5.899 8.6742 5.98805 8.041 6.16614C6.52726 5.14708 5.86437 5.35485 5.86437 5.35485C5.42905 6.44316 5.70607 7.25445 5.78522 7.45232C5.28064 8.00637 4.97394 8.71872 4.97394 9.57948C4.97394 12.607 6.81417 13.2896 8.57526 13.4875C8.3477 13.6854 8.13994 14.0317 8.07068 14.5461C7.61557 14.7539 6.47779 15.0903 5.76544 13.8932C5.61703 13.6557 5.17181 13.072 4.54851 13.0819C3.88562 13.0918 4.28137 13.4578 4.5584 13.6062C4.89479 13.7942 5.28064 14.4967 5.36969 14.7242C5.52799 15.1694 6.04246 16.0203 8.03111 15.6542C8.03111 16.3171 8.041 16.9404 8.041 17.1284C8.041 17.3362 7.89259 17.5736 7.49684 17.5044C5.92041 16.9796 4.54923 15.9718 3.57782 14.6239C2.60641 13.276 2.08409 11.6565 2.08496 9.99502C2.08496 5.62198 5.62692 2.08002 9.99996 2.08002Z" fill="currentColor"/></svg>',
    "google-drive": '<svg class="message-link-brand-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M2.92604 15.3557L3.66105 16.6346C3.81378 16.9038 4.03333 17.1153 4.29106 17.2692L6.91611 12.6923H1.66602C1.66602 12.9903 1.74238 13.2884 1.89511 13.5576L2.92604 15.3557Z" fill="#0066DA"/><path d="M9.99935 7.30764L7.3743 2.73071C7.11657 2.88456 6.89702 3.0961 6.74429 3.36533L1.89511 11.8269C1.74519 12.0903 1.66622 12.3886 1.66602 12.6923H6.91611L9.99935 7.30764Z" fill="#00AC47"/><path d="M15.7075 17.2692C15.9652 17.1153 16.1847 16.9038 16.3375 16.6346L16.6429 16.1057L18.1034 13.5576C18.2561 13.2884 18.3325 12.9903 18.3325 12.6923H13.082L14.1993 14.9038L15.7075 17.2692Z" fill="#EA4335"/><path d="M9.99858 7.30769L12.6236 2.73077C12.3659 2.57692 12.07 2.5 11.7645 2.5H8.23264C7.92718 2.5 7.63127 2.58654 7.37354 2.73077L9.99858 7.30769Z" fill="#00832D"/><path d="M13.0821 12.6923H6.91557L4.29053 17.2692C4.54826 17.423 4.84417 17.5 5.14963 17.5H14.848C15.1535 17.5 15.4494 17.4134 15.7071 17.2692L13.0821 12.6923Z" fill="#2684FC"/><path d="M15.6787 7.5961L13.2541 3.36533C13.1014 3.0961 12.8818 2.88456 12.6241 2.73071L9.99902 7.30764L13.0823 12.6923H18.3228C18.3228 12.3942 18.2464 12.0961 18.0937 11.8269L15.6787 7.5961Z" fill="#FFBA00"/></svg>',
    "google-calendar": '<svg class="message-link-brand-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M13.8579 6.14215H6.14209V13.8579H13.8579V6.14215Z" fill="white"/><path d="M13.8579 17.33L17.33 13.8579L15.5939 13.5617L13.8579 13.8579L13.541 15.4459L13.8579 17.33Z" fill="#EA4335"/><path d="M2.66992 13.8579V16.1727C2.66992 16.8121 3.18784 17.33 3.82729 17.33H6.14204L6.49852 15.594L6.14204 13.8579L4.25041 13.5617L2.66992 13.8579Z" fill="#188038"/><path d="M17.33 6.1421V3.82735C17.33 3.18791 16.8121 2.66998 16.1726 2.66998H13.8579C13.6466 3.53102 13.541 4.16468 13.541 4.57097C13.541 4.97724 13.6466 5.50094 13.8579 6.1421C14.6258 6.36198 15.2045 6.47193 15.5939 6.47193C15.9834 6.47193 16.5621 6.36198 17.33 6.1421Z" fill="#1967D2"/><path d="M17.33 6.14215H13.8579V13.8579H17.33V6.14215Z" fill="#FBBC04"/><path d="M13.8579 13.8578H6.14209V17.33H13.8579V13.8578Z" fill="#34A853"/><path d="M13.8578 2.66998H3.82729C3.18784 2.66998 2.66992 3.18791 2.66992 3.82735V13.8579H6.14204V6.1421H13.8578V2.66998Z" fill="#4285F4"/><path d="M7.72445 12.1277C7.43608 11.9328 7.23642 11.6483 7.12744 11.2722L7.7968 10.9963C7.85756 11.2278 7.96364 11.4072 8.11506 11.5345C8.26553 11.6618 8.44878 11.7245 8.66289 11.7245C8.88182 11.7245 9.06989 11.658 9.2271 11.5249C9.38432 11.3918 9.46341 11.222 9.46341 11.0166C9.46341 10.8063 9.38045 10.6347 9.21456 10.5016C9.04868 10.3685 8.84035 10.3019 8.59151 10.3019H8.20477V9.63932H8.55197C8.76609 9.63932 8.94644 9.58146 9.09304 9.46572C9.23964 9.34998 9.31294 9.19181 9.31294 8.99024C9.31294 8.81084 9.24736 8.66809 9.1162 8.56104C8.98502 8.45399 8.81913 8.39997 8.61755 8.39997C8.4208 8.39997 8.26456 8.45206 8.14882 8.55719C8.03317 8.66259 7.9462 8.79568 7.89613 8.94393L7.23354 8.66809C7.3213 8.41926 7.48237 8.19936 7.71866 8.00936C7.95497 7.81935 8.25684 7.72388 8.62334 7.72388C8.89436 7.72388 9.13837 7.77597 9.35442 7.88108C9.57046 7.98621 9.7402 8.13185 9.86269 8.31703C9.98518 8.50317 10.0459 8.71149 10.0459 8.94297C10.0459 9.17927 9.98904 9.37891 9.87523 9.54287C9.76142 9.70683 9.62158 9.83222 9.45569 9.91999V9.95953C9.66989 10.0478 9.85595 10.1929 9.99386 10.3791C10.1337 10.5672 10.2041 10.7919 10.2041 11.0542C10.2041 11.3165 10.1376 11.5509 10.0045 11.7563C9.87137 11.9618 9.68716 12.1238 9.45375 12.2415C9.21939 12.3591 8.95609 12.4189 8.66386 12.4189C8.32532 12.4199 8.01283 12.3225 7.72445 12.1277ZM11.836 8.80602L11.1011 9.33745L10.7336 8.77998L12.0521 7.82901H12.5574V12.3148H11.836V8.80602Z" fill="#4285F4"/></svg>',
    gmail: '<svg class="message-link-brand-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M5.63563 16.0028V9.81974L3.71805 8.06541L1.99854 7.09192V14.9117C1.99854 15.5154 2.48772 16.0028 3.08966 16.0028H5.63563Z" fill="#4285F4"/><path d="M14.3647 16.0028H16.9107C17.5145 16.0028 18.0019 15.5136 18.0019 14.9117V7.09192L16.0542 8.20702L14.3647 9.81974V16.0028Z" fill="#34A853"/><path d="M5.63543 9.81965L5.37451 7.40371L5.63543 5.09143L9.99995 8.36481L14.3645 5.09143L14.6564 7.27887L14.3645 9.81965L9.99995 13.093L5.63543 9.81965Z" fill="#EA4335"/><path d="M14.3647 5.09142V9.81964L18.0019 7.09183V5.63698C18.0019 4.28762 16.4615 3.51837 15.3831 4.32763L14.3647 5.09142Z" fill="#FBBC04"/><path d="M1.99854 7.09183L3.6713 8.34639L5.63563 9.81964V5.09142L4.61724 4.32763C3.53702 3.51837 1.99854 4.28762 1.99854 5.63698V7.09183Z" fill="#C5221F"/></svg>',
    linear: '<svg class="message-link-brand-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M2.27894 11.8191C2.24372 11.6689 2.4226 11.5744 2.53165 11.6834L8.31156 17.4633C8.42062 17.5724 8.32605 17.7513 8.1759 17.716C5.25911 17.0318 2.96318 14.7359 2.27894 11.8191ZM2.08526 9.50256C2.08247 9.5474 2.09933 9.59119 2.1311 9.62296L10.372 17.8639C10.4038 17.8956 10.4476 17.9125 10.4924 17.9097C10.8675 17.8863 11.2354 17.8369 11.5946 17.7631C11.7156 17.7383 11.7576 17.5896 11.6703 17.5022L2.49273 8.32471C2.40537 8.23735 2.25668 8.27939 2.23183 8.40041C2.15807 8.75953 2.10862 9.12751 2.08526 9.50256ZM2.75155 6.78238C2.7252 6.84155 2.73862 6.9107 2.78442 6.95651L13.0385 17.2105C13.0843 17.2564 13.1534 17.2698 13.2126 17.2434C13.4953 17.1175 13.7694 16.9755 14.0335 16.8185C14.1209 16.7666 14.1343 16.6465 14.0625 16.5747L3.42033 5.93252C3.34844 5.86063 3.22835 5.87412 3.17643 5.96152C3.0195 6.22562 2.87749 6.49964 2.75155 6.78238ZM4.08883 4.94113C4.03025 4.88254 4.02662 4.78858 4.08182 4.72678C5.53266 3.10253 7.6431 2.08002 9.99235 2.08002C14.3679 2.08002 17.915 5.62709 17.915 10.0026C17.915 12.3519 16.8925 14.4623 15.2682 15.9132C15.2064 15.9684 15.1124 15.9647 15.0538 15.9061L4.08883 4.94113Z" fill="currentColor"/></svg>',
    notion: '<svg class="message-link-brand-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M5.08659 4.92479C5.57295 5.3199 5.7554 5.28975 6.66865 5.22882L15.2785 4.71184C15.4611 4.71184 15.3092 4.52966 15.2484 4.49939L13.8185 3.46567C13.5445 3.25297 13.1795 3.00937 12.4798 3.0703L4.14291 3.67837C3.83888 3.70852 3.77814 3.86054 3.89924 3.9824L5.08659 4.92479ZM5.60351 6.93129V15.9903C5.60351 16.4772 5.84681 16.6593 6.39441 16.6292L15.8566 16.0817C16.4045 16.0516 16.4655 15.7167 16.4655 15.3212V6.32296C16.4655 5.9281 16.3136 5.71515 15.9782 5.74555L6.09013 6.32296C5.72522 6.35362 5.60351 6.53616 5.60351 6.93129ZM14.9446 7.41724C15.0052 7.69112 14.9446 7.96475 14.6702 7.99552L14.2143 8.08636V14.7743C13.8185 14.9871 13.4534 15.1087 13.1493 15.1087C12.6623 15.1087 12.5403 14.9566 12.1756 14.5008L9.19339 9.81922V14.3488L10.1371 14.5618C10.1371 14.5618 10.137 15.1087 9.37571 15.1087L7.27685 15.2305C7.21588 15.1087 7.27685 14.805 7.48974 14.7441L8.03745 14.5923V8.60335L7.27698 8.54241C7.216 8.26854 7.36789 7.87366 7.79415 7.84301L10.0458 7.69124L13.1493 12.4338V8.23837L12.358 8.14755C12.2973 7.81274 12.5403 7.56962 12.8446 7.53947L14.9446 7.41724ZM3.44292 2.8576L12.1147 2.21901C13.1796 2.12767 13.4536 2.18885 14.1229 2.67506L16.891 4.62062C17.3477 4.95519 17.5 5.04627 17.5 5.41099V16.0817C17.5 16.7505 17.2564 17.146 16.4046 17.2065L6.33418 17.8146C5.6948 17.8451 5.3905 17.754 5.05566 17.3281L3.01717 14.6833C2.6519 14.1964 2.5 13.8322 2.5 13.4061V3.92122C2.5 3.37434 2.74368 2.91816 3.44292 2.8576Z" fill="currentColor"/></svg>',
    slack: '<svg class="message-link-brand-icon" width="20" height="20" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M5.37305 12.1146C5.37305 13.0446 4.62206 13.7962 3.69287 13.7962C2.76368 13.7962 2.0127 13.0446 2.0127 12.1146C2.0127 11.1847 2.76368 10.4331 3.69287 10.4331H5.37305V12.1146ZM6.21314 12.1146C6.21314 11.1847 6.96413 10.4331 7.89331 10.4331C8.8225 10.4331 9.57349 11.1847 9.57349 12.1146V16.3185C9.57349 17.2484 8.8225 18 7.89331 18C6.96413 18 6.21314 17.2484 6.21314 16.3185V12.1146Z" fill="#E01E5A"/><path d="M7.89335 5.36307C6.96416 5.36307 6.21317 4.61147 6.21317 3.68153C6.21317 2.75159 6.96416 2 7.89335 2C8.82254 2 9.57352 2.75159 9.57352 3.68153V5.36307H7.89335ZM7.89335 6.21657C8.82254 6.21657 9.57352 6.96817 9.57352 7.89811C9.57352 8.82805 8.82254 9.57964 7.89335 9.57964H3.68018C2.75099 9.57964 2 8.82805 2 7.89811C2 6.96817 2.75099 6.21657 3.68018 6.21657H7.89335Z" fill="#36C5F0"/><path d="M14.6267 7.89811C14.6267 6.96817 15.3777 6.21657 16.3069 6.21657C17.2361 6.21657 17.9871 6.96817 17.9871 7.89811C17.9871 8.82805 17.2361 9.57964 16.3069 9.57964H14.6267V7.89811ZM13.7866 7.89811C13.7866 8.82805 13.0356 9.57964 12.1064 9.57964C11.1773 9.57964 10.4263 8.82805 10.4263 7.89811V3.68153C10.4263 2.75159 11.1773 2 12.1064 2C13.0356 2 13.7866 2.75159 13.7866 3.68153V7.89811Z" fill="#2EB67D"/><path d="M12.1064 14.6369C13.0356 14.6369 13.7866 15.3885 13.7866 16.3185C13.7866 17.2484 13.0356 18 12.1064 18C11.1773 18 10.4263 17.2484 10.4263 16.3185V14.6369H12.1064ZM12.1064 13.7962C11.1773 13.7962 10.4263 13.0446 10.4263 12.1146C10.4263 11.1847 11.1773 10.4331 12.1064 10.4331H16.3196C17.2488 10.4331 17.9998 11.1847 17.9998 12.1146C17.9998 13.0446 17.2488 13.7962 16.3196 13.7962H12.1064Z" fill="#ECB22E"/></svg>'
  };

  function hostnameMatchesKnownSource(hostname, sourceHostname) {
    const host = String(hostname || "").trim().toLowerCase();
    const source = String(sourceHostname || "").trim().toLowerCase();
    return Boolean(source && (host === source || host.endsWith(`.${source}`)));
  }

  function knownAppIdForHTTPURL(url) {
    const host = String(url?.hostname || "").trim().toLowerCase();
    if (!host) {
      return "";
    }

    for (const source of knownExternalLinkSources) {
      if (source.hostnames.some((candidate) => hostnameMatchesKnownSource(host, candidate))) {
        return source.appId;
      }
    }
    return "";
  }

  function createTrustedSVG(markup) {
    const template = document.createElement("template");
    template.innerHTML = String(markup || "").trim();
    const icon = template.content.firstElementChild;
    return icon?.namespaceURI === "http://www.w3.org/2000/svg" ? icon : null;
  }

  function createGlobeLinkIcon() {
    return createTrustedSVG('<svg class="message-link-fallback-icon" width="20" height="20" viewBox="0 0 20 20" fill="currentColor" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path d="M10 2.125C14.3492 2.125 17.875 5.65076 17.875 10C17.875 14.3492 14.3492 17.875 10 17.875C5.65076 17.875 2.125 14.3492 2.125 10C2.125 5.65076 5.65076 2.125 10 2.125ZM7.88672 10.625C7.94334 12.3161 8.22547 13.8134 8.63965 14.9053C8.87263 15.5194 9.1351 15.9733 9.39453 16.2627C9.65437 16.5524 9.86039 16.625 10 16.625C10.1396 16.625 10.3456 16.5524 10.6055 16.2627C10.8649 15.9733 11.1274 15.5194 11.3604 14.9053C11.7745 13.8134 12.0567 12.3161 12.1133 10.625H7.88672ZM3.40527 10.625C3.65313 13.2734 5.45957 15.4667 7.89844 16.2822C7.7409 15.997 7.5977 15.6834 7.4707 15.3486C6.99415 14.0923 6.69362 12.439 6.63672 10.625H3.40527ZM13.3633 10.625C13.3064 12.439 13.0059 14.0923 12.5293 15.3486C12.4022 15.6836 12.2582 15.9969 12.1006 16.2822C14.5399 15.467 16.3468 13.2737 16.5947 10.625H13.3633ZM12.1006 3.7168C12.2584 4.00235 12.4021 4.31613 12.5293 4.65137C13.0059 5.90775 13.3064 7.56102 13.3633 9.375H16.5947C16.3468 6.72615 14.54 4.53199 12.1006 3.7168ZM10 3.375C9.86039 3.375 9.65437 3.44756 9.39453 3.7373C9.1351 4.02672 8.87263 4.48057 8.63965 5.09473C8.22547 6.18664 7.94334 7.68388 7.88672 9.375H12.1133C12.0567 7.68388 11.7745 6.18664 11.3604 5.09473C11.1274 4.48057 10.8649 4.02672 10.6055 3.7373C10.3456 3.44756 10.1396 3.375 10 3.375ZM7.89844 3.7168C5.45942 4.53222 3.65314 6.72647 3.40527 9.375H6.63672C6.69362 7.56102 6.99415 5.90775 7.4707 4.65137C7.59781 4.31629 7.74073 4.00224 7.89844 3.7168Z"/></svg>') || document.createElement("span");
  }

  const sourceLinkTooltipState = {
    element: null,
    installed: false,
    showTimer: null,
    target: null
  };

  function clampSourceTooltipValue(value, min, max) {
    return Math.min(Math.max(value, min), max);
  }

  function sourceTooltipNumericCSSVariable(name, fallback) {
    const rawValue = window.getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    const value = Number.parseFloat(rawValue);
    return Number.isFinite(value) ? value : fallback;
  }

  function ensureSourceLinkTooltipElement() {
    if (sourceLinkTooltipState.element && document.body?.contains(sourceLinkTooltipState.element)) {
      return sourceLinkTooltipState.element;
    }

    const tooltip = document.createElement("div");
    tooltip.id = "message-source-link-tooltip";
    tooltip.className = "message-source-link-tooltip";
    tooltip.setAttribute("role", "tooltip");
    document.body?.appendChild(tooltip);
    sourceLinkTooltipState.element = tooltip;
    return tooltip;
  }

  function sourceLinkFromTooltipEventTarget(target) {
    if (!(target instanceof Element)) {
      return null;
    }
    const link = target.closest("a.message-source-link[data-message-source-tooltip]");
    return link instanceof HTMLAnchorElement ? link : null;
  }

  function clearSourceLinkTooltipTimer() {
    if (sourceLinkTooltipState.showTimer !== null) {
      window.clearTimeout(sourceLinkTooltipState.showTimer);
      sourceLinkTooltipState.showTimer = null;
    }
  }

  function positionSourceLinkTooltip(link) {
    const tooltip = sourceLinkTooltipState.element;
    if (!tooltip || !(link instanceof HTMLAnchorElement)) {
      return;
    }

    const linkRect = link.getBoundingClientRect();
    const tooltipRect = tooltip.getBoundingClientRect();
    const viewportWidth = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 0);
    const viewportHeight = Math.max(document.documentElement.clientHeight || 0, window.innerHeight || 0);
    const margin = sourceTooltipNumericCSSVariable("--message-source-tooltip-viewport-margin", 8);
    const gap = sourceTooltipNumericCSSVariable("--message-source-tooltip-gap", 3);
    const preferredLeft = linkRect.left + (linkRect.width / 2) - (tooltipRect.width / 2);
    const maxLeft = Math.max(margin, viewportWidth - tooltipRect.width - margin);
    const left = clampSourceTooltipValue(preferredLeft, margin, maxLeft);
    const topAbove = linkRect.top - tooltipRect.height - gap;
    const topBelow = linkRect.bottom + gap;
    const top = topAbove >= margin
      ? topAbove
      : clampSourceTooltipValue(topBelow, margin, Math.max(margin, viewportHeight - tooltipRect.height - margin));

    tooltip.style.left = `${Math.round(left)}px`;
    tooltip.style.top = `${Math.round(top)}px`;
    tooltip.classList.toggle("is-below", topAbove < margin);
  }

  function hideSourceLinkTooltip() {
    clearSourceLinkTooltipTimer();
    const previousTarget = sourceLinkTooltipState.target;
    if (previousTarget?.getAttribute?.("aria-describedby") === "message-source-link-tooltip") {
      previousTarget.removeAttribute("aria-describedby");
    }
    sourceLinkTooltipState.target = null;
    sourceLinkTooltipState.element?.classList?.remove("is-visible", "is-below", "has-structured-content");
  }

  function middleEllipsizedSourcePath(value, maxLength = 76) {
    const path = String(value || "").trim();
    if (path.length <= maxLength) {
      return path;
    }
    const lastSlashIndex = path.lastIndexOf("/");
    const fileName = lastSlashIndex >= 0 ? path.slice(lastSlashIndex) : "";
    if (fileName.length > 0 && fileName.length < maxLength - 18) {
      const prefixLength = Math.max(12, maxLength - fileName.length - 3);
      return `${path.slice(0, prefixLength)}...${fileName}`;
    }
    const headLength = Math.max(12, Math.floor((maxLength - 3) * 0.45));
    const tailLength = Math.max(12, maxLength - 3 - headLength);
    return `${path.slice(0, headLength)}...${path.slice(path.length - tailLength)}`;
  }

  function renderSourceLinkTooltipContent(tooltip, link) {
    const primary = String(link?.dataset?.messageSourceTooltipPrimary || "").trim();
    const path = String(link?.dataset?.messageSourceTooltipPath || "").trim();
    const text = String(link?.dataset?.messageSourceTooltip || "").trim();
    tooltip.replaceChildren();
    tooltip.removeAttribute("title");
    tooltip.classList.toggle("has-structured-content", Boolean(primary || path));

    if (!primary && !path) {
      tooltip.textContent = text;
      return text;
    }

    const accessibleParts = [];
    if (primary) {
      const primaryElement = document.createElement("span");
      primaryElement.className = "message-source-link-tooltip-primary";
      primaryElement.textContent = primary;
      tooltip.appendChild(primaryElement);
      accessibleParts.push(primary);
    }
    if (path) {
      const pathElement = document.createElement("span");
      pathElement.className = "message-source-link-tooltip-path";
      pathElement.textContent = middleEllipsizedSourcePath(path);
      tooltip.appendChild(pathElement);
      accessibleParts.push(path);
    }
    return accessibleParts.join("\n") || text;
  }

  function showSourceLinkTooltip(link) {
    const text = String(link?.dataset?.messageSourceTooltip || "").trim();
    if (!text) {
      hideSourceLinkTooltip();
      return;
    }

    const tooltip = ensureSourceLinkTooltipElement();
    if (!tooltip) {
      return;
    }

    sourceLinkTooltipState.target = link;
    renderSourceLinkTooltipContent(tooltip, link);
    tooltip.classList.remove("is-visible", "is-below");
    link.setAttribute("aria-describedby", "message-source-link-tooltip");
    positionSourceLinkTooltip(link);
    window.requestAnimationFrame(() => {
      if (sourceLinkTooltipState.target !== link) {
        return;
      }
      positionSourceLinkTooltip(link);
      tooltip.classList.add("is-visible");
    });
  }

  function scheduleSourceLinkTooltip(link) {
    clearSourceLinkTooltipTimer();
    sourceLinkTooltipState.target = link;
    sourceLinkTooltipState.showTimer = window.setTimeout(() => {
      sourceLinkTooltipState.showTimer = null;
      if (sourceLinkTooltipState.target === link) {
        showSourceLinkTooltip(link);
      }
    }, 250);
  }

  function installSourceLinkTooltipHandlers() {
    if (sourceLinkTooltipState.installed || typeof document === "undefined") {
      return;
    }

    sourceLinkTooltipState.installed = true;
    document.addEventListener("mouseover", (event) => {
      const link = sourceLinkFromTooltipEventTarget(event.target);
      if (!link || (event.relatedTarget instanceof Node && link.contains(event.relatedTarget))) {
        return;
      }
      scheduleSourceLinkTooltip(link);
    });
    document.addEventListener("mouseout", (event) => {
      const link = sourceLinkFromTooltipEventTarget(event.target);
      if (!link || (event.relatedTarget instanceof Node && link.contains(event.relatedTarget))) {
        return;
      }
      if (sourceLinkTooltipState.target === link) {
        hideSourceLinkTooltip();
      }
    });
    document.addEventListener("focusin", (event) => {
      const link = sourceLinkFromTooltipEventTarget(event.target);
      if (link) {
        scheduleSourceLinkTooltip(link);
      }
    });
    document.addEventListener("focusout", (event) => {
      const link = sourceLinkFromTooltipEventTarget(event.target);
      if (link && sourceLinkTooltipState.target === link) {
        hideSourceLinkTooltip();
      }
    });
    window.addEventListener("resize", hideSourceLinkTooltip);
    window.addEventListener("scroll", hideSourceLinkTooltip, true);
  }

  function existingSourceLinkInner(link) {
    const firstElement = link?.firstElementChild || null;
    return firstElement?.classList?.contains("message-source-link-inner") ? firstElement : null;
  }

  function sourceLinkTextWrapperForInner(inner) {
    return Array.from(inner?.children || []).find((child) => (
      child?.classList?.contains("message-source-link-text")
    )) || null;
  }

  function unwrapSourceLinkInner(link) {
    const inner = existingSourceLinkInner(link);
    if (!inner) {
      return;
    }

    const textWrapper = sourceLinkTextWrapperForInner(inner);
    if (textWrapper) {
      while (textWrapper.firstChild) {
        link.insertBefore(textWrapper.firstChild, inner);
      }
      inner.remove();
      return;
    }

    const firstInnerChild = inner.firstElementChild;
    if (
      firstInnerChild?.classList?.contains("message-link-favicon-frame")
      || firstInnerChild?.classList?.contains("message-link-favicon")
    ) {
      firstInnerChild.remove();
    }
    while (inner.firstChild) {
      link.insertBefore(inner.firstChild, inner);
    }
    inner.remove();
  }

  function existingLinkFaviconFrame(link) {
    const inner = existingSourceLinkInner(link);
    const firstElement = inner?.firstElementChild || link?.firstElementChild || null;
    if (
      firstElement?.classList?.contains("message-link-favicon-frame")
      || firstElement?.classList?.contains("message-link-favicon")
    ) {
      return firstElement;
    }
    return null;
  }

  function clearExternalLinkDecoration(link) {
    if (sourceLinkTooltipState.target === link) {
      hideSourceLinkTooltip();
    }
    unwrapSourceLinkInner(link);
    const existingFrame = existingLinkFaviconFrame(link);
    if (existingFrame) {
      existingFrame.remove();
    }
    link?.classList?.remove("message-source-link");
    if (link?.dataset) {
      delete link.dataset.messageSourceHost;
      delete link.dataset.messageSourceAppId;
      delete link.dataset.messageSourceTooltip;
    }
  }

  function removeSourceLinkWrappingParentheses(link) {
    const before = link?.previousSibling || null;
    const after = link?.nextSibling || null;
    if (before?.nodeType !== Node.TEXT_NODE || after?.nodeType !== Node.TEXT_NODE) {
      return;
    }

    const beforeText = String(before.nodeValue || "");
    const afterText = String(after.nodeValue || "");
    const openMatch = /([(\uFF08])\s*$/.exec(beforeText);
    if (!openMatch) {
      return;
    }

    const isFullWidth = openMatch[1] === "\uFF08";
    const closePattern = isFullWidth ? /^\s*\uFF09/ : /^\s*\)/;
    if (!closePattern.test(afterText)) {
      return;
    }

    before.nodeValue = beforeText.slice(0, openMatch.index);
    after.nodeValue = afterText.replace(closePattern, "");
  }

  function createLinkIconFrame(link, url) {
    const frame = document.createElement("span");
    frame.className = "message-link-favicon-frame";
    frame.setAttribute("aria-hidden", "true");

    const knownAppId = knownAppIdForHTTPURL(url);
    const knownIconMarkup = knownExternalLinkIconSVG[knownAppId] || "";
    const knownIcon = knownIconMarkup ? createTrustedSVG(knownIconMarkup) : null;
    if (knownIcon) {
      frame.classList.add("has-known-icon");
      frame.dataset.sourceAppId = knownAppId;
      frame.appendChild(knownIcon);
      return frame;
    }

    frame.classList.add("is-favicon-missing");
    frame.appendChild(createGlobeLinkIcon());

    const faviconURL = faviconURLForHTTPURL(url);
    if (!faviconURL) {
      return frame;
    }

    const icon = document.createElement("img");
    icon.className = "message-link-favicon";
    icon.setAttribute("alt", "");
    icon.setAttribute("aria-hidden", "true");
    icon.setAttribute("loading", "lazy");
    icon.setAttribute("decoding", "async");
    icon.setAttribute("referrerpolicy", "no-referrer");
    icon.setAttribute("draggable", "false");

    icon.addEventListener("load", () => {
      frame.classList.add("is-favicon-loaded");
      frame.classList.remove("is-favicon-missing");
    });
    icon.addEventListener("error", () => {
      frame.classList.remove("is-favicon-loaded");
      frame.classList.add("is-favicon-missing");
      icon.removeAttribute("src");
    });

    frame.appendChild(icon);
    icon.setAttribute("src", faviconURL);
    return frame;
  }

  function wrapSourceLinkContent(link, url) {
    unwrapSourceLinkInner(link);
    const existingFrame = existingLinkFaviconFrame(link);
    if (existingFrame) {
      existingFrame.remove();
    }

    const inner = document.createElement("span");
    inner.className = "message-source-link-inner";

    const text = document.createElement("span");
    text.className = "message-source-link-text";
    while (link.firstChild) {
      text.appendChild(link.firstChild);
    }

    inner.appendChild(createLinkIconFrame(link, url));
    inner.appendChild(text);
    link.appendChild(inner);
  }

  function linkTextWithoutAccessibleLabel(link) {
    const clone = link.cloneNode(true);
    Array.from(clone.querySelectorAll(".readex-native-link-accessible-label")).forEach((label) => {
      label.remove();
    });
    return String(clone.textContent || "").replace(/\s+/g, " ").trim();
  }

  function isFootnoteLikeLink(link) {
    if (!(link instanceof HTMLAnchorElement)) {
      return false;
    }
    const href = String(link.getAttribute("href") || "").trim();
    return link.classList.contains("footnote-backref")
      || link.classList.contains("footnote-link")
      || link.hasAttribute("data-footnote-ref")
      || link.hasAttribute("data-footnote-backref")
      || /^#(?:user-content-)?fn(?:ref)?/i.test(href)
      || /^fnref/i.test(String(link.id || ""));
  }

  function isSymbolOnlyLink(link) {
    const text = linkTextWithoutAccessibleLabel(link);
    return text.length > 0
      && text.length <= 4
      && /^[\s[\]().#\d↩↩︎↵←↑↓]+$/u.test(text);
  }

  function ensureHiddenNativeLinkLabel(link, label) {
    const resolvedLabel = String(label || "").trim();
    if (!resolvedLabel || link.querySelector(".readex-native-link-accessible-label")) {
      return;
    }
    const hiddenLabel = document.createElement("span");
    hiddenLabel.className = "readex-native-link-accessible-label";
    hiddenLabel.textContent = resolvedLabel;
    link.appendChild(hiddenLabel);
  }

  function stripNativeLinkTooltip(link) {
    if (!(link instanceof HTMLAnchorElement)) {
      return;
    }

    const title = String(link.getAttribute("title") || "").trim();
    const ariaLabel = String(link.getAttribute("aria-label") || "").trim();
    const shouldSuppressAriaLabel = Boolean(ariaLabel)
      && (isFootnoteLikeLink(link) || isSymbolOnlyLink(link));
    const accessibleLabel = title || (shouldSuppressAriaLabel ? ariaLabel : "");
    if (accessibleLabel && (isFootnoteLikeLink(link) || isSymbolOnlyLink(link))) {
      ensureHiddenNativeLinkLabel(link, accessibleLabel);
      link.dataset.readexNativeTooltipSuppressed = "1";
    }
    link.removeAttribute("title");
    if (shouldSuppressAriaLabel) {
      link.removeAttribute("aria-label");
    }
    Array.from(link.querySelectorAll("[title]")).forEach((child) => {
      child.removeAttribute("title");
    });
  }

  function stripRenderedLinkNativeTooltips(root) {
    if (!root || typeof root.querySelectorAll !== "function") {
      return;
    }
    root.querySelectorAll("a[href]").forEach((link) => {
      stripNativeLinkTooltip(link);
    });
  }

  function shouldDecorateRenderedCodeBlocks(root, options) {
    if (!root) {
      return false;
    }
    const resolvedOptions = options && typeof options === "object" ? options : {};
    if (resolvedOptions.decorateCodeBlocks === false) {
      return false;
    }
    if (resolvedOptions.highlightCode === true || resolvedOptions.codeChrome === true) {
      return true;
    }
    const sourceMarkdown = typeof resolvedOptions.sourceMarkdown === "string"
      ? resolvedOptions.sourceMarkdown
      : null;
    if (sourceMarkdown !== null) {
      return detectRenderFeatures(sourceMarkdown).hasCodeBlocks;
    }
    return Boolean(root.querySelector?.("pre > code"));
  }

  function decorateRenderedMarkdown(root, options) {
    if (!root) {
      return;
    }

    const resolvedOptions = options && typeof options === "object" ? options : {};
    decorateImages(root);
    stripRenderedLinkNativeTooltips(root);
    decorateExternalLinks(root, {
      wrapContent: resolvedOptions.wrapExternalLinkContent !== false
    });
    stripRenderedLinkNativeTooltips(root);
    if (shouldDecorateRenderedCodeBlocks(root, resolvedOptions)) {
      decorateCodeBlocks(root, resolvedOptions);
    }
  }

  function decorateExternalLinks(root, options) {
    if (!root || typeof root.querySelectorAll !== "function") {
      return;
    }

    const shouldWrapContent = !(options && options.wrapContent === false);
    root.querySelectorAll("a[href]").forEach((link) => {
      if (!(link instanceof HTMLAnchorElement) || link.closest(".katex")) {
        return;
      }

      const existingFrame = existingLinkFaviconFrame(link);
      const userImage = Array.from(link.querySelectorAll("img")).find((candidate) => (
        candidate !== existingFrame
        && !candidate.classList.contains("message-link-favicon")
        && !candidate.closest(".message-link-favicon-frame")
      ));
      if (userImage) {
        clearExternalLinkDecoration(link);
        return;
      }

      const url = externalHTTPURLForLink(link);
      if (!url) {
        clearExternalLinkDecoration(link);
        return;
      }

      link.classList.add("message-source-link");
      link.setAttribute("target", "_blank");
      link.setAttribute("rel", "noopener noreferrer");
      stripNativeLinkTooltip(link);
      link.dataset.messageSourceHost = url.hostname;
      link.dataset.messageSourceTooltip = url.href;
      const knownAppId = knownAppIdForHTTPURL(url);
      if (knownAppId) {
        link.dataset.messageSourceAppId = knownAppId;
      } else if (link.dataset.messageSourceAppId) {
        delete link.dataset.messageSourceAppId;
      }
      if (shouldWrapContent) {
        removeSourceLinkWrappingParentheses(link);
        wrapSourceLinkContent(link, url);
      }
    });
  }

  function renderMarkdownInto(content, markdown, options) {
    if (!content) {
      return { renderedLength: 0, renderDurationMs: 0, engine: "missing-content" };
    }

    const renderStart = performance.now();
    const resolvedOptions = options && typeof options === "object" ? options : {};
    hideSourceLinkTooltip();
    clearSmoothStreamingController(content);

    try {
      if (!hasRenderableMarkdownEngine()) {
        return renderPlainTextPreviewInto(content, markdown, resolvedOptions);
      }

      const renderState = renderSourceMappedMarkdownInto(content, markdown, resolvedOptions);
      decorateRenderedMarkdown(content, Object.assign({}, resolvedOptions, { sourceMarkdown: String(markdown || "") }));
      rememberStreamingRenderState(content, markdown, renderState.blocks, resolvedOptions);
      content.style.whiteSpace = "normal";
      runAfterRenderHook(content, resolvedOptions);
      return {
        renderedLength: measureRenderedLength(content, resolvedOptions),
        renderDurationMs: performance.now() - renderStart,
        engine: activeMarkdownEngineName()
      };
    } catch (renderError) {
      clearStreamingRenderState(content);
      const previewMetrics = renderPlainTextPreviewInto(content, markdown, resolvedOptions);
      return {
        renderedLength: previewMetrics.renderedLength,
        renderDurationMs: performance.now() - renderStart,
        engine: "fallback-error"
      };
    }
  }

  function splitMarkdownIntoChunks(markdown, targetChars) {
    const source = String(markdown || "").replace(/\r\n?/g, "\n");
    const safeTarget = Math.max(4000, Number(targetChars) || 18000);

    if (!source) {
      return [""];
    }

    if (source.length <= safeTarget) {
      return [source];
    }

    const lines = source.split("\n");
    const chunks = [];
    const buffer = [];
    const hardLimit = safeTarget * 2;
    let bufferLength = 0;
    let activeFence = "";
    let insideTable = false;

    function pushChunk() {
      if (!buffer.length) {
        return;
      }

      chunks.push(buffer.join("\n"));
      buffer.length = 0;
      bufferLength = 0;
    }

    lines.forEach((line, index) => {
      const trimmedLine = line.trim();
      const fenceMatch = line.match(/^\s*(`{3,}|~{3,})/);

      buffer.push(line);
      bufferLength += line.length + 1;

      if (fenceMatch) {
        const fenceMarker = fenceMatch[1];
        if (!activeFence) {
          activeFence = fenceMarker;
        } else if (fenceMarker[0] === activeFence[0] && fenceMarker.length >= activeFence.length) {
          activeFence = "";
        }
      }

      if (!insideTable && /^<table\b/i.test(trimmedLine)) {
        insideTable = true;
      }
      if (insideTable && /<\/table>/i.test(trimmedLine)) {
        insideTable = false;
      }

      if (activeFence || insideTable) {
        return;
      }

      if (bufferLength < safeTarget) {
        return;
      }

      const nextLine = index + 1 < lines.length ? lines[index + 1].trim() : "";
      const isNaturalBoundary = trimmedLine === ""
        || /^#{1,6}\s/.test(nextLine)
        || /^!\[/.test(nextLine)
        || /^<table\b/i.test(nextLine)
        || /^\|/.test(nextLine);

      if (isNaturalBoundary || bufferLength >= hardLimit) {
        pushChunk();
      }
    });

    pushChunk();

    return chunks.length ? chunks : [source];
  }

  function renderMarkdownChunkFragment(markdown, options) {
    const holder = document.createElement("div");
    const chunkOptions = Object.assign({}, options || {}, {
      progressive: false,
      measureTextLength: false
    });
    renderMarkdownInto(holder, markdown, chunkOptions);

    const fragment = document.createDocumentFragment();
    while (holder.firstChild) {
      fragment.appendChild(holder.firstChild);
    }
    return fragment;
  }

  function restoreDesiredScrollProgressIfNeeded(options) {
    const resolvedOptions = options && typeof options === "object" ? options : {};
    if (resolvedOptions.suppressProgressiveScrollRestore === true) {
      return;
    }

    if (window.__ChatTranscriptPreservesRelativeScrollPositionDuringAsyncLayout === false) {
      return;
    }

    const scrollMemory = window.ChatTranscriptScrollMemory;
    if (!scrollMemory || typeof scrollMemory.restoreDesiredProgress !== "function") {
      return;
    }

    scrollMemory.restoreDesiredProgress();
  }

  function renderMarkdownProgressivelyInto(content, markdown, options) {
    if (!content) {
      return Promise.resolve({ renderedLength: 0, renderDurationMs: 0, engine: "missing-content" });
    }

    const renderStart = performance.now();
    const resolvedOptions = options && typeof options === "object" ? options : {};
    clearSmoothStreamingController(content);
    const generation = String((Number(content.dataset.renderGeneration || "0") || 0) + 1);
    const chunks = splitMarkdownIntoChunks(markdown, resolvedOptions.chunkTargetChars);
    const chunkBudgetMs = Math.max(4, Number(resolvedOptions.chunkBudgetMs) || 10);
    let chunkIndex = 0;

    if (content.__progressiveRenderTimer) {
      window.clearTimeout(content.__progressiveRenderTimer);
      content.__progressiveRenderTimer = null;
    }

    content.dataset.renderGeneration = generation;
    content.dataset.renderComplete = "false";
    content.style.whiteSpace = "normal";

    function isStale() {
      return content.dataset.renderGeneration !== generation;
    }

    function finalize(engine) {
      content.__progressiveRenderTimer = null;
      if (isStale()) {
        return {
          renderedLength: 0,
          renderDurationMs: performance.now() - renderStart,
          engine: "progressive-cancelled"
        };
      }

      content.dataset.renderComplete = "true";
      restoreDesiredScrollProgressIfNeeded(resolvedOptions);
      return {
        renderedLength: measureRenderedLength(content, resolvedOptions),
        renderDurationMs: performance.now() - renderStart,
        engine
      };
    }

    function appendNextChunk() {
      if (chunkIndex >= chunks.length) {
        return false;
      }

      const fragment = renderMarkdownChunkFragment(chunks[chunkIndex], resolvedOptions);
      if (chunkIndex === 0) {
        content.innerHTML = "";
      }
      content.appendChild(fragment);
      restoreDesiredScrollProgressIfNeeded(resolvedOptions);
      chunkIndex += 1;
      return true;
    }

    return new Promise((resolve) => {
      if (!appendNextChunk()) {
        resolve(finalize("progressive-empty"));
        return;
      }

      if (isStale()) {
        resolve(finalize("progressive-cancelled"));
        return;
      }

      function renderBatch() {
        if (isStale()) {
          resolve(finalize("progressive-cancelled"));
          return;
        }

        const batchStart = performance.now();
        while (chunkIndex < chunks.length && performance.now() - batchStart < chunkBudgetMs) {
          appendNextChunk();
        }

        if (chunkIndex < chunks.length) {
          content.__progressiveRenderTimer = window.setTimeout(renderBatch, 0);
          return;
        }

        resolve(finalize(`progressive-${activeMarkdownEngineName()}`));
      }

      if (chunkIndex < chunks.length) {
        content.__progressiveRenderTimer = window.setTimeout(renderBatch, 0);
      } else {
        resolve(finalize(`progressive-${activeMarkdownEngineName()}`));
      }
    });
  }

  function renderUserHTML(text) {
    return `<p>${String(text || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;")
      .replace(/\n/g, "<br />")}</p>`;
  }

  installSourceLinkTooltipHandlers();

  window.ChatMarkdownRenderer = {
    formatCollapsedCodeText,
    decorateRenderedMarkdown,
    renderMarkdownInto,
    renderMarkdownStreamingInto,
    renderMarkdownProgressivelyInto,
    splitMarkdownIntoChunks,
    renderPlainTextPreviewInto,
    renderUserHTML
  };

  window.__chatTranscriptMagnifyCodeBlockMindmapAtPoint = magnifyCodeBlockMindmapAtPoint;
  window.__chatTranscriptEndCodeBlockMindmapMagnification = endCodeBlockMindmapMagnification;
  window.__chatTranscriptApplyCodeBlockMindmapExportStates = applyCodeBlockMindmapExportStates;
  window.__chatTranscriptCollectCodeBlockMindmapExportStates = collectCodeBlockMindmapExportStates;

  window.renderMarkdown = function (markdown) {
    const content = document.getElementById("content");
    return renderMarkdownInto(content, markdown, null);
  };

  window.renderMarkdownWithOptions = function (markdown, options) {
    const content = document.getElementById("content");
    if (options && options.streaming === true) {
      return renderMarkdownStreamingInto(content, markdown, options);
    }
    if (options && options.progressive === true) {
      return renderMarkdownProgressivelyInto(content, markdown, options);
    }
    return renderMarkdownInto(content, markdown, options);
  };

  window.renderMarkdownPreview = function (markdown) {
    const content = document.getElementById("content");
    return renderPlainTextPreviewInto(content, markdown);
  };

  window.addEventListener("load", function () {
    if (window.__lastMarkdown && window.renderMarkdown) {
      window.renderMarkdown(window.__lastMarkdown);
    }
  });
})();
