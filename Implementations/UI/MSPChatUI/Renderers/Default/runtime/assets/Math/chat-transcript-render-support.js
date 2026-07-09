(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript render support dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript render support dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptRenderSupportFactory = function createChatTranscriptRenderSupport(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const transcriptUIState = requiredFunction(dependencies, "transcriptUIState");
    const postMessageAction = requiredFunction(dependencies, "postMessageAction");
    const postTranscriptProbe = requiredFunction(dependencies, "postTranscriptProbe");
    const statusModel = requiredObject(dependencies, "statusModel");
    const resolveRuntimeModel = requiredFunction(dependencies, "resolveRuntimeModel");
    const resolveMessageBlockRenderer = requiredFunction(dependencies, "resolveMessageBlockRenderer");
    const resolveInteractionState = requiredFunction(dependencies, "resolveInteractionState");
    const legacyMessageIsStreaming = requiredFunction(statusModel, "legacyMessageIsStreaming");
    const legacyMessageStatus = requiredFunction(statusModel, "legacyMessageStatus");
    const structuredMessageShellStatus = requiredFunction(statusModel, "structuredMessageShellStatus");

    function runtimeModel() {
      const value = resolveRuntimeModel();
      return value && typeof value === "object" ? value : null;
    }

    function messageBlockRenderer() {
      const value = resolveMessageBlockRenderer();
      return value && typeof value === "object" ? value : null;
    }

    function interactionState() {
      const value = resolveInteractionState();
      return value && typeof value === "object" ? value : null;
    }

    function messageIsStreaming(message) {
      const runtime = runtimeModel();
      if (runtime && typeof runtime.messageIsStreaming === "function") {
        return runtime.messageIsStreaming(message);
      }
      return legacyMessageIsStreaming(message);
    }

    function effectiveMessageStatus(message) {
      const runtime = runtimeModel();
      if (runtime && typeof runtime.effectiveMessageStatus === "function") {
        return runtime.effectiveMessageStatus(message);
      }
      return legacyMessageStatus(message) || structuredMessageShellStatus(message) || "success";
    }

    function rootAttribute(name) {
      return trimmed(document.documentElement?.getAttribute(name));
    }

    function readexMarkdownRendererProfile() {
      const rootProfile = rootAttribute("data-readex-markdown-renderer");
      if (rootProfile) {
        return rootProfile;
      }
      const payloadProfile = trimmed(window.__chatTranscriptPayload?.readexMarkdownRendererProfile);
      if (payloadProfile) {
        return payloadProfile;
      }
      return trimmed(window.__chatTranscriptPresentation?.readexMarkdownRendererProfile) || "legacy-readex";
    }

    function readexMarkstreamCodeTheme() {
      const rootCodeTheme = rootAttribute("data-readex-markstream-code-theme");
      if (rootCodeTheme) {
        return rootCodeTheme;
      }
      const payloadCodeTheme = trimmed(window.__chatTranscriptPayload?.readexMarkstreamCodeTheme);
      if (payloadCodeTheme) {
        return payloadCodeTheme;
      }
      return trimmed(window.__chatTranscriptPresentation?.readexMarkstreamCodeTheme) || "vitesse";
    }

    function markdownRenderOptions() {
      return {
        streaming: false,
        readexMarkdownRendererProfile: readexMarkdownRendererProfile(),
        readexMarkstreamCodeTheme: readexMarkstreamCodeTheme(),
        mathRenderer: "katex",
        mathFallbackRenderer: "none",
        measureTextLength: true,
        streamingMinDelayMs: 10,
        streamingCatchUpDivisor: 5,
        streamingMinimumBatch: 1
      };
    }

    function existingReadexPageReferenceInner(anchor) {
      const firstElement = anchor?.firstElementChild || null;
      return firstElement?.classList?.contains("message-source-link-inner") ? firstElement : null;
    }

    function linkTextWithoutAccessibleLabel(anchor) {
      const clone = anchor.cloneNode(true);
      clone.querySelectorAll(".readex-native-link-accessible-label").forEach((label) => {
        label.remove();
      });
      return trimmed(clone.textContent).replace(/\s+/g, " ");
    }

    function isFootnoteLikeLink(anchor) {
      if (!(anchor instanceof HTMLAnchorElement)) {
        return false;
      }
      const href = trimmed(anchor.getAttribute("href"));
      return anchor.classList.contains("footnote-backref")
        || anchor.classList.contains("footnote-link")
        || anchor.hasAttribute("data-footnote-ref")
        || anchor.hasAttribute("data-footnote-backref")
        || /^#(?:user-content-)?fn(?:ref)?/i.test(href)
        || /^fnref/i.test(trimmed(anchor.id));
    }

    function isSymbolOnlyLink(anchor) {
      const text = linkTextWithoutAccessibleLabel(anchor);
      return text.length > 0
        && text.length <= 4
        && /^[\s[\]().#\d↩↩︎↵←↑↓]+$/u.test(text);
    }

    function ensureHiddenNativeLinkLabel(anchor, label) {
      const resolvedLabel = trimmed(label);
      if (!resolvedLabel || anchor.querySelector(".readex-native-link-accessible-label")) {
        return;
      }
      const hiddenLabel = document.createElement("span");
      hiddenLabel.className = "readex-native-link-accessible-label";
      hiddenLabel.textContent = resolvedLabel;
      anchor.appendChild(hiddenLabel);
    }

    function stripNativeLinkTooltip(anchor) {
      if (!(anchor instanceof HTMLAnchorElement)) {
        return;
      }
      const title = trimmed(anchor.getAttribute("title"));
      const ariaLabel = trimmed(anchor.getAttribute("aria-label"));
      const shouldSuppressAriaLabel = Boolean(ariaLabel)
        && (isFootnoteLikeLink(anchor) || isSymbolOnlyLink(anchor));
      const accessibleLabel = title || (shouldSuppressAriaLabel ? ariaLabel : "");
      if (accessibleLabel && (isFootnoteLikeLink(anchor) || isSymbolOnlyLink(anchor))) {
        ensureHiddenNativeLinkLabel(anchor, accessibleLabel);
        anchor.dataset.readexNativeTooltipSuppressed = "1";
      }
      anchor.removeAttribute("title");
      if (shouldSuppressAriaLabel) {
        anchor.removeAttribute("aria-label");
      }
      anchor.querySelectorAll("[title]").forEach((child) => {
        child.removeAttribute("title");
      });
    }

    function wrapReadexPageReferenceLinkText(anchor) {
      if (!anchor || existingReadexPageReferenceInner(anchor)) {
        return;
      }

      const inner = document.createElement("span");
      inner.className = "message-source-link-inner";

      const text = document.createElement("span");
      text.className = "message-source-link-text";
      while (anchor.firstChild) {
        text.appendChild(anchor.firstChild);
      }

      inner.appendChild(text);
      anchor.appendChild(inner);
    }

    function applyMessageSourceLinkTooltip(anchor, tooltipDescriptor, options = {}) {
      if (!anchor || !tooltipDescriptor) {
        return false;
      }
      const primary = trimmed(tooltipDescriptor.primary);
      const path = trimmed(tooltipDescriptor.path);
      const tooltipLabel = trimmed(tooltipDescriptor.tooltip)
        || [primary, path].filter(Boolean).join("\n");
      if (!tooltipLabel) {
        return false;
      }

      anchor.classList.add("message-source-link");
      stripNativeLinkTooltip(anchor);
      if (anchor.dataset) {
        delete anchor.dataset.messageSourceHost;
        delete anchor.dataset.messageSourceAppId;
        if (options.readexContentReferenceValidated === true) {
          anchor.dataset.readexContentReferenceValidated = "true";
        }
        anchor.dataset.messageSourceTooltip = tooltipLabel;
        if (primary) {
          anchor.dataset.messageSourceTooltipPrimary = primary;
        } else {
          delete anchor.dataset.messageSourceTooltipPrimary;
        }
        if (path) {
          anchor.dataset.messageSourceTooltipPath = path;
        } else {
          delete anchor.dataset.messageSourceTooltipPath;
        }
        const payload = options.payload;
        if (payload && typeof payload === "object") {
          try {
            anchor.dataset.readexContentReferencePayload = JSON.stringify(payload);
          } catch (_) {
            delete anchor.dataset.readexContentReferencePayload;
          }
        } else if (options.readexContentReferenceValidated === true) {
          delete anchor.dataset.readexContentReferencePayload;
        }
      }
      wrapReadexPageReferenceLinkText(anchor);
      return true;
    }

    function decorateReadexPageReferenceLink(anchor, tooltipDescriptor, payload) {
      applyMessageSourceLinkTooltip(anchor, tooltipDescriptor, {
        payload,
        readexContentReferenceValidated: true
      });
    }

    let readexReferenceValidationSequence = 0;
    const readexContentReferenceValidationCache = new Map();

    function readexContentReferenceCacheKey(href) {
      return trimmed(href);
    }

    function decodedReadexSourceLinkValue(value) {
      const rawValue = trimmed(value);
      if (!rawValue) {
        return "";
      }
      try {
        return decodeURIComponent(rawValue);
      } catch (_) {
        return rawValue;
      }
    }

    function plainReadexSourceLinkPathFromHref(href) {
      const rawHref = trimmed(href);
      if (!rawHref || rawHref.startsWith("#")) {
        return "";
      }

      try {
        const normalizedHref = /^www\./i.test(rawHref) ? `https://${rawHref}` : rawHref;
        const url = new URL(normalizedHref, window.location.href);
        const protocol = trimmed(url.protocol).toLowerCase();
        if (protocol === "javascript:" || protocol === "data:") {
          return "";
        }
        if (protocol === "readex:") {
          return trimmed(url.searchParams.get("path"))
            || trimmed(url.searchParams.get("url"))
            || trimmed(url.searchParams.get("uri"))
            || rawHref;
        }
        if (protocol === "file:") {
          return decodedReadexSourceLinkValue(url.pathname) || rawHref;
        }
        if (protocol === "http:" || protocol === "https:") {
          return url.href;
        }
        return rawHref;
      } catch (_) {
        return rawHref;
      }
    }

    function plainReadexSourceLinkTooltipDescriptor(anchor) {
      if (!(anchor instanceof HTMLAnchorElement)) {
        return null;
      }
      if (anchor.closest(".katex") || isFootnoteLikeLink(anchor) || isSymbolOnlyLink(anchor)) {
        return null;
      }
      if (anchor.querySelector("img")) {
        return null;
      }

      const path = plainReadexSourceLinkPathFromHref(anchor.getAttribute("href"));
      if (!path) {
        return null;
      }
      const label = linkTextWithoutAccessibleLabel(anchor);
      const primary = label && label !== path ? label : "";
      return { primary, path };
    }

    function decorateUndecoratedReadexSourceLinkTooltip(anchor) {
      if (!(anchor instanceof HTMLAnchorElement) || trimmed(anchor.dataset?.messageSourceTooltip)) {
        return false;
      }
      const tooltipDescriptor = plainReadexSourceLinkTooltipDescriptor(anchor);
      if (!tooltipDescriptor) {
        return false;
      }
      return applyMessageSourceLinkTooltip(anchor, tooltipDescriptor);
    }

    function readexReferenceValidationIDForAnchor(anchor) {
      if (!anchor?.dataset) {
        return "";
      }
      const existing = trimmed(anchor.dataset.readexContentReferenceValidationId);
      if (existing) {
        return existing;
      }
      readexReferenceValidationSequence += 1;
      const id = `readex-ref-${Date.now().toString(36)}-${readexReferenceValidationSequence.toString(36)}`;
      anchor.dataset.readexContentReferenceValidationId = id;
      return id;
    }

    function readexValidatedTooltipDescriptorFromResult(result) {
      const primary = trimmed(result?.primary);
      const path = trimmed(result?.path);
      if (!primary && !path) {
        return null;
      }
      return { primary, path };
    }

    function rememberReadexContentReferenceValidation(result) {
      const href = readexContentReferenceCacheKey(result?.href);
      if (!href) {
        return;
      }
      if (result?.valid === false) {
        readexContentReferenceValidationCache.set(href, {
          href,
          valid: false
        });
        return;
      }

      const tooltipDescriptor = readexValidatedTooltipDescriptorFromResult(result);
      if (!tooltipDescriptor) {
        return;
      }
      readexContentReferenceValidationCache.set(href, {
        href,
        valid: true,
        tooltipDescriptor,
        payload: result?.payload && typeof result.payload === "object" ? result.payload : null
      });
    }

    function applyCachedReadexContentReferenceValidation(anchor) {
      if (!(anchor instanceof HTMLAnchorElement)) {
        return false;
      }
      const href = readexContentReferenceCacheKey(anchor.getAttribute("href"));
      const cached = href ? readexContentReferenceValidationCache.get(href) : null;
      if (!cached) {
        return false;
      }

      if (anchor.dataset) {
        delete anchor.dataset.readexContentReferenceValidationPendingHref;
      }
      if (cached.valid === false) {
        replaceReadexContentReferenceWithPlainText(anchor);
        return true;
      }
      decorateReadexPageReferenceLink(anchor, cached.tooltipDescriptor, cached.payload);
      return true;
    }

    function replayCachedReadexContentReferenceValidations(root) {
      if (!root || typeof root.querySelectorAll !== "function" || !readexContentReferenceValidationCache.size) {
        return;
      }
      root.querySelectorAll("a[href]").forEach((anchor) => {
        applyCachedReadexContentReferenceValidation(anchor);
      });
    }

    function replaceReadexContentReferenceWithPlainText(anchor) {
      if (!anchor || !anchor.parentNode) {
        return;
      }
      const text = document.createElement("span");
      text.className = "readex-unresolved-content-reference";
      while (anchor.firstChild) {
        text.appendChild(anchor.firstChild);
      }
      anchor.parentNode.replaceChild(text, anchor);
    }

    function applyReadexContentReferenceValidation(response) {
      const results = Array.isArray(response?.results) ? response.results : [];
      if (!results.length) {
        return;
      }
      const resultsByID = new Map();
      results.forEach((result) => {
        const id = trimmed(result?.id);
        if (id) {
          resultsByID.set(id, result);
        }
        rememberReadexContentReferenceValidation(result);
      });
      if (!resultsByID.size) {
        return;
      }

      document.querySelectorAll("a[data-readex-content-reference-validation-id]").forEach((anchor) => {
        const result = resultsByID.get(trimmed(anchor.dataset.readexContentReferenceValidationId));
        if (!result) {
          return;
        }
        const expectedHref = trimmed(result.href);
        if (expectedHref && trimmed(anchor.getAttribute("href")) !== expectedHref) {
          return;
        }
        applyCachedReadexContentReferenceValidation(anchor);
      });
    }

    window.__chatTranscriptApplyReadexContentReferenceValidation = applyReadexContentReferenceValidation;

    function validateReadexContentReferenceLinks(root) {
      if (!root || typeof root.querySelectorAll !== "function") {
        return;
      }

      const items = [];
      root.querySelectorAll("a[href]").forEach((anchor) => {
        const href = anchor.getAttribute("href");
        if (!trimmed(href)) {
          return;
        }
        if (applyCachedReadexContentReferenceValidation(anchor)) {
          return;
        }
        decorateUndecoratedReadexSourceLinkTooltip(anchor);
        if (anchor.dataset?.readexContentReferenceValidated === "true") {
          return;
        }
        if (trimmed(anchor.dataset?.readexContentReferenceValidationPendingHref) === trimmed(href)) {
          return;
        }
        const id = readexReferenceValidationIDForAnchor(anchor);
        if (id) {
          anchor.dataset.readexContentReferenceValidationPendingHref = trimmed(href);
          items.push({ id, href });
        }
      });
      if (!items.length) {
        return;
      }
      postMessageAction({
        action: "validateReadexContentReferences",
        requestID: `readex-ref-validation-${Date.now().toString(36)}-${readexReferenceValidationSequence.toString(36)}`,
        items
      });
    }

    function resolvedReadexMarkdownRendererProfile(options) {
      return trimmed(options?.readexMarkdownRendererProfile) || readexMarkdownRendererProfile();
    }

    function shouldUseSharedMarkdownDecorators(options) {
      return resolvedReadexMarkdownRendererProfile(options).startsWith("markstream-");
    }

    function decorateRenderedMarkdownWithRenderer(renderer, root, options) {
      if (!shouldUseSharedMarkdownDecorators(options)) {
        return;
      }
      const decorator = typeof renderer?.decorateRenderedMarkdown === "function"
        ? renderer.decorateRenderedMarkdown
        : null;
      if (!decorator) {
        return;
      }

      try {
        decorator(root, Object.assign({}, options || {}, {
          decorateCodeBlocks: false,
          wrapExternalLinkContent: true
        }));
      } catch (_) {
        // Link decoration should never make markdown rendering fail.
      }
    }

    function postProcessRenderedMarkdown(renderer, root, options) {
      if (options?.readexStreamingLightweight === true) {
        return;
      }
      decorateRenderedMarkdownWithRenderer(renderer, root, options);
      replayCachedReadexContentReferenceValidations(root);
      validateReadexContentReferenceLinks(root);
      scheduleMarkdownLayoutClipProbe(root, options);
      scheduleMarkstreamLayoutOverlapProbe(root, Object.assign({}, options || {}, {
        source: "render"
      }));
      scheduleMarkstreamTextPaintClipProbe(root, Object.assign({}, options || {}, {
        source: "render"
      }));
    }

    function refreshRenderedMarkdownDecorators(renderer, root, options) {
      postProcessRenderedMarkdown(renderer, root, options);
    }

    function finalizedLightweightPostProcessOptions(options) {
      return Object.assign({}, options || {}, {
        streaming: false,
        streamingFinalizeImmediate: false,
        readexStreamingLightweight: false,
        readexStreamingFinalizedLightweight: true
      });
    }

    function scheduleFinalizedLightweightMarkdownPostProcess(renderer, element, options) {
      if (!renderer || !element) {
        return;
      }
      const requestFrame = typeof window.requestAnimationFrame === "function"
        ? window.requestAnimationFrame.bind(window)
        : (callback) => window.setTimeout(callback, 16);
      requestFrame(() => {
        if (!element.isConnected) {
          return;
        }
        postProcessRenderedMarkdown(
          renderer,
          element,
          finalizedLightweightPostProcessOptions(options)
        );
      });
    }

    function roundedRectPayload(rect) {
      if (!rect) {
        return null;
      }
      const round = (value) => Math.round(Number(value || 0) * 10) / 10;
      return {
        x: round(rect.x),
        y: round(rect.y),
        width: round(rect.width),
        height: round(rect.height),
        left: round(rect.left),
        right: round(rect.right),
        top: round(rect.top),
        bottom: round(rect.bottom)
      };
    }

    function elementDebugSelector(element) {
      if (!(element instanceof Element)) {
        return "";
      }
      const tag = element.tagName.toLowerCase();
      const id = element.id ? `#${element.id}` : "";
      const classes = String(element.className || "")
        .trim()
        .split(/\s+/)
        .filter(Boolean)
        .slice(0, 4)
        .map((className) => `.${className}`)
        .join("");
      const messageID = element.getAttribute("data-message-id");
      const sourceID = element.getAttribute("data-source-block-id");
      const data = [
        messageID ? `[data-message-id="${messageID}"]` : "",
        sourceID ? `[data-source-block-id="${sourceID}"]` : ""
      ].join("");
      return `${tag}${id}${classes}${data}`;
    }

    function elementStyleProbe(element) {
      if (!(element instanceof Element)) {
        return {};
      }
      const style = window.getComputedStyle(element);
      return {
        display: style.display,
        position: style.position,
        overflowX: style.overflowX,
        overflowY: style.overflowY,
        whiteSpace: style.whiteSpace,
        overflowWrap: style.overflowWrap,
        wordBreak: style.wordBreak,
        textAlign: style.textAlign,
        fontSize: style.fontSize,
        fontWeight: style.fontWeight,
        lineHeight: style.lineHeight,
        letterSpacing: style.letterSpacing,
        width: style.width,
        minWidth: style.minWidth,
        maxWidth: style.maxWidth,
        marginLeft: style.marginLeft,
        marginRight: style.marginRight,
        paddingLeft: style.paddingLeft,
        paddingRight: style.paddingRight,
        boxSizing: style.boxSizing,
        contain: style.contain,
        contentVisibility: style.contentVisibility,
        clipPath: style.clipPath,
        mask: style.mask || style.webkitMask || "",
        filter: style.filter,
        willChange: style.willChange,
        transform: style.transform
      };
    }

    function nearestHorizontalClipAncestor(element, rect) {
      let current = element instanceof Element ? element.parentElement : null;
      while (current) {
        const style = window.getComputedStyle(current);
        const clipsX = ["hidden", "clip", "auto", "scroll"].includes(style.overflowX);
        if (clipsX) {
          const parentRect = current.getBoundingClientRect();
          if (rect.right > parentRect.right + 0.5 || rect.left < parentRect.left - 0.5) {
            return {
              selector: elementDebugSelector(current),
              rect: roundedRectPayload(parentRect),
              style: elementStyleProbe(current),
              deltaLeft: Math.round((parentRect.left - rect.left) * 10) / 10,
              deltaRight: Math.round((rect.right - parentRect.right) * 10) / 10
            };
          }
        }
        current = current.parentElement;
      }
      return null;
    }

    function collectMarkdownLayoutClipIssues(root) {
      if (!(root instanceof Element)) {
        return [];
      }
      const issues = [];
      const textWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      while (issues.length < 12 && textWalker.nextNode()) {
        const node = textWalker.currentNode;
        const sample = String(node.nodeValue || "").replace(/\s+/g, " ").trim();
        if (!sample) {
          continue;
        }
        const parent = node.parentElement;
        if (!parent) {
          continue;
        }
        const range = document.createRange();
        range.selectNodeContents(node);
        const rects = Array.from(range.getClientRects ? range.getClientRects() : []);
        range.detach();
        for (const rect of rects) {
          if (!rect || rect.width <= 0 || rect.height <= 0) {
            continue;
          }
          const clipAncestor = nearestHorizontalClipAncestor(parent, rect);
          if (!clipAncestor) {
            continue;
          }
          issues.push({
            type: "textRangeClip",
            text: sample.slice(0, 80),
            textRect: roundedRectPayload(rect),
            textParent: {
              selector: elementDebugSelector(parent),
              rect: roundedRectPayload(parent.getBoundingClientRect()),
              style: elementStyleProbe(parent)
            },
            clipAncestor
          });
          break;
        }
      }

      const elements = Array.from(root.querySelectorAll("*"));
      for (const element of elements) {
        if (issues.length >= 12) {
          break;
        }
        if (!(element instanceof HTMLElement)) {
          continue;
        }
        if (element.scrollWidth <= element.clientWidth + 1) {
          continue;
        }
        issues.push({
          type: "elementHorizontalOverflow",
          selector: elementDebugSelector(element),
          rect: roundedRectPayload(element.getBoundingClientRect()),
          clientWidth: element.clientWidth,
          scrollWidth: element.scrollWidth,
          style: elementStyleProbe(element),
          text: String(element.textContent || "").replace(/\s+/g, " ").trim().slice(0, 80)
        });
      }
      return issues;
    }

    function numericStylePixels(value) {
      const number = Number.parseFloat(String(value || ""));
      return Number.isFinite(number) ? Math.round(number * 10) / 10 : null;
    }

    function rectDeltaPayload(outer, inner) {
      if (!outer || !inner) {
        return null;
      }
      const round = (value) => Math.round(Number(value || 0) * 10) / 10;
      return {
        left: round(inner.left - outer.left),
        right: round(outer.right - inner.right),
        top: round(inner.top - outer.top),
        bottom: round(outer.bottom - inner.bottom)
      };
    }

    function rectIntersectsViewport(rect, padding = 120) {
      if (!rect) {
        return false;
      }
      const viewportWidth = window.innerWidth || document.documentElement?.clientWidth || 0;
      const viewportHeight = window.innerHeight || document.documentElement?.clientHeight || 0;
      return rect.bottom >= -padding &&
        rect.right >= -padding &&
        rect.top <= viewportHeight + padding &&
        rect.left <= viewportWidth + padding;
    }

    function elementLayoutProbe(element) {
      if (!(element instanceof Element)) {
        return null;
      }
      const payload = {
        selector: elementDebugSelector(element),
        rect: roundedRectPayload(element.getBoundingClientRect()),
        style: elementStyleProbe(element)
      };
      if (element instanceof HTMLElement) {
        payload.clientWidth = element.clientWidth;
        payload.scrollWidth = element.scrollWidth;
        payload.offsetLeft = Math.round(Number(element.offsetLeft || 0) * 10) / 10;
        payload.clientLeft = Math.round(Number(element.clientLeft || 0) * 10) / 10;
      }
      return payload;
    }

    function suspiciousPaintAncestorFlags(style) {
      const flags = [];
      if (["hidden", "clip", "auto", "scroll"].includes(style.overflowX)) {
        flags.push(`overflowX:${style.overflowX}`);
      }
      if (["hidden", "clip", "auto", "scroll"].includes(style.overflowY)) {
        flags.push(`overflowY:${style.overflowY}`);
      }
      if (style.contain && style.contain !== "none") {
        flags.push(`contain:${style.contain}`);
      }
      if (style.contentVisibility && style.contentVisibility !== "visible") {
        flags.push(`contentVisibility:${style.contentVisibility}`);
      }
      if (style.transform && style.transform !== "none") {
        flags.push("transform");
      }
      if (style.clipPath && style.clipPath !== "none") {
        flags.push("clipPath");
      }
      if ((style.mask && style.mask !== "none") || (style.webkitMask && style.webkitMask !== "none")) {
        flags.push("mask");
      }
      if (style.filter && style.filter !== "none") {
        flags.push("filter");
      }
      if (style.willChange && style.willChange !== "auto") {
        flags.push(`willChange:${style.willChange}`);
      }
      return flags;
    }

    function ancestorPaintChain(element, root) {
      const chain = [];
      let current = element instanceof Element ? element.parentElement : null;
      while (current && chain.length < 8) {
        const style = window.getComputedStyle(current);
        const flags = suspiciousPaintAncestorFlags(style);
        const include =
          flags.length > 0 ||
          current === root ||
          current.classList?.contains("readex-markstream-root") ||
          current.classList?.contains("markstream-vue") ||
          current.classList?.contains("markdown-renderer") ||
          current.classList?.contains("message-content") ||
          current.classList?.contains("assistant-fragment");
        if (include) {
          const probe = elementLayoutProbe(current);
          if (probe) {
            probe.flags = flags;
            chain.push(probe);
          }
        }
        if (current === root || current === document.body || current === document.documentElement) {
          break;
        }
        current = current.parentElement;
      }
      return chain;
    }

    function textRangeRect(node, startOffset, endOffset) {
      const range = document.createRange();
      range.setStart(node, startOffset);
      range.setEnd(node, endOffset);
      const rects = Array.from(range.getClientRects ? range.getClientRects() : []);
      const rect = rects.find((candidate) => candidate && candidate.width > 0 && candidate.height > 0) || null;
      const unionRect = typeof range.getBoundingClientRect === "function"
        ? range.getBoundingClientRect()
        : null;
      range.detach();
      return {
        firstRect: roundedRectPayload(rect),
        unionRect: roundedRectPayload(unionRect),
        rectCount: rects.length
      };
    }

    function canvasTextInkProbe(text, style) {
      const sample = String(text || "");
      if (!sample) {
        return null;
      }
      const canvas = document.createElement("canvas");
      const context = canvas.getContext("2d");
      if (!context) {
        return null;
      }
      context.font = style.font || [
        style.fontStyle,
        style.fontVariant,
        style.fontWeight,
        style.fontSize,
        style.fontFamily
      ].filter(Boolean).join(" ");
      const metrics = context.measureText(sample);
      const round = (value) => Number.isFinite(Number(value))
        ? Math.round(Number(value) * 10) / 10
        : null;
      return {
        text: sample,
        width: round(metrics.width),
        actualBoundingBoxLeft: round(metrics.actualBoundingBoxLeft),
        actualBoundingBoxRight: round(metrics.actualBoundingBoxRight),
        actualBoundingBoxAscent: round(metrics.actualBoundingBoxAscent),
        actualBoundingBoxDescent: round(metrics.actualBoundingBoxDescent)
      };
    }

    function markstreamTextPaintSample(node, root, index) {
      const rawText = String(node.nodeValue || "");
      const compactText = rawText.replace(/\s+/g, " ").trim();
      if (!compactText) {
        return null;
      }
      const parent = node.parentElement;
      if (!parent) {
        return null;
      }
      const parentStyle = window.getComputedStyle(parent);
      const firstCluster = Array.from(compactText)[0] || compactText[0] || "";
      const firstClusterLength = Math.max(1, firstCluster.length);
      const firstOffset = rawText.search(/\S/);
      const safeStartOffset = Math.max(0, firstOffset);
      const safeEndOffset = Math.min(rawText.length, safeStartOffset + firstClusterLength);
      const nodeRange = textRangeRect(node, 0, rawText.length);
      const firstRange = safeEndOffset > safeStartOffset
        ? textRangeRect(node, safeStartOffset, safeEndOffset)
        : null;
      const parentRect = parent.getBoundingClientRect();
      const rootRect = root.getBoundingClientRect();
      const viewportRect = firstRange?.firstRect || nodeRange.firstRect || roundedRectPayload(parentRect);
      const fontSize = numericStylePixels(parentStyle.fontSize);
      const sample = {
        index,
        text: compactText.slice(0, 80),
        hasCJK: /[\u3400-\u9fff\uf900-\ufaff]/.test(compactText),
        nearViewport: rectIntersectsViewport(viewportRect, 160),
        parent: elementLayoutProbe(parent),
        rootDelta: rectDeltaPayload(rootRect, parentRect),
        nodeRange,
        firstRange,
        parentToNodeDelta: rectDeltaPayload(parentRect, nodeRange.firstRect),
        parentToFirstDelta: firstRange ? rectDeltaPayload(parentRect, firstRange.firstRect) : null,
        firstInk: canvasTextInkProbe(firstCluster, parentStyle),
        fontSize,
        ancestorChain: ancestorPaintChain(parent, root)
      };
      let score = 0;
      if (sample.hasCJK) {
        score += 10;
      }
      if (fontSize !== null && fontSize >= 20) {
        score += 6;
      }
      if (sample.nearViewport) {
        score += 30;
      }
      const firstLeftDelta = sample.parentToFirstDelta?.left;
      if (typeof firstLeftDelta === "number" && firstLeftDelta <= 1.5) {
        score += 5;
      }
      if (sample.ancestorChain.some((ancestor) => Array.isArray(ancestor.flags) && ancestor.flags.length > 0)) {
        score += 4;
      }
      sample.riskScore = score;
      return sample;
    }

    function markstreamRootsForProbe(root) {
      if (!(root instanceof Element)) {
        return [];
      }
      const roots = [];
      if (root.classList?.contains("readex-markstream-root")) {
        roots.push(root);
      }
      root.querySelectorAll?.(".readex-markstream-root").forEach((element) => {
        if (element instanceof Element) {
          roots.push(element);
        }
      });
      return Array.from(new Set(roots));
    }

    function collectMarkstreamTextPaintSamples(root) {
      const roots = markstreamRootsForProbe(root);
      const samples = [];
      for (const markstreamRoot of roots) {
        const textWalker = document.createTreeWalker(markstreamRoot, NodeFilter.SHOW_TEXT);
        let visited = 0;
        let offscreenFallbackCount = 0;
        while (visited < 2000 && textWalker.nextNode()) {
          visited += 1;
          const parent = textWalker.currentNode?.parentElement;
          const parentRect = parent?.getBoundingClientRect ? parent.getBoundingClientRect() : null;
          const nearViewport = rectIntersectsViewport(parentRect, 240);
          if (!nearViewport) {
            if (offscreenFallbackCount >= 32) {
              continue;
            }
            offscreenFallbackCount += 1;
          }
          const sample = markstreamTextPaintSample(textWalker.currentNode, markstreamRoot, samples.length);
          if (sample) {
            samples.push(sample);
          }
          if (samples.length >= 96) {
            break;
          }
        }
        if (samples.length >= 96) {
          break;
        }
      }
      return samples
        .sort((lhs, rhs) => (rhs.riskScore || 0) - (lhs.riskScore || 0))
        .slice(0, 5);
    }

    function postMarkstreamTextPaintClipProbe(root, options) {
      if (!readexLayoutProbeEnabled()) {
        return;
      }
      const hostBridge = window.__chatTranscriptHostBridge;
      if (!hostBridge || typeof hostBridge.postPresentationProbe !== "function") {
        return;
      }
      const rendererProfile = resolvedReadexMarkdownRendererProfile(options);
      if (!rendererProfile.startsWith("markstream-")) {
        return;
      }
      const probeRoot = root instanceof Element ? root : document.body;
      if (!(probeRoot instanceof Element)) {
        return;
      }
      const samples = collectMarkstreamTextPaintSamples(probeRoot);
      const computedRootStyle = window.getComputedStyle(document.documentElement);
      hostBridge.postPresentationProbe({
        kind: "markstream_text_paint_clip_probe",
        source: trimmed(options?.source) || "unknown",
        rendererProfile,
        root: elementLayoutProbe(probeRoot),
        rootCount: markstreamRootsForProbe(probeRoot).length,
        sampleCount: samples.length,
        viewport: {
          width: Math.round(Number(window.innerWidth || 0) * 10) / 10,
          height: Math.round(Number(window.innerHeight || 0) * 10) / 10
        },
        pageZoom: numericStylePixels(computedRootStyle.getPropertyValue("--chat-page-zoom-factor")),
        bodyFontSize: numericStylePixels(computedRootStyle.getPropertyValue("--chat-body-font-size")),
        samples
      });
    }

    let pendingMarkstreamTextPaintClipProbe = null;
    let markstreamTextPaintClipProbeScheduled = false;

    function scheduleMarkstreamTextPaintClipProbe(root, options = {}) {
      if (!readexLayoutProbeEnabled()) {
        return;
      }
      const rendererProfile = resolvedReadexMarkdownRendererProfile(options);
      if (!rendererProfile.startsWith("markstream-")) {
        return;
      }
      pendingMarkstreamTextPaintClipProbe = {
        root: document.body instanceof Element ? document.body : root,
        options: Object.assign({}, options || {}, { readexMarkdownRendererProfile: rendererProfile })
      };
      if (markstreamTextPaintClipProbeScheduled) {
        return;
      }
      markstreamTextPaintClipProbeScheduled = true;
      const requestFrame = typeof window.requestAnimationFrame === "function"
        ? window.requestAnimationFrame.bind(window)
        : (callback) => window.setTimeout(callback, 16);
      requestFrame(() => {
        requestFrame(() => {
          markstreamTextPaintClipProbeScheduled = false;
          const pending = pendingMarkstreamTextPaintClipProbe;
          pendingMarkstreamTextPaintClipProbe = null;
          if (pending) {
            postMarkstreamTextPaintClipProbe(pending.root, pending.options);
          }
        });
      });
    }

    function postMarkdownLayoutClipProbe(root, options) {
      if (!readexLayoutProbeEnabled()) {
        return;
      }
      const hostBridge = window.__chatTranscriptHostBridge;
      if (!hostBridge || typeof hostBridge.postPresentationProbe !== "function") {
        return;
      }
      const issues = collectMarkdownLayoutClipIssues(root);
      if (!issues.length) {
        return;
      }
      hostBridge.postPresentationProbe({
        kind: "markdown_layout_clip_probe",
        rendererProfile: trimmed(options?.readexMarkdownRendererProfile),
        root: {
          selector: elementDebugSelector(root),
          rect: roundedRectPayload(root.getBoundingClientRect()),
          clientWidth: root.clientWidth,
          scrollWidth: root.scrollWidth,
          style: elementStyleProbe(root)
        },
        issues
      });
    }

    function scheduleMarkdownLayoutClipProbe(root, options) {
      if (!readexLayoutProbeEnabled()) {
        return;
      }
      const requestFrame = typeof window.requestAnimationFrame === "function"
        ? window.requestAnimationFrame.bind(window)
        : (callback) => window.setTimeout(callback, 16);
      requestFrame(() => {
        requestFrame(() => postMarkdownLayoutClipProbe(root, options));
      });
    }

    function readexLayoutProbeEnabled() {
      return window.__chatTranscriptReadexLayoutProbeEnabled === true;
    }

    function compactLayoutProbeText(element) {
      return String(element?.textContent || "").replace(/\s+/g, " ").trim().slice(0, 120);
    }

    function markstreamLayoutBlockCandidates(markstreamRoot) {
      if (!(markstreamRoot instanceof Element)) {
        return [];
      }
      const selector = [
        "h1", "h2", "h3", "h4", "h5", "h6",
        "p", "li", "pre", "blockquote", "table", "figure",
        "ul", "ol", "hr",
        "[data-readex-markdown-block]",
        ".markdown-alert",
        ".contains-task-list"
      ].join(", ");
      return Array.from(markstreamRoot.querySelectorAll?.(selector) || [])
        .filter((element) => element instanceof HTMLElement)
        .filter((element) => {
          const rect = element.getBoundingClientRect();
          if (!rect || rect.width <= 0 || rect.height <= 0) {
            return false;
          }
          if (!rectIntersectsViewport(rect, 320)) {
            return false;
          }
          const style = window.getComputedStyle(element);
          if (style.display === "none" || style.visibility === "hidden") {
            return false;
          }
          return true;
        })
        .slice(0, 160);
    }

    function markstreamLayoutCandidatePayload(element, index) {
      return {
        index,
        selector: elementDebugSelector(element),
        tagName: String(element?.tagName || "").toLowerCase(),
        rect: roundedRectPayload(element?.getBoundingClientRect?.()),
        style: elementStyleProbe(element),
        childElementCount: element?.children?.length || 0,
        textLength: String(element?.textContent || "").length,
        text: compactLayoutProbeText(element)
      };
    }

    function verticalOverlapIssuePayload(previous, current, index) {
      if (!(previous instanceof HTMLElement) || !(current instanceof HTMLElement)) {
        return null;
      }
      if (previous.contains(current) || current.contains(previous)) {
        return null;
      }
      const previousRect = previous.getBoundingClientRect();
      const currentRect = current.getBoundingClientRect();
      if (!previousRect || !currentRect) {
        return null;
      }
      const overlapY = previousRect.bottom - currentRect.top;
      if (overlapY <= 2) {
        return null;
      }
      const overlapX = Math.min(previousRect.right, currentRect.right) - Math.max(previousRect.left, currentRect.left);
      if (overlapX <= 2) {
        return null;
      }
      return {
        index,
        overlapY: Math.round(overlapY * 10) / 10,
        overlapX: Math.round(overlapX * 10) / 10,
        previous: markstreamLayoutCandidatePayload(previous, index - 1),
        current: markstreamLayoutCandidatePayload(current, index)
      };
    }

    function collectMarkstreamLayoutOverlapRoots(root) {
      const roots = markstreamRootsForProbe(root);
      return roots.slice(0, 8).map((markstreamRoot, rootIndex) => {
        const candidates = markstreamLayoutBlockCandidates(markstreamRoot);
        const issues = [];
        for (let index = 1; index < candidates.length && issues.length < 8; index += 1) {
          const issue = verticalOverlapIssuePayload(candidates[index - 1], candidates[index], index);
          if (issue) {
            issues.push(issue);
          }
        }
        return {
          rootIndex,
          root: elementLayoutProbe(markstreamRoot),
          candidateCount: candidates.length,
          sampleCandidates: candidates.slice(0, 16).map(markstreamLayoutCandidatePayload),
          issues
        };
      });
    }

    function postMarkstreamLayoutOverlapProbe(root, options = {}) {
      if (!readexLayoutProbeEnabled()) {
        return;
      }
      const hostBridge = window.__chatTranscriptHostBridge;
      if (!hostBridge || typeof hostBridge.postPresentationProbe !== "function") {
        return;
      }
      const rendererProfile = resolvedReadexMarkdownRendererProfile(options);
      if (!rendererProfile.startsWith("markstream-")) {
        return;
      }
      const probeRoot = root instanceof Element ? root : document.body;
      if (!(probeRoot instanceof Element)) {
        return;
      }
      const roots = collectMarkstreamLayoutOverlapRoots(probeRoot);
      const issueCount = roots.reduce((sum, entry) => sum + (entry.issues?.length || 0), 0);
      if (issueCount <= 0 && options?.forceReadexLayoutProbe !== true) {
        return;
      }
      hostBridge.postPresentationProbe({
        kind: "markstream_layout_overlap_probe",
        source: trimmed(options?.source) || "unknown",
        rendererProfile,
        root: elementLayoutProbe(probeRoot),
        rootCount: roots.length,
        issueCount,
        viewport: {
          width: Math.round(Number(window.innerWidth || 0) * 10) / 10,
          height: Math.round(Number(window.innerHeight || 0) * 10) / 10
        },
        roots
      });
    }

    let pendingMarkstreamLayoutOverlapProbe = null;
    let markstreamLayoutOverlapProbeScheduled = false;

    function scheduleMarkstreamLayoutOverlapProbe(root, options = {}) {
      if (!readexLayoutProbeEnabled()) {
        return;
      }
      const rendererProfile = resolvedReadexMarkdownRendererProfile(options);
      if (!rendererProfile.startsWith("markstream-")) {
        return;
      }
      pendingMarkstreamLayoutOverlapProbe = {
        root: root instanceof Element ? root : document.body,
        options: Object.assign({}, options || {}, { readexMarkdownRendererProfile: rendererProfile })
      };
      if (markstreamLayoutOverlapProbeScheduled) {
        return;
      }
      markstreamLayoutOverlapProbeScheduled = true;
      const requestFrame = typeof window.requestAnimationFrame === "function"
        ? window.requestAnimationFrame.bind(window)
        : (callback) => window.setTimeout(callback, 16);
      requestFrame(() => {
        requestFrame(() => {
          markstreamLayoutOverlapProbeScheduled = false;
          const pending = pendingMarkstreamLayoutOverlapProbe;
          pendingMarkstreamLayoutOverlapProbe = null;
          if (pending) {
            postMarkstreamLayoutOverlapProbe(pending.root, pending.options);
          }
        });
      });
    }

    window.__chatTranscriptScheduleMarkstreamLayoutOverlapProbe = scheduleMarkstreamLayoutOverlapProbe;
    window.__chatTranscriptScheduleMarkstreamTextPaintClipProbe = scheduleMarkstreamTextPaintClipProbe;

    function renderMarkdownIntoElement(renderer, element, markdown, options) {
      if (!renderer || !element) {
        return null;
      }

      const baseOptions = options && typeof options === "object" ? options : {};
      const previousAfterRender = typeof baseOptions.afterRender === "function" ? baseOptions.afterRender : null;
      const resolvedOptions = Object.assign({}, baseOptions, {
        afterRender(root) {
          if (previousAfterRender) {
            previousAfterRender(root);
          }
          postProcessRenderedMarkdown(renderer, root, resolvedOptions);
        }
      });
      const rendererProfile = trimmed(resolvedOptions.readexMarkdownRendererProfile) || "legacy-readex";
      const markstreamSDK = window.ReadexMarkstreamSDK;
      if (rendererProfile.startsWith("markstream-")) {
        if (markstreamSDK && typeof markstreamSDK.renderMarkdownInto === "function") {
          try {
            let markstreamMetrics = null;
            if (
              resolvedOptions.streaming === true
              && resolvedOptions.readexStreamingLightweight === true
              && typeof markstreamSDK.updateMarkdownStreamingSource === "function"
            ) {
              markstreamMetrics = markstreamSDK.updateMarkdownStreamingSource(element, markdown || "", resolvedOptions);
              return markstreamMetrics;
            } else if (
              resolvedOptions.streaming === true
              && resolvedOptions.streamingFinalizeImmediate === true
              && typeof markstreamSDK.finalizeMarkdownStreamingSource === "function"
            ) {
              markstreamMetrics = markstreamSDK.finalizeMarkdownStreamingSource(element, markdown || "", resolvedOptions);
              if (markstreamMetrics?.lightweightFinalizeUpdate === true) {
                scheduleFinalizedLightweightMarkdownPostProcess(renderer, element, resolvedOptions);
                return markstreamMetrics;
              }
            } else if (resolvedOptions.streaming === true && typeof markstreamSDK.renderMarkdownStreamingInto === "function") {
              markstreamMetrics = markstreamSDK.renderMarkdownStreamingInto(element, markdown || "", resolvedOptions);
            } else {
              markstreamMetrics = markstreamSDK.renderMarkdownInto(element, markdown || "", resolvedOptions);
            }
            postProcessRenderedMarkdown(renderer, element, resolvedOptions);
            return markstreamMetrics;
          } catch (error) {
            console.warn("[ReadexMarkstreamSDK] render failed; falling back to legacy renderer", error);
            if (typeof markstreamSDK.unmount === "function") {
              markstreamSDK.unmount(element);
            }
          }
        }
      } else if (markstreamSDK && typeof markstreamSDK.unmount === "function") {
        markstreamSDK.unmount(element);
      }

      let metrics = null;
      if (resolvedOptions.streaming === true && typeof renderer.renderMarkdownStreamingInto === "function") {
        metrics = renderer.renderMarkdownStreamingInto(element, markdown || "", resolvedOptions);
      } else if (resolvedOptions.progressive === true && typeof renderer.renderMarkdownProgressivelyInto === "function") {
        metrics = renderer.renderMarkdownProgressivelyInto(element, markdown || "", resolvedOptions);
      } else {
        metrics = renderer.renderMarkdownInto(element, markdown || "", resolvedOptions);
      }
      postProcessRenderedMarkdown(renderer, element, resolvedOptions);
      return metrics;
    }

    function postMainTextRenderProbe(event, message, blockKey, text, metrics, renderOptions = {}) {
      if (!messageIsStreaming(message) && renderOptions.streaming !== true) {
        return;
      }

      postTranscriptProbe("streaming_render", event, {
        messageID: trimmed(message?.id),
        blockKey: trimmed(blockKey),
        status: effectiveMessageStatus(message),
        textLength: String(text || "").length,
        streamingOption: Boolean(renderOptions.streaming),
        engine: trimmed(metrics?.engine) || "unknown",
        displayedLength: Number(metrics?.displayedLength) || 0,
        targetLength: Number(metrics?.targetLength) || 0,
        queuedCharCount: Number(metrics?.queuedCharCount) || 0,
        renderedLength: Number(metrics?.renderedLength) || 0,
        liveTailMode: trimmed(metrics?.liveTailMode),
        stableBlockCount: Number(metrics?.stableBlockCount) || 0,
        replacedBlockCount: Number(metrics?.replacedBlockCount) || 0,
        sourceBlockCount: Number(metrics?.sourceBlockCount) || 0
      });
    }

    function directChildByClass(root, className) {
      if (!root) {
        return null;
      }
      return Array.from(root.children || []).find((child) => child.classList?.contains(className)) || null;
    }

    function removeDirectChild(root, child) {
      if (root && child && child.parentNode === root) {
        child.remove();
      }
    }

    function replaceElementIfSignatureChanged(element, signature, buildElement) {
      if (!element) {
        const replacement = buildElement();
        replacement.__chatTranscriptSignature = signature;
        return replacement;
      }
      if (element.__chatTranscriptSignature === signature) {
        return element;
      }
      const replacement = buildElement();
      replacement.__chatTranscriptSignature = signature;
      element.replaceWith(replacement);
      return replacement;
    }

    function messageDOMKey(message, index) {
      return trimmed(message?.patchKey) || trimmed(message?.id) || `__message_index_${index}`;
    }

    function fallbackBlockKey(block, index) {
      return trimmed(block?.id) || `__message_block_${index}`;
    }

    function fallbackBlockSignature(block, message) {
      return JSON.stringify({
        block,
        role: message?.role,
        status: message?.status,
        isStreaming: messageIsStreaming(message)
      });
    }

    function messageRenderSignature(message) {
      const state = transcriptUIState() || {};
      const messageID = trimmed(message?.id);
      const runtime = runtimeModel();
      const blockRenderer = messageBlockRenderer();
      const copiedInteractionState = interactionState();
      const renderableBlocks = runtime && typeof runtime.renderableMessageBlocks === "function"
        ? runtime.renderableMessageBlocks(message)
        : [];
      const blockKey = blockRenderer && typeof blockRenderer.messageBlockKey === "function"
        ? blockRenderer.messageBlockKey
        : fallbackBlockKey;
      const blockSignature = blockRenderer && typeof blockRenderer.messageBlockSignature === "function"
        ? blockRenderer.messageBlockSignature
        : fallbackBlockSignature;
      const visibleUserToolbarMessageIDs = state.visibleUserToolbarMessageIDs || {};
      const memoryCitationStateKey = trimmed(message?.patchKey)
        || messageID
        || trimmed(message?.readexTurnID || message?.readexTurnId)
        || trimmed(message?.readexCodexTurnID || message?.readexCodexTurnId);
      const expandedMemoryCitationMessageIDs = state.readexMemoryCitationExpandedMessageIDs || {};

      return JSON.stringify({
        shell: {
          id: messageID,
          role: message?.role,
          replyToMessageID: message?.replyToMessageID,
          title: message?.title,
          timeText: message?.timeText,
          status: effectiveMessageStatus(message),
          headerPageSummary: message?.headerPageSummary,
          footerPageSummary: message?.footerPageSummary,
          completedGoalDurationMilliseconds: message?.completedGoalDurationMilliseconds,
          branchNoticeText: message?.branchNoticeText,
          memoryCitation: message?.memoryCitation || null,
          memoryCitationExpanded: Boolean(
            memoryCitationStateKey && expandedMemoryCitationMessageIDs[memoryCitationStateKey]
          ),
          attachmentCount: Array.isArray(message?.attachments) ? message.attachments.length : 0
        },
        blocks: renderableBlocks.map((block, index) => ({
          key: blockKey(block, index),
          signature: blockSignature(block, message)
        })),
        editing: state.editingMessageId === messageID,
        userToolbarVisible: Boolean(visibleUserToolbarMessageIDs[messageID]),
        copied: messageID && copiedInteractionState && typeof copiedInteractionState.isMessageCopied === "function"
          ? copiedInteractionState.isMessageCopied(messageID)
          : false,
        activeModelPicker: state.activeModelPickerMessageId === messageID
      });
    }

    return Object.freeze({
      markdownRenderOptions,
      renderMarkdownIntoElement,
      refreshRenderedMarkdownDecorators,
      applyMessageSourceLinkTooltip,
      postMainTextRenderProbe,
      directChildByClass,
      removeDirectChild,
      replaceElementIfSignatureChanged,
      messageDOMKey,
      messageRenderSignature
    });
  };
})();
