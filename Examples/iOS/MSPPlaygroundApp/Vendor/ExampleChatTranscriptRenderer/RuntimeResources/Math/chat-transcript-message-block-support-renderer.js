(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript message block support renderer dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptMessageBlockSupportRendererFactory = function createChatTranscriptMessageBlockSupportRenderer(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const blockText = requiredFunction(dependencies, "blockText");
    const makeIcon = requiredFunction(dependencies, "makeIcon");
    const appendIcon = requiredFunction(dependencies, "appendIcon");
    const readexAccentColor = requiredFunction(dependencies, "readexAccentColor");
    const blockIsLive = requiredFunction(dependencies, "blockIsLive");
    const messageIsStreaming = requiredFunction(dependencies, "messageIsStreaming");
    const markdownRenderOptions = requiredFunction(dependencies, "markdownRenderOptions");
    const renderMarkdownIntoElement = requiredFunction(dependencies, "renderMarkdownIntoElement");
    const formatThinkingSeconds = requiredFunction(dependencies, "formatThinkingSeconds");
    const directChildByClass = requiredFunction(dependencies, "directChildByClass");
    const removeDirectChild = requiredFunction(dependencies, "removeDirectChild");
    const replaceElementIfSignatureChanged = requiredFunction(dependencies, "replaceElementIfSignatureChanged");
    const transcriptUIState = requiredFunction(dependencies, "transcriptUIState");
    const citationPreviewStateKey = requiredFunction(dependencies, "citationPreviewStateKey");
    const toggleCitationPreview = requiredFunction(dependencies, "toggleCitationPreview");
    const populateReferenceAvatar = requiredFunction(dependencies, "populateReferenceAvatar");
    const displayTitleForReference = requiredFunction(dependencies, "displayTitleForReference");
    const hostnameForReference = requiredFunction(dependencies, "hostnameForReference");
    const renderBranchNotice = requiredFunction(dependencies, "renderBranchNotice");
    const patchBranchNotice = requiredFunction(dependencies, "patchBranchNotice");
    const isThinkingBlockExpanded = requiredFunction(dependencies, "isThinkingBlockExpanded");
    const hasExplicitThinkingBlockExpandedState = requiredFunction(dependencies, "hasExplicitThinkingBlockExpandedState");
    const setThinkingBlockExpanded = requiredFunction(dependencies, "setThinkingBlockExpanded");
    const postAttachmentOpen = requiredFunction(dependencies, "postAttachmentOpen");
    const postMessageAction = requiredFunction(dependencies, "postMessageAction");
    const postPresentationProbe = requiredFunction(dependencies, "postPresentationProbe");
    const resolveMarkdownRenderer = requiredFunction(dependencies, "resolveMarkdownRenderer");
    const renderReadexVideoProgressBlock = requiredFunction(dependencies, "renderReadexVideoProgressBlock");
    const codexShimmerSweepMilliseconds = 1000;
    const codexShimmerIntervalMilliseconds = 4000;
    const codexShimmerInitialDelayMilliseconds = 600;

    function readexContentReferenceProbeValue(value) {
      if (value === undefined) {
        return null;
      }
      if (value === null || typeof value !== "object") {
        return value;
      }
      try {
        return JSON.parse(JSON.stringify(value));
      } catch (_) {
        return String(value);
      }
    }

    function readexContentReferenceProbeKeys(value) {
      if (!value || typeof value !== "object") {
        return [];
      }
      return Object.keys(value).sort();
    }

    function readexContentReferenceProbe(stage, payload = {}) {
      if (!window.__chatTranscriptReadexReferenceProbeEnabled) {
        return;
      }
      try {
        postPresentationProbe({
          kind: "readex_content_reference",
          stage,
          ...readexContentReferenceProbeValue(payload)
        });
      } catch (_) {}
    }

    function buildSupportLine(iconName, titleText, chevronName) {
      const row = document.createElement("div");
      row.className = "support-line";

      const icon = appendIcon(row, iconName);
      decorateReadexTerminalCommandIcon(icon, iconName);

      const title = document.createElement("span");
      title.className = "support-line-title";
      title.textContent = titleText;
      row.appendChild(title);

      const spacer = document.createElement("span");
      spacer.className = "support-line-spacer";
      row.appendChild(spacer);

      if (chevronName) {
        const chevron = document.createElement("span");
        chevron.className = "support-chevron";
        chevron.innerHTML = makeIcon(chevronName);
        row.appendChild(chevron);
      }

      return row;
    }

    function readexIconIsTerminalCommand(iconName) {
      return trimmed(iconName) === "terminal-square";
    }

    function decorateReadexTerminalCommandIcon(icon, iconName) {
      if (icon && readexIconIsTerminalCommand(iconName)) {
        icon.classList.add("readex-terminal-command-icon");
      }
    }

    function configurePressableSupportLine(row, options = {}) {
      if (!row) {
        return null;
      }

      const isInteractive = Boolean(options.interactive);
      const opensPreview = Boolean(options.opensPreview);
      row.classList.toggle("is-interactive", isInteractive);
      row.classList.toggle("opens-preview", opensPreview);
      row.querySelectorAll(".readex-preview-jump-target").forEach((node) => {
        node.classList.remove("readex-preview-jump-target");
      });
      if (opensPreview) {
        row
          .querySelectorAll(":scope > svg, :scope > .sf-symbol-mask, .support-line-title, .support-chevron")
          .forEach((node) => node.classList.add("readex-preview-jump-target"));
      }
      if (isInteractive) {
        row.tabIndex = 0;
        row.setAttribute("role", "button");
        if (options.hasPopup) {
          row.setAttribute("aria-haspopup", options.hasPopup);
        } else {
          row.removeAttribute("aria-haspopup");
        }
        if (typeof options.expanded === "boolean") {
          row.setAttribute("aria-expanded", options.expanded ? "true" : "false");
        } else {
          row.removeAttribute("aria-expanded");
        }
      } else {
        row.removeAttribute("tabindex");
        row.removeAttribute("role");
        row.removeAttribute("aria-haspopup");
        row.removeAttribute("aria-expanded");
      }

      return row;
    }

    function updateSupportLine(root, iconName, titleText, chevronName) {
      const signature = JSON.stringify({ iconName, titleText, chevronName });
      const current = directChildByClass(root, "support-line");
      const next = replaceElementIfSignatureChanged(
        current,
        signature,
        () => buildSupportLine(iconName, titleText, chevronName)
      );
      if (next && next.parentNode !== root) {
        root.insertBefore(next, root.firstChild);
      }
      return next;
    }

    function setSupportLineTitleText(element, titleText) {
      const supportLine = directChildByClass(element, "support-line");
      const title = supportLine ? supportLine.querySelector(".support-line-title") : null;
      if (title && title.textContent !== titleText) {
        title.textContent = titleText;
      }
    }

    function readexDisclosureAnimationConfig() {
      const reducedMotion = typeof window.matchMedia === "function"
        && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      return {
        enabled: !reducedMotion,
        durationMilliseconds: 500
      };
    }

    function cleanupReadexDisclosureAnimationStyles(element) {
      element.style.removeProperty("height");
      element.style.removeProperty("overflow");
      element.style.removeProperty("opacity");
      element.style.removeProperty("transform");
      element.style.removeProperty("transform-origin");
      element.style.removeProperty("will-change");
      delete element.__chatTranscriptReadexDisclosureAnimationOpening;
      delete element.__chatTranscriptReadexDisclosureCloseAction;
    }

    function removeReadexDisclosureAnimationEffect(animation) {
      if (!animation) {
        return;
      }
      animation.onfinish = null;
      animation.oncancel = null;
      try {
        animation.cancel();
      } catch (_) {
      }
    }

    function readexDisclosureCloseAction(options = {}) {
      const duration = Number(options.durationMilliseconds) > 0
        ? String(Number(options.durationMilliseconds))
        : "";
      return [
        options.hideOnFinish === true ? "hide" : "",
        options.removeOnFinish === true ? "remove" : "",
        options.reserveLayout === true ? "reserve" : "collapse",
        options.preserveScrollAnchor === true ? "anchor" : "",
        duration
      ].join(":");
    }

    function readexDisclosureScrollRoot() {
      return document.scrollingElement || document.documentElement || document.body || null;
    }

    function readexDisclosureMaximumScrollTop(root) {
      if (!root) {
        return 0;
      }
      return Math.max((Number(root.scrollHeight) || 0) - (Number(root.clientHeight) || 0), 0);
    }

    function readexDisclosureClamp(value, minimum, maximum) {
      return Math.min(Math.max(value, minimum), maximum);
    }

    function readexDisclosureViewportRect(root) {
      if (!root) {
        return null;
      }
      if (root === document.scrollingElement || root === document.documentElement || root === document.body) {
        return {
          top: 0,
          bottom: window.innerHeight || document.documentElement.clientHeight || 0
        };
      }
      const rect = root.getBoundingClientRect();
      return {
        top: rect.top,
        bottom: rect.bottom
      };
    }

    function captureReadexDisclosureScrollAnchor(element) {
      const root = readexDisclosureScrollRoot();
      const viewport = readexDisclosureViewportRect(root);
      if (!root || !viewport || !(element instanceof HTMLElement)) {
        return null;
      }

      const maximumScrollTop = readexDisclosureMaximumScrollTop(root);
      const scrollTop = Number(root.scrollTop) || 0;
      const distanceFromBottom = Math.max(maximumScrollTop - scrollTop, 0);
      const rect = element.getBoundingClientRect();
      const pinsBottom = distanceFromBottom <= 64;
      const staysAboveViewport = rect.bottom <= viewport.top;
      if (!pinsBottom && !staysAboveViewport) {
        return null;
      }

      return {
        root,
        scrollTop,
        maximumScrollTop,
        pinsBottom,
        staysAboveViewport
      };
    }

    function restoreReadexDisclosureScrollAnchor(anchor) {
      if (!anchor?.root) {
        return;
      }
      const nextMaximumScrollTop = readexDisclosureMaximumScrollTop(anchor.root);
      if (anchor.pinsBottom) {
        anchor.root.scrollTop = nextMaximumScrollTop;
        return;
      }
      if (anchor.staysAboveViewport) {
        anchor.root.scrollTop = readexDisclosureClamp(
          anchor.scrollTop + nextMaximumScrollTop - anchor.maximumScrollTop,
          0,
          nextMaximumScrollTop
        );
      }
    }

    function startReadexDisclosureScrollAnchorTracking(element, anchor) {
      if (!anchor || !(element instanceof HTMLElement) || typeof window.requestAnimationFrame !== "function") {
        return null;
      }

      let frame = 0;
      let active = true;
      const tick = () => {
        if (!active) {
          return;
        }
        restoreReadexDisclosureScrollAnchor(anchor);
        frame = window.requestAnimationFrame(tick);
      };
      frame = window.requestAnimationFrame(tick);
      return () => {
        active = false;
        if (frame && typeof window.cancelAnimationFrame === "function") {
          window.cancelAnimationFrame(frame);
        }
      };
    }

    function stopReadexDisclosureScrollAnchorTracking(element) {
      if (!element) {
        return;
      }
      const stop = element?.__chatTranscriptReadexDisclosureStopScrollTracking;
      if (typeof stop === "function") {
        stop();
      }
      delete element.__chatTranscriptReadexDisclosureStopScrollTracking;
      delete element.__chatTranscriptReadexDisclosureScrollAnchor;
    }

    function finishReadexDisclosureClose(element, opening, options = {}, scrollAnchor = null) {
      if (!opening) {
        if (options.hideOnFinish) {
          element.hidden = true;
        }
        if (options.removeOnFinish) {
          element.remove();
        }
        restoreReadexDisclosureScrollAnchor(scrollAnchor);
      }
      if (typeof options.onFinish === "function") {
        options.onFinish();
      }
    }

    function readexDisclosureClosingAnimationMatches(element, options = {}) {
      return Boolean(element?.__chatTranscriptReadexDisclosureAnimation)
        && element.__chatTranscriptReadexDisclosureAnimationOpening === false
        && element.__chatTranscriptReadexDisclosureCloseAction === readexDisclosureCloseAction(options);
    }

    function cancelReadexDisclosureAnimation(element) {
      const animation = element?.__chatTranscriptReadexDisclosureAnimation;
      if (!animation) {
        return;
      }
      animation.onfinish = null;
      animation.oncancel = null;
      try {
        animation.cancel();
      } catch (_) {
      }
      element.__chatTranscriptReadexDisclosureAnimation = null;
      stopReadexDisclosureScrollAnchorTracking(element);
      cleanupReadexDisclosureAnimationStyles(element);
    }

    function cancelReadexAncestorDisclosureAnimations(element) {
      let ancestor = element?.parentElement;
      while (ancestor) {
        cancelReadexDisclosureAnimation(ancestor);
        ancestor = ancestor.parentElement;
      }
    }

    function readexDisclosureAnimationFrames(opening, height, startHeight = null, startOpacity = null) {
      const resolvedStartHeight = Number.isFinite(startHeight) ? Math.max(0, startHeight) : null;
      const resolvedStartOpacity = Number.isFinite(startOpacity)
        ? Math.min(Math.max(startOpacity, 0), 1)
        : null;
      const fromHeight = opening ? (resolvedStartHeight ?? 0) : height;
      const toHeight = opening ? height : 0;
      const start = { height: `${fromHeight}px`, opacity: opening ? (resolvedStartOpacity ?? 0) : 1 };
      const end = { height: `${toHeight}px`, opacity: opening ? 1 : 0 };
      return [start, end];
    }

    function readexDisclosureLayoutStableAnimationFrames(opening) {
      const start = {
        opacity: opening ? 0 : 1
      };
      const end = {
        opacity: opening ? 1 : 0
      };
      return [start, end];
    }

    function animateReadexDisclosureElement(element, opening, options = {}) {
      if (!(element instanceof HTMLElement)) {
        return;
      }

      if (!opening && readexDisclosureClosingAnimationMatches(element, options)) {
        return;
      }
      cancelReadexDisclosureAnimation(element);
      const config = readexDisclosureAnimationConfig();
      if (opening) {
        element.hidden = false;
      }

      if (!config.enabled || typeof element.animate !== "function") {
        const scrollAnchor = !opening && options.preserveScrollAnchor === true
          ? captureReadexDisclosureScrollAnchor(element)
          : null;
        cleanupReadexDisclosureAnimationStyles(element);
        finishReadexDisclosureClose(element, opening, options, scrollAnchor);
        return;
      }

      const height = Math.max(0, element.scrollHeight);
      if (height <= 0) {
        const scrollAnchor = !opening && options.preserveScrollAnchor === true
          ? captureReadexDisclosureScrollAnchor(element)
          : null;
        cleanupReadexDisclosureAnimationStyles(element);
        finishReadexDisclosureClose(element, opening, options, scrollAnchor);
        return;
      }

      const reserveLayout = options.reserveLayout === true;
      const scrollAnchor = !opening && options.preserveScrollAnchor === true
        ? captureReadexDisclosureScrollAnchor(element)
        : null;
      const configuredStartHeight = Number(options.startHeight);
      const startHeight = !reserveLayout && opening && Number.isFinite(configuredStartHeight)
        ? Math.max(0, configuredStartHeight)
        : null;
      const configuredStartOpacity = Number(options.startOpacity);
      const startOpacity = opening && Number.isFinite(configuredStartOpacity)
        ? Math.min(Math.max(configuredStartOpacity, 0), 1)
        : null;
      if (reserveLayout) {
        element.style.removeProperty("height");
        element.style.removeProperty("overflow");
      } else {
        element.style.height = !opening ? `${height}px` : `${startHeight ?? 0}px`;
        element.style.overflow = "hidden";
      }
      element.style.willChange = reserveLayout ? "opacity" : "height, opacity";

      const frames = reserveLayout
        ? readexDisclosureLayoutStableAnimationFrames(opening)
        : readexDisclosureAnimationFrames(opening, height, startHeight, startOpacity);
      let animation;
      try {
        animation = element.animate(frames, {
          duration: Number(options.durationMilliseconds) > 0
            ? Number(options.durationMilliseconds)
            : config.durationMilliseconds,
          easing: "cubic-bezier(0.19, 1.00, 0.22, 1.00)",
          fill: "both"
        });
      } catch (_) {
        cleanupReadexDisclosureAnimationStyles(element);
        finishReadexDisclosureClose(element, opening, options, scrollAnchor);
        return;
      }

      element.__chatTranscriptReadexDisclosureAnimation = animation;
      element.__chatTranscriptReadexDisclosureAnimationOpening = opening;
      element.__chatTranscriptReadexDisclosureCloseAction = opening ? "" : readexDisclosureCloseAction(options);
      element.__chatTranscriptReadexDisclosureScrollAnchor = scrollAnchor;
      element.__chatTranscriptReadexDisclosureStopScrollTracking = startReadexDisclosureScrollAnchorTracking(
        element,
        scrollAnchor
      );
      animation.onfinish = () => {
        if (element.__chatTranscriptReadexDisclosureAnimation !== animation) {
          return;
        }
        removeReadexDisclosureAnimationEffect(animation);
        element.__chatTranscriptReadexDisclosureAnimation = null;
        const resolvedScrollAnchor = element.__chatTranscriptReadexDisclosureScrollAnchor || null;
        stopReadexDisclosureScrollAnchorTracking(element);
        cleanupReadexDisclosureAnimationStyles(element);
        finishReadexDisclosureClose(element, opening, options, resolvedScrollAnchor);
      };
      animation.oncancel = () => {
        if (element.__chatTranscriptReadexDisclosureAnimation === animation) {
          element.__chatTranscriptReadexDisclosureAnimation = null;
          stopReadexDisclosureScrollAnchorTracking(element);
          cleanupReadexDisclosureAnimationStyles(element);
        }
      };
    }

    function readexDisclosureVisibleHeight(element) {
      if (!(element instanceof HTMLElement)) {
        return 0;
      }
      const rect = element.getBoundingClientRect();
      const rectHeight = Number(rect?.height);
      if (Number.isFinite(rectHeight) && rectHeight > 0) {
        return rectHeight;
      }
      const clientHeight = Number(element.clientHeight);
      return Number.isFinite(clientHeight) ? Math.max(0, clientHeight) : 0;
    }

    function retargetReadexDisclosureOpeningAnimation(element, options = {}) {
      if (!(element instanceof HTMLElement)) {
        return false;
      }
      const animation = element.__chatTranscriptReadexDisclosureAnimation;
      if (!animation || element.__chatTranscriptReadexDisclosureAnimationOpening !== true) {
        return false;
      }
      const currentHeight = readexDisclosureVisibleHeight(element);
      const currentOpacity = Number(window.getComputedStyle(element).opacity);
      const nextHeight = Math.max(0, Number(element.scrollHeight) || 0);
      if (nextHeight <= currentHeight + 2) {
        return false;
      }

      const timing = animation.effect && typeof animation.effect.getTiming === "function"
        ? animation.effect.getTiming()
        : null;
      const configuredDuration = Number(timing?.duration);
      const elapsed = Number(animation.currentTime);
      const remainingDuration = Number.isFinite(configuredDuration) && Number.isFinite(elapsed)
        ? Math.max(configuredDuration - elapsed, 0)
        : 0;
      const config = readexDisclosureAnimationConfig();
      const durationMilliseconds = Number(options.durationMilliseconds) > 0
        ? Number(options.durationMilliseconds)
        : Math.min(
            config.durationMilliseconds,
            Math.max(180, remainingDuration || Math.round(config.durationMilliseconds * 0.5))
          );
      animateReadexDisclosureElement(element, true, {
        ...options,
        startHeight: currentHeight,
        startOpacity: Number.isFinite(currentOpacity) ? currentOpacity : 1,
        durationMilliseconds
      });
      return true;
    }

    function renderSequentialShimmerText(element, text) {
      if (!element) {
        return;
      }

      const displayText = trimmed(text);
      if (!displayText) {
        stopCodexShimmerText(element);
        clearReadexShimmerPresentation(element);
        element.textContent = "";
        return;
      }

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

    function clearSequentialShimmerText(element, text) {
      if (!element) {
        return;
      }
      stopCodexShimmerText(element);
      clearReadexShimmerPresentation(element);
      element.textContent = text;
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
      delete element.dataset.subagentTitleName;
      delete element.dataset.subagentTitleColor;
      delete element.dataset.receiverThreadId;
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

    function ensureReadexContextStatusIcon(notice) {
      if (!notice) {
        return;
      }
      const label = notice.querySelector(".message-branch-notice-label");
      if (!label) {
        return;
      }
      const iconParent = label.parentElement;
      if (!iconParent || !notice.contains(iconParent)) {
        return;
      }

      let icon = notice.querySelector(".message-branch-notice-icon");
      if (!icon) {
        icon = document.createElement("span");
        icon.className = "message-branch-notice-icon";
        icon.setAttribute("aria-hidden", "true");
      }
      if (icon.parentElement !== iconParent || icon.nextSibling !== label) {
        iconParent.insertBefore(icon, label);
      }
      if (!icon.firstElementChild) {
        icon.innerHTML = makeIcon("square.stack.3d.up");
      }
    }

    function removeReadexContextStatusIcon(notice) {
      const icon = notice?.querySelector(".message-branch-notice-icon");
      if (icon) {
        icon.remove();
      }
    }

    function applyReadexContextStatusPresentation(notice, block) {
      if (!notice) {
        return null;
      }
      notice.classList.add("readex-context-status");
      const text = trimmed(blockText(block));
      const isProcessing = text === "正在自动压缩上下文" || blockIsLive(block);
      notice.classList.toggle("readex-context-status-processing", isProcessing);
      notice.classList.toggle("readex-context-status-completed", !isProcessing);
      if (isProcessing) {
        removeReadexContextStatusIcon(notice);
      } else {
        ensureReadexContextStatusIcon(notice);
      }
      const label = notice.querySelector(".message-branch-notice-label");
      if (isProcessing) {
        renderSequentialShimmerText(label, text);
      } else {
        clearSequentialShimmerText(label, text);
      }
      return notice;
    }

    function renderReadexContextStatusBlock(block, renderer, message, blockKey) {
      const text = trimmed(blockText(block));
      return applyReadexContextStatusPresentation(renderBranchNotice(blockKey, text), block);
    }

    function updateReadexContextStatusBlockElement(element, block, renderer, message, blockKey) {
      const text = trimmed(blockText(block));
      return applyReadexContextStatusPresentation(patchBranchNotice(element, blockKey, text), block);
    }

    function setThinkingTitleText(element, titleText) {
      const supportLine = directChildByClass(element, "support-line");
      const title = supportLine ? supportLine.querySelector(".support-line-title") : null;
      if (title?.classList?.contains("readex-tool-shimmer")) {
        renderSequentialShimmerText(title, titleText);
      } else {
        setSupportLineTitleText(element, titleText);
      }
    }

    function clearThinkingTimer(element) {
      if (!element || !element.__chatTranscriptThinkingTimer) {
        return;
      }
      window.clearInterval(element.__chatTranscriptThinkingTimer);
      element.__chatTranscriptThinkingTimer = null;
    }

    function liveThinkingStartedAt(element) {
      const startedAt = Number(element.__chatTranscriptThinkingStartedAt);
      if (Number.isFinite(startedAt) && startedAt > 0) {
        return startedAt;
      }
      const now = Date.now();
      element.__chatTranscriptThinkingStartedAt = now;
      return now;
    }

    function liveThinkingTitleText(element) {
      const milliseconds = Math.max(100, Date.now() - liveThinkingStartedAt(element));
      return `思考中（用时 ${formatThinkingSeconds(milliseconds)} 秒）`;
    }

    function syncThinkingTimer(element, isLiveThinking) {
      if (!isLiveThinking) {
        clearThinkingTimer(element);
        element.__chatTranscriptThinkingStartedAt = null;
        return;
      }

      const tick = () => {
        if (!element.isConnected) {
          clearThinkingTimer(element);
          return;
        }
        setThinkingTitleText(element, liveThinkingTitleText(element));
      };

      tick();
      if (!element.__chatTranscriptThinkingTimer) {
        element.__chatTranscriptThinkingTimer = window.setInterval(tick, 100);
      }
    }

    function updateThinkingBlockElement(element, block, renderer, message, blockKey) {
      const isStreaming = messageIsStreaming(message) || blockIsLive(block);
      const isLiveThinking = isStreaming && !(block && block.durationMilliseconds != null);
      const text = blockText(block);
      const expanded = isThinkingBlockExpanded(block, message, blockKey);
      element.__chatTranscriptThinkingBlock = block;
      element.__chatTranscriptThinkingMessage = message;

      let content = directChildByClass(element, "thinking-content");
      element.__chatTranscriptThinkingWasLive = isStreaming;
      element.className = expanded ? "thinking-block expanded" : "thinking-block";

      let titleText = "已深度思考";
      if (block && block.durationMilliseconds != null) {
        titleText = `已深度思考（用时 ${formatThinkingSeconds(block.durationMilliseconds)} 秒）`;
      } else if (isLiveThinking) {
        titleText = "思考中";
      }

      const supportLine = updateSupportLine(element, "lightbulb", titleText, expanded ? "chevron-down" : "chevron-right");
      const title = supportLine ? supportLine.querySelector(".support-line-title") : null;
      if (title) {
        title.classList.add("small");
        if (isLiveThinking) {
          renderSequentialShimmerText(title, titleText);
        } else {
          clearSequentialShimmerText(title, titleText);
        }
      }
      syncThinkingTimer(element, isLiveThinking);
      configurePressableSupportLine(supportLine, {
        interactive: Boolean(trimmed(text)),
        expanded
      });

      if (expanded) {
        if (!content) {
          content = document.createElement("div");
          content.className = "thinking-content";
          element.appendChild(content);
        }
        cancelReadexDisclosureAnimation(content);
        renderMarkdownIntoElement(renderer, content, text, markdownRenderOptionsForSupport(message, blockKey));
      } else {
        removeDirectChild(element, content);
      }
    }

    function installThinkingBlockInteractions(element) {
      if (!element || element.__chatTranscriptThinkingInteractionsInstalled) {
        return;
      }
      element.__chatTranscriptThinkingInteractionsInstalled = true;

      const toggle = (event) => {
        const target = event?.target;
        if (!(target instanceof Element) || !target.closest(".support-line.is-interactive")) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();

        const message = element.__chatTranscriptThinkingMessage;
        const block = element.__chatTranscriptThinkingBlock;
        const blockKey = trimmed(element.dataset.blockKey);
        if (!message || !block || !blockKey) {
          return;
        }

        const nextExpanded = !isThinkingBlockExpanded(block, message, blockKey);
        setThinkingBlockExpanded(message, blockKey, nextExpanded);
        updateThinkingBlockElement(element, block, resolveMarkdownRenderer(), message, blockKey);
      };

      element.addEventListener("click", toggle);
      element.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        toggle(event);
      });

      const closePopover = () => {
        const message = element.__chatTranscriptReasoningActivityMessage;
        const block = element.__chatTranscriptReasoningActivityBlock;
        const blockKey = trimmed(element.dataset.blockKey);
        if (!message || !block || !blockKey || !isThinkingBlockExpanded(block, message, blockKey)) {
          return;
        }
        setThinkingBlockExpanded(message, blockKey, false);
        updateReasoningActivityBlockElement(element, block, resolveMarkdownRenderer(), message, blockKey);
      };

      const handleDocumentPointerDown = (event) => {
        if (!element.isConnected) {
          document.removeEventListener("mousedown", handleDocumentPointerDown);
          document.removeEventListener("keydown", handleDocumentKeyDown);
          return;
        }
        const target = event?.target;
        if (target instanceof Node && element.contains(target)) {
          return;
        }
        closePopover();
      };

      const handleDocumentKeyDown = (event) => {
        if (event.key !== "Escape") {
          return;
        }
        if (!element.isConnected) {
          document.removeEventListener("mousedown", handleDocumentPointerDown);
          document.removeEventListener("keydown", handleDocumentKeyDown);
          return;
        }
        closePopover();
      };

      document.addEventListener("mousedown", handleDocumentPointerDown);
      document.addEventListener("keydown", handleDocumentKeyDown);
    }

    function renderThinkingBlock(block, renderer, message, blockKey) {
      const container = document.createElement("div");
      container.dataset.blockKey = blockKey;
      container.dataset.blockType = "thinking";
      installThinkingBlockInteractions(container);
      updateThinkingBlockElement(container, block, renderer, message, blockKey);
      return container;
    }

    function reasoningSummaryParts(block) {
      const parts = Array.isArray(block?.summaryParts)
        ? block.summaryParts.map((part) => trimmed(part)).filter(Boolean)
        : [];
      const fallbackText = trimmed(blockText(block));
      if (parts.length > 0) {
        return parts;
      }
      return fallbackText ? [fallbackText] : [];
    }

    function reasoningSummaryMarkdown(parts) {
      return parts.map((part, index) => {
        const normalized = String(part || "")
          .replace(/\r\n/g, "\n")
          .replace(/\r/g, "\n")
          .split("\n")
          .map((line, lineIndex) => (lineIndex === 0 ? line : `   ${line}`))
          .join("\n");
        return `${index + 1}. ${normalized}`;
      }).join("\n\n");
    }

    function reasoningSummaryTitle(block, parts, isStreaming) {
      const countText = `${parts.length} 条`;
      if (block && block.durationMilliseconds != null) {
        return `推理摘要 · ${countText} · 用时 ${formatThinkingSeconds(block.durationMilliseconds)} 秒`;
      }
      return isStreaming ? `推理摘要 · ${countText} · 正在思考` : `推理摘要 · ${countText}`;
    }

    function updateReasoningSummaryBlockElement(element, block, renderer, message, blockKey) {
      const isStreaming = messageIsStreaming(message) || blockIsLive(block);
      const parts = reasoningSummaryParts(block);
      const expanded = isThinkingBlockExpanded(block, message, blockKey);
      element.__chatTranscriptReasoningSummaryBlock = block;
      element.__chatTranscriptReasoningSummaryMessage = message;

      let content = directChildByClass(element, "reasoning-summary-content");
      element.__chatTranscriptReasoningSummaryWasLive = isStreaming;
      element.className = expanded ? "reasoning-summary-block expanded" : "reasoning-summary-block";

      const supportLine = updateSupportLine(
        element,
        "sparkles",
        reasoningSummaryTitle(block, parts, isStreaming),
        expanded ? "chevron-down" : "chevron-right"
      );
      configurePressableSupportLine(supportLine, {
        interactive: parts.length > 0,
        expanded
      });

      if (expanded && parts.length > 0) {
        if (!content) {
          content = document.createElement("div");
          content.className = "reasoning-summary-content thinking-content";
          element.appendChild(content);
        }
        cancelReadexDisclosureAnimation(content);
        renderMarkdownIntoElement(renderer, content, reasoningSummaryMarkdown(parts), markdownRenderOptionsForSupport(message, blockKey));
      } else {
        removeDirectChild(element, content);
      }
    }

    function installReasoningSummaryBlockInteractions(element) {
      if (!element || element.__chatTranscriptReasoningSummaryInteractionsInstalled) {
        return;
      }
      element.__chatTranscriptReasoningSummaryInteractionsInstalled = true;

      const toggle = (event) => {
        const target = event?.target;
        if (!(target instanceof Element) || !target.closest(".support-line.is-interactive")) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();

        const message = element.__chatTranscriptReasoningSummaryMessage;
        const block = element.__chatTranscriptReasoningSummaryBlock;
        const blockKey = trimmed(element.dataset.blockKey);
        if (!message || !block || !blockKey) {
          return;
        }

        const nextExpanded = !isThinkingBlockExpanded(block, message, blockKey);
        setThinkingBlockExpanded(message, blockKey, nextExpanded);
        updateReasoningSummaryBlockElement(element, block, resolveMarkdownRenderer(), message, blockKey);
      };

      element.addEventListener("click", toggle);
      element.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        toggle(event);
      });
    }

    function renderReasoningSummaryBlock(block, renderer, message, blockKey) {
      const container = document.createElement("div");
      container.dataset.blockKey = blockKey;
      container.dataset.blockType = "reasoning_summary";
      installReasoningSummaryBlockInteractions(container);
      updateReasoningSummaryBlockElement(container, block, renderer, message, blockKey);
      return container;
    }

    function normalizedStringArray(values) {
      if (!Array.isArray(values)) {
        return [];
      }
      const seen = new Set();
      return values.map((value) => trimmed(value)).filter((value) => {
        if (!value || seen.has(value)) {
          return false;
        }
        seen.add(value);
        return true;
      });
    }

    function appendSearchQueryChips(container, queries) {
      const normalizedQueries = normalizedStringArray(queries);
      if (!normalizedQueries.length) {
        return;
      }

      const chips = document.createElement("div");
      chips.className = "search-query-chips";
      normalizedQueries.forEach((query) => {
        const chip = document.createElement("span");
        chip.className = "search-query-chip";
        appendIcon(chip, "magnifyingglass");
        const label = document.createElement("span");
        label.textContent = query;
        chip.appendChild(label);
        chips.appendChild(chip);
      });
      container.appendChild(chips);
    }

    function buildReferenceChip(references, message, blockKey) {
      const safeReferences = Array.isArray(references) ? references : [];
      if (!safeReferences.length) {
        return null;
      }

      const previewKey = citationPreviewStateKey(message, blockKey);
      const isPreviewActive = trimmed(transcriptUIState().activeCitationPreviewBlockKey) === previewKey;
      const chip = document.createElement("button");
      chip.type = "button";
      chip.className = "reference-chip";
      chip.dataset.citationPreviewKey = previewKey;
      chip.classList.toggle("is-active", isPreviewActive);
      chip.setAttribute("aria-haspopup", "dialog");
      chip.setAttribute("aria-pressed", isPreviewActive ? "true" : "false");
      chip.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        toggleCitationPreview(previewKey);
      });

      const avatars = document.createElement("div");
      avatars.className = "reference-avatars";
      safeReferences.slice(0, 3).forEach((reference) => {
        const avatar = document.createElement("span");
        avatar.className = "reference-avatar";
        populateReferenceAvatar(avatar, reference);
        avatars.appendChild(avatar);
      });
      chip.appendChild(avatars);

      const label = document.createElement("span");
      label.textContent = `${safeReferences.length} 个引用内容`;
      chip.appendChild(label);

      return chip;
    }

    function searchBlockStatusIsLive(status) {
      const value = normalizedReadexStatus(status);
      return value === "pending" || value === "processing" || value === "streaming" || value === "searching";
    }

    function renderSearchResultsBlock(references, message, blockKey, queries = [], status = "success", actions = []) {
      const safeReferences = Array.isArray(references) ? references : [];
      const normalizedQueries = normalizedStringArray(queries);
      const safeActions = Array.isArray(actions) ? actions : [];
      const isLive = searchBlockStatusIsLive(status);
      const item = {
        id: `search_results:${trimmed(blockKey)}`,
        type: "web-search",
        text: "",
        query: normalizedQueries[0] || "",
        action: safeActions[0] || null,
        completed: !isLive,
        detailText: "",
        previewItems: [],
        childItems: [],
        toolName: "web_search",
        toolBatchId: "",
        status: isLive ? "processing" : "success",
        durationMilliseconds: 0,
        searchQueries: normalizedQueries,
        searchReferences: safeReferences,
        webSearchActions: safeActions,
        isWebSearchGroup: true
      };
      if (!readexWebSearchActivityShouldRender(item)) {
        return null;
      }
      item.text = readexWebSearchDisplaySummaryText(item);
      const container = buildReadexWebSearchActivityElement(item, null, "", {
        standalone: true,
        initialExpanded: safeActions.length > 0 || normalizedQueries.length > 0
      });
      container.classList.add("search-results-block");
      return container;
    }

    function readexSourcesSections(block) {
      return (Array.isArray(block?.sections) ? block.sections : [])
        .map((section) => ({
          ...section,
          title: trimmed(section?.title),
          type: trimmed(section?.type),
          items: Array.isArray(section?.items) ? section.items.filter(Boolean) : []
        }))
        .filter((section) => section.items.length > 0);
    }

    function readexSourcesSectionItemCount(section) {
      return Array.isArray(section?.items) ? section.items.length : 0;
    }

    function readexSourcesSummaryText(block) {
      const sections = readexSourcesSections(block);
      const details = sections.map((section) => {
        const count = readexSourcesSectionItemCount(section);
        if (section.type === "webSearch") {
          return `网页 ${count}`;
        }
        if (section.type === "readex") {
          return `资料 ${count}`;
        }
        return `${section.title || "来源"} ${count}`;
      });
      return details.length ? `来源 · ${details.join(" · ")}` : "来源";
    }

    function readexSourceReferenceSnippet(reference) {
      const content = String(reference?.content || "")
        .replace(/\r/g, " ")
        .replace(/\n/g, " ")
        .replace(/\t/g, " ")
        .trim();
      if (!content) {
        return "";
      }
      return content.length > 150 ? `${content.slice(0, 150)}…` : content;
    }

    function readexSourcePreviewTitle(preview) {
      return trimmed(preview?.title)
        || trimmed(preview?.fileName)
        || trimmed(preview?.documentName)
        || "资料来源";
    }

    function readexSourcePreviewMeta(preview, type) {
      const documentName = trimmed(preview?.documentName);
      const subtitle = trimmed(preview?.subtitle);
      const label = type === "pdf" ? "PDF 书页" : (type === "library" ? "知识库" : "资料");
      const parts = [label, documentName, subtitle].filter(Boolean);
      const seen = new Set();
      return parts.filter((part) => {
        if (seen.has(part)) {
          return false;
        }
        seen.add(part);
        return true;
      }).join(" · ");
    }

    function appendReadexSourcesSectionHeader(sectionElement, section) {
      const header = document.createElement("div");
      header.className = "readex-sources-section-header";

      appendIcon(header, section.type === "webSearch" ? "globe" : "doc");

      const label = document.createElement("span");
      label.className = "readex-sources-section-title";
      label.textContent = section.title || (section.type === "webSearch" ? "网页来源" : "资料来源");
      header.appendChild(label);

      const count = document.createElement("span");
      count.className = "readex-sources-section-count";
      count.textContent = String(readexSourcesSectionItemCount(section));
      header.appendChild(count);

      sectionElement.appendChild(header);
    }

    function appendReadexWebSourceItem(list, item) {
      const reference = item?.reference || {};
      const url = trimmed(reference?.url);
      const row = document.createElement(url ? "a" : "div");
      row.className = [
        "readex-source-item",
        url ? "is-link" : ""
      ].filter(Boolean).join(" ");
      if (url) {
        row.href = url;
        row.target = "_blank";
        row.rel = "noopener noreferrer";
      }

      const avatar = document.createElement("span");
      avatar.className = "readex-source-avatar reference-avatar";
      populateReferenceAvatar(avatar, reference);
      row.appendChild(avatar);

      const body = document.createElement("span");
      body.className = "readex-source-body";

      const title = document.createElement("span");
      title.className = "readex-source-title";
      title.textContent = displayTitleForReference(reference) || url || "网页来源";
      body.appendChild(title);

      const host = hostnameForReference(reference);
      if (host) {
        const meta = document.createElement("span");
        meta.className = "readex-source-meta";
        meta.textContent = host;
        body.appendChild(meta);
      }

      const snippetText = readexSourceReferenceSnippet(reference);
      if (snippetText) {
        const snippet = document.createElement("span");
        snippet.className = "readex-source-snippet";
        snippet.textContent = snippetText;
        body.appendChild(snippet);
      }

      row.appendChild(body);
      list.appendChild(row);
    }

    function appendReadexPreviewSourceItem(list, item) {
      const preview = item?.preview || {};
      const row = document.createElement("button");
      row.type = "button";
      row.className = "readex-source-item is-preview";

      const avatar = document.createElement("span");
      avatar.className = "readex-source-avatar readex-source-preview-avatar";
      avatar.innerHTML = makeIcon(item?.type === "library" ? "folder" : "doc");
      row.appendChild(avatar);

      const body = document.createElement("span");
      body.className = "readex-source-body";

      const title = document.createElement("span");
      title.className = "readex-source-title";
      title.textContent = readexSourcePreviewTitle(preview);
      body.appendChild(title);

      const metaText = readexSourcePreviewMeta(preview, item?.type);
      if (metaText) {
        const meta = document.createElement("span");
        meta.className = "readex-source-meta";
        meta.textContent = metaText;
        body.appendChild(meta);
      }

      row.appendChild(body);
      row.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        openReadexPreviewItem(preview);
      });
      list.appendChild(row);
    }

    function appendReadexSourcesSection(details, section) {
      const sectionElement = document.createElement("section");
      sectionElement.className = [
        "readex-sources-section",
        section.type === "webSearch" ? "is-web" : "is-readex"
      ].filter(Boolean).join(" ");
      appendReadexSourcesSectionHeader(sectionElement, section);

      const list = document.createElement("div");
      list.className = "readex-sources-list";
      section.items.forEach((item) => {
        if (section.type === "webSearch" || item?.type === "web") {
          appendReadexWebSourceItem(list, item);
        } else {
          appendReadexPreviewSourceItem(list, item);
        }
      });
      sectionElement.appendChild(list);
      details.appendChild(sectionElement);
    }

    function updateReadexSourcesBlockDetails(element, block) {
      const expanded = Boolean(element.__chatTranscriptReadexSourcesExpanded);
      const existing = directChildByClass(element, "readex-sources-details");
      if (!expanded) {
        if (existing) {
          animateReadexDisclosureElement(existing, false, { removeOnFinish: true, reserveLayout: true });
        }
        return;
      }

      const sections = readexSourcesSections(block);
      if (!sections.length) {
        removeDirectChild(element, existing);
        return;
      }

      const details = existing || document.createElement("div");
      if (existing) {
        cancelReadexDisclosureAnimation(existing);
      }
      details.className = "readex-sources-details";
      details.textContent = "";
      sections.forEach((section) => appendReadexSourcesSection(details, section));

      if (!existing) {
        element.appendChild(details);
        animateReadexDisclosureElement(details, true, { reserveLayout: true });
      }
    }

    function updateReadexSourcesBlockElement(element, block) {
      const sections = readexSourcesSections(block);
      element.className = "readex-sources-block";
      element.__chatTranscriptReadexSourcesBlock = block;
      if (!sections.length) {
        element.__chatTranscriptReadexSourcesExpanded = false;
      }

      const expanded = Boolean(element.__chatTranscriptReadexSourcesExpanded);
      const supportLine = updateSupportLine(
        element,
        "doc-on-doc",
        readexSourcesSummaryText(block),
        sections.length ? (expanded ? "chevron-down" : "chevron-right") : null
      );
      configurePressableSupportLine(supportLine, {
        interactive: sections.length > 0,
        expanded: sections.length > 0 ? expanded : undefined
      });
      updateReadexSourcesBlockDetails(element, block);
    }

    function installReadexSourcesBlockInteractions(element) {
      if (!element || element.__chatTranscriptReadexSourcesInteractionsInstalled) {
        return;
      }
      element.__chatTranscriptReadexSourcesInteractionsInstalled = true;

      const toggle = (event) => {
        const target = event?.target;
        if (!(target instanceof Element) || !target.closest(".support-line.is-interactive")) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();

        element.__chatTranscriptReadexSourcesExpanded = !element.__chatTranscriptReadexSourcesExpanded;
        updateReadexSourcesBlockElement(element, element.__chatTranscriptReadexSourcesBlock || {});
      };

      element.addEventListener("click", toggle);
      element.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        toggle(event);
      });
    }

    function renderReadexSourcesBlock(block) {
      const container = document.createElement("div");
      installReadexSourcesBlockInteractions(container);
      updateReadexSourcesBlockElement(container, block);
      return container;
    }

    function reasoningActivityItems(block) {
      return Array.isArray(block?.items) ? block.items : [];
    }

    function latestReasoningActivitySummary(block) {
      const items = reasoningActivityItems(block);
      for (let index = items.length - 1; index >= 0; index -= 1) {
        const item = items[index];
        if (item?.type === "summary" && meaningfulReasoningActivitySummaryText(item.text)) {
          return item;
        }
      }
      return null;
    }

    function meaningfulReasoningActivitySummaryText(text) {
      const value = trimmed(text);
      if (!value || /^[|▌█▋▊▉]+$/u.test(value) || [...value].length < 2) {
        return "";
      }
      return /[0-9A-Za-z\p{L}\p{N}\p{Ideographic}]/u.test(value) ? value : "";
    }

    function reasoningActivitySummaryTitle(item) {
      const ordinal = Number.isFinite(Number(item?.ordinal)) ? Number(item.ordinal) : 1;
      if (item && item.durationMilliseconds != null) {
        return `第 ${ordinal} 条 · 用时 ${formatThinkingSeconds(item.durationMilliseconds)} 秒`;
      }
      return `第 ${ordinal} 条`;
    }

    function thoughtDurationLabel(milliseconds) {
      const normalizedMilliseconds = Math.max(100, Number(milliseconds) || 0);
      return `${Math.max(1, Math.round(normalizedMilliseconds / 1000))}s`;
    }

    function reasoningActivityDurationMilliseconds(block) {
      const blockDuration = Number(block?.durationMilliseconds);
      if (Number.isFinite(blockDuration)) {
        return blockDuration;
      }
      const itemDurations = reasoningActivityItems(block)
        .map((item) => Number(item?.durationMilliseconds))
        .filter((duration) => Number.isFinite(duration) && duration > 0);
      if (!itemDurations.length) {
        return null;
      }
      return itemDurations.reduce((sum, duration) => sum + duration, 0);
    }

    function reasoningActivityStartedAtMilliseconds(block) {
      const startedAt = Number(block?.startedAtMilliseconds ?? block?.startedAtMs);
      return Number.isFinite(startedAt) && startedAt > 0 ? startedAt : null;
    }

    function reasoningActivityIsLive(block) {
      return reasoningActivityDurationMilliseconds(block) == null
        && reasoningActivityStartedAtMilliseconds(block) != null;
    }

    function reasoningActivityTitle(block, message) {
      const durationMilliseconds = reasoningActivityDurationMilliseconds(block);
      if (durationMilliseconds != null) {
        return `Thought for ${thoughtDurationLabel(durationMilliseconds)}`;
      }
      return reasoningActivityIsLive(block) ? liveReasoningActivityTitleText(block) : "Thought";
    }

    function reasoningActivityIsComplete(block, message) {
      return !reasoningActivityIsLive(block);
    }

    function clearReasoningActivityTimer(element) {
      if (!element || !element.__chatTranscriptReasoningActivityTimer) {
        return;
      }
      window.clearInterval(element.__chatTranscriptReasoningActivityTimer);
      element.__chatTranscriptReasoningActivityTimer = null;
    }

    function liveReasoningActivityTitleText(block) {
      const startedAt = reasoningActivityStartedAtMilliseconds(block);
      if (startedAt == null) {
        return reasoningActivityTitle(block);
      }
      const milliseconds = Math.max(100, Date.now() - startedAt);
      return `Thought for ${thoughtDurationLabel(milliseconds)}`;
    }

    function appendReasoningActivityMarker(row, markerKind, isLast) {
      const markerColumn = document.createElement("div");
      markerColumn.className = "reasoning-activity-marker-column";

      const marker = document.createElement("div");
      marker.className = markerKind === "search" ? "reasoning-activity-marker search" : "reasoning-activity-marker summary";
      if (markerKind === "search") {
        marker.innerHTML = makeIcon("globe");
      } else {
        const dot = document.createElement("span");
        dot.className = "reasoning-activity-dot";
        marker.appendChild(dot);
      }
      markerColumn.appendChild(marker);

      if (!isLast) {
        const line = document.createElement("div");
        line.className = "reasoning-activity-line";
        markerColumn.appendChild(line);
      }

      row.appendChild(markerColumn);
    }

    function appendReasoningActivitySummary(content, item, renderer, message) {
      const summaryText = meaningfulReasoningActivitySummaryText(item?.text);
      if (!summaryText) {
        return;
      }
      const summary = document.createElement("div");
      summary.className = "reasoning-activity-item reasoning-activity-summary";
      appendReasoningActivityMarker(summary, "summary", Boolean(item?.isLast));

      const bodyColumn = document.createElement("div");
      bodyColumn.className = "reasoning-activity-item-body";

      const body = document.createElement("div");
      body.className = "reasoning-activity-summary-content thinking-content";
      renderMarkdownIntoElement(renderer, body, summaryText, markdownRenderOptionsForSupport(message, item?.id || item?.sourceBlockId || item?.sourceBlockID));
      bodyColumn.appendChild(body);
      summary.appendChild(bodyColumn);
      content.appendChild(summary);
    }

    function appendReasoningActivitySearch(content, item, message, blockKey, itemIndex) {
      const safeReferences = Array.isArray(item?.searchReferences) ? item.searchReferences : [];
      const queries = normalizedStringArray(item?.searchQueries);
      if (!safeReferences.length && !queries.length) {
        return;
      }

      const search = document.createElement("div");
      search.className = "reasoning-activity-item reasoning-activity-search";
      appendReasoningActivityMarker(search, "search", Boolean(item?.isLast));

      const bodyColumn = document.createElement("div");
      bodyColumn.className = "reasoning-activity-item-body";

      const title = document.createElement("div");
      title.className = "reasoning-activity-item-title search";
      const label = document.createElement("span");
      const firstQuery = queries[0] || "";
      label.textContent = firstQuery ? `Searching for ${firstQuery}` : "Searching the web";
      title.appendChild(label);
      bodyColumn.appendChild(title);

      appendSearchQueryChips(bodyColumn, queries);
      const chip = buildReferenceChip(safeReferences, message, `${blockKey}:search:${itemIndex}`);
      if (chip) {
        bodyColumn.appendChild(chip);
      }
      search.appendChild(bodyColumn);
      content.appendChild(search);
    }

    function updateReasoningActivityBlockElement(element, block, renderer, message, blockKey) {
      element.className = "reasoning-activity-block";
      element.__chatTranscriptReasoningActivityBlock = block;
      element.__chatTranscriptReasoningActivityMessage = message;

      const supportLine = updateSupportLine(element, "", reasoningActivityTitle(block, message), "chevron-right");
      configurePressableSupportLine(supportLine, {
        interactive: reasoningActivityItems(block).length > 0,
        expanded: false
      });
      const isLive = !reasoningActivityIsComplete(block, message);
      syncReasoningActivityTimer(element, isLive, block, message, blockKey);
      postReasoningActivityPopoverUpdateAction(element, block, message, blockKey);
    }

    function viewportRectPayload(element) {
      const rect = element?.getBoundingClientRect?.();
      if (!rect) {
        return null;
      }
      return {
        x: rect.left,
        y: rect.top,
        width: rect.width,
        height: rect.height
      };
    }

    function reasoningActivityActionItems(block) {
      return reasoningActivityItems(block)
        .filter((item) => (item?.type === "summary" && meaningfulReasoningActivitySummaryText(item.text)) || item?.type === "search")
        .map((item) => ({
          type: item.type === "search" ? "search" : "summary",
          ordinal: Number.isFinite(Number(item.ordinal)) ? Number(item.ordinal) : null,
          text: item.type === "summary" ? meaningfulReasoningActivitySummaryText(item.text) : trimmed(item.text),
          durationMilliseconds: Number.isFinite(Number(item.durationMilliseconds)) ? Number(item.durationMilliseconds) : null,
          searchQueries: normalizedStringArray(item.searchQueries),
          searchReferences: Array.isArray(item.searchReferences) ? item.searchReferences : []
        }));
    }

    function reasoningActivityPopoverBridgeState() {
      const existing = window.__chatTranscriptReasoningActivityPopoverBridge;
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
        lastPostedAtByBlockKey: {},
        lastSignatureByBlockKey: {},
        pendingUpdateByBlockKey: {},
        pendingTimerByBlockKey: {}
      };
      window.__chatTranscriptReasoningActivityPopoverBridge = state;
      return state;
    }

    function isReasoningActivityPopoverSubscribed(blockKey) {
      return reasoningActivityPopoverBridgeState().activeBlockKey === trimmed(blockKey);
    }

    function reasoningActivityPopoverUpdatePayload(element, block, message, blockKey) {
      const items = reasoningActivityActionItems(block);
      if (!items.length) {
        return null;
      }
      return {
        action: "updateReasoningActivityPopover",
        blockKey,
        title: reasoningActivityIsComplete(block, message)
          ? reasoningActivityTitle(block, message)
          : liveReasoningActivityTitleText(block),
        isComplete: reasoningActivityIsComplete(block, message),
        durationMilliseconds: reasoningActivityDurationMilliseconds(block),
        items
      };
    }

    function reasoningActivityPopoverUpdateSignature(payload) {
      return JSON.stringify({
        title: payload.title,
        isComplete: payload.isComplete,
        durationMilliseconds: payload.durationMilliseconds,
        items: payload.items
      });
    }

    function flushPendingReasoningActivityPopoverUpdate(blockKey) {
      const state = reasoningActivityPopoverBridgeState();
      const pending = state.pendingUpdateByBlockKey?.[blockKey];
      if (!pending) {
        return;
      }
      delete state.pendingUpdateByBlockKey[blockKey];
      delete state.pendingTimerByBlockKey[blockKey];
      if (state.activeBlockKey !== blockKey) {
        return;
      }
      state.lastSignatureByBlockKey[blockKey] = pending.signature;
      state.lastPostedAtByBlockKey[blockKey] = Date.now();
      postMessageAction(pending.payload);
    }

    function postReasoningActivityPopoverAction(element, block, message, blockKey) {
      const supportLine = directChildByClass(element, "support-line") || element;
      const anchorRect = viewportRectPayload(supportLine);
      if (!anchorRect) {
        return;
      }
      postMessageAction({
        action: "toggleReasoningActivityPopover",
        blockKey,
        title: reasoningActivityIsComplete(block, message)
          ? reasoningActivityTitle(block, message)
          : liveReasoningActivityTitleText(block),
        isComplete: reasoningActivityIsComplete(block, message),
        durationMilliseconds: reasoningActivityDurationMilliseconds(block),
        items: reasoningActivityActionItems(block),
        anchorRect
      });
    }

    function postReasoningActivityPopoverUpdateAction(element, block, message, blockKey, options = {}) {
      const normalizedBlockKey = trimmed(blockKey);
      if (!normalizedBlockKey || !isReasoningActivityPopoverSubscribed(normalizedBlockKey)) {
        return;
      }
      const payload = reasoningActivityPopoverUpdatePayload(element, block, message, normalizedBlockKey);
      if (!payload) {
        return;
      }
      const state = reasoningActivityPopoverBridgeState();
      const signature = reasoningActivityPopoverUpdateSignature(payload);
      if (state.lastSignatureByBlockKey?.[normalizedBlockKey] === signature) {
        return;
      }

      const isImmediate = Boolean(options.immediate) || payload.isComplete;
      const minimumInterval = isImmediate ? 0 : 180;
      const now = Date.now();
      const lastPostedAt = Number(state.lastPostedAtByBlockKey?.[normalizedBlockKey]) || 0;
      const elapsed = now - lastPostedAt;
      if (elapsed >= minimumInterval) {
        if (state.pendingTimerByBlockKey?.[normalizedBlockKey]) {
          window.clearTimeout(state.pendingTimerByBlockKey[normalizedBlockKey]);
          delete state.pendingTimerByBlockKey[normalizedBlockKey];
          delete state.pendingUpdateByBlockKey[normalizedBlockKey];
        }
        state.lastSignatureByBlockKey[normalizedBlockKey] = signature;
        state.lastPostedAtByBlockKey[normalizedBlockKey] = now;
        postMessageAction(payload);
        return;
      }

      state.pendingUpdateByBlockKey[normalizedBlockKey] = { payload, signature };
      if (!state.pendingTimerByBlockKey[normalizedBlockKey]) {
        state.pendingTimerByBlockKey[normalizedBlockKey] = window.setTimeout(
          () => flushPendingReasoningActivityPopoverUpdate(normalizedBlockKey),
          Math.max(0, minimumInterval - elapsed)
        );
      }
    }

    function syncReasoningActivityTimer(element, isLive, block, message, blockKey) {
      if (!isLive) {
        clearReasoningActivityTimer(element);
        return;
      }

      const tick = () => {
        if (!element.isConnected) {
          clearReasoningActivityTimer(element);
          return;
        }
        setSupportLineTitleText(element, liveReasoningActivityTitleText(block));
        const now = Date.now();
        const lastPostedAt = Number(element.__chatTranscriptReasoningActivityPopoverPostedAt) || 0;
        if (now - lastPostedAt >= 1000) {
          element.__chatTranscriptReasoningActivityPopoverPostedAt = now;
          postReasoningActivityPopoverUpdateAction(element, block, message, blockKey);
        }
      };

      tick();
      if (!element.__chatTranscriptReasoningActivityTimer) {
        element.__chatTranscriptReasoningActivityTimer = window.setInterval(tick, 250);
      }
    }

    function installReasoningActivityBlockInteractions(element) {
      if (!element || element.__chatTranscriptReasoningActivityInteractionsInstalled) {
        return;
      }
      element.__chatTranscriptReasoningActivityInteractionsInstalled = true;

      const toggle = (event) => {
        const target = event?.target;
        if (!(target instanceof Element) || !target.closest(".support-line.is-interactive")) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();

        const message = element.__chatTranscriptReasoningActivityMessage;
        const block = element.__chatTranscriptReasoningActivityBlock;
        const blockKey = trimmed(element.dataset.blockKey);
        if (!message || !block || !blockKey) {
          return;
        }

        postReasoningActivityPopoverAction(element, block, message, blockKey);
      };

      element.addEventListener("click", toggle);
      element.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        toggle(event);
      });
    }

    function renderReasoningActivityBlock(block, renderer, message, blockKey) {
      const container = document.createElement("div");
      container.dataset.blockKey = blockKey;
      container.dataset.blockType = "reasoning_activity";
      installReasoningActivityBlockInteractions(container);
      updateReasoningActivityBlockElement(container, block, renderer, message, blockKey);
      return container;
    }

    function readexStatusAliasKey(value) {
      return trimmed(value).toLowerCase().replace(/[\s_-]+/g, "");
    }

    function normalizedReadexStatus(value) {
      const status = trimmed(value).toLowerCase();
      if (!status) {
        return "";
      }
      switch (readexStatusAliasKey(status)) {
        case "pending":
        case "processing":
        case "streaming":
        case "searching":
          return status;
        case "inprogress":
        case "running":
          return "processing";
        case "complete":
        case "completed":
        case "success":
        case "succeeded":
          return "success";
        case "failed":
        case "failure":
        case "error":
          return "failed";
        case "paused":
        case "pause":
          return "paused";
        case "interrupted":
        case "cancelled":
        case "canceled":
        case "stopped":
          return "interrupted";
        default:
          return "";
      }
    }

    function readexDurationMilliseconds(source) {
      const duration = Number(source?.durationMilliseconds);
      if (Number.isFinite(duration)) {
        return duration;
      }
      const codexDuration = Number(source?.durationMs);
      return Number.isFinite(codexDuration) ? codexDuration : null;
    }

    function readexPreviewItems(value) {
      if (!Array.isArray(value)) {
        return [];
      }
      return value.map((item) => {
        if (!item || typeof item !== "object") {
          return null;
        }
        const title = trimmed(item.title);
        if (!title) {
          return null;
        }
        const kind = trimmed(item.kind) || (trimmed(item.filePath) ? "file" : "markdown");
        const payload = item.payload && typeof item.payload === "object" ? item.payload : null;
        return {
          id: trimmed(item.id),
          kind,
          title,
          subtitle: trimmed(item.subtitle),
          documentName: trimmed(item.documentName),
          markdown: typeof item.markdown === "string" ? item.markdown : "",
          filePath: trimmed(item.filePath),
          fileName: trimmed(item.fileName),
          mimeType: trimmed(item.mimeType),
          attachmentKind: trimmed(item.attachmentKind),
          payload
        };
      }).filter((item) => {
        if (!item) {
          return false;
        }
        if (item.kind === "file" || item.kind === "video_frame") {
          return Boolean(item.filePath);
        }
        if (readexPreviewIsLibraryTree(item)) {
          return Boolean(item.payload || trimmed(item.markdown));
        }
        if (readexPreviewIsApplyPatchDiff(item)) {
          return Boolean(item.payload || trimmed(item.markdown));
        }
        return Boolean(trimmed(item.markdown));
      });
    }

    function readexKnowledgeMapDocumentPreviewItems(preview) {
      const markdown = typeof preview?.markdown === "string" ? preview.markdown : "";
      if (!markdown.includes("## 《")) {
        return [];
      }

      const matches = [];
      const pattern = /^##\s+《([^》]+)》\s*$/gmu;
      let match = pattern.exec(markdown);
      while (match) {
        matches.push({
          index: match.index,
          documentName: trimmed(match[1])
        });
        match = pattern.exec(markdown);
      }
      if (matches.length <= 1) {
        return [];
      }

      return matches.map((heading, index) => {
        const nextHeading = matches[index + 1];
        const section = markdown
          .slice(heading.index, nextHeading ? nextHeading.index : markdown.length)
          .trim();
        if (!section || !heading.documentName) {
          return null;
        }
        const syntheticID = [
          trimmed(preview?.id),
          "knowledge-map-document",
          String(index),
          heading.documentName
        ].filter(Boolean).join("\u{1f}");
        return {
          ...preview,
          id: syntheticID,
          title: `《${heading.documentName}》的知识地图结构`,
          documentName: heading.documentName,
          markdown: `# 知识地图结构\n\n${section}\n`
        };
      }).filter(Boolean);
    }

    function expandedReadexKnowledgeMapPreviewItems(text, previewItems) {
      if (readexToolCategory(text) !== "knowledgeMap" || previewItems.length !== 1) {
        return previewItems;
      }
      const preview = previewItems[0];
      if (trimmed(preview?.kind) !== "markdown") {
        return previewItems;
      }
      const documentPreviews = readexKnowledgeMapDocumentPreviewItems(preview);
      return documentPreviews.length > 1 ? documentPreviews : previewItems;
    }

    function openReadexPreviewItem(item) {
      if (!item) {
        return;
      }
      if (readexPreviewLooksLikeApplyPatch(item)) {
        return;
      }
      postMessageAction({
        action: "openReadexSupportPreview",
        preview: item
      });
    }

    function readexExtractedPDFAccentColor(seed) {
      return readexAccentColor(seed);
    }

    function readexApplyPatchAccentColorIsExcluded(color) {
      const normalizedColor = trimmed(color).toLowerCase();
      return normalizedColor === "#20c997"
        || normalizedColor === "#35c759"
        || normalizedColor === "#2dd4bf"
        || normalizedColor === "#ff4d7d"
        || normalizedColor === "#ff6b5f";
    }

    function readexApplyPatchAccentColor(seed) {
      const baseSeed = trimmed(seed) || "apply_patch_diff";
      for (let attempt = 0; attempt < 24; attempt += 1) {
        const candidate = readexAccentColor(attempt === 0 ? baseSeed : `${baseSeed}|${attempt}`);
        if (candidate && !readexApplyPatchAccentColorIsExcluded(candidate)) {
          return candidate;
        }
      }
      return "#2F8CFF";
    }

    function readexPreviewContentAccentKindForItem(item) {
      if (readexToolItemUsesExtractedPagePreviewPresentation(item)) {
        return "extracted_pdf";
      }
      if (readexToolItemUsesVideoFramePreviewPresentation(item)) {
        return "video_frame";
      }
      if (readexToolItemHasApplyPatchDiffPreview(item)) {
        return "apply_patch_diff";
      }
      return "";
    }

    function readexPreviewContentAccentKindForBlock(block) {
      for (const item of readexToolItems(block)) {
        const itemKind = readexPreviewContentAccentKindForItem(item);
        if (itemKind) {
          return itemKind;
        }
        for (const childItem of readexToolItemChildItems(item)) {
          const childKind = readexPreviewContentAccentKindForItem(childItem);
          if (childKind) {
            return childKind;
          }
        }
      }
      return "";
    }

    function readexPreviewContentAccentTurnSeed(message) {
      const readexTurnID = trimmed(message?.readexTurnID || message?.readexTurnId);
      if (readexTurnID) {
        return readexTurnID;
      }

      const patchKey = trimmed(message?.patchKey || message?.patch_key);
      const readexAssistantTurnPrefix = "readex-assistant-turn:";
      if (patchKey.startsWith(readexAssistantTurnPrefix)) {
        return trimmed(patchKey.slice(readexAssistantTurnPrefix.length));
      }

      return "";
    }

    function readexPreviewContentAccentBaseSeed(block, message, blockKey) {
      return readexPreviewContentAccentTurnSeed(message)
        || trimmed(message?.readexCodexTurnID || message?.readexCodexTurnId)
        || trimmed(block?.readexTurnID || block?.readexTurnId || block?.turnID || block?.turnId)
        || trimmed(block?.readexTurnStartedAtMilliseconds || block?.turnStartedAtMilliseconds)
        || trimmed(message?.id)
        || trimmed(block?.messageID || block?.messageId)
        || trimmed(block?.sourceBlockID || block?.sourceBlockId)
        || trimmed(block?.id)
        || trimmed(blockKey);
    }

    function readexPreviewContentAccentContext(block, message, blockKey) {
      if (!readexBlockHasPreviewContentAccentPresentation(block)) {
        return null;
      }
      const baseSeed = readexPreviewContentAccentBaseSeed(block, message, blockKey);
      const primaryKind = readexPreviewContentAccentKindForBlock(block);
      if (!baseSeed || !primaryKind) {
        return null;
      }
      return { baseSeed, primaryKind };
    }

    function readexPreviewContentAccentColorFromContext(context, kind) {
      const baseSeed = trimmed(context?.baseSeed);
      const contentKind = trimmed(kind);
      if (!baseSeed || !contentKind) {
        return "";
      }
      if (contentKind === "apply_patch_diff") {
        return readexApplyPatchAccentColor(`${baseSeed}|${contentKind}`);
      }
      return readexExtractedPDFAccentColor(`${baseSeed}|${contentKind}`);
    }

    function readexPreviewContentAccentPrimaryColor(context) {
      return readexPreviewContentAccentColorFromContext(context, context?.primaryKind);
    }

    function readexPreviewContentAccentSourceContext(source) {
      if (source && typeof source === "object") {
        return source;
      }
      const baseColor = trimmed(source);
      return baseColor ? { baseSeed: baseColor, primaryKind: "legacy_preview_content" } : null;
    }

    function readexBlockHasExtractedPagePreviewPresentation(block) {
      return readexToolItems(block).some((item) => {
        if (readexToolItemUsesExtractedPagePreviewPresentation(item)) {
          return true;
        }
        return readexToolItemChildItems(item).some(readexToolItemUsesExtractedPagePreviewPresentation);
      });
    }

    function readexBlockHasPreviewContentAccentPresentation(block) {
      return readexToolItems(block).some((item) => {
        if (readexToolItemUsesPreviewContentAccentPresentation(item)) {
          return true;
        }
        return readexToolItemChildItems(item).some(readexToolItemUsesPreviewContentAccentPresentation);
      });
    }

    function configureReadexExtractedPDFAccent(element, block, message, blockKey) {
      const accentContext = readexPreviewContentAccentContext(block, message, blockKey);
      const accentColor = readexPreviewContentAccentPrimaryColor(accentContext);
      if (!element || !accentColor) {
        element?.style?.removeProperty("--readex-extracted-pdf-accent");
        return accentContext;
      }
      element.style.setProperty("--readex-extracted-pdf-accent", accentColor);
      return accentContext;
    }

    function applyReadexExtractedPDFAccentVariable(element, accentColor) {
      if (!element) {
        return;
      }
      const color = trimmed(accentColor);
      if (color) {
        element.style.setProperty("--readex-extracted-pdf-accent", color);
      } else {
        element.style.removeProperty("--readex-extracted-pdf-accent");
      }
    }

    function applyReadexExtractedPDFAccent(element, accentColor) {
      if (!element) {
        return;
      }
      const color = trimmed(accentColor);
      if (color) {
        element.style.color = color;
      } else {
        element.style.removeProperty("color");
      }
    }

    function readexFirstExtractedPageLabel(preview) {
      const payloadLabels = readexExtractedPDFRangeLabelsFromPayload(preview);
      const label = payloadLabels[0] || readexExtractedPageRangeLabel(preview);
      const first = trimmed(label)
        .split(/[，,、；;]+/u)
        .map((part) => trimmed(part))
        .find(Boolean) || trimmed(label);
      if (!first) {
        return "";
      }
      for (const separator of ["-", "–", "—", "~", "～", "至", "到"]) {
        if (!first.includes(separator)) {
          continue;
        }
        const head = trimmed(first.split(separator)[0]);
        return head || first;
      }
      return first;
    }

    function readexSupportExplicitReferenceURLFromValue(value) {
      const rawValue = trimmed(value);
      if (!rawValue) {
        return null;
      }
      try {
        return new URL(rawValue);
      } catch (_) {
        return null;
      }
    }

    function readexSupportMarkdownDestinationFromValue(value) {
      const rawValue = trimmed(value);
      if (!rawValue) {
        return "";
      }
      if (readexSupportExplicitReferenceURLFromValue(rawValue)) {
        return rawValue;
      }
      const openIndex = rawValue.indexOf("](");
      if (openIndex < 0 || !rawValue.endsWith(")")) {
        return "";
      }
      return trimmed(rawValue.slice(openIndex + 2, -1));
    }

    function readexSupportPositiveIntegerFromValue(value) {
      const number = Number.parseInt(trimmed(value), 10);
      return Number.isFinite(number) && number > 0 ? number : null;
    }

    function readexSupportVideoTimeSecondsFromValue(value) {
      const rawValue = trimmed(value).replace(",", ".");
      if (!rawValue) {
        return null;
      }
      const numericSeconds = Number(rawValue);
      if (Number.isFinite(numericSeconds) && numericSeconds >= 0) {
        return numericSeconds;
      }
      const parts = rawValue.split(":").map((part) => Number(trimmed(part)));
      if (parts.length !== 2 && parts.length !== 3) {
        return null;
      }
      if (parts.some((part) => !Number.isFinite(part) || part < 0)) {
        return null;
      }
      if (parts.length === 2) {
        return (parts[0] * 60) + parts[1];
      }
      return (parts[0] * 3600) + (parts[1] * 60) + parts[2];
    }

    function readexSupportContentReferenceFromHref(href, label = "") {
      const rawHref = trimmed(href);
      const url = readexSupportExplicitReferenceURLFromValue(rawHref);
      if (!url || url.protocol !== "readex:") {
        return null;
      }
      const host = trimmed(url.hostname).toLowerCase();
      const isPageURL = ["page", "page-ref", "open-page"].includes(host);
      const isVideoURL = ["video-time", "video-timestamp", "open-video-time"].includes(host);
      const isContentURL = ["content", "file", "open", "reference", "content-reference"].includes(host);
      if (!isPageURL && !isVideoURL && !isContentURL) {
        return null;
      }
      const contentID = trimmed(
        url.searchParams.get("content_id")
          || url.searchParams.get("contentID")
          || url.searchParams.get("content")
      );
      const documentID = trimmed(
        url.searchParams.get("document_id")
          || url.searchParams.get("documentID")
          || url.searchParams.get("document")
      );
      const path = trimmed(
        url.searchParams.get("path")
          || url.searchParams.get("file_path")
          || url.searchParams.get("filePath")
      );
      const pageNumber = readexSupportPositiveIntegerFromValue(
        url.searchParams.get("page_number")
          || url.searchParams.get("pageNumber")
          || url.searchParams.get("page")
      );
      const pageLabel = trimmed(
        url.searchParams.get("page_label")
          || url.searchParams.get("pageLabel")
          || url.searchParams.get("label")
          || (isPageURL ? label : "")
      );
      const startSeconds = readexSupportVideoTimeSecondsFromValue(
        url.searchParams.get("start")
          || url.searchParams.get("start_seconds")
          || url.searchParams.get("startSeconds")
          || url.searchParams.get("time")
          || url.searchParams.get("timestamp")
      );
      const endSeconds = readexSupportVideoTimeSecondsFromValue(
        url.searchParams.get("end")
          || url.searchParams.get("end_seconds")
          || url.searchParams.get("endSeconds")
      );
      const payload = {
        action: "openReadexContentReference",
        contentID: contentID || documentID || undefined,
        documentID: documentID || undefined,
        path: path || undefined,
        pageNumber: pageNumber || undefined,
        pageLabel: pageLabel || undefined,
        startSeconds: startSeconds === null ? undefined : startSeconds,
        endSeconds: endSeconds === null ? undefined : endSeconds,
        url: rawHref
      };
      if (!payload.contentID && !payload.documentID && !payload.path) {
        return null;
      }
      if (isPageURL && !payload.pageNumber && !payload.pageLabel) {
        return null;
      }
      if (isVideoURL && payload.startSeconds === undefined) {
        return null;
      }
      return payload;
    }

    function readexSupportContentReferenceFromMarkdownLink(value, label = "") {
      const destination = readexSupportMarkdownDestinationFromValue(value);
      return destination ? readexSupportContentReferenceFromHref(destination, label) : null;
    }

    function readexSupportFirstValue(object, keys = []) {
      if (!object || typeof object !== "object") {
        return undefined;
      }
      for (const key of keys) {
        if (object[key] !== undefined && object[key] !== null) {
          return object[key];
        }
      }
      return undefined;
    }

    function readexSupportFirstTrimmedValue(object, keys = []) {
      return trimmed(readexSupportFirstValue(object, keys));
    }

    function readexSupportContentReferencePayloadFromObject(reference, options = {}) {
      if (!reference || typeof reference !== "object") {
        return null;
      }
      const nestedReference = reference.readexContentReference || reference.readex_content_reference;
      if (nestedReference && typeof nestedReference === "object") {
        const nestedPayload = readexSupportContentReferencePayloadFromObject(nestedReference, options);
        if (nestedPayload) {
          return nestedPayload;
        }
      }

      const pageLabelFallback = trimmed(options?.pageLabelFallback);
      const markdownReference = readexSupportContentReferenceFromMarkdownLink(
        reference.markdownLink || reference.markdown_link,
        pageLabelFallback
      );
      if (markdownReference) {
        return markdownReference;
      }

      const rawURL = readexSupportFirstTrimmedValue(reference, ["url", "href", "uri"]);
      if (rawURL) {
        const hrefReference = readexSupportContentReferenceFromHref(rawURL, pageLabelFallback);
        if (hrefReference) {
          return hrefReference;
        }
        const explicitURL = readexSupportExplicitReferenceURLFromValue(rawURL);
        if (explicitURL && (explicitURL.protocol === "http:" || explicitURL.protocol === "https:")) {
          return {
            action: "openReadexContentReference",
            url: rawURL
          };
        }
      }

      const pathKeys = Array.isArray(options?.pathKeys)
        ? options.pathKeys
        : ["path", "filePath", "file_path", "sourcePath", "source_path"];
      const pageNumberKeys = Array.isArray(options?.pageNumberKeys)
        ? options.pageNumberKeys
        : ["pageNumber", "page_number", "page"];
      const pageLabelKeys = Array.isArray(options?.pageLabelKeys)
        ? options.pageLabelKeys
        : ["pageLabel", "page_label", "label"];
      const startSecondsKeys = Array.isArray(options?.startSecondsKeys)
        ? options.startSecondsKeys
        : ["startSeconds", "start_seconds", "start", "time", "timestamp"];
      const endSecondsKeys = Array.isArray(options?.endSecondsKeys)
        ? options.endSecondsKeys
        : ["endSeconds", "end_seconds", "end"];
      const lineNumberKeys = Array.isArray(options?.lineNumberKeys)
        ? options.lineNumberKeys
        : ["lineNumber", "line_number", "line"];
      const columnNumberKeys = Array.isArray(options?.columnNumberKeys)
        ? options.columnNumberKeys
        : ["columnNumber", "column_number", "column"];

      const contentID = readexSupportFirstTrimmedValue(reference, ["contentID", "content_id", "content"]);
      const documentID = readexSupportFirstTrimmedValue(reference, ["documentID", "document_id", "document"]);
      const path = readexSupportFirstTrimmedValue(reference, pathKeys);
      const pageNumber = readexSupportPositiveIntegerFromValue(
        readexSupportFirstValue(reference, pageNumberKeys)
      );
      const pageLabel = readexSupportFirstTrimmedValue(reference, pageLabelKeys) || pageLabelFallback;
      const directStartSeconds = readexSupportVideoTimeSecondsFromValue(
        readexSupportFirstValue(reference, startSecondsKeys)
      );
      const fallbackStartSeconds = Number(options?.timeFallback);
      const startSeconds = directStartSeconds !== null
        ? directStartSeconds
        : (Number.isFinite(fallbackStartSeconds) && fallbackStartSeconds >= 0 ? fallbackStartSeconds : null);
      const endSeconds = readexSupportVideoTimeSecondsFromValue(
        readexSupportFirstValue(reference, endSecondsKeys)
      );
      const lineNumber = readexSupportPositiveIntegerFromValue(
        readexSupportFirstValue(reference, lineNumberKeys)
      );
      const columnNumber = readexSupportPositiveIntegerFromValue(
        readexSupportFirstValue(reference, columnNumberKeys)
      );

      if (!contentID && !documentID && !path && !rawURL) {
        return null;
      }
      if (options?.requirePage === true && !pageNumber && !pageLabel) {
        return null;
      }
      if (options?.requireTime === true && startSeconds === null) {
        return null;
      }
      if (endSeconds !== null && (startSeconds === null || endSeconds < startSeconds)) {
        return null;
      }

      return {
        action: "openReadexContentReference",
        contentID: contentID || undefined,
        documentID: documentID || undefined,
        path: path || undefined,
        pageNumber: pageNumber || undefined,
        pageLabel: pageLabel || undefined,
        startSeconds: startSeconds === null ? undefined : startSeconds,
        endSeconds: endSeconds === null ? undefined : endSeconds,
        lineNumber: lineNumber || undefined,
        columnNumber: columnNumber || undefined,
        url: rawURL || undefined
      };
    }

    function readexExtractedPageReferenceFromObject(reference, preview) {
      return readexSupportContentReferencePayloadFromObject(reference, {
        requirePage: true,
        pageLabelFallback: readexFirstExtractedPageLabel(preview)
      });
    }

    function readexExtractedPageReference(preview) {
      const payload = preview?.payload && typeof preview.payload === "object" ? preview.payload : null;
      const referenceCandidates = [
        payload?.readexContentReference,
        payload?.readex_content_reference,
        payload?.readexPageReference,
        payload?.readex_page_reference
      ];
      for (const reference of referenceCandidates) {
        const payloadReference = readexSupportContentReferencePayloadFromObject(reference, {
          requirePage: true,
          pageLabelFallback: readexFirstExtractedPageLabel(preview)
        });
        if (payloadReference) {
          return payloadReference;
        }
      }
      return null;
    }

    function readexExtractedPageRangeFilesFromPayload(payload) {
      const files = payload?.extractedPageRangeFiles || payload?.extracted_page_range_files;
      return Array.isArray(files) ? files : [];
    }

    function readexExtractedPageReferenceFileMatchesPreview(rangeFile, preview) {
      if (!rangeFile || typeof rangeFile !== "object") {
        return false;
      }
      const previewPath = trimmed(preview?.filePath || preview?.file_path);
      const rangePath = trimmed(rangeFile.extractedPDFPath || rangeFile.extracted_pdf_path || rangeFile.filePath || rangeFile.file_path);
      if (previewPath && rangePath && previewPath === rangePath) {
        return true;
      }
      const previewFileName = trimmed(preview?.fileName || preview?.file_name);
      const rangeFileName = trimmed(rangeFile.extractedPDFFileName || rangeFile.extracted_pdf_file_name || rangeFile.filename || rangeFile.fileName);
      return Boolean(previewFileName && rangeFileName && previewFileName === rangeFileName);
    }

    function readexExtractedPageReferenceFromItemResult(preview, item) {
      const payload = item?.result?.payload;
      if (!payload || typeof payload !== "object") {
        return null;
      }
      const rangeFiles = readexExtractedPageRangeFilesFromPayload(payload);
      const rangeFile = rangeFiles.find((candidate) => readexExtractedPageReferenceFileMatchesPreview(candidate, preview))
        || (rangeFiles.length === 1 ? rangeFiles[0] : null);
      if (!rangeFile || typeof rangeFile !== "object") {
        return null;
      }
      const markdownReference = readexSupportContentReferenceFromMarkdownLink(
        rangeFile.markdownLink || rangeFile.markdown_link,
        readexFirstExtractedPageLabel(preview)
      );
      if (markdownReference) {
        return markdownReference;
      }
      return readexExtractedPageReferenceFromObject({
        documentID: payload.documentID || payload.document_id || payload.document,
        contentID: payload.contentID || payload.content_id || payload.content || payload.documentID || payload.document_id,
        path: payload.pdf || payload.path || payload.filePath || payload.file_path,
        pageLabel: rangeFile.pageRangeLabel || rangeFile.page_range_label || rangeFile.label,
        pageNumber: readexSupportPositiveIntegerFromValue(rangeFile.pageRangeLabel || rangeFile.page_range_label)
      }, preview);
    }

    function openReadexExtractedPageReferenceOrPreview(preview, item = null) {
      readexContentReferenceProbe("js_pdf_preview_click", {
        previewFilePath: trimmed(preview?.filePath || preview?.file_path) || null,
        previewFileName: trimmed(preview?.fileName || preview?.file_name) || null,
        previewPayloadKeys: readexContentReferenceProbeKeys(preview?.payload),
        itemResultPayloadKeys: readexContentReferenceProbeKeys(item?.result?.payload)
      });
      const reference = readexExtractedPageReference(preview)
        || readexExtractedPageReferenceFromItemResult(preview, item);
      if (reference) {
        readexContentReferenceProbe("js_pdf_preview_post_message", {
          reference
        });
        postMessageAction({
          action: "openReadexContentReference",
          ...reference
        });
        return;
      }
      readexContentReferenceProbe("js_pdf_preview_fallback_preview", {
        previewFilePath: trimmed(preview?.filePath || preview?.file_path) || null,
        previewFileName: trimmed(preview?.fileName || preview?.file_name) || null
      });
      openReadexPreviewItem(preview);
    }

    function readexCollabPayloadFromValue(value) {
      if (!value || typeof value !== "object") {
        return null;
      }
      if (trimmed(value?.type) === "collabAgentToolCall") {
        return value;
      }
      if (value?.payload && typeof value.payload === "object" && trimmed(value.payload?.type) === "collabAgentToolCall") {
        return value.payload;
      }
      return null;
    }

    function readexCollabAgentPayload(item) {
      return readexCollabPayloadFromValue(item?.result)
        || readexCollabPayloadFromValue(item?.arguments)
        || null;
    }

    function readexCollabAgentReceiverThreadIDs(item) {
      const payload = readexCollabAgentPayload(item);
      if (!payload) {
        return [];
      }
      const receiverThreadIds = Array.isArray(payload?.receiverThreadIds)
        ? payload.receiverThreadIds
        : (Array.isArray(payload?.receiverThreadIDs) ? payload.receiverThreadIDs : []);
      const ids = receiverThreadIds
        .map((value) => trimmed(value))
        .filter(Boolean);
      const states = payload?.agentsStates && typeof payload.agentsStates === "object"
        ? payload.agentsStates
        : null;
      if (states) {
        Object.keys(states).sort().forEach((key) => {
          const state = states[key];
          const threadID = trimmed(state?.threadId) || trimmed(key);
          if (threadID) {
            ids.push(threadID);
          }
        });
      }
      const seen = new Set();
      return ids.filter((id) => {
        if (seen.has(id)) {
          return false;
        }
        seen.add(id);
        return true;
      });
    }

    function readexCollabAgentThreadID(item) {
      const ids = readexCollabAgentReceiverThreadIDs(item);
      return ids.length === 1 ? ids[0] : "";
    }

    function readexCollabAgentTool(item) {
      return trimmed(readexCollabAgentPayload(item)?.tool);
    }

    function readexCollabAgentCanOpenPanel(item) {
      if (!readexCollabAgentThreadID(item)) {
        return false;
      }
      const tool = readexCollabAgentTool(item);
      return tool !== "wait" && tool !== "closeAgent";
    }

    function readexCollabAgentExplicitDisplayName(item) {
      const payload = readexCollabAgentPayload(item);
      const states = payload?.agentsStates && typeof payload.agentsStates === "object"
        ? payload.agentsStates
        : null;
      if (states) {
        for (const key of Object.keys(states).sort()) {
          const name = trimmed(states[key]?.agentNickname);
          if (name) {
            return name;
          }
        }
      }
      return "";
    }

    function readexCollabAgentDisplayName(item) {
      const explicitName = readexCollabAgentExplicitDisplayName(item);
      if (explicitName) {
        return explicitName;
      }
      return "智能体";
    }

    function readexSubagentStableIndex(seed, count) {
      if (!count) {
        return 0;
      }
      let hash = 5381n;
      const minimumInt64 = -(1n << 63n);
      for (const scalar of String(seed || "")) {
        hash = BigInt.asIntN(64, (hash << 5n) + hash + BigInt(scalar.codePointAt(0) || 0));
      }
      if (hash === minimumInt64) {
        return 0;
      }
      const positive = hash < 0n ? -hash : hash;
      return Number(positive % BigInt(count));
    }

    function readexSubagentAvatarSymbolName(threadID) {
      const symbols = [
        "sparkles", "atom", "function", "sum", "brain.head.profile", "lightbulb",
        "scope", "point.3.connected.trianglepath.dotted", "wand.and.stars", "graduationcap"
      ];
      return symbols[readexSubagentStableIndex(threadID, symbols.length)] || "sparkles";
    }

    function readexSubagentAvatarColor(threadID) {
      const colors = [
        "#007AFF", "#30B0C7", "#34C759", "#FF9500",
        "#FF2D55", "#5856D6", "#AF52DE", "#32ADE6"
      ];
      return colors[readexSubagentStableIndex(threadID, colors.length)] || "#007AFF";
    }

    function readexCollabAgentAvatarDescriptor(item) {
      const threadID = readexCollabAgentReceiverThreadIDs(item)[0] || "";
      if (!threadID) {
        return null;
      }
      return {
        symbolName: readexSubagentAvatarSymbolName(threadID),
        color: readexSubagentAvatarColor(threadID)
      };
    }

    function buildReadexSubagentAvatarGlyph(descriptor, className = "readex-subagent-avatar-glyph") {
      if (!descriptor) {
        return null;
      }
      const iconMarkup = makeIcon(descriptor.symbolName) || makeIcon("sparkles");
      if (!iconMarkup) {
        return null;
      }
      const glyph = document.createElement("span");
      glyph.className = className;
      glyph.style.color = descriptor.color;
      glyph.innerHTML = iconMarkup;
      return glyph;
    }

    function appendReadexToolAvatarOrIcon(row, item, accentColor = "") {
      const avatar = buildReadexSubagentAvatarGlyph(readexCollabAgentAvatarDescriptor(item));
      if (avatar) {
        row.appendChild(avatar);
        return avatar;
      }
      const iconName = readexToolIcon(item);
      const icon = appendIcon(row, iconName);
      decorateReadexTerminalCommandIcon(icon, iconName);
      if (icon && readexToolItemUsesPreviewContentAccentPresentation(item)) {
        icon.classList.add("readex-extracted-pdf-accent-icon");
        applyReadexExtractedPDFAccent(icon, accentColor);
      }
      return icon;
    }

    function openReadexCollabAgentPanel(threadID, event) {
      if (event) {
        event.preventDefault();
        event.stopPropagation();
      }
      if (!threadID) {
        return;
      }
      postMessageAction({
        action: "openReadexSubagentPanel",
        receiverThreadId: threadID
      });
    }

    function installReadexCollabAgentOpenTarget(element, threadID) {
      if (!element || !threadID) {
        return;
      }
      element.dataset.receiverThreadId = threadID;
      const openPanel = (event) => {
        openReadexCollabAgentPanel(threadID, event);
      };
      element.addEventListener("click", openPanel);
      element.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        openPanel(event);
      });
    }

    function appendReadexSubagentTitleFragments(parent, titleText, agentName, color, threadID = "") {
      const nameIndex = agentName ? titleText.indexOf(agentName) : -1;
      if (nameIndex < 0) {
        parent.appendChild(document.createTextNode(titleText));
        return false;
      }
      if (nameIndex > 0) {
        parent.appendChild(document.createTextNode(titleText.slice(0, nameIndex)));
      }
      const name = document.createElement("span");
      name.className = "readex-subagent-title-name";
      name.style.color = color;
      name.textContent = titleText.slice(nameIndex, nameIndex + agentName.length);
      if (threadID) {
        name.classList.add("is-open-target");
        name.setAttribute("role", "button");
        name.setAttribute("tabindex", "0");
        name.setAttribute("title", "打开智能体面板");
        installReadexCollabAgentOpenTarget(name, threadID);
      }
      parent.appendChild(name);
      const tailText = titleText.slice(nameIndex + agentName.length);
      if (tailText) {
        parent.appendChild(document.createTextNode(tailText));
      }
      return true;
    }

    function renderReadexSubagentShimmerTitle(label, titleText, agentName, color, threadID = "") {
      const displayText = trimmed(titleText);
      if (!displayText) {
        stopCodexShimmerText(label);
        clearReadexShimmerPresentation(label);
        label.textContent = "";
        return;
      }
      if (label.classList.contains("readex-tool-shimmer")
        && label.dataset.shimmerText === displayText
        && label.dataset.subagentTitleName === agentName
        && label.dataset.subagentTitleColor === color
        && label.dataset.receiverThreadId === threadID
        && label.querySelector(":scope > .readex-tool-shimmer-sweep")) {
        return;
      }

      stopCodexShimmerText(label);
      clearReadexShimmerPresentation(label);
      label.textContent = "";
      label.dataset.shimmerText = displayText;
      label.dataset.subagentTitleName = agentName;
      label.dataset.subagentTitleColor = color;
      label.dataset.receiverThreadId = threadID;
      label.classList.add("readex-tool-shimmer");
      appendReadexSubagentTitleFragments(label, displayText, agentName, color, threadID);

      const sweep = document.createElement("span");
      sweep.setAttribute("aria-hidden", "true");
      sweep.className = "readex-tool-shimmer-sweep";
      const highlight = document.createElement("span");
      highlight.className = "readex-tool-shimmer-highlight";
      appendReadexSubagentTitleFragments(highlight, displayText, agentName, color);
      sweep.appendChild(highlight);
      label.appendChild(sweep);
      startCodexShimmerText(label);
    }

    function renderReadexToolItemTitle(label, item, accentColor = "") {
      const titleText = String(item?.text || "");
      if (!readexToolItemIsLive(item) && readexToolItemUsesExtractedPagePreviewPresentation(item)) {
        stopCodexShimmerText(label);
        clearReadexShimmerPresentation(label);
        label.textContent = "";
        if (appendReadexExtractedPageTitleFragments(label, item, titleText, accentColor)) {
          return;
        }
      }
      const agentName = readexCollabAgentExplicitDisplayName(item);
      const descriptor = readexCollabAgentAvatarDescriptor(item);
      const threadID = readexCollabAgentCanOpenPanel(item) ? readexCollabAgentThreadID(item) : "";
      const nameIndex = agentName ? titleText.indexOf(agentName) : -1;
      if (!agentName || !descriptor?.color || nameIndex < 0) {
        if (readexToolItemIsLive(item)) {
          renderSequentialShimmerText(label, titleText);
          return;
        }
        clearSequentialShimmerText(label, titleText);
        return;
      }

      if (readexToolItemIsLive(item)) {
        renderReadexSubagentShimmerTitle(label, titleText, agentName, descriptor.color, threadID);
        return;
      }

      stopCodexShimmerText(label);
      clearReadexShimmerPresentation(label);
      label.textContent = "";
      appendReadexSubagentTitleFragments(label, titleText, agentName, descriptor.color, threadID);
    }

    function appendReadexExtractedPageReferenceText(parent, item, preview, text, accentColor = "") {
      const link = document.createElement("span");
      link.className = "readex-extracted-page-reference-link";
      link.setAttribute("role", "button");
      link.setAttribute("tabindex", "0");
      link.textContent = text;
      applyReadexExtractedPDFAccent(link, accentColor);
      const open = (event) => {
        event.preventDefault();
        event.stopPropagation();
        openReadexExtractedPageReferenceOrPreview(preview, item);
      };
      link.addEventListener("click", open);
      link.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        open(event);
      });
      parent.appendChild(link);
    }

    function readexSupportTargetIsNestedReferenceControl(target) {
      return target instanceof Element
        && Boolean(target.closest(".readex-extracted-page-reference-link, .readex-tool-page-range-button, .readex-video-frame-timestamp-link"));
    }

    function readexExtractedPDFPageCountSuffixAt(text, offset) {
      const suffix = String(text || "").slice(offset);
      const match = suffix.match(/^(（\s*\d+\s*页\s*）|\(\s*\d+\s*页\s*\))/u);
      return match ? match[0] : "";
    }

    function appendReadexExtractedPageTitleFragments(parent, item, titleText, accentColor = "") {
      const previews = Array.isArray(item?.previewItems) ? item.previewItems : [];
      const pagePreviews = previews.filter((preview) => trimmed(preview?.attachmentKind) === "extractedPDF");
      if (!pagePreviews.length) {
        parent.appendChild(document.createTextNode(titleText));
        return false;
      }

      let cursor = 0;
      let matched = false;
      pagePreviews.forEach((preview) => {
        const label = readexExtractedPageRangeLabel(preview);
        if (!label) {
          return;
        }
        const candidates = [`书页 ${label}`, `书页${label}`, label];
        let match = null;
        for (const candidate of candidates) {
          const index = titleText.indexOf(candidate, cursor);
          if (index < 0) {
            continue;
          }
          if (!match || index < match.index || (index === match.index && candidate.length > match.text.length)) {
            match = { index, text: candidate };
          }
        }
        if (!match) {
          return;
        }
        if (match.index > cursor) {
          parent.appendChild(document.createTextNode(titleText.slice(cursor, match.index)));
        }
        const matchEnd = match.index + match.text.length;
        const pageCountSuffix = readexExtractedPDFPageCountSuffixAt(titleText, matchEnd);
        appendReadexExtractedPageReferenceText(parent, item, preview, match.text + pageCountSuffix, accentColor);
        cursor = matchEnd + pageCountSuffix.length;
        matched = true;
      });

      if (!matched) {
        parent.textContent = titleText;
        return false;
      }
      if (cursor < titleText.length) {
        parent.appendChild(document.createTextNode(titleText.slice(cursor)));
      }
      return true;
    }

    function readexToolActivityExtractedPageItem(block) {
      return readexToolItems(block).find(readexToolItemUsesExtractedPagePreviewPresentation) || null;
    }

    function readexToolActivityPreviewContentAccentItem(block) {
      for (const item of readexToolItems(block)) {
        if (readexToolItemUsesPreviewContentAccentPresentation(item)) {
          return item;
        }
        const childItem = readexToolItemChildItems(item).find(readexToolItemUsesPreviewContentAccentPresentation);
        if (childItem) {
          return childItem;
        }
      }
      return null;
    }

    function decorateReadexExtractedPDFSupportLine(supportLine, block, titleText, isComplete, accentSource = "") {
      if (!supportLine) {
        return false;
      }
      const item = readexToolActivityExtractedPageItem(block);
      const accentItem = readexToolActivityPreviewContentAccentItem(block);
      const accentColor = readexToolItemPreviewContentAccentColor(accentItem, accentSource);
      const usesPreviewContentAccent = Boolean(accentColor);
      supportLine.classList.toggle("has-preview-content-accent", usesPreviewContentAccent);
      const icon = supportLine.querySelector(":scope > svg, :scope > .sf-symbol-mask");
      icon?.classList?.toggle("readex-extracted-pdf-accent-icon", usesPreviewContentAccent);
      applyReadexExtractedPDFAccent(icon, accentColor);
      if (!item || !isComplete) {
        return false;
      }
      const title = supportLine.querySelector(".support-line-title");
      if (!title) {
        return false;
      }
      stopCodexShimmerText(title);
      clearReadexShimmerPresentation(title);
      title.textContent = "";
      return appendReadexExtractedPageTitleFragments(title, item, titleText, accentColor);
    }

    function appendReadexCollabAgentOpenChip(row, item) {
      if (!readexCollabAgentCanOpenPanel(item)) {
        return;
      }
      const threadID = readexCollabAgentThreadID(item);
      const chip = document.createElement("span");
      chip.className = "readex-subagent-open-chip";
      chip.setAttribute("role", "button");
      chip.setAttribute("tabindex", "0");
      chip.setAttribute("title", "打开智能体面板");
      const descriptor = readexCollabAgentAvatarDescriptor(item);
      const icon = buildReadexSubagentAvatarGlyph(
        descriptor,
        "readex-subagent-open-chip-icon readex-subagent-avatar-glyph"
      );
      if (icon) {
        chip.appendChild(icon);
      }
      const label = document.createElement("span");
      label.className = "readex-subagent-open-chip-label";
      label.textContent = readexCollabAgentDisplayName(item);
      if (descriptor?.color) {
        label.style.color = descriptor.color;
      }
      chip.appendChild(label);

      installReadexCollabAgentOpenTarget(chip, threadID);
      row.appendChild(chip);
    }

    function installReadexCollabAgentOpenAction(element, item) {
      if (!element || !readexCollabAgentCanOpenPanel(item)) {
        return;
      }
      const threadID = readexCollabAgentThreadID(item);
      element.classList.add("is-subagent-prompt");
      element.setAttribute("role", "button");
      element.setAttribute("tabindex", "0");
      element.setAttribute("title", "打开智能体面板");
      installReadexCollabAgentOpenTarget(element, threadID);
    }

    function readexPreviewIsVideoFrame(preview) {
      return trimmed(preview?.kind) === "video_frame";
    }

    function readexNestedDisclosureExpandedKeys(owner) {
      if (!(owner instanceof HTMLElement)) {
        return null;
      }
      if (!(owner.__chatTranscriptReadexNestedDisclosureExpandedKeys instanceof Set)) {
        owner.__chatTranscriptReadexNestedDisclosureExpandedKeys = readexNestedDisclosureInitialKeySet(owner);
      }
      return owner.__chatTranscriptReadexNestedDisclosureExpandedKeys;
    }

    function readexNestedDisclosureCollapsedKeys(owner) {
      if (!(owner instanceof HTMLElement)) {
        return null;
      }
      if (!(owner.__chatTranscriptReadexNestedDisclosureCollapsedKeys instanceof Set)) {
        owner.__chatTranscriptReadexNestedDisclosureCollapsedKeys = readexNestedDisclosureInitialCollapsedKeySet(owner);
      }
      return owner.__chatTranscriptReadexNestedDisclosureCollapsedKeys;
    }

    function readexNestedDisclosureInitialKeySet(owner) {
      const sourceID = trimmed(owner?.__chatTranscriptReadexNestedDisclosureSourceID);
      if (!sourceID) {
        return new Set();
      }
      return new Set(readexNestedDisclosurePayloadKeyMap().get(sourceID) || []);
    }

    function readexNestedDisclosureInitialCollapsedKeySet(owner) {
      const sourceID = trimmed(owner?.__chatTranscriptReadexNestedDisclosureSourceID);
      if (!sourceID) {
        return new Set();
      }
      return new Set(readexNestedDisclosureCollapsedPayloadKeyMap().get(sourceID) || []);
    }

    function readexNestedDisclosurePayloadKeyMap() {
      const payload = window.__chatTranscriptPayload || window.__chatLongImagePayload || {};
      const candidates = [
        payload.expandedReadexNestedDisclosureKeysBySourceBlockID,
        payload.expandedReadexNestedDisclosureKeysBySourceBlockId
      ];
      return readexNestedDisclosureKeyMapFromCandidates(candidates);
    }

    function readexNestedDisclosureCollapsedPayloadKeyMap() {
      const payload = window.__chatTranscriptPayload || window.__chatLongImagePayload || {};
      const candidates = [
        payload.collapsedReadexNestedDisclosureKeysBySourceBlockID,
        payload.collapsedReadexNestedDisclosureKeysBySourceBlockId
      ];
      return readexNestedDisclosureKeyMapFromCandidates(candidates);
    }

    function readexNestedDisclosureKeyMapFromCandidates(candidates) {
      const output = new Map();

      candidates.forEach((candidate) => {
        if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) {
          return;
        }
        Object.entries(candidate).forEach(([rawSourceID, rawKeys]) => {
          const sourceID = trimmed(rawSourceID);
          if (!sourceID || !Array.isArray(rawKeys)) {
            return;
          }
          const keys = rawKeys.map((key) => trimmed(key)).filter(Boolean);
          if (!keys.length) {
            return;
          }
          const existing = output.get(sourceID) || new Set();
          keys.forEach((key) => existing.add(key));
          output.set(sourceID, existing);
        });
      });

      return output;
    }

    function configureReadexNestedDisclosureOwner(owner, block) {
      if (!(owner instanceof HTMLElement)) {
        return;
      }
      const sourceID = readexDisclosureSourceIDFromBlock(block);
      const existingKeys = owner.__chatTranscriptReadexNestedDisclosureExpandedKeys instanceof Set
        ? owner.__chatTranscriptReadexNestedDisclosureExpandedKeys
        : null;
      const existingCollapsedKeys = owner.__chatTranscriptReadexNestedDisclosureCollapsedKeys instanceof Set
        ? owner.__chatTranscriptReadexNestedDisclosureCollapsedKeys
        : null;
      if (owner.__chatTranscriptReadexNestedDisclosureSourceID !== sourceID) {
        owner.__chatTranscriptReadexNestedDisclosureSourceID = sourceID;
        owner.__chatTranscriptReadexNestedDisclosureExpandedKeys = existingKeys || readexNestedDisclosureInitialKeySet(owner);
        owner.__chatTranscriptReadexNestedDisclosureCollapsedKeys = existingCollapsedKeys || readexNestedDisclosureInitialCollapsedKeySet(owner);
      } else if (!(owner.__chatTranscriptReadexNestedDisclosureExpandedKeys instanceof Set)) {
        owner.__chatTranscriptReadexNestedDisclosureExpandedKeys = readexNestedDisclosureInitialKeySet(owner);
      } else if (!(owner.__chatTranscriptReadexNestedDisclosureCollapsedKeys instanceof Set)) {
        owner.__chatTranscriptReadexNestedDisclosureCollapsedKeys = readexNestedDisclosureInitialCollapsedKeySet(owner);
      }
    }

    function readexNestedDisclosureIsExpanded(owner, key) {
      const normalizedKey = trimmed(key);
      if (!normalizedKey) {
        return false;
      }
      const collapsedKeys = readexNestedDisclosureCollapsedKeys(owner);
      if (collapsedKeys?.has(normalizedKey)) {
        return false;
      }
      const keys = readexNestedDisclosureExpandedKeys(owner);
      if (keys?.has(normalizedKey)) {
        return true;
      }
      return false;
    }

    function setReadexNestedDisclosureExpanded(owner, key, expanded) {
      const normalizedKey = trimmed(key);
      const keys = readexNestedDisclosureExpandedKeys(owner);
      const collapsedKeys = readexNestedDisclosureCollapsedKeys(owner);
      if (!normalizedKey || !keys || !collapsedKeys) {
        return;
      }
      if (expanded) {
        keys.add(normalizedKey);
        collapsedKeys.delete(normalizedKey);
      } else {
        keys.delete(normalizedKey);
        collapsedKeys.add(normalizedKey);
      }
      postReadexNestedDisclosureExpansionState();
    }

    function readexPreviewStableKey(preview) {
      return [
        trimmed(preview?.id),
        trimmed(preview?.kind),
        trimmed(preview?.title),
        trimmed(preview?.subtitle),
        trimmed(preview?.filePath),
        trimmed(preview?.documentName)
      ].filter(Boolean).join("|");
    }

    function readexToolDisclosureStableKey(item, index, namespace) {
      const stableID = trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID) || trimmed(item?.id)
        || trimmed(item?.callID) || trimmed(item?.callId) || trimmed(item?.toolCallID) || trimmed(item?.toolCallId);
      if (stableID) {
        return [
          trimmed(namespace) || "tool",
          stableID
        ].join("\u{1f}");
      }
      const previewKey = (Array.isArray(item?.previewItems) ? item.previewItems : [])
        .map(readexPreviewStableKey)
        .filter(Boolean)
        .join(",");
      return [
        trimmed(namespace) || "tool",
        Number.isFinite(Number(index)) ? String(index) : "",
        trimmed(item?.text),
        previewKey
      ].join("\u{1f}");
    }

    function readexPreviewDisplayTitle(preview) {
      return [trimmed(preview?.title), trimmed(preview?.subtitle)]
        .filter(Boolean)
        .join(" · ");
    }

    function readexPreviewLooksLikeLibraryTree(preview) {
      const title = trimmed(preview?.title);
      const markdown = trimmed(preview?.markdown);
      return title === "知识库结构" && (markdown.includes("# 知识库结构") || markdown.includes("返回 PDF 文档"));
    }

    function readexPreviewIsLibraryTree(preview) {
      return trimmed(preview?.kind) === "library_tree" || readexPreviewLooksLikeLibraryTree(preview);
    }

    function readexLibraryTreeObjects(value) {
      return Array.isArray(value)
        ? value.filter((item) => item && typeof item === "object")
        : [];
    }

    function readexLibraryTreeInteger(value) {
      const number = Number(value);
      return Number.isFinite(number) ? Math.max(0, Math.floor(number)) : 0;
    }

    function readexLibraryTreeSortByName(lhs, rhs) {
      const lhsName = trimmed(lhs?.path) || trimmed(lhs?.name) || trimmed(lhs?.n) || trimmed(lhs?.fileName) || trimmed(lhs?.documentName);
      const rhsName = trimmed(rhs?.path) || trimmed(rhs?.name) || trimmed(rhs?.n) || trimmed(rhs?.fileName) || trimmed(rhs?.documentName);
      return lhsName.localeCompare(rhsName, undefined, { numeric: true, sensitivity: "base" });
    }

    function readexLibraryTreePush(map, key, value) {
      const normalizedKey = trimmed(key);
      const existing = map.get(normalizedKey);
      if (existing) {
        existing.push(value);
      } else {
        map.set(normalizedKey, [value]);
      }
    }

    function readexLibraryTreeFolderIDFromPath(path) {
      const normalizedPath = trimmed(path);
      if (!normalizedPath || normalizedPath === "/") {
        return "";
      }
      return normalizedPath.startsWith("/") ? normalizedPath : `/${normalizedPath}`;
    }

    function readexLibraryTreeNameFromPath(path) {
      const normalizedPath = readexLibraryTreeFolderIDFromPath(path);
      if (!normalizedPath) {
        return "根目录";
      }
      return normalizedPath.split("/").filter(Boolean).pop() || normalizedPath;
    }

    function readexLibraryTreeParentIDFromPath(path, folderIDs) {
      const normalizedPath = readexLibraryTreeFolderIDFromPath(path);
      const parts = normalizedPath.split("/").filter(Boolean);
      if (parts.length <= 1) {
        return null;
      }
      const parentPath = `/${parts.slice(0, -1).join("/")}`;
      return folderIDs.has(parentPath) ? parentPath : null;
    }

    function readexLibraryTreeArray(value) {
      return Array.isArray(value) ? value : [];
    }

    function readexLibraryTreeFolderID(folder) {
      return trimmed(folder?.folderID)
        || trimmed(folder?.folderId)
        || trimmed(folder?.id)
        || readexLibraryTreeFolderIDFromPath(folder?.path);
    }

    function readexLibraryTreeFolderParentID(folder) {
      return trimmed(folder?.parentFolderID)
        || trimmed(folder?.parentFolderId)
        || trimmed(folder?.parentID)
        || trimmed(folder?.parentId)
        || trimmed(folder?.parent)
        || "";
    }

    function readexLibraryTreeFolderName(folder, folderID) {
      return trimmed(folder?.name)
        || trimmed(folder?.n)
        || readexLibraryTreeNameFromPath(folder?.path)
        || trimmed(folderID)
        || "未命名文件夹";
    }

    function normalizedReadexLibraryTreeFolders(rawFolders) {
      const folders = readexLibraryTreeObjects(rawFolders).map((folder) => {
        const folderID = readexLibraryTreeFolderID(folder);
        if (!folderID) {
          return null;
        }
        return {
          ...folder,
          folderID,
          parentFolderID: readexLibraryTreeFolderParentID(folder),
          name: readexLibraryTreeFolderName(folder, folderID),
          path: trimmed(folder?.path) || (folderID.startsWith("/") ? folderID : ""),
          childFolderCount: readexLibraryTreeInteger(folder?.childFolderCount ?? folder?.cf),
          pdfDocumentCount: readexLibraryTreeInteger(folder?.pdfDocumentCount ?? folder?.pdfs)
        };
      }).filter(Boolean);

      const folderIDs = new Set(folders.map((folder) => folder.folderID));
      const folderIDByPath = new Map(
        folders
          .map((folder) => [readexLibraryTreeFolderIDFromPath(folder.path), folder.folderID])
          .filter(([path]) => Boolean(path))
      );
      folders.forEach((folder) => {
        if (folder.parentFolderID && !folderIDs.has(folder.parentFolderID)) {
          folder.parentFolderID = folderIDByPath.get(readexLibraryTreeFolderIDFromPath(folder.parentFolderID)) || "";
        }
        if (!folder.parentFolderID && folder.path) {
          folder.parentFolderID = readexLibraryTreeParentIDFromPath(folder.path, folderIDs) || "";
        }
      });
      return folders;
    }

    function readexLibraryTreeDocumentFolderID(document, folderIDs, folderIDByPath) {
      const explicitID = trimmed(document?.folderID)
        || trimmed(document?.folderId)
        || trimmed(document?.f);
      if (explicitID) {
        return folderIDs.has(explicitID)
          ? explicitID
          : (folderIDByPath.get(readexLibraryTreeFolderIDFromPath(explicitID)) || explicitID);
      }
      const folderPath = trimmed(document?.folderPath) || trimmed(document?.path);
      return folderIDByPath.get(readexLibraryTreeFolderIDFromPath(folderPath))
        || readexLibraryTreeFolderIDFromPath(folderPath);
    }

    function readexLibraryTreeDocumentMap(document) {
      return readexLibraryTreeArray(document?.map);
    }

    function normalizedReadexLibraryTreeDocuments(rawDocuments, folderIDs, folderIDByPath) {
      return readexLibraryTreeObjects(rawDocuments).map((document) => {
        const map = readexLibraryTreeDocumentMap(document);
        const mapsCount = readexLibraryTreeInteger(document?.maps);
        const explicitHasMap = document?.hasKnowledgeMap === true;
        const hasKnowledgeMap = explicitHasMap || mapsCount > 0 || map.length > 0;
        return {
          ...document,
          documentID: trimmed(document?.documentID) || trimmed(document?.documentId) || trimmed(document?.id),
          fileName: trimmed(document?.fileName) || trimmed(document?.documentName) || trimmed(document?.n) || "未命名 PDF",
          folderID: readexLibraryTreeDocumentFolderID(document, folderIDs, folderIDByPath),
          folderPath: trimmed(document?.folderPath) || trimmed(document?.path),
          pageCount: readexLibraryTreeInteger(document?.pageCount ?? document?.pages),
          hasKnowledgeMap,
          selectedKnowledgeMapTitle: trimmed(document?.selectedKnowledgeMapTitle) || trimmed(map[1]),
          selectedKnowledgeMapNodeCount: readexLibraryTreeInteger(document?.selectedKnowledgeMapNodeCount ?? map[2])
        };
      });
    }

    function readexLibraryTreePayloadFromMarkdown(markdown) {
      const lines = String(markdown || "").split(/\r?\n/u).map((line) => line.trim()).filter(Boolean);
      const folders = [];
      const documents = [];
      let section = "";

      lines.forEach((line) => {
        if (line === "## 文件夹") {
          section = "folders";
          return;
        }
        if (line === "## PDF 文档") {
          section = "documents";
          return;
        }
        if (!line.startsWith("- ")) {
          return;
        }

        if (section === "folders") {
          const match = line.match(/^- (.+?)（PDF\s*(\d+)\s*个，子文件夹\s*(\d+)\s*个）$/u);
          if (!match) {
            return;
          }
          const path = readexLibraryTreeFolderIDFromPath(match[1]);
          folders.push({
            folderID: path,
            name: readexLibraryTreeNameFromPath(path),
            parentFolderID: null,
            path,
            childFolderCount: readexLibraryTreeInteger(match[3]),
            pdfDocumentCount: readexLibraryTreeInteger(match[2])
          });
          return;
        }

        if (section === "documents") {
          const match = line.match(/^- 《(.+)》 · (.+?) · (\d+)\s*页 · (.+)$/u);
          if (!match) {
            return;
          }
          const folderPath = readexLibraryTreeFolderIDFromPath(match[2]) || "/";
          const mapText = trimmed(match[4]);
          const mapMatch = mapText.match(/^知识地图：(.+)，(\d+)\s*个节点$/u);
          documents.push({
            documentID: `${folderPath}/${match[1]}`,
            fileName: match[1],
            kind: "pdf",
            folderID: folderPath === "/" ? null : folderPath,
            folderPath,
            pageCount: readexLibraryTreeInteger(match[3]),
            hasKnowledgeMap: !mapText.includes("无知识地图"),
            selectedKnowledgeMapTitle: mapMatch ? trimmed(mapMatch[1]) : null,
            selectedKnowledgeMapNodeCount: mapMatch ? readexLibraryTreeInteger(mapMatch[2]) : 0
          });
        }
      });

      const folderIDs = new Set(folders.map((folder) => folder.folderID).filter(Boolean));
      folders.forEach((folder) => {
        folder.parentFolderID = readexLibraryTreeParentIDFromPath(folder.path, folderIDs);
      });
      return { folders, documents };
    }

    function readexLibraryTreeContext(preview) {
      const payload = preview?.payload && typeof preview.payload === "object"
        ? preview.payload
        : readexLibraryTreePayloadFromMarkdown(preview?.markdown || "");
      const folders = normalizedReadexLibraryTreeFolders(payload.folders);
      const folderIDs = new Set(folders.map((folder) => trimmed(folder.folderID)).filter(Boolean));
      const folderIDByPath = new Map(
        folders
          .map((folder) => [readexLibraryTreeFolderIDFromPath(folder.path), folder.folderID])
          .filter(([path]) => Boolean(path))
      );
      const documents = normalizedReadexLibraryTreeDocuments(payload.documents, folderIDs, folderIDByPath);
      const foldersByParentID = new Map();
      const documentsByFolderID = new Map();

      folders.forEach((folder) => {
        const parentID = trimmed(folder.parentFolderID);
        readexLibraryTreePush(
          foldersByParentID,
          parentID && folderIDs.has(parentID) ? parentID : "",
          folder
        );
      });

      documents.forEach((document) => {
        const folderID = trimmed(document.folderID);
        readexLibraryTreePush(
          documentsByFolderID,
          folderID && folderIDs.has(folderID) ? folderID : "",
          document
        );
      });

      foldersByParentID.forEach((items) => items.sort(readexLibraryTreeSortByName));
      documentsByFolderID.forEach((items) => items.sort(readexLibraryTreeSortByName));
      return { folders, documents, foldersByParentID, documentsByFolderID };
    }

    function readexLibraryTreeChildMeta(folders, documents) {
      const parts = [];
      if (folders.length > 0) {
        parts.push(`${folders.length} 个文件夹`);
      }
      if (documents.length > 0) {
        parts.push(`${documents.length} 个 PDF`);
      }
      return parts.join(" · ") || "空";
    }

    function readexLibraryTreeDocumentMeta(document) {
      const parts = [];
      const pageCount = readexLibraryTreeInteger(document?.pageCount);
      if (pageCount > 0) {
        parts.push(`${pageCount} 页`);
      }

      if (document?.hasKnowledgeMap === true) {
        const nodeCount = readexLibraryTreeInteger(document.selectedKnowledgeMapNodeCount);
        parts.push(nodeCount > 0 ? `知识地图：${nodeCount} 个节点` : "有知识地图");
      } else {
        parts.push("无知识地图");
      }

      return parts.join(" · ");
    }

    function appendReadexLibraryTreeText(row, labelText, metaText) {
      const textWrap = document.createElement("span");
      textWrap.className = "readex-library-tree-text";

      const label = document.createElement("span");
      label.className = "readex-library-tree-label";
      label.textContent = labelText;
      textWrap.appendChild(label);

      if (metaText) {
        const meta = document.createElement("span");
        meta.className = "readex-library-tree-meta";
        meta.textContent = metaText;
        textWrap.appendChild(meta);
      }

      row.appendChild(textWrap);
    }

    function appendReadexLibraryTreeChevron(row, hasChildren) {
      const chevron = document.createElement("span");
      chevron.className = hasChildren
        ? "readex-library-tree-chevron"
        : "readex-library-tree-chevron is-placeholder";
      if (hasChildren) {
        chevron.innerHTML = makeIcon("chevron-right");
      }
      row.appendChild(chevron);
      return chevron;
    }

    function appendReadexLibraryTreeDocument(container, documentItem, depth) {
      const row = document.createElement("div");
      row.className = "readex-library-tree-row is-document";
      row.style.setProperty("--readex-library-tree-depth", String(depth));
      appendReadexLibraryTreeChevron(row, false);
      appendIcon(row, "doc.text.magnifyingglass");
      appendReadexLibraryTreeText(
        row,
        trimmed(documentItem?.fileName) || "未命名 PDF",
        readexLibraryTreeDocumentMeta(documentItem)
      );
      container.appendChild(row);
    }

    function appendReadexLibraryTreeBranch(container, branch, depth, context, disclosureContext = null, ancestry = new Set()) {
      const folderID = branch.type === "root" ? "" : trimmed(branch.folderID);
      if (branch.type !== "root" && folderID && ancestry.has(folderID)) {
        return;
      }
      const nextAncestry = new Set(ancestry);
      if (folderID) {
        nextAncestry.add(folderID);
      }
      const childFolders = (context.foldersByParentID.get(folderID) || []).filter((folder) => {
        const childFolderID = trimmed(folder?.folderID);
        return childFolderID && childFolderID !== folderID && !nextAncestry.has(childFolderID);
      });
      const childDocuments = context.documentsByFolderID.get(folderID) || [];
      const hasChildren = childFolders.length > 0 || childDocuments.length > 0;
      const disclosureKey = disclosureContext
        ? `${disclosureContext.baseKey}:branch:${folderID || "root"}`
        : "";
      const initiallyExpanded = hasChildren
        && readexNestedDisclosureIsExpanded(disclosureContext?.owner, disclosureKey);
      const wrapper = document.createElement("div");
      wrapper.className = "readex-library-tree-node";

      const row = document.createElement(hasChildren ? "button" : "div");
      if (hasChildren) {
        row.type = "button";
        row.setAttribute("aria-expanded", initiallyExpanded ? "true" : "false");
      }
      row.className = [
        "readex-library-tree-row",
        branch.type === "root" ? "is-root" : "is-folder",
        hasChildren ? "is-expandable" : ""
      ].filter(Boolean).join(" ");
      row.style.setProperty("--readex-library-tree-depth", String(depth));

      const chevron = appendReadexLibraryTreeChevron(row, hasChildren);
      if (hasChildren && initiallyExpanded) {
        chevron.innerHTML = makeIcon("chevron-down");
      }
      appendIcon(row, branch.type === "root" ? "books.vertical" : "folder");
      appendReadexLibraryTreeText(
        row,
        branch.type === "root" ? "根目录" : (trimmed(branch.name) || "未命名文件夹"),
        readexLibraryTreeChildMeta(childFolders, childDocuments)
      );

      const children = document.createElement("div");
      children.className = "readex-library-tree-children";
      children.hidden = !initiallyExpanded;
      childFolders.forEach((folder) => {
        appendReadexLibraryTreeBranch(children, { ...folder, type: "folder" }, depth + 1, context, disclosureContext, nextAncestry);
      });
      childDocuments.forEach((document) => {
        appendReadexLibraryTreeDocument(children, document, depth + 1);
      });

      if (hasChildren) {
        row.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          const expanded = row.getAttribute("aria-expanded") === "true";
          const nextExpanded = !expanded;
          row.setAttribute("aria-expanded", nextExpanded ? "true" : "false");
          chevron.innerHTML = makeIcon(nextExpanded ? "chevron-down" : "chevron-right");
          setReadexNestedDisclosureExpanded(disclosureContext?.owner, disclosureKey, nextExpanded);
          cancelReadexAncestorDisclosureAnimations(children);
          animateReadexDisclosureElement(children, nextExpanded, { hideOnFinish: true, reserveLayout: true });
        });
      }

      wrapper.appendChild(row);
      if (hasChildren) {
        wrapper.appendChild(children);
      }
      container.appendChild(wrapper);
    }

    function appendReadexLibraryTreePreview(details, preview, disclosureContext = null) {
      const tree = document.createElement("div");
      tree.className = "readex-library-tree";
      appendReadexLibraryTreeBranch(tree, { type: "root" }, 0, readexLibraryTreeContext(preview), disclosureContext);
      details.appendChild(tree);
    }

    function readexToolItemHasLibraryTreePreview(item) {
      return Array.isArray(item?.previewItems) && item.previewItems.some(readexPreviewIsLibraryTree);
    }

    function appendReadexLibraryTreeToolItem(details, item, stateOwner = null, disclosureKey = "") {
      const libraryPreviews = item.previewItems.filter(readexPreviewIsLibraryTree);
      const otherPreviews = item.previewItems.filter((preview) => !readexPreviewIsLibraryTree(preview));
      const initiallyExpanded = readexNestedDisclosureIsExpanded(stateOwner, disclosureKey);

      const wrapper = document.createElement("div");
      wrapper.className = "readex-tool-activity-disclosure";

      const row = document.createElement("button");
      row.type = "button";
      row.className = [
        "readex-tool-activity-item",
        readexToolItemIsLive(item) ? "is-live" : "",
        readexToolItemIsFailed(item) ? "is-failed" : "",
        "is-preview"
      ].filter(Boolean).join(" ");
      row.setAttribute("aria-expanded", initiallyExpanded ? "true" : "false");
      appendReadexToolAvatarOrIcon(row, item);

      const textWrap = document.createElement("span");
      textWrap.className = "readex-tool-activity-item-text";

      const label = document.createElement("span");
      label.className = "readex-tool-activity-item-title";
      renderReadexToolItemTitle(label, item);
      textWrap.appendChild(label);
      row.appendChild(textWrap);
      appendReadexCollabAgentOpenChip(row, item);

      const chevron = document.createElement("span");
      chevron.className = "readex-tool-activity-item-chevron";
      chevron.innerHTML = makeIcon("chevron-right");
      row.appendChild(chevron);

      const nested = document.createElement("div");
      nested.className = "readex-tool-activity-nested";
      nested.hidden = !initiallyExpanded;

      libraryPreviews.forEach((preview, previewIndex) => {
        appendReadexLibraryTreePreview(nested, preview, {
          owner: stateOwner,
          baseKey: `${disclosureKey}:preview:${previewIndex}:${readexPreviewStableKey(preview)}`
        });
      });

      otherPreviews.forEach((preview) => {
        appendReadexToolPreviewItem(nested, item, preview);
      });

      row.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        const expanded = row.getAttribute("aria-expanded") === "true";
        const nextExpanded = !expanded;
        row.setAttribute("aria-expanded", nextExpanded ? "true" : "false");
        setReadexNestedDisclosureExpanded(stateOwner, disclosureKey, nextExpanded);
        cancelReadexAncestorDisclosureAnimations(nested);
        animateReadexDisclosureElement(nested, nextExpanded, { hideOnFinish: true, reserveLayout: true });
      });

      wrapper.appendChild(row);
      wrapper.appendChild(nested);
      details.appendChild(wrapper);
    }

    function readexActivityItemType(item) {
      const type = trimmed(item?.type);
      if (type === "operation_summary") {
        return "operation_summary";
      }
      if (type === "progress") {
        return "progress";
      }
      if (type === "main_text") {
        return "main_text";
      }
      if (type === "video_progress") {
        return "video_progress";
      }
      if (type === "web-search" || type === "webSearch" || type === "web_search") {
        return "web-search";
      }
      if (type === "mcpToolCall" || type === "mcp_tool_call") {
        return "tool";
      }
      return normalizedReadexToolName(readexToolItemName(item)) === "web_search" ? "web-search" : "tool";
    }

    function readexActivityItemStatus(item, type) {
      const status = normalizedReadexStatus(item?.status);
      if (status) {
        return status;
      }
      if (trimmed(item?.error)) {
        return "failed";
      }
      if (type === "progress") {
        return "success";
      }
      return "";
    }

    function readexActivityItemIsLiveFromFields(item, status, durationMilliseconds) {
      if (item?.completed === true) {
        return false;
      }
      if (item?.completed === false) {
        return true;
      }
      if (status) {
        return status === "pending" || status === "processing" || status === "streaming" || status === "searching";
      }
      return !Number.isFinite(durationMilliseconds);
    }

    function readexActivitySearchQueries(item) {
      const queries = normalizedStringArray(item?.searchQueries);
      const query = trimmed(item?.query);
      if (query && !queries.includes(query)) {
        return [query].concat(queries);
      }
      return queries;
    }

    function readexActivityShellExecution(item) {
      const shellExecution = item?.shellExecution;
      if (!shellExecution || typeof shellExecution !== "object" || Array.isArray(shellExecution)) {
        return null;
      }
      const command = trimmed(shellExecution.command);
      const output = typeof shellExecution.output === "string" ? shellExecution.output : "";
      const rawOutput = typeof shellExecution.rawOutput === "string" ? shellExecution.rawOutput : "";
      if (!command && !output && !rawOutput) {
        return null;
      }
      const exitCode = Number(shellExecution.exitCode);
      const wallTimeSeconds = Number(shellExecution.wallTimeSeconds);
      return {
        command,
        cwd: trimmed(shellExecution.cwd),
        kind: trimmed(shellExecution.kind) || "unknown",
        target: trimmed(shellExecution.target),
        query: trimmed(shellExecution.query),
        exitCode: Number.isFinite(exitCode) ? exitCode : null,
        wallTimeSeconds: Number.isFinite(wallTimeSeconds) ? wallTimeSeconds : null,
        output,
        rawOutput
      };
    }

    function readexNormalizedCommandActionType(value) {
      const type = trimmed(value).replace(/[\s-]+/g, "_");
      switch (type) {
        case "read":
        case "search":
        case "list_files":
        case "unknown":
          return type;
        case "listFiles":
        case "listfiles":
          return "list_files";
        default:
          return type || "unknown";
      }
    }

    function readexActivityCommandExecution(item) {
      const commandExecution = item?.commandExecution;
      if (!commandExecution || typeof commandExecution !== "object" || Array.isArray(commandExecution)) {
        return null;
      }
      const command = trimmed(commandExecution.command);
      const aggregatedOutput = typeof commandExecution.aggregatedOutput === "string"
        ? commandExecution.aggregatedOutput
        : "";
      if (!command && !aggregatedOutput) {
        return null;
      }
      const exitCode = Number(commandExecution.exitCode);
      const wallTimeSeconds = Number(commandExecution.wallTimeSeconds);
      const commandActions = (Array.isArray(commandExecution.commandActions) ? commandExecution.commandActions : [])
        .map((action) => ({
          type: readexNormalizedCommandActionType(action?.type),
          command: trimmed(action?.command) || command,
          name: trimmed(action?.name),
          path: trimmed(action?.path),
          query: trimmed(action?.query)
        }));
      return {
        id: trimmed(commandExecution.id),
        callID: trimmed(commandExecution.callID || commandExecution.callId),
        cwd: trimmed(commandExecution.cwd),
        command,
        commandActions,
        aggregatedOutput,
        exitCode: Number.isFinite(exitCode) ? exitCode : null,
        status: normalizedReadexStatus(commandExecution.status),
        wallTimeSeconds: Number.isFinite(wallTimeSeconds) ? wallTimeSeconds : null
      };
    }

    function readexCommandExecutionPrimaryAction(execution) {
      const action = Array.isArray(execution?.commandActions) ? execution.commandActions[0] : null;
      if (action) {
        return {
          type: readexNormalizedCommandActionType(action.type),
          command: trimmed(action.command) || trimmed(execution?.command),
          name: trimmed(action.name),
          path: trimmed(action.path),
          query: trimmed(action.query)
        };
      }
      return {
        type: "unknown",
        command: trimmed(execution?.command),
        name: "",
        path: "",
        query: ""
      };
    }

    function readexCommandExecutionIsLive(execution) {
      const status = normalizedReadexStatus(execution?.status);
      if (status) {
        return status === "pending" || status === "processing" || status === "streaming" || status === "searching";
      }
      return execution?.exitCode == null;
    }

    function readexCommandExecutionIsFailed(execution) {
      const status = normalizedReadexStatus(execution?.status);
      return status === "failed" || (execution?.exitCode != null && execution.exitCode !== 0);
    }

    function readexCommandExecutionSummaryText(execution, fallbackText = "") {
      if (!execution) {
        return trimmed(fallbackText);
      }
      if (readexCommandExecutionIsFailed(execution)) {
        return "资料库命令执行失败";
      }
      const action = readexCommandExecutionPrimaryAction(execution);
      const isLive = readexCommandExecutionIsLive(execution);
      const target = action.path || action.name || "";
      switch (action.type) {
        case "read":
          return isLive
            ? `正在读取 ${target || "文本文件"}`
            : `已读取 ${target || "文本文件"}`;
        case "search":
          if (action.query && target) {
            return isLive ? `正在 ${target} 搜索“${action.query}”` : `已在 ${target} 搜索“${action.query}”`;
          }
          if (action.query) {
            return isLive ? `正在搜索“${action.query}”` : `已搜索“${action.query}”`;
          }
          return isLive ? "正在搜索资料库" : "已搜索资料库";
        case "list_files":
          return isLive
            ? `正在查看 ${target || "资料库"}`
            : `已查看 ${target || "资料库"}`;
        default:
          return trimmed(fallbackText) || (isLive ? "正在执行资料库命令" : "已执行资料库命令");
      }
    }

    function readexShellExecutionFromCommandExecution(execution) {
      if (!execution) {
        return null;
      }
      const action = readexCommandExecutionPrimaryAction(execution);
      const command = trimmed(execution.command) || trimmed(action.command);
      const output = typeof execution.aggregatedOutput === "string" ? execution.aggregatedOutput : "";
      if (!command && !output) {
        return null;
      }
      return {
        command,
        cwd: trimmed(execution.cwd),
        kind: action.type || "unknown",
        target: trimmed(action.path || action.name),
        query: trimmed(action.query),
        exitCode: execution.exitCode,
        wallTimeSeconds: execution.wallTimeSeconds,
        output,
        rawOutput: ""
      };
    }

    function readexPreviewIsExtractedPDF(preview) {
      return trimmed(preview?.attachmentKind) === "extractedPDF";
    }

    function readexExtractedPDFPreviewItems(previewItems) {
      const previews = Array.isArray(previewItems) ? previewItems : [];
      return previews.filter(readexPreviewIsExtractedPDF);
    }

    function readexVideoFramePreviewItems(previewItems) {
      const previews = Array.isArray(previewItems) ? previewItems : [];
      return previews.filter(readexPreviewIsVideoFrame);
    }

    function readexPreviewIsVideoDownloadProgress(preview) {
      return trimmed(preview?.kind) === "video_download_progress"
        || trimmed(preview?.payload?.type) === "video_download_progress";
    }

    function readexVideoDownloadProgressPreviewItems(previewItems) {
      const previews = Array.isArray(previewItems) ? previewItems : [];
      return previews.filter(readexPreviewIsVideoDownloadProgress);
    }

    function readexVideoDownloadProgressSourceFromPreview(preview, item = null) {
      if (!readexPreviewIsVideoDownloadProgress(preview)) {
        return null;
      }
      const payload = preview?.payload && typeof preview.payload === "object" ? preview.payload : {};
      const source = {
        ...payload,
        id: trimmed(payload.id) || trimmed(preview?.id) || trimmed(item?.id),
        sourceBlockId: trimmed(payload.sourceBlockId)
          || trimmed(payload.sourceBlockID)
          || trimmed(preview?.id)
          || trimmed(item?.sourceBlockId)
          || trimmed(item?.sourceBlockID)
          || trimmed(item?.id),
        text: trimmed(payload.text) || trimmed(preview?.title) || trimmed(item?.text) || "正在下载视频",
        subtitleText: trimmed(payload.subtitleText) || trimmed(preview?.subtitle) || trimmed(item?.subtitleText),
        detailText: trimmed(payload.detailText) || trimmed(item?.detailText),
        status: normalizedReadexStatus(payload.status) || normalizedReadexStatus(item?.status) || "processing",
        phase: trimmed(payload.phase),
        phaseTitle: trimmed(payload.phaseTitle),
        summaryParts: Array.isArray(payload.summaryParts) ? payload.summaryParts : [],
        items: Array.isArray(payload.items) ? payload.items : []
      };
      [
        "durationMilliseconds",
        "startedAtMilliseconds",
        "progress",
        "progressUpdatedAtMilliseconds",
        "progressRatePerSecond",
        "batchCurrentItemIndex",
        "batchCompletedItemCount",
        "batchTotalItemCount",
        "batchProgress"
      ].forEach((key) => {
        const value = Number(payload[key]);
        source[key] = Number.isFinite(value) ? value : null;
      });
      return source;
    }

    function readexVideoDownloadProgressSource(item, previewItems) {
      const previews = readexVideoDownloadProgressPreviewItems(previewItems);
      if (!previews.length) {
        return null;
      }
      return readexVideoDownloadProgressSourceFromPreview(previews[previews.length - 1], item);
    }

    function readexVideoDownloadProgressActivityDisplayText(item, options = {}) {
      if (options?.insideOperationSummary === true) {
        return "";
      }
      const previewItems = Array.isArray(options?.previewItems)
        ? options.previewItems
        : readexPreviewItems(item?.previewItems);
      const source = readexVideoDownloadProgressSource(item, previewItems);
      if (!source) {
        return "";
      }
      return trimmed(source.text) || "正在下载视频";
    }

    function readexPreviewItemsAreExtractedPDF(previewItems) {
      const previews = Array.isArray(previewItems) ? previewItems : [];
      return previews.length > 0
        && previews.every(readexPreviewIsExtractedPDF);
    }

    function readexPreviewItemsHaveVideoFrames(previewItems) {
      return readexVideoFramePreviewItems(previewItems).length > 0;
    }

    function readexExtractedPDFDocumentName(preview) {
      const documentName = trimmed(preview?.documentName);
      if (documentName) {
        return documentName;
      }
      const subtitle = trimmed(preview?.subtitle);
      if (subtitle.startsWith("《") && subtitle.endsWith("》") && subtitle.length > 2) {
        return trimmed(subtitle.slice(1, -1));
      }
      const fileName = trimmed(preview?.fileName);
      if (!fileName) {
        return "";
      }
      const lastComponent = fileName.split(/[\\/]/u).filter(Boolean).pop() || fileName;
      return trimmed(lastComponent.replace(/\.[^.]+$/u, ""));
    }

    function readexExtractedPDFRangeLabelsFromPayload(preview) {
      const payload = preview?.payload && typeof preview.payload === "object" ? preview.payload : null;
      if (!payload) {
        return [];
      }
      const labels = normalizedStringArray(payload.extractedRanges || payload.extractedPageRangeLabels)
        .filter((label) => label.toLowerCase() !== "none");
      return labels;
    }

    function readexExtractedPDFPageCountFromPreviewItems(previewItems) {
      const extractedPDFItems = readexExtractedPDFPreviewItems(previewItems);
      const counts = extractedPDFItems
        .map((preview) => Number(preview?.payload?.extractedPageCount))
        .filter((count) => Number.isFinite(count) && count > 0);
      if (counts.length) {
        return counts.reduce((sum, count) => sum + count, 0);
      }
      return readexExtractedPageCountFromLabels(readexExtractedPageRangeLabels(extractedPDFItems));
    }

    function readexExtractedPDFPreviewDisplayText(previewItems) {
      const previews = readexExtractedPDFPreviewItems(previewItems);
      const documentNames = [];
      const seenDocumentNames = new Set();
      previews.map(readexExtractedPDFDocumentName).filter(Boolean).forEach((name) => {
        if (!seenDocumentNames.has(name)) {
          seenDocumentNames.add(name);
          documentNames.push(name);
        }
      });
      const labels = previews
        .flatMap((preview) => {
          const payloadLabels = readexExtractedPDFRangeLabelsFromPayload(preview);
          return payloadLabels.length ? payloadLabels : [readexExtractedPageRangeLabel(preview)];
        })
        .map((label) => trimmed(label).replace(/^书页\s*/u, ""))
        .filter(Boolean);
      const labelText = labels.length ? ` ${labels.join("、")}` : "";
      const pageCount = readexExtractedPDFPageCountFromPreviewItems(previews);
      const pageCountText = pageCount > 0 ? `（${pageCount} 页）` : "";
      if (documentNames.length === 1) {
        return `已查看《${documentNames[0]}》书页${labelText}${pageCountText}`;
      }
      if (documentNames.length > 1) {
        return `已查看${documentNames.length}篇文档的 PDF 页面`;
      }
      return `已查看 PDF 页面${pageCountText}`;
    }

    function readexExtractedPDFActivityDisplayText(item, options = {}) {
      if (options?.insideOperationSummary === true) {
        return "";
      }
      if (normalizedReadexStatus(item?.status) === "failed" || trimmed(item?.error)) {
        return "";
      }
      const commandExecution = options?.commandExecution || readexActivityCommandExecution(item);
      if (commandExecution && readexCommandExecutionIsFailed(commandExecution)) {
        return "";
      }
      const previewItems = Array.isArray(options?.previewItems)
        ? options.previewItems
        : readexPreviewItems(item?.previewItems);
      const extractedPDFItems = readexExtractedPDFPreviewItems(previewItems);
      const rawText = trimmed(item?.text);
      if (extractedPDFItems.length > 0) {
        if (readexToolTextLooksLikeExtractedPDFPageLookup(rawText)) {
          return readexToolDisplayText(rawText, extractedPDFItems);
        }
        return readexExtractedPDFPreviewDisplayText(extractedPDFItems);
      }
      return "";
    }

    function readexVideoFrameActivityDisplayText(item, options = {}) {
      if (options?.insideOperationSummary === true) {
        return "";
      }
      if (normalizedReadexStatus(item?.status) === "failed" || trimmed(item?.error)) {
        return "";
      }
      const commandExecution = options?.commandExecution || readexActivityCommandExecution(item);
      if (commandExecution && readexCommandExecutionIsFailed(commandExecution)) {
        return "";
      }
      const previewItems = Array.isArray(options?.previewItems)
        ? options.previewItems
        : readexPreviewItems(item?.previewItems);
      const videoFrameItems = readexVideoFramePreviewItems(previewItems);
      if (!videoFrameItems.length) {
        return "";
      }
      const frameCount = videoFrameItems.length;
      return frameCount > 0 ? `已抽取当前视频帧（${frameCount} 张）` : "已抽取当前视频帧";
    }

    function readexPreviewPresentationKind(preview) {
      if (readexPreviewIsExtractedPDF(preview)) {
        return "extractedPDF";
      }
      if (readexPreviewIsVideoFrame(preview)) {
        return "videoFrame";
      }
      if (readexPreviewIsVideoDownloadProgress(preview)) {
        return "videoDownloadProgress";
      }
      return "";
    }

    function readexPreviewPresentationGroups(previewItems) {
      const groups = [];
      (Array.isArray(previewItems) ? previewItems : []).forEach((preview) => {
        const kind = readexPreviewPresentationKind(preview);
        if (!kind) {
          return;
        }
        let group = groups.find((candidate) => candidate.kind === kind);
        if (!group) {
          group = { kind, previewItems: [] };
          groups.push(group);
        }
        group.previewItems.push(preview);
      });
      return groups;
    }

    function readexPreviewPresentationGroupedPreviews(groups) {
      const groupedPreviews = new Set();
      (Array.isArray(groups) ? groups : []).forEach((group) => {
        (Array.isArray(group?.previewItems) ? group.previewItems : []).forEach((preview) => {
          groupedPreviews.add(preview);
        });
      });
      return groupedPreviews;
    }

    function readexPreviewPresentationShouldSplit(groups, remainingPreviews) {
      const safeGroups = Array.isArray(groups) ? groups : [];
      const safeRemainingPreviews = Array.isArray(remainingPreviews) ? remainingPreviews : [];
      return safeGroups.length > 1 || (safeGroups.length > 0 && safeRemainingPreviews.length > 0);
    }

    function readexPreviewPresentationShouldKeepBaseItem(item, remainingPreviews) {
      if (Array.isArray(remainingPreviews) && remainingPreviews.length > 0) {
        return true;
      }
      if (readexActivityCommandExecution(item) || readexActivityShellExecution(item)) {
        return true;
      }
      if (trimmed(item?.detailText)) {
        return true;
      }
      return Array.isArray(item?.childItems) && item.childItems.length > 0;
    }

    function readexPreviewPresentationSourceID(item, kind) {
      const baseID = trimmed(item?.id)
        || trimmed(item?.sourceBlockID || item?.sourceBlockId)
        || trimmed(item?.toolCallID || item?.toolCallId)
        || "readex-preview";
      return `${baseID}:preview:${kind}`;
    }

    function readexPreviewPresentationSourceBlockID(item, kind) {
      const baseID = trimmed(item?.sourceBlockID || item?.sourceBlockId)
        || trimmed(item?.id)
        || "readex-preview";
      return `${baseID}:preview:${kind}`;
    }

    function readexPreviewPresentationText(item, group, options = {}) {
      if (!group || !Array.isArray(group.previewItems) || !group.previewItems.length) {
        return "";
      }
      switch (group.kind) {
        case "extractedPDF":
          return readexExtractedPDFActivityDisplayText(item, {
            ...options,
            previewItems: group.previewItems
          });
        case "videoFrame":
          return readexVideoFrameActivityDisplayText(item, {
            ...options,
            previewItems: group.previewItems
          });
        case "videoDownloadProgress":
          return readexVideoDownloadProgressActivityDisplayText(item, {
            ...options,
            previewItems: group.previewItems
          });
        default:
          return "";
      }
    }

    function readexPreviewPresentationSourceItem(item, group, options = {}) {
      const kind = trimmed(group?.kind);
      const text = readexPreviewPresentationText(item, group, options);
      if (!kind || !text) {
        return null;
      }
      const sourceBlockID = readexPreviewPresentationSourceBlockID(item, kind);
      return {
        ...item,
        id: readexPreviewPresentationSourceID(item, kind),
        sourceBlockID,
        sourceBlockId: sourceBlockID,
        type: "preview",
        tool: "",
        name: "",
        toolName: "",
        readexToolName: "",
        text,
        detailText: "",
        previewItems: group.previewItems,
        childItems: [],
        commandExecution: null,
        shellExecution: null
      };
    }

    function readexPreviewPresentationBaseSourceItem(item, remainingPreviews) {
      const commandExecution = readexActivityCommandExecution(item);
      const base = {
        ...item,
        previewItems: Array.isArray(remainingPreviews) ? remainingPreviews : []
      };
      if (!base.previewItems.length && commandExecution) {
        const summaryText = readexCommandExecutionSummaryText(commandExecution, trimmed(item?.text));
        if (summaryText) {
          base.text = summaryText;
        }
      }
      return base;
    }

    function readexPreviewPresentationExpandedSourceItems(item, options = {}) {
      if (options?.insideOperationSummary === true) {
        return [item];
      }

      const sourcePreviewItems = readexPreviewItems(item?.previewItems);
      const groups = readexPreviewPresentationGroups(sourcePreviewItems);
      const groupedPreviews = readexPreviewPresentationGroupedPreviews(groups);
      const remainingPreviews = sourcePreviewItems.filter((preview) => !groupedPreviews.has(preview));
      if (!readexPreviewPresentationShouldSplit(groups, remainingPreviews)) {
        return [item];
      }

      const sourceItems = [];
      if (readexPreviewPresentationShouldKeepBaseItem(item, remainingPreviews)) {
        sourceItems.push(readexPreviewPresentationBaseSourceItem(item, remainingPreviews));
      }
      groups.forEach((group) => {
        const previewItem = readexPreviewPresentationSourceItem(item, group, options);
        if (previewItem) {
          sourceItems.push(previewItem);
        }
      });
      return sourceItems.length ? sourceItems : [item];
    }

    function readexActivityToolText(item, options = {}) {
      const text = trimmed(item?.text);
      const commandExecution = options?.commandExecution || readexActivityCommandExecution(item);
      const extractedPDFText = readexExtractedPDFActivityDisplayText(item, {
        commandExecution,
        previewItems: options?.previewItems,
        isLive: options?.isLive,
        insideOperationSummary: options?.insideOperationSummary
      });
      if (extractedPDFText) {
        return extractedPDFText;
      }
      const videoFrameText = readexVideoFrameActivityDisplayText(item, {
        commandExecution,
        previewItems: options?.previewItems,
        isLive: options?.isLive,
        insideOperationSummary: options?.insideOperationSummary
      });
      if (videoFrameText) {
        return videoFrameText;
      }
      const videoDownloadProgressText = readexVideoDownloadProgressActivityDisplayText(item, {
        commandExecution,
        previewItems: options?.previewItems,
        isLive: options?.isLive,
        insideOperationSummary: options?.insideOperationSummary
      });
      if (videoDownloadProgressText) {
        return videoDownloadProgressText;
      }
      if (commandExecution) {
        const summaryText = readexCommandExecutionSummaryText(commandExecution, text);
        if (summaryText) {
          return summaryText;
        }
      }
      if (text) {
        return text;
      }
      const toolName = readexToolItemName(item);
      const serverName = trimmed(item?.server);
      if (toolName && serverName) {
        return `${serverName}.${toolName}`;
      }
      return toolName || serverName;
    }

    function normalizedReadexActivityItems(item, options = {}) {
      return readexPreviewPresentationExpandedSourceItems(item, options)
        .map((sourceItem) => normalizedReadexActivityItem(sourceItem, options))
        .filter(Boolean);
    }

    function normalizedReadexActivityItem(item, options = {}) {
      const type = readexActivityItemType(item);
      const searchQueries = readexActivitySearchQueries(item);
      const searchReferences = Array.isArray(item?.searchReferences) ? item.searchReferences : [];
      const webSearchActions = Array.isArray(item?.webSearchActions) ? item.webSearchActions : [];
      const commandExecution = readexActivityCommandExecution(item);
      const durationMilliseconds = readexDurationMilliseconds(item);
      const status = readexActivityItemStatus(item, type);
      const isLive = readexActivityItemIsLiveFromFields(item, status, durationMilliseconds);
      const sourcePreviewItems = readexPreviewItems(item?.previewItems);
      const insideOperationSummary = options?.insideOperationSummary === true;
      const videoDownloadProgressSource = type === "tool" && !insideOperationSummary
        ? readexVideoDownloadProgressSource(item, sourcePreviewItems)
        : null;
      const extractedPDFText = type === "tool"
        ? readexExtractedPDFActivityDisplayText(item, {
          commandExecution,
          previewItems: sourcePreviewItems,
          isLive,
          insideOperationSummary
        })
        : "";
      const videoFrameText = type === "tool"
        ? readexVideoFrameActivityDisplayText(item, {
          commandExecution,
          previewItems: sourcePreviewItems,
          isLive,
          insideOperationSummary
        })
        : "";
      const videoDownloadProgressText = videoDownloadProgressSource
        ? (trimmed(videoDownloadProgressSource.text) || "正在下载视频")
        : "";
      const rawText = type === "tool"
        ? (extractedPDFText || videoFrameText || videoDownloadProgressText || readexActivityToolText(item, {
          commandExecution,
          previewItems: sourcePreviewItems,
          isLive,
          insideOperationSummary
        }))
        : trimmed(item?.text);
      const effectiveType = videoDownloadProgressSource ? "video_progress" : type;
      const effectiveStatus = videoDownloadProgressSource
        ? (normalizedReadexStatus(videoDownloadProgressSource.status) || status)
        : status;
      const effectiveDurationMilliseconds = videoDownloadProgressSource
        && Number.isFinite(Number(videoDownloadProgressSource.durationMilliseconds))
        ? Number(videoDownloadProgressSource.durationMilliseconds)
        : durationMilliseconds;
      const effectiveIsLive = videoDownloadProgressSource
        ? readexActivityItemIsLiveFromFields(
          videoDownloadProgressSource,
          effectiveStatus,
          effectiveDurationMilliseconds
        )
        : isLive;
      const videoProgressItems = effectiveType === "video_progress"
        ? (videoDownloadProgressSource
          ? (Array.isArray(videoDownloadProgressSource.items) ? videoDownloadProgressSource.items : [])
          : (Array.isArray(item?.items) ? item.items : (Array.isArray(item?.childItems) ? item.childItems : [])))
        : [];
      const hasVideoProgressPayload = effectiveType === "video_progress"
        && (
          videoProgressItems.length > 0
          || trimmed(videoDownloadProgressSource?.detailText || item?.detailText)
          || trimmed(videoDownloadProgressSource?.subtitleText || item?.subtitleText)
          || Number.isFinite(Number(videoDownloadProgressSource?.progress ?? item?.progress))
          || Number.isFinite(Number(videoDownloadProgressSource?.batchCompletedItemCount ?? item?.batchCompletedItemCount))
        );
      if (!rawText && effectiveType !== "web-search" && !hasVideoProgressPayload) {
        return null;
      }

      const baseText = rawText || (
        effectiveType === "web-search"
          ? readexWebSearchSummaryText(searchQueries, searchReferences, effectiveIsLive)
          : ""
      );
      const previewItems = expandedReadexKnowledgeMapPreviewItems(
        baseText,
        sourcePreviewItems
      );
      const progress = Number(videoDownloadProgressSource?.progress ?? item?.progress);

      const childItems = effectiveType === "video_progress"
        ? []
        : (Array.isArray(item?.childItems)
          ? item.childItems
            .flatMap((childItem) => normalizedReadexActivityItems(childItem, {
              insideOperationSummary: insideOperationSummary || effectiveType === "operation_summary"
            }))
            .filter(Boolean)
          : []);
      const displayedChildItems = effectiveType === "operation_summary"
        ? childItems.filter(readexActivityItemIsOperationSummaryChild)
        : childItems;
      const usesPreviewPresentation = Boolean(extractedPDFText || videoFrameText || videoDownloadProgressSource);
      const renderedWebSearchActions = insideOperationSummary && effectiveType === "web-search"
        ? deduplicatedOperationSummaryWebSearchActions(item, webSearchActions)
        : webSearchActions;
      const renderedWebSearchAction = insideOperationSummary && effectiveType === "web-search"
        ? (renderedWebSearchActions[0] || item?.action || item?.webSearchAction || null)
        : (item?.action || item?.webSearchAction || webSearchActions[0] || null);

      return readexToolItemWithModelTaskChildren({
        id: trimmed(videoDownloadProgressSource?.id) || trimmed(item?.id) || trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID),
        sourceBlockId: trimmed(videoDownloadProgressSource?.sourceBlockId) || trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID),
        type: effectiveType,
        text: effectiveType === "tool" ? readexToolDisplayText(baseText, previewItems) : baseText,
        query: trimmed(item?.query) || searchQueries[0] || "",
        action: renderedWebSearchAction,
        completed: !effectiveIsLive,
        detailText: videoDownloadProgressSource
          ? trimmed(videoDownloadProgressSource.detailText)
          : (usesPreviewPresentation ? "" : trimmed(item?.detailText)),
        subtitleText: videoDownloadProgressSource
          ? trimmed(videoDownloadProgressSource.subtitleText)
          : trimmed(item?.subtitleText),
        progress: Number.isFinite(progress) ? progress : null,
        progressUpdatedAtMilliseconds: Number.isFinite(Number(videoDownloadProgressSource?.progressUpdatedAtMilliseconds ?? item?.progressUpdatedAtMilliseconds)) ? Number(videoDownloadProgressSource?.progressUpdatedAtMilliseconds ?? item.progressUpdatedAtMilliseconds) : null,
        progressRatePerSecond: Number.isFinite(Number(videoDownloadProgressSource?.progressRatePerSecond ?? item?.progressRatePerSecond)) ? Number(videoDownloadProgressSource?.progressRatePerSecond ?? item.progressRatePerSecond) : null,
        batchCurrentItemIndex: Number.isFinite(Number(videoDownloadProgressSource?.batchCurrentItemIndex ?? item?.batchCurrentItemIndex)) ? Number(videoDownloadProgressSource?.batchCurrentItemIndex ?? item.batchCurrentItemIndex) : null,
        batchCompletedItemCount: Number.isFinite(Number(videoDownloadProgressSource?.batchCompletedItemCount ?? item?.batchCompletedItemCount)) ? Number(videoDownloadProgressSource?.batchCompletedItemCount ?? item.batchCompletedItemCount) : null,
        batchTotalItemCount: Number.isFinite(Number(videoDownloadProgressSource?.batchTotalItemCount ?? item?.batchTotalItemCount)) ? Number(videoDownloadProgressSource?.batchTotalItemCount ?? item.batchTotalItemCount) : null,
        batchProgress: Number.isFinite(Number(videoDownloadProgressSource?.batchProgress ?? item?.batchProgress)) ? Number(videoDownloadProgressSource?.batchProgress ?? item.batchProgress) : null,
        items: videoProgressItems,
        phase: trimmed(videoDownloadProgressSource?.phase) || trimmed(item?.phase),
        phaseTitle: trimmed(videoDownloadProgressSource?.phaseTitle) || trimmed(item?.phaseTitle),
        summaryParts: videoDownloadProgressSource
          ? (Array.isArray(videoDownloadProgressSource.summaryParts) ? videoDownloadProgressSource.summaryParts : [])
          : (Array.isArray(item?.summaryParts) ? item.summaryParts : []),
        previewItems,
        childItems: displayedChildItems,
        server: trimmed(item?.server),
        arguments: item?.arguments ?? null,
        result: item?.result ?? null,
        error: trimmed(item?.error),
        toolName: readexToolItemName(item),
        toolBatchId: readexToolItemBatchID(item),
        status: effectiveStatus,
        durationMilliseconds: effectiveDurationMilliseconds,
        searchQueries,
        searchReferences,
        webSearchActions: renderedWebSearchActions,
        webSearchAction: insideOperationSummary && effectiveType === "web-search"
          ? renderedWebSearchAction
          : item?.webSearchAction || null,
        webSearchReference: item?.webSearchReference || null,
        reference: item?.reference || null,
        shellExecution: usesPreviewPresentation
          ? null
          : readexActivityShellExecution(item) || readexShellExecutionFromCommandExecution(commandExecution),
        commandExecution: usesPreviewPresentation ? null : commandExecution
      });
    }

    function readexActivityItemIsOperationSummaryChild(item) {
      return item?.type !== "progress"
        && item?.type !== "main_text"
        && item?.type !== "video_progress"
        && item?.type !== "operation_summary";
    }

    function readexActivityItems(block) {
      if (!Array.isArray(block?.items)) {
        return [];
      }
      const items = block.items
        .flatMap((item) => normalizedReadexActivityItems(item))
        .filter(Boolean);
      return groupReadexToolItems(items);
    }

    function readexToolItems(block) {
      return readexActivityItems(block);
    }

    function readexActivityItemBypassesToolGrouping(item) {
      return item?.type === "progress"
        || item?.type === "main_text"
        || item?.type === "video_progress"
        || item?.type === "operation_summary";
    }

    function groupReadexToolItems(items) {
      const output = [];
      let pendingToolItems = [];

      const flushToolItems = () => {
        if (!pendingToolItems.length) {
          return;
        }
        output.push(...groupReadexAdjacentPreviewItems(
          groupReadexBatchedPreviewItems(
            groupReadexTextReadRangeItems(groupReadexWebSearchItems(groupReadexSavedAnswerWriteItems(pendingToolItems)))
          )
        ));
        pendingToolItems = [];
      };

      (Array.isArray(items) ? items : []).forEach((item) => {
        if (readexActivityItemBypassesToolGrouping(item)) {
          flushToolItems();
          output.push(item);
          return;
        }
        pendingToolItems.push(item);
      });
      flushToolItems();
      return output;
    }

    function readexToolItemIsWebSearch(item) {
      return item?.type === "web-search"
        || item?.type === "webSearch"
        || item?.type === "web_search"
        || normalizedReadexToolName(readexToolItemName(item)) === "web_search";
    }

    function readexToolItemIsWebSearchGroup(item) {
      return Boolean(item?.isWebSearchGroup) || readexToolItemIsWebSearch(item);
    }

    function readexWebSearchSummaryText(queries, references, isProcessing) {
      return isProcessing
        ? "正在搜索网页"
        : `已搜索网页 ${readexWebSearchActivityCount(queries, references)} 次`;
    }

    function readexWebSearchActivityCount(queries, references) {
      const referenceCount = Array.isArray(references) ? references.length : 0;
      if (referenceCount > 0) {
        return referenceCount;
      }
      const queryCount = normalizedStringArray(queries).length;
      return Math.max(1, queryCount);
    }

    function readexWebSearchReferenceKey(reference) {
      return trimmed(reference?.url)
        || trimmed(reference?.title)
        || trimmed(reference?.content);
    }

    function mergedReadexWebSearchReferences(items) {
      const output = [];
      const seen = new Set();
      (Array.isArray(items) ? items : []).forEach((item) => {
        const references = [];
        if (item?.webSearchReference) {
          references.push(item.webSearchReference);
        }
        if (item?.type === "web-search" && item?.reference) {
          references.push(item.reference);
        }
        if (Array.isArray(item?.searchReferences)) {
          references.push(...item.searchReferences);
        }
        references.forEach((reference) => {
          const key = readexWebSearchReferenceKey(reference);
          if (!key || seen.has(key)) {
            return;
          }
          seen.add(key);
          output.push(reference);
        });
      });
      return output;
    }

    function mergedReadexWebSearchQueries(items) {
      const queries = [];
      (Array.isArray(items) ? items : []).forEach((item) => {
        queries.push(trimmed(item?.query));
        queries.push(...normalizedStringArray(item?.searchQueries));
      });
      return normalizedStringArray(queries);
    }

    function readexActivityActionType(action) {
      const type = trimmed(action?.type);
      if (type === "open_page") {
        return "openPage";
      }
      if (type === "find_in_page") {
        return "findInPage";
      }
      return type;
    }

    function readexActivityActionQueries(action) {
      return normalizedStringArray(action?.queries);
    }

    function readexActivityActionKey(action) {
      return [
        readexActivityActionType(action),
        trimmed(action?.query),
        readexActivityActionQueries(action).join("\u{1e}"),
        trimmed(action?.url),
        trimmed(action?.pattern)
      ].join("\u{1f}");
    }

    function readexWebSearchActionKey(action) {
      return readexActivityActionKey(action);
    }

    function deduplicatedOperationSummaryWebSearchActions(item, webSearchActions) {
      const actions = [];
      if (item?.action) {
        actions.push(item.action);
      }
      if (item?.webSearchAction) {
        actions.push(item.webSearchAction);
      }
      if (Array.isArray(webSearchActions)) {
        actions.push(...webSearchActions);
      }

      const output = [];
      const indexesByKey = new Map();
      const fallbackQuery = normalizedStringArray(item?.searchQueries)[0] || trimmed(item?.query);
      actions.forEach((action) => {
        const key = [
          readexActivityActionType(action),
          readexActivityActionDetail(action, fallbackQuery),
          trimmed(action?.url),
          trimmed(action?.pattern)
        ].join("\u{1f}");
        if (!key.replace(/\u{1f}/gu, "").trim()) {
          return;
        }
        const existingIndex = indexesByKey.get(key);
        if (existingIndex != null) {
          output[existingIndex] = mergedOperationSummaryWebSearchAction(output[existingIndex], action);
          return;
        }
        indexesByKey.set(key, output.length);
        output.push(action);
      });
      return output;
    }

    function mergedOperationSummaryWebSearchAction(existing, incoming) {
      const merged = { ...(existing || {}) };
      if (!trimmed(merged.query) && trimmed(incoming?.query)) {
        merged.query = incoming.query;
      }
      if (readexActivityActionQueries(merged).length === 0) {
        const incomingQueries = readexActivityActionQueries(incoming);
        if (incomingQueries.length > 0) {
          merged.queries = incomingQueries;
        }
      }
      if (!trimmed(merged.url) && trimmed(incoming?.url)) {
        merged.url = incoming.url;
      }
      if (!trimmed(merged.pattern) && trimmed(incoming?.pattern)) {
        merged.pattern = incoming.pattern;
      }
      if (trimmed(incoming?.status)) {
        merged.status = incoming.status;
      }
      if (incoming?.completed === true || (incoming?.completed === false && merged.completed !== true)) {
        merged.completed = incoming.completed;
      }
      return merged;
    }

    function mergedReadexWebSearchActions(items) {
      const output = [];
      const seen = new Set();
      (Array.isArray(items) ? items : []).forEach((item) => {
        const actions = [];
        if (item?.webSearchAction) {
          actions.push(item.webSearchAction);
        }
        if (item?.action) {
          actions.push(item.action);
        }
        if (Array.isArray(item?.webSearchActions)) {
          actions.push(...item.webSearchActions);
        }
        actions.forEach((action) => {
          const key = readexWebSearchActionKey(action);
          if (!key || seen.has(key)) {
            return;
          }
          seen.add(key);
          output.push(action);
        });
      });
      return output;
    }

    function readexWebSearchActionsForLines(item) {
      if (Array.isArray(item?.webSearchActions) && item.webSearchActions.length > 0) {
        return item.webSearchActions;
      }
      if (item?.webSearchAction) {
        return [item.webSearchAction];
      }
      if (item?.action) {
        return [item.action];
      }
      return [];
    }

    function readexWebSearchGroupedChildItems(items) {
      return (Array.isArray(items) ? items : []).flatMap((item) => {
        const childItems = readexToolItemChildItems(item);
        if (childItems.length > 0) {
          return childItems;
        }
        return [];
      });
    }

    function groupReadexWebSearchItems(items) {
      const sourceItems = Array.isArray(items) ? items : [];
      const webSearchItems = sourceItems.filter(readexToolItemIsWebSearch);
      if (!webSearchItems.length) {
        return sourceItems;
      }

      const childItems = readexWebSearchGroupedChildItems(webSearchItems);
      const searchQueries = mergedReadexWebSearchQueries([].concat(webSearchItems, childItems));
      const searchReferences = mergedReadexWebSearchReferences([].concat(webSearchItems, childItems));
      const webSearchActions = mergedReadexWebSearchActions([].concat(webSearchItems, childItems));
      const hasLiveItem = webSearchItems.some(readexToolItemIsLive);
      const groupedItem = {
        ...webSearchItems[0],
        type: "web-search",
        text: "",
        query: searchQueries[0] || "",
        action: webSearchActions[0] || null,
        completed: !hasLiveItem,
        detailText: "",
        previewItems: [],
        childItems,
        toolName: "web_search",
        toolBatchId: "",
        status: hasLiveItem ? "processing" : "success",
        durationMilliseconds: hasLiveItem
          ? null
          : (webSearchItems
            .map((item) => Number(item.durationMilliseconds))
            .filter(Number.isFinite)
            .reduce((max, value) => Math.max(max, value), 0) || webSearchItems[0].durationMilliseconds),
        searchQueries,
        searchReferences,
        webSearchActions,
        isWebSearchGroup: true
      };
      groupedItem.text = readexWebSearchDisplaySummaryText(groupedItem);
      if (!readexWebSearchActivityShouldRender(groupedItem)) {
        return sourceItems.filter((item) => !readexToolItemIsWebSearch(item));
      }

      let didInsertGroup = false;
      return sourceItems
        .map((item) => {
          if (!readexToolItemIsWebSearch(item)) {
            return item;
          }
          if (didInsertGroup) {
            return null;
          }
          didInsertGroup = true;
          return groupedItem;
        })
        .filter(Boolean);
    }

    function readexToolItemIsSavedAnswerWrite(item) {
      const text = trimmed(item?.text);
      if (!text || readexToolCategory(item) !== "savedAnswer") {
        return false;
      }
      return text.includes("已保存 AI 回答到")
        || (text.includes("已更新") && text.includes("AI 回答"))
        || (text.includes("已跳过") && text.includes("AI 回答"));
    }

    function groupReadexSavedAnswerWriteItems(items) {
      const output = [];
      let pending = [];

      const flush = () => {
        if (!pending.length) {
          return;
        }
        if (pending.length === 1) {
          output.push(pending[0]);
        } else {
          output.push({
            ...pending[0],
            text: `已保存 AI 回答（${pending.length} 个）`,
            detailText: "",
            previewItems: [],
            childItems: pending,
            isSavedAnswerWriteGroup: true,
            status: pending.some(readexToolItemIsLive) ? "processing" : "success",
            durationMilliseconds: pending
              .map((item) => Number(item.durationMilliseconds))
              .filter(Number.isFinite)
              .reduce((max, value) => Math.max(max, value), 0) || pending[0].durationMilliseconds
          });
        }
        pending = [];
      };

      items.forEach((item) => {
        if (readexToolItemIsSavedAnswerWrite(item)) {
          pending.push(item);
          return;
        }
        flush();
        output.push(item);
      });
      flush();
      return output;
    }

    function readexToolItemTextReadRangeInfo(item) {
      if (normalizedReadexToolName(readexToolItemName(item)) !== "readex.read_text") {
        return null;
      }
      if (readexToolItemIsLive(item)) {
        return null;
      }
      const text = trimmed(item?.text);
      const match = /^已读取(.+?)\s+第\s+(\d+)(?:-(\d+))?\s+行$/u.exec(text);
      if (!match) {
        return null;
      }
      const path = trimmed(match[1]);
      const lineStart = Number(match[2]);
      const lineEnd = Number(match[3] || match[2]);
      if (!path || !Number.isFinite(lineStart) || !Number.isFinite(lineEnd) || lineStart <= 0 || lineEnd < lineStart) {
        return null;
      }
      return { path, lineStart, lineEnd };
    }

    function readexMergedLineRangeCount(infos) {
      const ranges = (Array.isArray(infos) ? infos : [])
        .filter(Boolean)
        .map((info) => [info.lineStart, info.lineEnd])
        .sort((left, right) => left[0] - right[0] || left[1] - right[1]);
      let count = 0;
      let currentStart = null;
      let currentEnd = null;
      ranges.forEach(([start, end]) => {
        if (currentStart === null) {
          currentStart = start;
          currentEnd = end;
          return;
        }
        if (start <= currentEnd + 1) {
          currentEnd = Math.max(currentEnd, end);
          return;
        }
        count += currentEnd - currentStart + 1;
        currentStart = start;
        currentEnd = end;
      });
      if (currentStart !== null) {
        count += currentEnd - currentStart + 1;
      }
      return count;
    }

    function readexTextReadRangeGroupSummary(items) {
      const infos = (Array.isArray(items) ? items : [])
        .map(readexToolItemTextReadRangeInfo)
        .filter(Boolean);
      const path = infos[0]?.path || "";
      const lineCount = readexMergedLineRangeCount(infos);
      const count = infos.length;
      return lineCount > 0
        ? `已读取${path} ${count} 处 · 共 ${lineCount} 行`
        : `已读取${path} ${count} 处`;
    }

    function groupReadexTextReadRangeItems(items) {
      const output = [];
      let pending = [];
      let pendingPath = "";

      const flush = () => {
        if (!pending.length) {
          return;
        }
        if (pending.length === 1) {
          output.push(pending[0]);
        } else {
          output.push({
            ...pending[0],
            text: readexTextReadRangeGroupSummary(pending),
            detailText: "",
            previewItems: [],
            childItems: pending,
            isTextReadRangeGroup: true,
            status: "success",
            durationMilliseconds: pending
              .map((item) => Number(item.durationMilliseconds))
              .filter(Number.isFinite)
              .reduce((max, value) => Math.max(max, value), 0) || pending[0].durationMilliseconds
          });
        }
        pending = [];
        pendingPath = "";
      };

      (Array.isArray(items) ? items : []).forEach((item) => {
        const info = readexToolItemTextReadRangeInfo(item);
        if (info && (!pending.length || pendingPath === info.path)) {
          pending.push(item);
          pendingPath = info.path;
          return;
        }
        flush();
        if (info) {
          pending.push(item);
          pendingPath = info.path;
          return;
        }
        output.push(item);
      });
      flush();
      return output;
    }

    function readexToolItemIsSavedAnswerWriteGroup(item) {
      const text = trimmed(item?.text);
      const detailText = trimmed(item?.detailText);
      return item?.isSavedAnswerWriteGroup === true
        || (text.startsWith("已保存 AI 回答（")
          && detailText.includes("已保存 AI 回答到"));
    }

    function readexModelTaskDetailLineIsChild(line) {
      const value = trimmed(line);
      return /^第\s*\d+\s*个模型[:：]/u.test(value)
        || value.includes("项模型任务未展开显示");
    }

    function readexModelTaskDetailLines(item) {
      const lines = trimmed(item?.detailText)
        .split(/\n+/u)
        .map((line) => trimmed(line))
        .filter(Boolean);
      if (!lines.some(readexModelTaskDetailLineIsChild)) {
        return [];
      }
      return lines;
    }

    function readexModelTaskDetailLineStatus(line) {
      const value = trimmed(line);
      if (!readexModelTaskDetailLineIsChild(value)) {
        return "success";
      }
      if (value.includes("项模型任务未展开显示")) {
        return "success";
      }
      if (value.includes("正在") || value.includes("等待") || value.includes("已发送")) {
        return "processing";
      }
      if (value.includes("失败")) {
        return "failed";
      }
      return "success";
    }

    function readexModelTaskDetailLineDurationMilliseconds(line) {
      return readexModelTaskDetailLineStatus(line) === "processing" ? null : 0;
    }

    function readexModelTaskPreviewItemsMatchingLine(line, previewItems) {
      const normalizedLine = trimmed(line);
      if (!normalizedLine || !Array.isArray(previewItems) || !previewItems.length) {
        return [];
      }
      const matched = previewItems.find((preview) => {
        const title = trimmed(preview?.title);
        if (!title) {
          return false;
        }
        if (normalizedLine.includes(title)) {
          return true;
        }
        const outputMarker = " 输出 ";
        const markerIndex = title.indexOf(outputMarker);
        if (markerIndex >= 0) {
          const taskID = trimmed(title.slice(0, markerIndex));
          return Boolean(taskID) && normalizedLine.includes(taskID);
        }
        return false;
      });
      return matched ? [matched] : [];
    }

    function readexToolItemWithModelTaskChildren(item) {
      const lines = readexModelTaskDetailLines(item);
      if (!lines.length) {
        return item;
      }
      const previewItems = readexPreviewItems(item?.previewItems);
      const childItems = lines.map((line, index) => {
        const status = readexModelTaskDetailLineStatus(line);
        return {
          id: [
            trimmed(item?.id),
            String(index),
            line
          ].filter(Boolean).join("\u{1f}"),
          text: line,
          detailText: "",
          previewItems: readexModelTaskPreviewItemsMatchingLine(line, previewItems),
          toolBatchId: readexToolItemBatchID(item),
          status,
          durationMilliseconds: readexModelTaskDetailLineDurationMilliseconds(line),
          isModelTaskChild: true
        };
      });
      return {
        ...item,
        detailText: "",
        previewItems: [],
        childItems: readexToolItemChildItems(item).concat(childItems),
        hasModelTaskChildren: true
      };
    }

    function readexToolItemIsKnowledgeMapLookup(item) {
      const text = trimmed(item?.text);
      return readexToolCategory(item) === "knowledgeMap"
        && text.includes("已查看")
        && text.includes("知识地图结构");
    }

    function readexToolItemIsSavedAIAnswerLookup(item) {
      const text = trimmed(item?.text);
      return readexToolCategory(item) === "savedAnswer"
        && text.includes("已读取")
        && text.includes("AI 回答");
    }

    function readexToolItemIsBookPageLabelMapping(item) {
      const text = trimmed(item?.text);
      return readexToolCategory(item) === "bookPageLabels"
        && text.includes("已查看")
        && text.includes("书本页码映射");
    }

    function readexToolItemIsBookPageLabelConfiguration(item) {
      const text = trimmed(item?.text);
      const looksLikeBookPageLabelConfiguration = text.includes("书本页码")
        || text.includes("页码规则")
        || text.includes("自动页码模型");
      const looksCompleted = text.includes("已配置")
        || text.includes("已修补")
        || text.includes("已保存")
        || text.includes("已用自动页码模型")
        || text.includes("自动配置正文页码")
        || text.includes("自动生成");
      return readexToolCategory(item) === "bookPageLabels"
        && looksCompleted
        && looksLikeBookPageLabelConfiguration
        && !text.includes("书本页码映射");
    }

    function readexToolTextLooksLikeExtractedPDFPageLookup(text) {
      const value = trimmed(text);
      if (!value) {
        return false;
      }
      const lowercaseText = value.toLowerCase();
      const looksRead = value.includes("已查看")
        || value.includes("已读取")
        || value.includes("已读")
        || lowercaseText.includes("viewed")
        || lowercaseText.includes("read");
      const looksPage = value.includes("书页")
        || value.includes("PDF 页面")
        || lowercaseText.includes("pdf page");
      const looksPageLabelMapping = value.includes("书本页码映射")
        || lowercaseText.includes("book page label")
        || lowercaseText.includes("page-label");
      return looksRead && looksPage && !looksPageLabelMapping;
    }

    function readexToolItemIsExtractedPDFPageLookup(item) {
      const text = trimmed(item?.text);
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      return readexToolCategory(item) === "pages"
        && readexToolTextLooksLikeExtractedPDFPageLookup(text)
        && (!previewItems.length || readexToolItemHasExtractedPagePreviews(item));
    }

    function readexToolItemIsDocumentOutlineLookup(item) {
      const text = trimmed(item?.text);
      if (readexToolCategory(item) !== "documentOutline" || !text.includes("可跳转目录")) {
        return false;
      }
      return text.includes("已查看")
        || text.includes("已读取")
        || text.includes("已读");
    }

    function readexToolItemIsDocumentOutlineConfiguration(item) {
      const text = trimmed(item?.text);
      return readexToolCategory(item) === "documentOutline"
        && text.includes("可跳转目录")
        && (text.includes("已配置") || text.includes("已修补") || text.includes("已保存"));
    }

    function readexToolItemBatchID(item) {
      return trimmed(item?.toolBatchId)
        || trimmed(item?.toolBatchID)
        || trimmed(item?.readexToolBatchID)
        || trimmed(item?.readexToolBatchId);
    }

    function readexToolGroupPreviewCount(items) {
      return (Array.isArray(items) ? items : []).reduce((sum, item) => {
        const previewCount = Array.isArray(item?.previewItems) ? item.previewItems.length : 0;
        return sum + Math.max(1, previewCount);
      }, 0);
    }

    function readexToolGroupText(descriptor, items) {
      if (typeof descriptor?.textForItems === "function") {
        return descriptor.textForItems(Array.isArray(items) ? items : []);
      }
      const count = Array.isArray(items) ? items.length : Number(items);
      return descriptor?.text(Number.isFinite(count) ? count : 0);
    }

    function readexToolBatchGroupDescriptor(item) {
      if (readexToolItemIsKnowledgeMapLookup(item)) {
        return {
          kind: "knowledgeMapLookup",
          text: (count) => `已查看${count}篇文档的知识地图结构`,
          flag: "isKnowledgeMapLookupGroup"
        };
      }
      if (readexToolItemIsSavedAIAnswerLookup(item)) {
        return {
          kind: "savedAIAnswerLookup",
          textForItems: (items) => `已读取 ${readexToolGroupPreviewCount(items)} 个 AI 回答`,
          flag: "isSavedAIAnswerLookupGroup"
        };
      }
      if (readexToolItemIsBookPageLabelMapping(item)) {
        return {
          kind: "bookPageLabelMapping",
          text: (count) => `已查看${count}篇文档书本页码映射`,
          flag: "isBookPageLabelMappingGroup"
        };
      }
      if (readexToolItemIsBookPageLabelConfiguration(item)) {
        return {
          kind: "bookPageLabelConfiguration",
          text: (count) => `已处理${count}篇文档的书本页码`,
          flag: "isBookPageLabelConfigurationGroup"
        };
      }
      if (readexToolItemIsExtractedPDFPageLookup(item)) {
        return {
          kind: "extractedPDFPages",
          text: (count) => `已查看${count}篇文档的 PDF 页面`,
          flag: "isExtractedPDFPagesGroup"
        };
      }
      if (readexToolItemIsDocumentOutlineLookup(item)) {
        return {
          kind: "documentOutlineLookup",
          text: (count) => `已查看${count}篇文档的可跳转目录`,
          flag: "isDocumentOutlineLookupGroup"
        };
      }
      if (readexToolItemIsDocumentOutlineConfiguration(item)) {
        return {
          kind: "documentOutlineConfiguration",
          text: (count) => `已处理${count}篇文档的可跳转目录`,
          flag: "isDocumentOutlineConfigurationGroup"
        };
      }
      return null;
    }

    function groupReadexBatchedPreviewItems(items) {
      const groupsByKey = new Map();
      items.forEach((item, index) => {
        const descriptor = readexToolBatchGroupDescriptor(item);
        if (!descriptor) {
          return;
        }
        const batchID = readexToolItemBatchID(item);
        if (!batchID) {
          return;
        }
        const key = `${descriptor.kind}:${batchID}`;
        const group = groupsByKey.get(key) || { indexes: [], items: [], descriptor, batchID };
        group.indexes.push(index);
        group.items.push(item);
        groupsByKey.set(key, group);
      });

      const groupedByFirstIndex = new Map();
      const skippedIndexes = new Set();
      groupsByKey.forEach((group) => {
        if (!group || group.items.length <= 1) {
          return;
        }
        const firstIndex = group.indexes[0];
        group.indexes.slice(1).forEach((index) => skippedIndexes.add(index));
        groupedByFirstIndex.set(firstIndex, {
          ...group.items[0],
          text: readexToolGroupText(group.descriptor, group.items),
          detailText: "",
          previewItems: [],
          toolBatchId: group.batchID,
          childItems: group.items,
          [group.descriptor.flag]: true,
          status: group.items.some(readexToolItemIsLive) ? "processing" : "success",
          durationMilliseconds: group.items
            .map((item) => Number(item.durationMilliseconds))
            .filter(Number.isFinite)
            .reduce((max, value) => Math.max(max, value), 0) || group.items[0].durationMilliseconds
        });
      });

      return items.flatMap((item, index) => {
        if (groupedByFirstIndex.has(index)) {
          return [groupedByFirstIndex.get(index)];
        }
        if (skippedIndexes.has(index)) {
          return [];
        }
        return [item];
      });
    }

    function readexToolAdjacentGroupDescriptor(item) {
      const descriptor = readexToolBatchGroupDescriptor(item);
      if (!descriptor || readexToolItemBatchID(item)) {
        return null;
      }
      return descriptor.kind === "documentOutlineLookup" || descriptor.kind === "extractedPDFPages"
        ? descriptor
        : null;
    }

    function groupReadexAdjacentPreviewItems(items) {
      const output = [];
      let pending = [];
      let pendingDescriptor = null;

      const flush = () => {
        if (!pending.length) {
          return;
        }
        if (pending.length === 1 || !pendingDescriptor) {
          output.push(...pending);
        } else {
          output.push({
            ...pending[0],
            text: readexToolGroupText(pendingDescriptor, pending),
            detailText: "",
            previewItems: [],
            childItems: pending,
            [pendingDescriptor.flag]: true,
            status: pending.some(readexToolItemIsLive) ? "processing" : "success",
            durationMilliseconds: pending
              .map((item) => Number(item.durationMilliseconds))
              .filter(Number.isFinite)
              .reduce((max, value) => Math.max(max, value), 0) || pending[0].durationMilliseconds
          });
        }
        pending = [];
        pendingDescriptor = null;
      };

      items.forEach((item) => {
        const descriptor = readexToolAdjacentGroupDescriptor(item);
        if (descriptor && (!pendingDescriptor || pendingDescriptor.kind === descriptor.kind)) {
          pending.push(item);
          pendingDescriptor = descriptor;
          return;
        }
        flush();
        if (descriptor) {
          pending.push(item);
          pendingDescriptor = descriptor;
          return;
        }
        output.push(item);
      });
      flush();
      return output;
    }

    function readexToolItemChildItems(item) {
      return Array.isArray(item?.childItems) ? item.childItems.filter(Boolean) : [];
    }

    function readexToolItemIsLive(item) {
      if (readexToolItemIsWebSearch(item)) {
        if (item?.completed === true) {
          return false;
        }
        if (item?.completed === false) {
          return true;
        }
      }
      const status = normalizedReadexStatus(item?.status);
      if (status) {
        return status === "pending" || status === "processing" || status === "streaming" || status === "searching";
      }
      return readexDurationMilliseconds(item) == null;
    }

    function readexToolItemIsFailed(item) {
      return normalizedReadexStatus(item?.status) === "failed"
        || readexCommandExecutionIsFailed(readexToolItemCommandExecution(item))
        || Boolean(trimmed(item?.error));
    }

    function readexToolItemCommandExecution(item) {
      return readexActivityCommandExecution(item);
    }

    function readexToolItemShellExecution(item) {
      return readexActivityShellExecution(item)
        || readexShellExecutionFromCommandExecution(readexToolItemCommandExecution(item));
    }

    function readexToolItemHasShellExecution(item) {
      return Boolean(readexToolItemShellExecution(item));
    }

    function readexToolItemShouldSuppressDetail(item) {
      const text = trimmed(item?.text);
      const category = readexToolCategory(item);
      return Array.isArray(item?.previewItems)
        && item.previewItems.length > 0
        && (text.includes("节点总结")
          || text.includes("回答列表")
          || category === "bookPageLabels"
          || category === "documentOutline"
          || (category === "pages" && readexToolItemHasExtractedPagePreviews(item)));
    }

    function readexToolItemDetailText(item) {
      if (readexToolItemHasShellExecution(item)) {
        return "";
      }
      if (readexToolItemShouldSuppressDetail(item)) {
        return "";
      }
      const detailText = trimmed(item?.detailText);
      if (detailText) {
        return detailText;
      }
      const errorText = trimmed(item?.error);
      return errorText ? `错误：${errorText}` : "";
    }

    function readexToolItemSinglePreviewShouldDisclose(item) {
      const previews = Array.isArray(item?.previewItems) ? item.previewItems : [];
      return readexToolItemHasExtractedPagePreviews(item)
        || readexToolCategory(item) === "savedAnswer"
        || previews.some(readexPreviewIsVideoFrame)
        || previews.some(readexPreviewIsApplyPatchDiff);
    }

    function readexActivityItemIsExpandable(item, options = {}) {
      if (!item) {
        return false;
      }
      if (options?.progressItemsExpandable === true && item.type === "progress") {
        return true;
      }
      if (readexToolItemHasLibraryTreePreview(item)) {
        return true;
      }
      if (readexToolItemChildItems(item).length > 0) {
        return true;
      }
      if (readexToolItemHasShellExecution(item)) {
        return true;
      }
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      if (previewItems.length > 1) {
        return true;
      }
      if (previewItems.length === 1 && readexToolItemSinglePreviewShouldDisclose(item)) {
        return true;
      }
      if (previewItems.length === 1 && readexToolItemDetailText(item)) {
        return true;
      }
      return Boolean(readexToolItemDetailText(item));
    }

    function readexToolItemIsExpandable(item) {
      return readexActivityItemIsExpandable(item);
    }

    function readexToolActivityBlockIDSet(propertyName) {
      const payload = window.__chatTranscriptPayload || window.__chatLongImagePayload || {};
      const values = Array.isArray(payload?.[propertyName]) ? payload[propertyName] : [];
      return new Set(values.map((value) => trimmed(value)).filter(Boolean));
    }

    function readexToolActivityPayloadWantsExpansion(block) {
      const expandedIDs = readexToolActivityBlockIDSet("expandedReadexToolActivityBlockIDs");
      if (!expandedIDs.size) {
        return false;
      }
      const candidates = [
        block?.sourceBlockId,
        block?.sourceBlockID,
        block?.id
      ].map((value) => trimmed(value)).filter(Boolean);
      return candidates.some((candidate) => expandedIDs.has(candidate));
    }

    function readexToolActivityPayloadHasUserCollapsed(block) {
      const collapsedIDs = readexToolActivityBlockIDSet("collapsedReadexToolActivityBlockIDs");
      if (!collapsedIDs.size) {
        return false;
      }
      const candidates = [
        block?.sourceBlockId,
        block?.sourceBlockID,
        block?.id
      ].map((value) => trimmed(value)).filter(Boolean);
      return candidates.some((candidate) => collapsedIDs.has(candidate));
    }

    function readexToolActivityPayloadExpansionState(block) {
      if (readexToolActivityPayloadHasUserCollapsed(block)) {
        return false;
      }
      if (readexToolActivityPayloadWantsExpansion(block)) {
        return true;
      }
      return null;
    }

    function configureReadexToolActivityExpansionState(element, block, blockKey, isExpandable) {
      if (!(element instanceof HTMLElement)) {
        return;
      }

      const sourceID = readexDisclosureSourceIDFromBlock(block) || trimmed(blockKey);
      if (element.__chatTranscriptReadexToolActivityExpansionSourceID !== sourceID) {
        element.__chatTranscriptReadexToolActivityExpansionSourceID = sourceID;
        element.__chatTranscriptReadexToolActivityUserToggled = false;
        element.__chatTranscriptReadexToolActivityExpanded = undefined;
      }

      if (!isExpandable) {
        element.__chatTranscriptReadexToolActivityExpanded = false;
        return;
      }
      const payloadExpansionState = readexToolActivityPayloadExpansionState(block);
      if (typeof element.__chatTranscriptReadexToolActivityExpanded !== "boolean") {
        element.__chatTranscriptReadexToolActivityExpanded = payloadExpansionState ?? false;
      } else if (
        element.__chatTranscriptReadexToolActivityUserToggled !== true
        && payloadExpansionState != null
      ) {
        element.__chatTranscriptReadexToolActivityExpanded = payloadExpansionState;
      }
    }

    function readexToolActivityPrimaryPreview(block) {
      const items = readexToolItems(block);
      if (items.length !== 1) {
        return null;
      }
      const item = items[0];
      if (readexToolItemHasLibraryTreePreview(item)) {
        return null;
      }
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      if (readexToolItemIsExpandable(item) || previewItems.length !== 1) {
        return null;
      }
      return previewItems[0];
    }

    function readexToolItemName(item) {
      return trimmed(item?.readexToolName)
        || trimmed(item?.toolName)
        || trimmed(item?.tool)
        || trimmed(item?.name);
    }

    function readexToolItemIsApplyPatch(item) {
      const toolName = normalizedReadexToolName(readexToolItemName(item));
      return toolName === "apply_patch"
        || toolName === "readex.apply_patch"
        || trimmed(item?.text).includes("修改文本文件");
    }

    function normalizedReadexToolName(toolName) {
      const value = trimmed(toolName);
      if (!value) {
        return "";
      }
      if (value === "readex.enqueue_video_downloads" || value === "readex_enqueue_video_downloads") {
        return "readex.download_video";
      }
      if (value.startsWith("readex_")) {
        return `readex.${value.slice("readex_".length)}`;
      }
      return value;
    }

    function readexToolCategoryForToolName(toolName) {
      switch (normalizedReadexToolName(toolName)) {
        case "web_search":
          return "search";
        case "workspace.shell":
        case "readex.shell":
          return "shell";
        case "readex.operation_summary":
          return "summary";
        case "readex.get_library_manifest":
          return "library";
        case "readex.ls":
          return "libraryPathList";
        case "readex.read_text":
          return "textRead";
        case "readex.attach_text_file":
          return "textRead";
        case "readex.write_text_file":
        case "apply_patch":
        case "readex.apply_patch":
          return "textWrite";
        case "readex.get_node_manifest":
        case "readex.edit_knowledge_map_structure":
          return "knowledgeMap";
        case "readex.get_book_page_labels":
        case "readex.configure_book_page_labels":
          return "bookPageLabels";
        case "readex.get_document_outline":
        case "readex.configure_document_outline":
          return "documentOutline";
        case "readex.get_saved_ai_answers":
        case "readex.save_node_answer":
          return "savedAnswer";
        case "readex.expand_video_items":
        case "readex.download_video":
        case "readex.create_video":
          return "videoSource";
        case "readex.extract_current_video_frames":
          return "videoFrame";
        case "readex.attach_current_video_transcript":
          return "subtitle";
        case "readex.extract_pdf_pages":
          return "pages";
        default:
          return "";
      }
    }

    function readexToolCategoryForPreviewItems(previewItems) {
      const items = Array.isArray(previewItems) ? previewItems : [];
      if (readexExtractedPDFPreviewItems(items).length > 0) {
        return "pages";
      }
      if (items.some(readexPreviewIsVideoFrame)) {
        return "videoFrame";
      }
      if (items.some(readexPreviewIsVideoDownloadProgress)) {
        return "videoSource";
      }
      if (items.some((preview) => trimmed(preview?.title) === "当前视频字幕")) {
        return "subtitle";
      }
      return "";
    }

    function readexToolCategory(input) {
      const value = typeof input === "string" ? trimmed(input) : trimmed(input?.text);
      const toolName = typeof input === "string" ? "" : normalizedReadexToolName(readexToolItemName(input));
      const commandExecution = typeof input === "string" ? null : readexToolItemCommandExecution(input);
      const previewCategory = typeof input === "string"
        ? ""
        : readexToolCategoryForPreviewItems(input?.previewItems);
      if (previewCategory) {
        return previewCategory;
      }
      if (commandExecution) {
        const commandActionType = readexCommandExecutionPrimaryAction(commandExecution)?.type;
        switch (commandActionType) {
          case "read":
            return "textRead";
          case "search":
            return "textSearch";
          case "list_files":
            return "libraryPathList";
          case "unknown":
            return "shell";
        }
      }
      if (toolName === "readex.read_text" && readexTextSearchText(value)) {
        return "textSearch";
      }
      const structuredCategory = typeof input === "string"
        ? ""
        : readexToolCategoryForToolName(toolName);
      if (structuredCategory) {
        return structuredCategory;
      }

      const lowerValue = value.toLowerCase();
      const libraryFileIOCategory = readexLibraryFileIOTextCategory(value);
      if (libraryFileIOCategory) {
        return libraryFileIOCategory;
      }
      if (value.includes("预算")) {
        return "budget";
      }
      if (value.includes("资料库命令") || value.includes("仓库命令")) {
        return "shell";
      }
      if (
        value.includes("书本页码")
        || value.includes("页码规则")
        || value.includes("自动页码模型")
        || value.includes("自动配置正文页码")
        || lowerValue.includes("book page label")
        || lowerValue.includes("page-label")
      ) {
        return "bookPageLabels";
      }
      if (
        value.includes("可跳转目录")
        || value.includes("目录页")
        || value.includes("配置目录")
        || value.includes("生成目录")
        || lowerValue.includes("document outline")
      ) {
        return "documentOutline";
      }
      if (value.includes("知识库")) {
        return "library";
      }
      if (value.includes("知识地图")) {
        return "knowledgeMap";
      }
      if (value.includes("总结") || value.includes("回答列表")) {
        return "summary";
      }
      if (value.includes("AI 讲解") || value.includes("AI 回答") || value.includes("已保存")) {
        return "savedAnswer";
      }
      if (value.includes("搜索")) {
        return "search";
      }
      if (
        value.includes("技能")
        && (
          value.includes("正在加载")
          || value.includes("已加载")
          || value.includes("未完成加载")
          || value.includes("正在查看")
          || value.includes("已查看")
          || value.includes("未完成查看")
        )
      ) {
        return "skill";
      }
      if (value.includes("结构化内容")) {
        return "blocks";
      }
      if (
        value.includes("视频素材")
        || value.includes("视频文件")
        || value.includes("视频列表")
        || value.includes("下载视频")
        || value.includes("视频下载")
        || value.includes("视频讲解")
        || value.includes("音视频")
        || value.includes("讲义素材视频")
      ) {
        return "videoSource";
      }
      if (
        value.includes("视频帧")
        || value.includes("抽取当前视频帧")
        || value.includes("抽出视频帧")
      ) {
        return "videoFrame";
      }
      if (value.includes("抽取") || value.includes("页面") || value.includes("书页")) {
        return "pages";
      }
      if (
        value.includes("当前视频字幕")
        || value.includes("附加当前视频字幕")
        || value.includes("查看当前视频字幕")
        || value.includes("字幕已附加")
        || value.includes("未完成附加当前视频字幕")
        || value.includes("未完成查看当前视频字幕")
        || value.includes("正在附加当前视频字幕")
        || value.includes("正在查看当前视频字幕")
        || value.includes("已附加当前视频字幕")
        || value.includes("已查看当前视频字幕")
        || value.includes("当前视频没有可读取的 SRT/VTT 字幕文件")
        || value.includes("当前视频没有可读取的字幕文件")
        || value.includes("当前视频没有可读取的字幕")
        || value.includes("正在获取字幕")
        || value.includes("字幕已获取")
        || value.includes("字幕已生成")
        || value.includes("平台字幕")
        || value.includes("本地转写字幕")
      ) {
        return "subtitle";
      }
      if (
        value.includes("正在下载音频")
        || value.includes("音频已下载")
        || value.includes("音频文件")
      ) {
        return "audio";
      }
      return "tool";
    }

    function readexToolCategoryIcon(category) {
      switch (category) {
        case "library":
          return "books.vertical";
        case "libraryPathList":
          return "folder";
        case "textRead":
          return "doc.text";
        case "textSearch":
          return "magnifyingglass";
        case "textWrite":
          return "square.and.pencil";
        case "knowledgeMap":
          return "point.3.connected.trianglepath.dotted";
        case "summary":
          return "list.bullet.rectangle";
        case "savedAnswer":
          return "text.alignleft";
        case "bookPageLabels":
          return "textformat.123";
        case "documentOutline":
          return "list.bullet.rectangle";
        case "search":
          return "globe";
        case "shell":
          return "terminal-square";
        case "pages":
          return "doc.text.magnifyingglass";
        case "blocks":
          return "square.stack.3d.up";
        case "budget":
          return "gauge.with.dots.needle.33percent";
        case "skill":
          return "wand.and.stars";
        case "videoSource":
          return "film.stack";
        case "videoFrame":
          return "photo.on.rectangle.angled";
        case "subtitle":
          return "captions.bubble";
        case "audio":
          return "waveform";
        case "tool":
          return "cpu";
        default:
          return "cpu";
      }
    }

    function readexToolNameIcon(toolName) {
      switch (normalizedReadexToolName(toolName)) {
        case "readex.ls":
          return "folder";
        case "workspace.shell":
        case "readex.shell":
          return "terminal-square";
        case "readex.attach_text_file":
          return "doc.text";
        case "readex.write_text_file":
        case "apply_patch":
        case "readex.apply_patch":
          return "square.and.pencil";
        case "readex.extract_current_video_frames":
          return "photo.on.rectangle.angled";
        default:
          return "";
      }
    }

    function readexLibraryFileIOTextCategory(text) {
      const value = trimmed(text);
      if (!value) {
        return "";
      }
      if (
        value.includes("仓库路径")
        || value.startsWith("正在查看/")
        || value.startsWith("已查看/")
        || value.startsWith("未完成查看/")
      ) {
        return "libraryPathList";
      }
      if (
        readexTextSearchText(value)
      ) {
        return "textSearch";
      }
      if (
        value.includes("读取文本文件")
        || value.includes("读取文本片段")
        || value.includes("附加文本文件")
        || value.startsWith("正在读取/")
        || value.startsWith("已读取/")
        || value.startsWith("未完成读取/")
        || value.startsWith("正在附加/")
        || value.startsWith("已附加/")
        || value.startsWith("未完成附加/")
      ) {
        return "textRead";
      }
      if (
        value.includes("写入文本文件")
        || value.includes("修改文本文件")
        || value.startsWith("正在写入/")
        || value.startsWith("已写入/")
        || value.startsWith("未完成写入/")
      ) {
        return "textWrite";
      }
      return "";
    }

    function readexTextSearchText(value) {
      const text = trimmed(value);
      return text.startsWith("正在搜索/")
        || text.startsWith("已搜索/")
        || text.startsWith("未完成搜索/")
        || text.startsWith("正在搜索文本")
        || text.startsWith("已搜索文本")
        || text.startsWith("未完成搜索文本")
        || (text.startsWith("在“") && text.includes("”中找到") && text.includes("处"));
    }

    function readexToolItemIsCompletedTextSearch(item) {
      const text = trimmed(item?.text);
      return readexToolCategory(item) === "textSearch"
        && !text.startsWith("正在")
        && !text.startsWith("未完成");
    }

    function readexToolItemsContainFoldableTextSearchRun(items) {
      let runLength = 0;
      for (const item of Array.isArray(items) ? items : []) {
        if (readexToolItemIsCompletedTextSearch(item)) {
          runLength += 1;
          if (runLength > 1) {
            return true;
          }
          continue;
        }
        runLength = 0;
      }
      return false;
    }

    function readexToolActivityTitleSegments(items) {
      const segments = [];
      let pendingTextSearchCount = 0;
      let pendingTextSearchTitle = "";

      const flushTextSearchRun = () => {
        if (pendingTextSearchCount <= 0) {
          return;
        }
        segments.push(pendingTextSearchCount > 1
          ? `已搜索 ${pendingTextSearchCount} 次`
          : pendingTextSearchTitle);
        pendingTextSearchCount = 0;
        pendingTextSearchTitle = "";
      };

      (Array.isArray(items) ? items : []).forEach((item) => {
        if (readexToolItemIsCompletedTextSearch(item)) {
          pendingTextSearchCount += 1;
          if (pendingTextSearchCount === 1) {
            pendingTextSearchTitle = trimmed(item?.text);
          }
          return;
        }
        flushTextSearchRun();
        if (readexToolItemHasApplyPatchDiffPreview(item)) {
          segments.push(readexApplyPatchActivitySummaryText(item));
          return;
        }
        const text = trimmed(item?.text);
        if (text) {
          segments.push(text);
        }
      });
      flushTextSearchRun();
      return segments.filter(Boolean);
    }

    function readexToolIcon(input) {
      if (typeof input !== "string" && input?.webSearchReference) {
        return "globe";
      }
      if (typeof input !== "string") {
        if (readexActivityItemType(input) === "operation_summary") {
          return "list";
        }
        if (readexToolItemShellExecution(input) || readexToolItemCommandExecution(input)) {
          return "terminal-square";
        }
        const toolIcon = readexToolNameIcon(readexToolItemName(input));
        if (toolIcon) {
          return toolIcon;
        }
      }
      const textCategory = readexLibraryFileIOTextCategory(
        typeof input === "string" ? input : input?.text
      );
      return readexToolCategoryIcon(textCategory || readexToolCategory(input));
    }

    function readexToolCategorySummary(category, count) {
      switch (category) {
        case "library":
          return `已查看知识库 ${count} 次`;
        case "libraryPathList":
          return `已查看仓库路径 ${count} 次`;
        case "textRead":
          return `已读取文本文件 ${count} 次`;
        case "textSearch":
          return `已搜索文本文件 ${count} 次`;
        case "textWrite":
          return `已写入文本文件 ${count} 次`;
        case "knowledgeMap":
          return `已查看知识地图 ${count} 次`;
        case "summary":
          return `已查看回答列表 ${count} 次`;
        case "savedAnswer":
          return `已读取 AI 回答 ${count} 次`;
        case "bookPageLabels":
          return `已配置书本页码 ${count} 次`;
        case "documentOutline":
          return `已配置可跳转目录 ${count} 次`;
        case "search":
          return `已搜索网页 ${count} 次`;
        case "shell":
          return `已执行资料库命令 ${count} 次`;
        case "blocks":
          return `已读取结构化内容 ${count} 次`;
        case "pages":
          return `已查看书页 ${count} 次`;
        case "budget":
          return "已触达工具预算";
        case "skill":
          return `已加载技能 ${count} 次`;
        case "videoSource":
          return `已获取视频素材 ${count} 次`;
        case "videoFrame":
          return `已抽取视频帧 ${count} 次`;
        case "subtitle":
          return `已获取字幕 ${count} 次`;
        case "audio":
          return `已下载音频 ${count} 次`;
        case "tool":
        default:
          return `已使用工具 ${count} 次`;
      }
    }

    function readexWebSearchTrimURLText(value) {
      return trimmed(value).replace(/^[("'`]+|[)"'`,.;!?]+$/gu, "");
    }

    function readexWebSearchURLFromText(value) {
      const text = trimmed(value);
      if (!text) {
        return "";
      }
      const siteMatch = text.match(/\bsite:([^\s)]+)/iu);
      if (siteMatch?.[1]) {
        return readexWebSearchTrimURLText(siteMatch[1]);
      }
      const urlMatch = text.match(/\bhttps?:\/\/[^\s"'<>]+/iu);
      if (urlMatch?.[0]) {
        return readexWebSearchTrimURLText(urlMatch[0]);
      }
      return "";
    }

    function readexWebSearchSiteHostname(value) {
      try {
        return new URL(`https://${readexWebSearchTrimURLText(value)}`).hostname.replace(/^www\./iu, "");
      } catch (error) {
        return "";
      }
    }

    function readexWebSearchFormattedQuery(value) {
      const text = trimmed(value);
      if (!text) {
        return "";
      }
      const sites = [];
      const withoutSites = text.replace(/\bsite:([^\s]+)/giu, (match, site) => {
        const hostname = readexWebSearchSiteHostname(site);
        if (!hostname) {
          return match;
        }
        if (!sites.includes(hostname)) {
          sites.push(hostname);
        }
        return "";
      });
      if (!sites.length) {
        return text;
      }
      const query = withoutSites.replace(/\bOR\b/gu, " ").replace(/\s+/gu, " ").trim();
      return query ? `${query} | ${sites.join(" · ")}` : text;
    }

    function readexIdentityQueryFormatter(value) {
      return value;
    }

    function readexActivitySearchActionDetail(action, fallbackQuery = "", formatQuery = readexIdentityQueryFormatter) {
      const query = trimmed(action?.query);
      const queries = readexActivityActionQueries(action);
      if (query) {
        return formatQuery(query);
      }
      const resolvedQuery = queries[0] || trimmed(fallbackQuery);
      const formattedQuery = formatQuery(resolvedQuery);
      return queries.length > 1 && formattedQuery ? `${formattedQuery} ...` : formattedQuery;
    }

    function readexActivityActionDetail(action, fallbackQuery = "", formatQuery = readexIdentityQueryFormatter) {
      const type = readexActivityActionType(action);
      const url = trimmed(action?.url);
      const pattern = trimmed(action?.pattern);
      if (type === "openPage") {
        return url;
      }
      if (type === "findInPage") {
        if (pattern && url) {
          return `'${pattern}' in ${url}`;
        }
        if (pattern) {
          return `'${pattern}'`;
        }
        return url;
      }
      const resolvedQuery = readexActivitySearchActionDetail(action, fallbackQuery, formatQuery);
      if (type === "search") {
        return resolvedQuery;
      }
      return resolvedQuery || url || pattern;
    }

    function readexWebSearchActionDetail(action, fallbackQuery = "") {
      return readexActivityActionDetail(action, fallbackQuery, readexWebSearchFormattedQuery);
    }

    function readexWebSearchActionURL(action, item) {
      const type = readexActivityActionType(action);
      if (type === "openPage" || type === "findInPage") {
        return trimmed(action?.url);
      }
      if (type === "search") {
        const candidates = [trimmed(action?.query)]
          .concat(readexActivityActionQueries(action))
          .concat(trimmed(item?.query));
        for (const candidate of candidates) {
          const url = readexWebSearchURLFromText(candidate);
          if (url) {
            return url;
          }
        }
        return "";
      }
      return "";
    }

    function readexWebSearchHostnameFromURL(rawURL) {
      const value = readexWebSearchTrimURLText(rawURL);
      if (!value) {
        return "";
      }
      const candidates = /^[a-z][a-z\d+\-.]*:\/\//iu.test(value)
        ? [value]
        : [`https://${value}`];
      for (const candidate of candidates) {
        try {
          const url = new URL(candidate);
          const hostname = trimmed(url.hostname).replace(/^www\./iu, "");
          if (hostname && (url.protocol === "http:" || url.protocol === "https:")) {
            return hostname;
          }
        } catch (error) {
        }
      }
      return "";
    }

    function readexWebSearchFaviconDomain(hostname) {
      const parts = trimmed(hostname).split(".").filter(Boolean);
      if (parts.length <= 2) {
        return parts.join(".");
      }
      const secondLevel = parts[parts.length - 2] || "";
      const topLevel = parts[parts.length - 1] || "";
      if (topLevel.length === 2 && secondLevel.length <= 3 && parts.length >= 3) {
        return parts.slice(-3).join(".");
      }
      return parts.slice(-2).join(".");
    }

    function readexWebSearchFaviconURLForValue(value) {
      const hostname = readexWebSearchHostnameFromURL(value);
      if (!hostname) {
        return "";
      }
      const domain = readexWebSearchFaviconDomain(hostname);
      return domain
        ? `https://www.google.com/s2/favicons?domain=${encodeURIComponent(domain)}&sz=32`
        : "";
    }

    function readexNonEmptyWebSearchLines(lines) {
      return (Array.isArray(lines) ? lines : []).flatMap((line) => {
        const detail = trimmed(line?.detail);
        return detail ? [{ ...line, detail }] : [];
      });
    }

    function readexWebSearchActionCompleted(action, item) {
      if (action?.completed === true) {
        return true;
      }
      if (action?.completed === false) {
        return false;
      }
      const status = normalizedReadexStatus(action?.status);
      if (status) {
        return !(status === "pending" || status === "processing" || status === "streaming" || status === "searching");
      }
      return !readexToolItemIsLive(item);
    }

    function readexWebSearchActionLines(item) {
      return readexWebSearchActionsForLines(item).map((action, index) => {
        const detail = readexWebSearchActionDetail(action, normalizedStringArray(item?.searchQueries)[0]);
        const url = readexWebSearchActionURL(action, item);
        return {
          key: `${detail}:${index}`,
          kind: "action",
          detail,
          url,
          faviconURL: readexWebSearchFaviconURLForValue(url),
          completed: readexWebSearchActionCompleted(action, item)
        };
      });
    }

    function readexWebSearchQueryLines(item) {
      const isLive = readexToolItemIsLive(item);
      return mergedReadexWebSearchQueries([item]).map((query, index) => {
        const url = readexWebSearchURLFromText(query);
        return {
          key: `${query}:${index}`,
          kind: "query",
          detail: query,
          url,
          faviconURL: readexWebSearchFaviconURLForValue(url),
          completed: !isLive
        };
      });
    }

    function readexWebSearchDisplayLines(item) {
      if (!item) {
        return [];
      }
      const childLines = readexToolItemChildItems(item).flatMap(readexWebSearchDisplayLines);
      const childActionLines = childLines.filter((line) => line.kind === "action");
      const actionLines = readexNonEmptyWebSearchLines(
        childActionLines.length > 0 ? childActionLines : readexWebSearchActionLines(item)
      );
      if (actionLines.length > 0) {
        return actionLines;
      }
      const childQueryLines = childLines.filter((line) => line.kind === "query");
      const queryLines = readexNonEmptyWebSearchLines(
        childQueryLines.length > 0 ? childQueryLines : readexWebSearchQueryLines(item)
      );
      if (queryLines.length > 0) {
        return queryLines;
      }
      return [];
    }

    function readexWebSearchActiveDetail(item) {
      const lines = readexWebSearchDisplayLines(item);
      if (!lines.length) {
        return "";
      }
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        if (!lines[index].completed) {
          return trimmed(lines[index].detail);
        }
      }
      return trimmed(lines[lines.length - 1]?.detail);
    }

    function readexWebSearchHeaderText(item) {
      if (readexToolItemIsLive(item)) {
        return "正在搜索网页";
      }
      return trimmed(item?.text)
        || readexWebSearchDisplaySummaryText(item);
    }

    function readexWebSearchDisplaySummaryText(item) {
      if (readexToolItemIsLive(item)) {
        return "正在搜索网页";
      }
      return `已搜索网页 ${readexWebSearchDisplayLines(item).length} 次`;
    }

    function readexWebSearchActivityShouldRender(item) {
      return readexToolItemIsLive(item) || readexWebSearchDisplayLines(item).length > 0;
    }

    function appendReadexWebSearchFavicon(row, line) {
      const faviconURL = trimmed(line?.faviconURL);
      const frame = document.createElement("span");
      frame.className = "readex-web-search-favicon-frame";

      const fallback = document.createElement("span");
      fallback.className = "readex-web-search-favicon-fallback";
      fallback.innerHTML = makeIcon("globe");
      if (!fallback.firstElementChild) {
        frame.classList.add("is-system-icon-missing");
        frame.dataset.missingSystemIcon = "globe";
      }
      frame.appendChild(fallback);

      if (!faviconURL) {
        row.appendChild(frame);
        return;
      }

      const image = document.createElement("img");
      image.className = "readex-web-search-favicon";
      image.alt = "";
      image.decoding = "async";
      image.draggable = false;
      image.referrerPolicy = "no-referrer";
      image.addEventListener("load", () => {
        frame.classList.add("is-favicon-loaded");
      });
      image.addEventListener("error", () => {
        frame.classList.add("is-favicon-failed");
        image.removeAttribute("src");
      });
      frame.appendChild(image);
      image.src = faviconURL;
      row.appendChild(frame);
    }

    function scrollReadexWebSearchLinesToBottom(list) {
      if (!(list instanceof HTMLElement) || list.closest("[hidden]")) {
        return;
      }
      list.scrollTop = list.scrollHeight;
    }

    function readexWebSearchLinesIsNearBottom(list) {
      if (!(list instanceof HTMLElement)) {
        return true;
      }
      const remaining = list.scrollHeight - list.clientHeight - list.scrollTop;
      return remaining <= 48;
    }

    function readexWebSearchContainerShouldFollowLatest(container) {
      if (!(container instanceof HTMLElement)) {
        return true;
      }
      const list = container.querySelector(".readex-web-search-lines");
      return readexWebSearchLinesIsNearBottom(list);
    }

    function scheduleReadexWebSearchAutoScroll(list) {
      if (!(list instanceof HTMLElement)) {
        return;
      }
      if (typeof window === "undefined" || typeof window.requestAnimationFrame !== "function") {
        scrollReadexWebSearchLinesToBottom(list);
        return;
      }
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => {
          scrollReadexWebSearchLinesToBottom(list);
        });
      });
    }

    function appendReadexWebSearchLines(container, item, lines = null, options = {}) {
      const displayLines = Array.isArray(lines) ? lines : readexWebSearchDisplayLines(item);
      if (!displayLines.length) {
        return false;
      }

      const list = document.createElement("div");
      list.className = "readex-web-search-lines";
      displayLines.forEach((line) => {
        const row = document.createElement("div");
        row.className = [
          "readex-web-search-line",
          line.completed ? "is-complete" : "is-live"
        ].filter(Boolean).join(" ");
        appendReadexWebSearchFavicon(row, line);

        const label = document.createElement("span");
        label.className = "readex-web-search-line-text";
        label.textContent = trimmed(line.detail);
        row.appendChild(label);
        list.appendChild(row);
      });
      container.appendChild(list);
      if (options.autoScrollToBottom) {
        scheduleReadexWebSearchAutoScroll(list);
      }
      return true;
    }

    function appendReadexWebSearchHeaderText(row, item) {
      const title = document.createElement("span");
      title.className = "readex-web-search-header-title";

      const isLive = readexToolItemIsLive(item);
      const action = document.createElement("span");
      action.className = "readex-web-search-header-action";
      const activeDetailText = isLive ? readexWebSearchActiveDetail(item) : "";
      const actionText = isLive && activeDetailText
        ? `正在网页中搜索 ${activeDetailText}`
        : readexWebSearchHeaderText(item);
      if (isLive) {
        renderSequentialShimmerText(action, actionText);
      } else {
        clearSequentialShimmerText(action, actionText);
      }
      title.appendChild(action);

      row.appendChild(title);
    }

    function buildReadexWebSearchActivityElement(item, stateOwner = null, disclosureKey = "", options = {}) {
      const lines = readexWebSearchDisplayLines(item);
      const canExpand = lines.length > 0;
      const shouldAutoScroll = options.autoScrollToBottom === true
        || (options.autoScrollToBottom !== false && readexToolItemIsLive(item));
      const initiallyExpanded = canExpand && (
        options.initialExpanded === true
        || readexNestedDisclosureIsExpanded(stateOwner, disclosureKey)
      );
      const wrapper = document.createElement("div");
      wrapper.className = [
        "readex-web-search-activity",
        options.standalone ? "is-standalone" : "",
        readexToolItemIsLive(item) ? "is-live" : "is-complete"
      ].filter(Boolean).join(" ");

      const row = document.createElement(canExpand ? "button" : "div");
      if (canExpand) {
        row.type = "button";
        row.setAttribute("aria-expanded", initiallyExpanded ? "true" : "false");
      }
      row.className = [
        "readex-web-search-header",
        canExpand ? "is-interactive" : ""
      ].filter(Boolean).join(" ");
      appendIcon(row, "globe");
      appendReadexWebSearchHeaderText(row, item);

      let nested = null;
      let chevron = null;
      if (canExpand) {
        chevron = document.createElement("span");
        chevron.className = "readex-web-search-chevron";
        chevron.innerHTML = makeIcon("chevron-right");
        row.appendChild(chevron);

        nested = document.createElement("div");
        nested.className = "readex-web-search-nested";
        nested.hidden = !initiallyExpanded;
        appendReadexWebSearchLines(nested, item, lines, {
          autoScrollToBottom: initiallyExpanded && shouldAutoScroll
        });

        row.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          const expanded = row.getAttribute("aria-expanded") === "true";
          const nextExpanded = !expanded;
          row.setAttribute("aria-expanded", nextExpanded ? "true" : "false");
          setReadexNestedDisclosureExpanded(stateOwner, disclosureKey, nextExpanded);
          cancelReadexAncestorDisclosureAnimations(nested);
          animateReadexDisclosureElement(nested, nextExpanded, { hideOnFinish: true, reserveLayout: true });
          if (nextExpanded && shouldAutoScroll) {
            scheduleReadexWebSearchAutoScroll(nested.querySelector(".readex-web-search-lines"));
          }
        });
      }

      wrapper.appendChild(row);
      if (nested) {
        wrapper.appendChild(nested);
      }
      return wrapper;
    }

    function appendReadexWebSearchActivityItem(details, item, stateOwner = null, disclosureKey = "", options = {}) {
      details.appendChild(buildReadexWebSearchActivityElement(item, stateOwner, disclosureKey, options));
    }

    function readexToolActivityIsComplete(block, message) {
      return !readexToolItems(block).some(readexToolItemIsLive);
    }

    function readexToolActivityTitle(block, message) {
      const items = readexToolItems(block);
      const liveItem = items.slice().reverse().find(readexToolItemIsLive);
      if (liveItem) {
        if (readexToolItemIsWebSearchGroup(liveItem)) {
          const detail = readexWebSearchActiveDetail(liveItem);
          return detail ? `正在网页中搜索 ${detail}` : liveItem.text;
        }
        if (readexToolItemHasApplyPatchDiffPreview(liveItem)) {
          return readexApplyPatchActivitySummaryText(liveItem);
        }
        return liveItem.text;
      }

      const concreteTitles = readexToolActivityTitleSegments(items);
      if (concreteTitles.length === 1) {
        return concreteTitles[0];
      }
      if (concreteTitles.length > 1) {
        const shown = concreteTitles.slice(0, 3).join("；");
        const omitted = concreteTitles.length - 3;
        return omitted > 0 ? `${shown}；另 ${omitted} 项` : shown;
      }
      return readexToolActivityIsComplete(block, message) ? "已使用工具" : "正在使用工具…";
    }

    function readexToolActivityIcon(block) {
      const items = readexToolItems(block);
      const liveItem = items.slice().reverse().find(readexToolItemIsLive);
      const item = liveItem || items[items.length - 1];
      return readexToolIcon(item || block || "");
    }

    function appendReadexToolStatusItem(details, item, preview = null, options = {}) {
      const opensPreview = preview
        && !readexPreviewIsLibraryTree(preview)
        && !readexPreviewLooksLikeApplyPatch(preview)
        && !readexToolItemIsApplyPatch(item);
      const previewContentAccentContext = options?.previewContentAccentContext || trimmed(options?.extractedPDFAccentColor);
      const previewContentAccentColor = readexToolItemPreviewContentAccentColor(item, previewContentAccentContext);
      const row = document.createElement(opensPreview ? "button" : "div");
      if (opensPreview) {
        row.type = "button";
      }
      row.className = [
        "readex-tool-activity-item",
        readexToolItemIsLive(item) ? "is-live" : "",
        readexToolItemIsFailed(item) ? "is-failed" : "",
        opensPreview ? "is-preview" : "",
        opensPreview ? "opens-preview" : "",
        previewContentAccentColor ? "has-preview-content-accent" : ""
      ].filter(Boolean).join(" ");
      applyReadexExtractedPDFAccentVariable(row, previewContentAccentColor);
      if (!options?.suppressIcon) {
        appendReadexToolAvatarOrIcon(row, item, previewContentAccentColor);
      }

      const textWrap = document.createElement("span");
      textWrap.className = "readex-tool-activity-item-text";

      const label = document.createElement("span");
      label.className = "readex-tool-activity-item-title";
      renderReadexToolItemTitle(label, item, previewContentAccentColor);
      textWrap.appendChild(label);

      const detailText = readexToolItemDetailText(item);
      if (detailText) {
        const detail = document.createElement("span");
        detail.className = "readex-tool-activity-item-detail";
        detail.textContent = detailText;
        textWrap.appendChild(detail);
      }

      row.appendChild(textWrap);
      appendReadexCollabAgentOpenChip(row, item);
      if (opensPreview) {
        const chevron = document.createElement("span");
        chevron.className = "readex-tool-activity-item-chevron";
        chevron.innerHTML = makeIcon("chevron-right");
        row.appendChild(chevron);

        row.addEventListener("click", (event) => {
          const target = event?.target;
          if (readexSupportTargetIsNestedReferenceControl(target)) {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          openReadexPreviewItem(preview);
        });
      }
      details.appendChild(row);
    }

    function readexToolItemUsesPlainStatusRow(item) {
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      return previewItems.length === 0
        && !readexToolItemHasShellExecution(item)
        && !readexToolItemIsWebSearchGroup(item)
        && !readexToolItemHasLibraryTreePreview(item)
        && !readexToolItemShouldDisclose(item);
    }

    function patchReadexToolStatusRow(row, item, options = {}) {
      if (!row || !row.classList?.contains("readex-tool-activity-item")) {
        return null;
      }
      const previewContentAccentContext = options?.previewContentAccentContext || trimmed(options?.extractedPDFAccentColor);
      const previewContentAccentColor = readexToolItemPreviewContentAccentColor(item, previewContentAccentContext);
      row.className = [
        "readex-tool-activity-item",
        readexToolItemIsLive(item) ? "is-live" : "",
        readexToolItemIsFailed(item) ? "is-failed" : "",
        previewContentAccentColor ? "has-preview-content-accent" : ""
      ].filter(Boolean).join(" ");
      applyReadexExtractedPDFAccentVariable(row, previewContentAccentColor);
      row.replaceChildren();
      if (!options?.suppressIcon) {
        appendReadexToolAvatarOrIcon(row, item, previewContentAccentColor);
      }

      const textWrap = document.createElement("span");
      textWrap.className = "readex-tool-activity-item-text";

      const label = document.createElement("span");
      label.className = "readex-tool-activity-item-title";
      renderReadexToolItemTitle(label, item, previewContentAccentColor);
      textWrap.appendChild(label);

      const detailText = readexToolItemDetailText(item);
      if (detailText) {
        const detail = document.createElement("span");
        detail.className = "readex-tool-activity-item-detail";
        detail.textContent = detailText;
        textWrap.appendChild(detail);
      }

      row.appendChild(textWrap);
      appendReadexCollabAgentOpenChip(row, item);
      return row;
    }

    function readexVideoFrameTimestampSeconds(preview) {
      const payload = preview?.payload || {};
      const directValue = Number(
        payload.timestamp
          ?? payload.startSeconds
          ?? payload.start_seconds
      );
      if (Number.isFinite(directValue) && directValue >= 0) {
        return directValue;
      }
      const label = trimmed(
        payload.timestamp_label
          || payload.timestampLabel
          || payload.requested_timestamp
          || payload.requestedTimestamp
      );
      if (!label) {
        return null;
      }
      const parts = label.split(":").map((part) => Number(part));
      if (!parts.length || parts.some((part) => !Number.isFinite(part) || part < 0)) {
        return null;
      }
      if (parts.length === 1) {
        return parts[0];
      }
      if (parts.length === 2) {
        return (parts[0] * 60) + parts[1];
      }
      if (parts.length === 3) {
        return (parts[0] * 3600) + (parts[1] * 60) + parts[2];
      }
      return null;
    }

    function readexVideoFrameReferencePayload(preview) {
      const payload = preview?.payload || {};
      return readexSupportContentReferencePayloadFromObject(payload, {
        requireTime: true,
        timeFallback: readexVideoFrameTimestampSeconds(preview),
        pathKeys: ["path", "filePath", "file_path", "video_path", "videoPath", "source_path", "sourcePath"]
      });
    }

    function openReadexVideoFrameReference(preview) {
      readexContentReferenceProbe("js_video_frame_click", {
        previewFilePath: trimmed(preview?.filePath || preview?.file_path) || null,
        previewFileName: trimmed(preview?.fileName || preview?.file_name) || null,
        previewPayloadKeys: readexContentReferenceProbeKeys(preview?.payload)
      });
      const payload = readexVideoFrameReferencePayload(preview);
      if (!payload) {
        readexContentReferenceProbe("js_video_frame_payload_missing");
        return false;
      }
      readexContentReferenceProbe("js_video_frame_post_message", {
        reference: payload
      });
      postMessageAction(payload);
      return true;
    }

    function appendReadexToolPreviewItem(details, item, preview, accentSource = "") {
      const previewContentAccentColor = readexToolItemPreviewContentAccentColor(item, accentSource);
      if (readexPreviewIsApplyPatchDiff(preview)) {
        appendReadexApplyPatchDiffPreview(details, item, preview);
        return;
      }
      if (readexToolItemIsApplyPatch(item) || readexPreviewLooksLikeApplyPatch(preview)) {
        return;
      }
      if (readexPreviewIsVideoFrame(preview)) {
        appendReadexVideoFramePreviewItem(details, preview, previewContentAccentColor);
        return;
      }
      if (readexPreviewIsLibraryTree(preview)) {
        appendReadexLibraryTreePreview(details, preview);
        return;
      }

      const row = document.createElement("button");
      row.type = "button";
      row.className = [
        "readex-tool-activity-item",
        readexToolItemIsLive(item) ? "is-live" : "",
        readexToolItemIsFailed(item) ? "is-failed" : "",
        "is-preview",
        "opens-preview",
        previewContentAccentColor ? "has-preview-content-accent" : ""
      ].filter(Boolean).join(" ");
      applyReadexExtractedPDFAccentVariable(row, previewContentAccentColor);
      appendReadexToolAvatarOrIcon(row, item, previewContentAccentColor);

      const textWrap = document.createElement("span");
      textWrap.className = "readex-tool-activity-item-text";

      const label = document.createElement("span");
      label.className = "readex-tool-activity-item-title";
      label.textContent = readexPreviewDisplayTitle(preview);
      textWrap.appendChild(label);

      row.appendChild(textWrap);
      const chevron = document.createElement("span");
      chevron.className = "readex-tool-activity-item-chevron";
      chevron.innerHTML = makeIcon("chevron-right");
      row.appendChild(chevron);
      row.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        openReadexPreviewItem(preview);
      });
      details.appendChild(row);
    }

    function appendReadexVideoFramePreviewItem(details, preview, accentColor = "") {
      const list = readexVideoFramePreviewList(details);
      const frame = document.createElement("div");
      frame.className = [
        "readex-video-frame-preview",
        "opens-preview",
        trimmed(accentColor) ? "has-preview-content-accent" : ""
      ].filter(Boolean).join(" ");
      applyReadexExtractedPDFAccentVariable(frame, accentColor);
      frame.setAttribute("role", "button");
      frame.setAttribute("tabindex", "0");
      frame.setAttribute("aria-label", readexPreviewDisplayTitle(preview));
      const openFramePreview = (event) => {
        event.preventDefault();
        event.stopPropagation();
        openReadexPreviewItem(preview);
      };
      frame.addEventListener("click", openFramePreview);
      frame.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        openFramePreview(event);
      });

      const imageButton = document.createElement("button");
      imageButton.type = "button";
      imageButton.className = "readex-video-frame-preview-image-button";
      imageButton.setAttribute("aria-label", "预览视频帧");

      const image = document.createElement("img");
      image.className = "readex-video-frame-preview-image";
      image.alt = readexPreviewDisplayTitle(preview);
      image.loading = "lazy";
      image.decoding = "async";
      const imagePath = trimmed(preview?.payload?.image_path || preview?.payload?.imagePath || preview?.filePath);
      const thumbnailPath = trimmed(preview?.payload?.thumbnail_path || preview?.payload?.thumbnailPath);
      const thumbnailDataURL = trimmed(
        preview?.payload?.thumbnail_data_url
          || preview?.payload?.thumbnailDataURL
          || preview?.payload?.thumbnailDataUrl
      );
      const imageDataURL = trimmed(
        preview?.payload?.image_data_url
          || preview?.payload?.imageDataURL
          || preview?.payload?.imageDataUrl
      );
      const imageSource = attachmentImageSource({
        kind: "importedImage",
        thumbnailURL: thumbnailDataURL || imageDataURL,
        filePath: imagePath || thumbnailPath,
        mimeType: preview?.mimeType || "image/jpeg",
        thumbnailMaxPixelSize: 1920
      });
      if (imageSource) {
        image.src = imageSource;
      }
      imageButton.appendChild(image);
      imageButton.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        openReadexPreviewItem(preview);
      });
      frame.appendChild(imageButton);

      const referencePayload = readexVideoFrameReferencePayload(preview);
      const title = document.createElement(referencePayload ? "button" : "span");
      if (referencePayload) {
        title.type = "button";
        title.setAttribute("title", "跳转到视频时间点");
        title.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          openReadexVideoFrameReference(preview);
        });
      }
      title.className = "readex-video-frame-preview-title";
      title.textContent = readexVideoFramePreviewCaption(preview);
      if (referencePayload) {
        title.classList.add("readex-video-frame-timestamp-link");
        applyReadexExtractedPDFAccent(title, accentColor);
      }
      frame.appendChild(title);

      list.appendChild(frame);
      const count = Number(list.dataset.frameCount || 0) + 1;
      list.dataset.frameCount = String(count);
      list.classList.toggle("is-scrollable", count > 8);
    }

    function readexVideoFramePreviewList(details) {
      const lastChild = details?.lastElementChild;
      if (lastChild?.classList?.contains("readex-video-frame-preview-list")) {
        return lastChild;
      }
      const list = document.createElement("div");
      list.className = "readex-video-frame-preview-list";
      list.dataset.frameCount = "0";
      details.appendChild(list);
      return list;
    }

    function readexVideoFramePreviewCaption(preview) {
      const frameLabel = readexVideoFrameIndexLabel(preview);
      const timeLabel = readexVideoFrameTimestampLabel(preview);
      if (frameLabel && timeLabel) {
        return `${frameLabel} · ${timeLabel}`;
      }
      if (frameLabel) {
        return frameLabel;
      }
      return timeLabel || "视频帧";
    }

    function readexVideoFrameIndexLabel(preview) {
      const payload = preview?.payload || {};
      const frameIndex = Number(payload.frame_index || payload.frameIndex);
      if (Number.isFinite(frameIndex)) {
        const totalFrames = Number(payload.total_frames || payload.totalFrames);
        if (Number.isFinite(totalFrames) && totalFrames > 0) {
          return `第${Math.trunc(frameIndex)}/${Math.trunc(totalFrames)}帧`;
        }
        return `第${Math.trunc(frameIndex)}帧`;
      }
      return normalizeReadexVideoFrameIndexLabel(readexPreviewDisplayTitle(preview));
    }

    function readexVideoFrameTimestampLabel(preview) {
      const payload = preview?.payload || {};
      const payloadLabel = normalizeReadexVideoFrameTimestampLabel(payload.timestamp_label || payload.timestampLabel);
      if (payloadLabel) {
        return payloadLabel;
      }
      const timestamp = Number(payload.timestamp);
      if (Number.isFinite(timestamp)) {
        const totalSeconds = Math.max(0, Math.floor(timestamp));
        return `${Math.floor(totalSeconds / 60)}:${String(totalSeconds % 60).padStart(2, "0")}`;
      }
      return normalizeReadexVideoFrameTimestampLabel(preview?.subtitle)
        || normalizeReadexVideoFrameTimestampLabel(readexPreviewDisplayTitle(preview));
    }

    function normalizeReadexVideoFrameTimestampLabel(value) {
      let text = trimmed(value);
      if (!text) {
        return "";
      }
      const timeIndex = text.indexOf("时间");
      if (timeIndex >= 0) {
        text = trimmed(text.slice(timeIndex + "时间".length));
      }
      text = trimmed(text.replace(/^[:：]\s*/, ""));
      text = trimmed(text.split("·")[0]);
      return text;
    }

    function normalizeReadexVideoFrameIndexLabel(value) {
      let text = trimmed(value);
      if (!text) {
        return "";
      }
      text = trimmed(text.split("·")[0]);
      if (!text || text.startsWith("时间")) {
        return "";
      }
      return text;
    }

    function readexPreviewIsApplyPatchDiff(preview) {
      const payload = readexApplyPatchDiffPayload(preview);
      if (!payload) {
        return false;
      }
      return Boolean(readexApplyPatchDiffText(payload));
    }

    function readexPreviewLooksLikeApplyPatch(preview) {
      if (readexPreviewIsApplyPatchDiff(preview)) {
        return true;
      }
      const title = trimmed(preview?.title);
      return title.includes("文本文件修改")
        || title.includes("文本文件差异");
    }

    function readexToolItemHasApplyPatchDiffPreview(item) {
      const previews = Array.isArray(item?.previewItems) ? item.previewItems : [];
      return previews.some(readexPreviewIsApplyPatchDiff);
    }

    function readexApplyPatchDiffPayload(preview) {
      return preview?.payload && typeof preview.payload === "object" ? preview.payload : null;
    }

    function readexApplyPatchDiffText(payload) {
      return trimmed(payload?.turn_diff || payload?.turnDiff || payload?.diff || payload?.patch_output?.turn_diff || payload?.patchOutput?.turnDiff);
    }

    function readexApplyPatchOperationID(payload) {
      return trimmed(payload?.operation_id || payload?.operationID);
    }

    function readexApplyPatchBooleanFlag(payload, keys) {
      for (const key of keys) {
        if (payload?.[key] === true) {
          return true;
        }
        if (payload?.[key] === false) {
          return false;
        }
      }
      return null;
    }

    function readexApplyPatchInitialPatchState(payload) {
      const canRedo = readexApplyPatchBooleanFlag(payload, ["can_redo", "canRedo"]);
      if (canRedo === true) {
        return "undone";
      }
      return "applied";
    }

    function appendReadexApplyPatchDiffPreview(details, item, preview) {
      const payload = readexApplyPatchDiffPayload(preview) || {};
      const diff = readexApplyPatchDiffText(payload);
      if (!diff) {
        return;
      }

      const card = document.createElement("div");
      card.className = "readex-apply-patch-diff-card";
      card.dataset.readexPatchState = readexApplyPatchInitialPatchState(payload);

      const body = document.createElement("div");
      body.className = "readex-apply-patch-diff-body";
      appendReadexApplyPatchDiffLines(body, diff);
      card.appendChild(body);

      const operationID = readexApplyPatchOperationID(payload);
      if (operationID) {
        appendReadexApplyPatchActions(card, operationID, payload);
      }

      details.appendChild(card);
    }

    function appendReadexApplyPatchDiffLines(container, diff) {
      String(diff || "").split(/\n/).forEach((line) => {
        const displayText = readexApplyPatchDiffDisplayText(line);
        if (displayText === null) {
          return;
        }
        const row = document.createElement("div");
        row.className = [
          "readex-apply-patch-diff-line",
          readexApplyPatchDiffLineClass(line)
        ].filter(Boolean).join(" ");
        row.textContent = displayText.length > 0 ? displayText : " ";
        container.appendChild(row);
      });
    }

    function readexApplyPatchDiffDisplayText(line) {
      if (readexApplyPatchDiffLineIsFileHeader(line)) {
        return null;
      }
      if (line.startsWith("@@")) {
        return readexApplyPatchHunkDisplayText(line);
      }
      return line;
    }

    function readexApplyPatchHunkDisplayText(line) {
      const match = line.match(/^@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+@@/);
      if (!match) {
        return "这一处修改";
      }
      const oldStart = Number(match[1]);
      const newStart = Number(match[2]);
      const lineNumber = oldStart > 0 ? oldStart : newStart;
      return lineNumber > 0 ? `第 ${lineNumber} 行附近的修改` : "这一处修改";
    }

    function readexApplyPatchDiffLineIsFileHeader(line) {
      return line.startsWith("diff --git")
        || line.startsWith("index ")
        || line.startsWith("---")
        || line.startsWith("+++")
        || line.startsWith("new file mode")
        || line.startsWith("deleted file mode");
    }

    function readexApplyPatchDiffLineClass(line) {
      if (line.startsWith("@@")) {
        return "is-hunk";
      }
      if (readexApplyPatchDiffLineIsFileHeader(line)) {
        return "is-header";
      }
      if (line.startsWith("+")) {
        return "is-added";
      }
      if (line.startsWith("-")) {
        return "is-removed";
      }
      return "is-context";
    }

    function appendReadexApplyPatchActions(card, operationID, payload) {
      const actions = document.createElement("div");
      actions.className = "readex-apply-patch-diff-actions";
      actions.appendChild(readexApplyPatchActionButton("撤回", "undo", operationID, card));
      actions.appendChild(readexApplyPatchActionButton("反撤回", "redo", operationID, card));
      card.appendChild(actions);
      updateReadexApplyPatchActionAvailability(card, payload);
    }

    function readexApplyPatchActionButton(label, direction, operationID, card) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "readex-apply-patch-diff-action";
      button.dataset.direction = direction;
      button.textContent = label;
      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        postMessageAction({
          action: "readexWriteOperationAction",
          operation_id: operationID,
          direction
        });
        card.dataset.readexPatchState = direction === "undo" ? "undone" : "applied";
        updateReadexApplyPatchActionAvailability(card);
      });
      return button;
    }

    function updateReadexApplyPatchActionAvailability(card, payload = null) {
      const canUndo = readexApplyPatchBooleanFlag(payload, ["can_undo", "canUndo"]);
      const canRedo = readexApplyPatchBooleanFlag(payload, ["can_redo", "canRedo"]);
      const state = card.dataset.readexPatchState === "undone" ? "undone" : "applied";
      card.querySelectorAll(".readex-apply-patch-diff-action").forEach((button) => {
        const direction = button.dataset.direction;
        if (direction === "undo") {
          button.disabled = canUndo === null ? state === "undone" : !canUndo;
        } else {
          button.disabled = canRedo === null ? state === "applied" : !canRedo;
        }
      });
    }

    function readexSupportPreviewMarkdown(preview) {
      return trimmed(preview?.markdown);
    }

    function appendReadexSupportMarkdownPreview(details, item, preview, options = {}) {
      const markdown = readexSupportPreviewMarkdown(preview);
      if (!markdown) {
        return;
      }
      const previewElement = document.createElement("div");
      previewElement.className = "message-content";
      const stableKey = trimmed(options?.blockKey)
        || readexPreviewStableKey(preview)
        || trimmed(item?.sourceBlockId)
        || trimmed(item?.sourceBlockID)
        || trimmed(item?.id);
      const renderOptions = markdownRenderOptionsForSupport(null, stableKey);
      const renderer = resolveMarkdownRenderer();
      renderMarkdownIntoElement(renderer, previewElement, markdown, renderOptions);
      details.appendChild(previewElement);
    }

    const readexApplyPatchRollingStatValues = new Map();

    function readexApplyPatchEditFilesIconMarkup() {
      return '<svg width="20" height="21" viewBox="0 0 20 21" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><path fill="currentColor" d="M11.3312 4.20472C12.7488 2.92391 14.9377 2.96644 16.3039 4.33265L16.4318 4.46742C17.6713 5.8393 17.6713 7.93343 16.4318 9.30531L16.3039 9.44007L10.0119 15.7311C9.68839 16.0546 9.45384 16.2917 9.22185 16.4821L8.98748 16.6588C8.78233 16.799 8.56429 16.9196 8.33709 17.0192L8.10759 17.1119C7.92582 17.1785 7.73843 17.2266 7.52166 17.2711L6.75701 17.4069L4.36345 17.8053C4.22059 17.8291 4.06914 17.8552 3.9406 17.8649C3.84183 17.8723 3.70833 17.875 3.56267 17.8395L3.41423 17.7907C3.19121 17.695 3.00747 17.5271 2.89177 17.316L2.84588 17.2223C2.75958 17.0209 2.76174 16.8276 2.77166 16.6959C2.78136 16.5674 2.80742 16.4159 2.83123 16.2731L3.22966 13.8795L3.36443 13.1149C3.40899 12.898 3.45795 12.7108 3.52459 12.5289L3.61736 12.2985C3.71691 12.0715 3.83772 11.854 3.97771 11.6491L4.15349 11.4147C4.34392 11.1825 4.58171 10.9484 4.90545 10.6246L11.1965 4.33265L11.3312 4.20472ZM5.84588 11.5651C5.49671 11.9142 5.31258 12.0998 5.1867 12.2526L5.07537 12.3991C4.98194 12.5358 4.90157 12.6812 4.83513 12.8327L4.77361 12.9869C4.73328 13.0971 4.70248 13.2125 4.66814 13.3815L4.54119 14.0983L4.14275 16.4918L4.14177 16.4938H4.1447L6.53826 16.0944L7.25505 15.9684C7.42406 15.9341 7.53946 15.9033 7.64959 15.8629L7.80291 15.8014C7.95461 15.7349 8.09953 15.6538 8.2365 15.5602L8.38396 15.4498C8.53674 15.3239 8.72231 15.1398 9.07146 14.7907L14.0588 9.80238L10.8332 6.57679L5.84588 11.5651ZM15.3635 5.27308C14.5281 4.43776 13.2058 4.38573 12.3097 5.11683L12.1369 5.27308L11.7736 5.63636L15.0002 8.86195L15.3635 8.49964L15.5197 8.32581C16.2015 7.48961 16.2015 6.28311 15.5197 5.44691L15.3635 5.27308Z"/></svg>';
    }

    function readexApplyPatchPayloadNumber(payload, keys) {
      for (const key of keys) {
        const value = Number(payload?.[key]);
        if (Number.isFinite(value)) {
          return Math.max(0, Math.trunc(value));
        }
      }
      return null;
    }

    function readexApplyPatchDiffStats(diff) {
      let added = 0;
      let removed = 0;
      String(diff || "").split(/\n/).forEach((line) => {
        if (line.startsWith("+++") || line.startsWith("---")) {
          return;
        }
        if (line.startsWith("+")) {
          added += 1;
        } else if (line.startsWith("-")) {
          removed += 1;
        }
      });
      return { added, removed };
    }

    function readexApplyPatchStats(payload) {
      const diffStats = readexApplyPatchDiffStats(readexApplyPatchDiffText(payload));
      return {
        added: readexApplyPatchPayloadNumber(payload, ["lines_added", "linesAdded", "added"]) ?? diffStats.added,
        removed: readexApplyPatchPayloadNumber(payload, ["lines_removed", "linesRemoved", "removed"]) ?? diffStats.removed
      };
    }

    function readexApplyPatchDisplayFileName(preview, payload) {
      const directName = trimmed(
        payload?.file_name
          || payload?.fileName
          || preview?.fileName
          || preview?.file_name
          || preview?.documentName
          || preview?.document_name
      );
      if (directName) {
        return directName;
      }
      const path = readexApplyPatchVirtualPath(payload?.move_path || payload?.movePath || payload?.path || payload?.p);
      if (!path) {
        return "文件";
      }
      const parts = path.split(/[\\/]+/).filter(Boolean);
      return parts[parts.length - 1] || path;
    }

    function readexApplyPatchActivitySummaryText(item) {
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      const primaryPreview = readexApplyPatchPrimaryPreview(previewItems.filter(readexPreviewIsApplyPatchDiff));
      if (!primaryPreview) {
        return trimmed(item?.text) || (readexToolItemIsLive(item) ? "正在编辑文件" : "已编辑文件");
      }
      const payload = readexApplyPatchDiffPayload(primaryPreview) || {};
      const files = readexApplyPatchPreviewFiles(primaryPreview, payload);
      const status = readexApplyPatchIsEditing(item, payload) ? "正在编辑" : "已编辑";
      if (files.length > 1) {
        return `${status} ${files.length} 个文件`;
      }
      const fileName = files[0]?.fileName || readexApplyPatchDisplayFileName(primaryPreview, payload);
      return `${status} ${fileName}`;
    }

    function readexApplyPatchPreviewFiles(preview, payload) {
      const structuredFiles = readexApplyPatchStructuredFiles(preview, payload);
      if (structuredFiles.length) {
        return structuredFiles;
      }
      const diff = readexApplyPatchDiffText(payload);
      if (!diff) {
        return [];
      }
      const changedPaths = readexApplyPatchChangedPaths(payload);
      const sections = readexApplyPatchSplitDiffByFile(diff);
      return sections.map((sectionDiff, index) => {
        const path = readexApplyPatchPathFromDiffSection(sectionDiff)
          || changedPaths[index]
          || readexApplyPatchDisplayPath(payload)
          || readexApplyPatchVirtualPath(payload?.path || payload?.p)
          || "";
        const filePayload = {
          ...(payload || {}),
          path,
          p: path,
          file_name: readexApplyPatchFileNameFromPath(path),
          turn_diff: sectionDiff,
          turnDiff: sectionDiff,
          diff: sectionDiff
        };
        return {
          index,
          path,
          fileName: filePayload.file_name || readexApplyPatchDisplayFileName(preview, filePayload),
          payload: filePayload,
          preview: readexApplyPatchPreviewForFile(preview, filePayload, sectionDiff, index)
        };
      });
    }

    function readexApplyPatchStructuredFiles(preview, payload) {
      const files = Array.isArray(payload?.files)
        ? payload.files
        : (Array.isArray(payload?.changed_files) ? payload.changed_files : []);
      return files
        .map((file, index) => {
          if (!file || typeof file !== "object") {
            return null;
          }
          const diff = readexApplyPatchDiffText(file);
          const path = readexApplyPatchVirtualPath(file.path || file.p || file.move_path || file.movePath)
            || readexApplyPatchDisplayPath(file);
          if (!diff && !path) {
            return null;
          }
          const filePayload = {
            ...(payload || {}),
            ...file,
            path,
            p: path,
            file_name: trimmed(file.file_name || file.fileName) || readexApplyPatchFileNameFromPath(path),
            turn_diff: diff || readexApplyPatchDiffText(payload),
            turnDiff: diff || readexApplyPatchDiffText(payload),
            diff: diff || readexApplyPatchDiffText(payload)
          };
          return {
            index,
            path,
            fileName: filePayload.file_name || readexApplyPatchDisplayFileName(preview, filePayload),
            payload: filePayload,
            preview: readexApplyPatchPreviewForFile(preview, filePayload, filePayload.diff, index)
          };
        })
        .filter(Boolean);
    }

    function readexApplyPatchPreviewForFile(preview, payload, diff, index) {
      const fileName = payload?.file_name || readexApplyPatchFileNameFromPath(payload?.path || payload?.p);
      return {
        ...(preview || {}),
        id: [
          trimmed(preview?.id),
          trimmed(payload?.path || payload?.p),
          Number.isFinite(Number(index)) ? String(index) : ""
        ].filter(Boolean).join(":"),
        title: fileName || preview?.title || "文本文件差异",
        subtitle: readexApplyPatchVirtualPath(payload?.path || payload?.p) || preview?.subtitle,
        documentName: fileName || preview?.documentName,
        fileName: fileName || preview?.fileName,
        markdown: undefined,
        payload: {
          ...(payload || {}),
          turn_diff: diff,
          turnDiff: diff,
          diff
        }
      };
    }

    function readexApplyPatchChangedPaths(payload) {
      const paths = Array.isArray(payload?.changed_paths)
        ? payload.changed_paths
        : (Array.isArray(payload?.changedPaths) ? payload.changedPaths : []);
      return paths.map(readexApplyPatchVirtualPath).filter(Boolean);
    }

    function readexApplyPatchSplitDiffByFile(diff) {
      const lines = String(diff || "").split(/\n/u);
      const sections = [];
      let current = [];
      lines.forEach((line) => {
        if (line.startsWith("diff --git ") && current.length) {
          sections.push(current.join("\n"));
          current = [];
        }
        current.push(line);
      });
      if (current.length) {
        sections.push(current.join("\n"));
      }
      return sections.map((section) => section.replace(/\n+$/u, "")).filter(Boolean);
    }

    function readexApplyPatchPathFromDiffSection(diff) {
      const lines = String(diff || "").split(/\n/u);
      for (const line of lines) {
        if (line.startsWith("+++ ")) {
          const path = readexApplyPatchNormalizeDiffPath(line.slice(4));
          if (path) {
            return path;
          }
        }
      }
      for (const line of lines) {
        if (line.startsWith("--- ")) {
          const path = readexApplyPatchNormalizeDiffPath(line.slice(4));
          if (path) {
            return path;
          }
        }
      }
      const gitHeader = lines.find((line) => line.startsWith("diff --git "));
      if (gitHeader) {
        const markerIndex = gitHeader.indexOf(" b/");
        if (markerIndex >= 0) {
          return readexApplyPatchNormalizeDiffPath(gitHeader.slice(markerIndex + 1));
        }
      }
      return "";
    }

    function readexApplyPatchNormalizeDiffPath(value) {
      let path = trimmed(value).replace(/^"|"$/g, "");
      if (!path || path === "/dev/null") {
        return "";
      }
      path = path.replace(/^(?:a|b)\//u, "");
      return readexApplyPatchVirtualPath(path);
    }

    function readexApplyPatchFileNameFromPath(path) {
      const normalized = readexApplyPatchVirtualPath(path);
      if (!normalized) {
        return "";
      }
      const parts = normalized.split(/[\\/]+/).filter(Boolean);
      return parts[parts.length - 1] || normalized;
    }

    function readexApplyPatchPathLooksLikeLocalFileSystemPath(path) {
      return /^file:/i.test(path)
        || /^\/(?:Users|Volumes|private|var|tmp|Library|System|Applications|opt|usr|bin|sbin|etc)(?:\/|$)/.test(path);
    }

    function readexApplyPatchVirtualPath(value) {
      const path = trimmed(value);
      if (!path) {
        return "";
      }
      if (/^[a-z][a-z0-9+.-]*:/i.test(path) || readexApplyPatchPathLooksLikeLocalFileSystemPath(path)) {
        return "";
      }
      return path.startsWith("/") ? path : `/${path}`;
    }

    function readexApplyPatchDisplayPath(payload, reference = null) {
      return readexApplyPatchVirtualPath(
        reference?.path
          || payload?.move_path
          || payload?.movePath
          || payload?.path
          || payload?.p
      );
    }

    function readexApplyPatchStatusIsLive(status) {
      const normalized = normalizedReadexStatus(status);
      if (normalized) {
        return normalized === "pending"
          || normalized === "processing"
          || normalized === "streaming"
          || normalized === "searching";
      }
      const value = trimmed(status).toLowerCase();
      return value === "editing"
        || value === "applying"
        || value === "running"
        || value === "updated"
        || value === "begin";
    }

    function readexApplyPatchStatusIsComplete(status) {
      const normalized = normalizedReadexStatus(status);
      if (normalized) {
        return normalized === "success" || normalized === "failed" || normalized === "interrupted";
      }
      const value = trimmed(status).toLowerCase();
      return value === "edited"
        || value === "applied"
        || value === "done"
        || value === "end";
    }

    function readexApplyPatchIsEditing(item, payload) {
      const statuses = [payload?.patch_status, payload?.patchStatus, payload?.status];
      if (statuses.some(readexApplyPatchStatusIsComplete)) {
        return false;
      }
      if (statuses.some(readexApplyPatchStatusIsLive)) {
        return true;
      }
      return readexToolItemIsLive(item);
    }

    function readexApplyPatchPrimaryPreview(previews) {
      const candidates = Array.isArray(previews) ? previews : [];
      if (!candidates.length) {
        return null;
      }
      for (let index = candidates.length - 1; index >= 0; index -= 1) {
        const payload = readexApplyPatchDiffPayload(candidates[index]) || {};
        const statuses = [payload?.patch_status, payload?.patchStatus, payload?.status];
        if (statuses.some(readexApplyPatchStatusIsComplete)) {
          return candidates[index];
        }
      }
      return candidates[candidates.length - 1];
    }

    function readexApplyPatchPreviewKey(item, preview, payload) {
      return [
        trimmed(preview?.id),
        trimmed(payload?.call_id || payload?.callID || item?.callID || item?.callId),
        trimmed(payload?.move_path || payload?.movePath || payload?.path || payload?.p),
        trimmed(item?.id)
      ].filter(Boolean).join("|") || readexPreviewStableKey(preview) || trimmed(item?.id) || "apply_patch_diff";
    }

    function readexApplyPatchDigitIndex(character) {
      return /^\d$/.test(character) ? Number(character) : 0;
    }

    function setReadexApplyPatchDigitOffset(stack, character) {
      stack.style.setProperty("--readex-patch-digit-offset", String(readexApplyPatchDigitIndex(character)));
    }

    function appendReadexApplyPatchRollingNumber(parent, value, key) {
      const nextText = String(Math.max(0, Math.trunc(Number(value) || 0)));
      const previousText = readexApplyPatchRollingStatValues.get(key) || "";
      const shouldAnimate = Boolean(previousText && previousText !== nextText);
      const previousCharacters = Array.from(previousText);
      const nextCharacters = Array.from(nextText);
      const number = document.createElement("span");
      number.className = "readex-apply-patch-stat-number";
      number.setAttribute("aria-hidden", "true");

      nextCharacters.forEach((character, index) => {
        if (!/^\d$/.test(character)) {
          const separator = document.createElement("span");
          separator.className = "readex-apply-patch-stat-number-separator";
          separator.textContent = character;
          number.appendChild(separator);
          return;
        }
        const previousIndex = previousCharacters.length - nextCharacters.length + index;
        const previousCharacter = previousCharacters[previousIndex];
        const initialCharacter = shouldAnimate && /^\d$/.test(previousCharacter) ? previousCharacter : character;
        const windowElement = document.createElement("span");
        windowElement.className = "readex-apply-patch-stat-digit-window";
        const stack = document.createElement("span");
        stack.className = "readex-apply-patch-stat-digit-stack";
        ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"].forEach((digit) => {
          const row = document.createElement("span");
          row.className = "readex-apply-patch-stat-digit";
          row.textContent = digit;
          stack.appendChild(row);
        });
        setReadexApplyPatchDigitOffset(stack, initialCharacter);
        windowElement.appendChild(stack);
        number.appendChild(windowElement);
        if (shouldAnimate && initialCharacter !== character) {
          const requestFrame = typeof window.requestAnimationFrame === "function"
            ? window.requestAnimationFrame.bind(window)
            : (callback) => window.setTimeout(callback, 16);
          requestFrame(() => {
            stack.classList.add("is-rolling");
            setReadexApplyPatchDigitOffset(stack, character);
          });
        }
      });

      readexApplyPatchRollingStatValues.set(key, nextText);
      parent.appendChild(number);
    }

    function appendReadexApplyPatchStat(parent, sign, value, className, key) {
      const stat = document.createElement("span");
      stat.className = `readex-apply-patch-stat ${className}`;
      stat.setAttribute("aria-label", `${sign}${Math.max(0, Math.trunc(Number(value) || 0))}`);
      stat.appendChild(document.createTextNode(sign));
      appendReadexApplyPatchRollingNumber(stat, value, key);
      parent.appendChild(stat);
    }

    function appendReadexApplyPatchActivityItem(details, item, stateOwner = null, disclosureKey = "", options = {}) {
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      const applyPatchPreviews = previewItems.filter(readexPreviewIsApplyPatchDiff);
      const primaryPreview = readexApplyPatchPrimaryPreview(applyPatchPreviews);
      if (!primaryPreview) {
        appendReadexToolDisclosureItem(details, item, stateOwner, disclosureKey, options);
        return;
      }
      const payload = readexApplyPatchDiffPayload(primaryPreview) || {};
      const initiallyExpanded = readexNestedDisclosureIsExpanded(stateOwner, disclosureKey);
      const accentSource = options?.previewContentAccentContext || trimmed(options?.extractedPDFAccentColor);
      const accentColor = readexToolItemPreviewContentAccentColor(item, accentSource)
        || readexApplyPatchAccentColor(readexApplyPatchPreviewKey(item, primaryPreview, payload));
      const isEditing = readexApplyPatchIsEditing(item, payload);
      const files = readexApplyPatchPreviewFiles(primaryPreview, payload);
      const summaryFileName = files.length > 1
        ? `${files.length} 个文件`
        : (files[0]?.fileName || readexApplyPatchDisplayFileName(primaryPreview, payload));
      const wrapper = document.createElement("div");
      wrapper.className = "readex-apply-patch-activity";

      const row = document.createElement("div");
      row.className = [
        "readex-apply-patch-activity-row",
        isEditing ? "is-live" : "is-complete",
        readexToolItemIsFailed(item) ? "is-failed" : "",
        accentColor ? "has-preview-content-accent" : ""
      ].filter(Boolean).join(" ");
      applyReadexExtractedPDFAccentVariable(row, accentColor);
      row.setAttribute("role", "button");
      row.setAttribute("tabindex", "0");
      row.setAttribute("aria-expanded", initiallyExpanded ? "true" : "false");

      const icon = document.createElement("span");
      icon.className = "readex-apply-patch-activity-icon";
      icon.innerHTML = readexApplyPatchEditFilesIconMarkup();
      row.appendChild(icon);

      const text = document.createElement("span");
      text.className = "readex-apply-patch-activity-text";

      const status = document.createElement("span");
      status.className = "readex-apply-patch-status";
      status.textContent = isEditing ? "正在编辑" : "已编辑";
      text.appendChild(status);

      const file = document.createElement("span");
      file.className = "readex-apply-patch-file-link";
      file.textContent = summaryFileName;
      text.appendChild(file);
      row.appendChild(text);

      const nested = document.createElement("div");
      nested.className = "readex-tool-activity-nested readex-apply-patch-activity-nested";
      nested.hidden = !initiallyExpanded;
      if (files.length > 1) {
        files.forEach((fileInfo, index) => {
          appendReadexApplyPatchFileActivityItem(
            nested,
            item,
            fileInfo,
            stateOwner,
            `${disclosureKey}:file:${trimmed(fileInfo.path) || index}`
          );
        });
      } else {
        appendReadexApplyPatchDiffPreview(nested, item, files[0]?.preview || primaryPreview);
      }

      const toggle = (event) => {
        event.preventDefault();
        event.stopPropagation();
        const expanded = row.getAttribute("aria-expanded") === "true";
        const nextExpanded = !expanded;
        row.setAttribute("aria-expanded", nextExpanded ? "true" : "false");
        setReadexNestedDisclosureExpanded(stateOwner, disclosureKey, nextExpanded);
        cancelReadexAncestorDisclosureAnimations(nested);
        animateReadexDisclosureElement(nested, nextExpanded, { hideOnFinish: true, reserveLayout: true });
      };
      row.addEventListener("click", toggle);
      row.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        toggle(event);
      });

      wrapper.appendChild(row);
      wrapper.appendChild(nested);
      details.appendChild(wrapper);
    }

    function appendReadexApplyPatchFileActivityItem(details, item, fileInfo, stateOwner = null, disclosureKey = "") {
      const preview = fileInfo?.preview;
      const payload = fileInfo?.payload || readexApplyPatchDiffPayload(preview) || {};
      const initiallyExpanded = readexNestedDisclosureIsExpanded(stateOwner, disclosureKey);
      const fileName = fileInfo?.fileName || readexApplyPatchDisplayFileName(preview, payload);

      const wrapper = document.createElement("div");
      wrapper.className = "readex-apply-patch-file-disclosure";

      const row = document.createElement("div");
      row.className = [
        "readex-apply-patch-activity-row",
        "readex-apply-patch-file-row",
        readexToolItemIsFailed(item) ? "is-failed" : ""
      ].filter(Boolean).join(" ");
      row.setAttribute("role", "button");
      row.setAttribute("tabindex", "0");
      row.setAttribute("aria-expanded", initiallyExpanded ? "true" : "false");

      const text = document.createElement("span");
      text.className = "readex-apply-patch-activity-text";

      const status = document.createElement("span");
      status.className = "readex-apply-patch-status";
      status.textContent = "已编辑";
      text.appendChild(status);

      const file = document.createElement("span");
      file.className = "readex-apply-patch-file-link";
      file.textContent = fileName;
      text.appendChild(file);
      row.appendChild(text);

      const nested = document.createElement("div");
      nested.className = "readex-tool-activity-nested readex-apply-patch-activity-nested";
      nested.hidden = !initiallyExpanded;
      appendReadexApplyPatchDiffPreview(nested, item, preview);

      const toggle = (event) => {
        event.preventDefault();
        event.stopPropagation();
        const expanded = row.getAttribute("aria-expanded") === "true";
        const nextExpanded = !expanded;
        row.setAttribute("aria-expanded", nextExpanded ? "true" : "false");
        setReadexNestedDisclosureExpanded(stateOwner, disclosureKey, nextExpanded);
        cancelReadexAncestorDisclosureAnimations(nested);
        animateReadexDisclosureElement(nested, nextExpanded, { hideOnFinish: true, reserveLayout: true });
      };
      row.addEventListener("click", toggle);
      row.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        toggle(event);
      });

      wrapper.appendChild(row);
      wrapper.appendChild(nested);
      details.appendChild(wrapper);
    }

    function readexToolItemHasExtractedPagePreviews(item) {
      const previews = Array.isArray(item?.previewItems) ? item.previewItems : [];
      return readexExtractedPDFPreviewItems(previews).length > 0;
    }

    function readexToolItemUsesExtractedPagePreviewPresentation(item) {
      return readexToolItemHasExtractedPagePreviews(item)
        && readexToolItemIsExtractedPDFPageLookup(item);
    }

    function readexToolItemUsesVideoFramePreviewPresentation(item) {
      const previews = Array.isArray(item?.previewItems) ? item.previewItems : [];
      return previews.some(readexPreviewIsVideoFrame);
    }

    function readexToolItemUsesPreviewContentAccentPresentation(item) {
      return Boolean(readexPreviewContentAccentKindForItem(item));
    }

    function readexToolItemShouldUsePreviewContentAccentColor(item, accentSource = "") {
      return Boolean(readexToolItemPreviewContentAccentColor(item, accentSource));
    }

    function readexToolItemPreviewContentAccentColor(item, accentSource = "") {
      if (!readexToolItemUsesPreviewContentAccentPresentation(item) || readexToolItemIsFailed(item)) {
        return "";
      }
      const kind = readexPreviewContentAccentKindForItem(item);
      const context = readexPreviewContentAccentSourceContext(accentSource);
      const color = readexPreviewContentAccentColorFromContext(context, kind);
      if (color) {
        return color;
      }
      return accentSource && typeof accentSource !== "object" ? trimmed(accentSource) : "";
    }

    function readexExtractedPageRangeLabel(preview) {
      const title = trimmed(preview?.title);
      return title
        .replace(/^抽取范围[:：]?\s*/u, "")
        .replace(/^书页\s*/u, "")
        .trim() || title || "页面";
    }

    function readexExtractedPageRangeLabels(previews) {
      const safePreviews = Array.isArray(previews) ? previews : [];
      return safePreviews
        .filter((preview) => trimmed(preview?.attachmentKind) === "extractedPDF")
        .map(readexExtractedPageRangeLabel)
        .map((label) => trimmed(label).replace(/^书页\s*/u, ""))
        .filter(Boolean);
    }

    function readexExtractedPageCountFromLabels(labels) {
      const counts = labels.map((label) => {
        const text = trimmed(label);
        const rangeMatch = text.match(/^(\d+)\s*[-–]\s*(\d+)$/u);
        if (rangeMatch) {
          const start = Number(rangeMatch[1]);
          const end = Number(rangeMatch[2]);
          return Number.isFinite(start) && Number.isFinite(end) ? Math.abs(end - start) + 1 : 0;
        }
        return /^\d+$/u.test(text) ? 1 : 0;
      });
      return counts.every((count) => count > 0)
        ? counts.reduce((sum, count) => sum + count, 0)
        : 0;
    }

    function readexTextContainsExtractedPDFPageCount(text, count) {
      if (!Number.isFinite(count) || count <= 0) {
        return false;
      }
      return new RegExp(`(?:（|\\()\\s*${count}\\s*页\\s*(?:）|\\))`, "u").test(text);
    }

    function readexToolTextWithExtractedPageLabels(text, previewItems) {
      const value = trimmed(text);
      if (!value.includes("书页")) {
        return value;
      }
      const labels = readexExtractedPageRangeLabels(previewItems);
      const count = readexExtractedPDFPageCountFromPreviewItems(previewItems)
        || readexExtractedPageCountFromLabels(labels);
      const countText = count > 0 ? `（${count} 页）` : "";
      if (!labels.length) {
        return value;
      }
      if (labels.some((label) => value.includes(label))) {
        return countText && !readexTextContainsExtractedPDFPageCount(value, count)
          ? `${value}${countText}`
          : value;
      }
      return `${value} ${labels.join("、")}${countText}`;
    }

    function readexToolTextWithConciseKnowledgeMapDocuments(text, previewItems) {
      const value = trimmed(text);
      const count = Array.isArray(previewItems) ? previewItems.length : 0;
      if (
        count > 1
        && readexToolCategory(value) === "knowledgeMap"
        && value.includes("篇文档")
        && value.includes("知识地图结构")
      ) {
        return `已查看${count}篇文档的知识地图结构`;
      }
      return value;
    }

    function readexToolDisplayText(text, previewItems) {
      const conciseText = readexToolTextWithConciseKnowledgeMapDocuments(text, previewItems);
      return readexToolTextWithExtractedPageLabels(conciseText, previewItems);
    }

    function appendReadexExtractedPageRangeDetail(nested, item, accentSource = "") {
      const previewContentAccentColor = readexToolItemPreviewContentAccentColor(item, accentSource);
      const detail = document.createElement("div");
      detail.className = [
        "readex-tool-activity-disclosure-detail",
        "readex-tool-page-range-detail",
        previewContentAccentColor ? "has-preview-content-accent" : ""
      ].filter(Boolean).join(" ");
      applyReadexExtractedPDFAccentVariable(detail, previewContentAccentColor);

      item.previewItems.forEach((preview) => {
        const row = document.createElement("button");
        row.type = "button";
        row.className = "readex-tool-page-range-row readex-tool-page-range-button";
        applyReadexExtractedPDFAccent(row, previewContentAccentColor);
        row.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          openReadexExtractedPageReferenceOrPreview(preview, item);
        });

        const prefix = document.createElement("span");
        prefix.textContent = "已查看 ";
        row.appendChild(prefix);

        const label = document.createElement("span");
        label.className = "readex-tool-page-range-label";
        label.textContent = `书页 ${readexExtractedPageRangeLabel(preview)}`;
        row.appendChild(label);
        detail.appendChild(row);
      });

      nested.appendChild(detail);
    }

    function appendReadexToolDisclosureDetail(nested, detailText, item = null, accentSource = "") {
      const previewContentAccentColor = readexToolItemPreviewContentAccentColor(item, accentSource);
      const detail = document.createElement("div");
      detail.className = [
        "readex-tool-activity-disclosure-detail",
        previewContentAccentColor ? "has-preview-content-accent" : ""
      ].filter(Boolean).join(" ");
      applyReadexExtractedPDFAccentVariable(detail, previewContentAccentColor);
      installReadexCollabAgentOpenAction(detail, item);
      const lines = trimmed(detailText)
        .split(/\n+/)
        .map((line) => trimmed(line))
        .filter(Boolean);

      if (lines.length <= 1) {
        detail.textContent = trimmed(detailText);
        nested.appendChild(detail);
        return;
      }

      detail.classList.add("is-line-list");
      lines.forEach((line) => {
        const row = document.createElement("div");
        row.className = "readex-tool-activity-disclosure-detail-row";
        row.textContent = line;
        detail.appendChild(row);
      });
      nested.appendChild(detail);
    }

    function readexToolItemShouldDisclose(item) {
      if (!item) {
        return false;
      }
      const detailText = readexToolItemDetailText(item);
      const category = readexToolCategory(item);
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      if (readexToolItemChildItems(item).length > 0) {
        return true;
      }
      if (readexToolItemHasShellExecution(item)) {
        return true;
      }
      if (readexToolItemIsFailed(item) && trimmed(item?.error)) {
        return true;
      }
      if (previewItems.length > 1) {
        return true;
      }
      if (previewItems.length === 1 && readexToolItemSinglePreviewShouldDisclose(item)) {
        return true;
      }
      if (category === "videoSource" || category === "subtitle" || category === "audio") {
        return false;
      }
      if (detailText) {
        return true;
      }
      return false;
    }

    function readexShellDisplayCwd(rawCwd) {
      let cwd = trimmed(rawCwd) || "/";
      if (!cwd.startsWith("/")) {
        cwd = `/${cwd}`;
      }

      const workspaceLabelPrefix = "/<readex-workspace>/files";
      if (cwd === workspaceLabelPrefix) {
        return "/";
      }
      if (cwd.startsWith(`${workspaceLabelPrefix}/`)) {
        return cwd.slice(workspaceLabelPrefix.length) || "/";
      }

      const workspaceMarker = "/ReadexModeWorkspaces/";
      const workspaceIndex = cwd.indexOf(workspaceMarker);
      if (workspaceIndex !== -1) {
        const filesIndex = cwd.indexOf("/files", workspaceIndex + workspaceMarker.length);
        if (filesIndex !== -1) {
          const suffix = cwd.slice(filesIndex + "/files".length);
          if (!suffix) {
            return "/";
          }
          if (suffix.startsWith("/")) {
            return suffix;
          }
        }
      }

      return cwd;
    }

    function readexShellExecutionPrompt(shell) {
      const cwd = readexShellDisplayCwd(shell?.cwd);
      return `readex@library ${cwd} %`;
    }

    function readexShellExecutionPromptParts(shell) {
      const cwd = readexShellDisplayCwd(shell?.cwd);
      return {
        user: "readex@library",
        cwd,
        sigil: "%"
      };
    }

    function readexShellExecutionTranscript(shell) {
      const lines = [`${readexShellExecutionPrompt(shell)} ${shell?.command || ""}`];
      const output = typeof shell?.output === "string" ? shell.output.trimEnd() : "";
      if (output) {
        lines.push(output);
      }
      if (shell?.exitCode != null) {
        lines.push("", `Process exited with code ${shell.exitCode}`);
      }
      if (shell?.wallTimeSeconds != null) {
        if (shell?.exitCode == null) {
          lines.push("");
        }
        lines.push(`Wall time: ${shell.wallTimeSeconds.toFixed(4)} seconds`);
      }
      return lines.join("\n");
    }

    function appendReadexShellExecutionText(parent, className, text) {
      if (!text) {
        return;
      }
      const span = document.createElement("span");
      span.className = className;
      span.textContent = text;
      parent.appendChild(span);
    }

    function appendReadexShellExecutionPrompt(parent, shell) {
      const parts = readexShellExecutionPromptParts(shell);
      const prompt = document.createElement("span");
      prompt.className = "readex-shell-execution-prompt";
      appendReadexShellExecutionText(prompt, "readex-shell-execution-prompt-user", parts.user);
      prompt.appendChild(document.createTextNode(" "));
      appendReadexShellExecutionText(prompt, "readex-shell-execution-prompt-cwd", parts.cwd);
      prompt.appendChild(document.createTextNode(" "));
      appendReadexShellExecutionText(prompt, "readex-shell-execution-prompt-sigil", parts.sigil);
      parent.appendChild(prompt);
    }

    function appendReadexShellExecutionOutputText(parent, text, className = "readex-shell-execution-output") {
      appendReadexShellExecutionText(parent, className, text);
    }

    function appendReadexShellExecutionHighlightedSearchText(parent, text, query) {
      const needle = trimmed(query);
      if (!text || !needle || needle.length > 120) {
        appendReadexShellExecutionOutputText(parent, text);
        return;
      }

      const lowerText = text.toLowerCase();
      const lowerNeedle = needle.toLowerCase();
      let cursor = 0;
      while (cursor < text.length) {
        const index = lowerText.indexOf(lowerNeedle, cursor);
        if (index === -1) {
          appendReadexShellExecutionOutputText(parent, text.slice(cursor));
          break;
        }
        if (index > cursor) {
          appendReadexShellExecutionOutputText(parent, text.slice(cursor, index));
        }
        appendReadexShellExecutionOutputText(
          parent,
          text.slice(index, index + needle.length),
          "readex-shell-execution-match"
        );
        cursor = index + needle.length;
      }
    }

    function readexShellExecutionOutputLooksLikeDirectoryPath(shell, line) {
      const command = trimmed(shell?.command);
      if (!line || !command.startsWith("find ")) {
        return false;
      }
      return /\s-type\s+d(?:\s|$)/.test(command) || /\s-type\s+directory(?:\s|$)/.test(command);
    }

    function appendReadexShellExecutionOutputLine(parent, shell, line, isErrorOutput) {
      if (isErrorOutput) {
        appendReadexShellExecutionOutputText(parent, line, "readex-shell-execution-error");
        return;
      }

      const longDirectoryMatch = line.match(/^(d[^\s]*\s+\S+\s+)(.+)$/);
      if (longDirectoryMatch) {
        appendReadexShellExecutionOutputText(parent, longDirectoryMatch[1]);
        appendReadexShellExecutionOutputText(parent, longDirectoryMatch[2], "readex-shell-execution-directory");
        return;
      }

      if (line.startsWith("/") && line.endsWith(":")) {
        appendReadexShellExecutionOutputText(parent, line.slice(0, -1), "readex-shell-execution-directory");
        appendReadexShellExecutionOutputText(parent, ":");
        return;
      }

      if (readexShellExecutionOutputLooksLikeDirectoryPath(shell, line)) {
        appendReadexShellExecutionOutputText(parent, line, "readex-shell-execution-directory");
        return;
      }

      if (trimmed(shell?.kind) === "search" && trimmed(shell?.query)) {
        appendReadexShellExecutionHighlightedSearchText(parent, line, shell.query);
        return;
      }

      appendReadexShellExecutionOutputText(parent, line);
    }

    function appendReadexShellExecutionOutput(parent, shell, output) {
      const isErrorOutput = shell?.exitCode != null && shell.exitCode !== 0;
      output.split("\n").forEach((line, index) => {
        if (index > 0) {
          parent.appendChild(document.createTextNode("\n"));
        }
        appendReadexShellExecutionOutputLine(parent, shell, line, isErrorOutput);
      });
    }

    function appendReadexShellExecutionTranscript(parent, shell) {
      const inputLine = document.createElement("span");
      inputLine.className = "readex-shell-execution-input-line";
      appendReadexShellExecutionPrompt(inputLine, shell);
      appendReadexShellExecutionText(inputLine, "readex-shell-execution-command", ` ${shell?.command || ""}`);
      parent.appendChild(inputLine);

      const output = typeof shell?.output === "string" ? shell.output.trimEnd() : "";
      const hasMeta = shell?.exitCode != null || shell?.wallTimeSeconds != null;
      if (output || hasMeta) {
        const separator = document.createElement("span");
        separator.className = "readex-shell-execution-separator";
        separator.setAttribute("aria-hidden", "true");
        parent.appendChild(separator);
      }
      if (output) {
        const outputBlock = document.createElement("span");
        outputBlock.className = "readex-shell-execution-output-block";
        appendReadexShellExecutionOutput(outputBlock, shell, output);
        parent.appendChild(outputBlock);
      }

      if (hasMeta) {
        parent.appendChild(document.createTextNode("\n\n"));
      }
      if (shell?.exitCode != null) {
        appendReadexShellExecutionText(
          parent,
          shell.exitCode === 0 ? "readex-shell-execution-meta" : "readex-shell-execution-meta readex-shell-execution-error",
          `Process exited with code ${shell.exitCode}`
        );
      }
      if (shell?.wallTimeSeconds != null) {
        if (shell?.exitCode != null) {
          parent.appendChild(document.createTextNode("\n"));
        }
        appendReadexShellExecutionText(parent, "readex-shell-execution-meta", `Wall time: ${shell.wallTimeSeconds.toFixed(4)} seconds`);
      }
    }

    function appendReadexShellExecutionViewer(nested, item) {
      const shell = readexToolItemShellExecution(item);
      if (!shell) {
        return;
      }

      const viewer = document.createElement("div");
      viewer.className = [
        "readex-shell-execution",
        shell.exitCode != null && shell.exitCode !== 0 ? "is-failed" : ""
      ].filter(Boolean).join(" ");

      const transcript = document.createElement("pre");
      transcript.className = "readex-shell-execution-transcript";
      appendReadexShellExecutionTranscript(transcript, shell);
      viewer.appendChild(transcript);

      nested.appendChild(viewer);
    }

    function appendReadexShellExecutionItem(details, item, stateOwner = null, disclosureKey = "", options = {}) {
      const initiallyExpanded = readexNestedDisclosureIsExpanded(stateOwner, disclosureKey);
      const extractedPDFAccentColor = trimmed(options?.extractedPDFAccentColor);
      const wrapper = document.createElement("div");
      wrapper.className = "readex-tool-activity-disclosure readex-shell-execution-disclosure";

      const row = document.createElement("button");
      row.type = "button";
      row.className = [
        "readex-tool-activity-item",
        readexToolItemIsLive(item) ? "is-live" : "",
        readexToolItemIsFailed(item) ? "is-failed" : "",
        "is-preview"
      ].filter(Boolean).join(" ");
      row.setAttribute("aria-expanded", initiallyExpanded ? "true" : "false");
      appendReadexToolAvatarOrIcon(row, item, extractedPDFAccentColor);

      const textWrap = document.createElement("span");
      textWrap.className = "readex-tool-activity-item-text";

      const label = document.createElement("span");
      label.className = "readex-tool-activity-item-title";
      renderReadexToolItemTitle(label, item, extractedPDFAccentColor);
      textWrap.appendChild(label);
      row.appendChild(textWrap);
      appendReadexCollabAgentOpenChip(row, item);

      const chevron = document.createElement("span");
      chevron.className = "readex-tool-activity-item-chevron";
      chevron.innerHTML = makeIcon("chevron-right");
      row.appendChild(chevron);

      const nested = document.createElement("div");
      nested.className = "readex-tool-activity-nested";
      nested.hidden = !initiallyExpanded;
      appendReadexShellExecutionViewer(nested, item);

      row.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        const expanded = row.getAttribute("aria-expanded") === "true";
        const nextExpanded = !expanded;
        row.setAttribute("aria-expanded", nextExpanded ? "true" : "false");
        setReadexNestedDisclosureExpanded(stateOwner, disclosureKey, nextExpanded);
        cancelReadexAncestorDisclosureAnimations(nested);
        animateReadexDisclosureElement(nested, nextExpanded, { hideOnFinish: true, reserveLayout: true });
      });

      wrapper.appendChild(row);
      wrapper.appendChild(nested);
      details.appendChild(wrapper);
    }

    function appendReadexActivityItem(details, item, stateOwner = null, disclosureKey = "", options = {}) {
      const previewAppender = typeof options?.previewAppender === "function"
        ? options.previewAppender
        : appendReadexToolPreviewItem;
      const previewContentAccentContext = options?.previewContentAccentContext || trimmed(options?.extractedPDFAccentColor);
      if (readexToolItemHasShellExecution(item)) {
        appendReadexShellExecutionItem(details, item, stateOwner, disclosureKey, {
          previewContentAccentContext
        });
        return;
      }
      if (readexToolItemIsWebSearchGroup(item)) {
        if (options?.webSearchOptions) {
          appendReadexWebSearchActivityItem(details, item, stateOwner, disclosureKey, options.webSearchOptions);
        } else {
          appendReadexWebSearchActivityItem(details, item, stateOwner, disclosureKey);
        }
        return;
      }
      if (item?.type === "video_progress") {
        details.appendChild(renderReadexVideoProgressBlock(item, disclosureKey));
        return;
      }
      if (readexToolItemHasLibraryTreePreview(item)) {
        appendReadexLibraryTreeToolItem(details, item, stateOwner, disclosureKey);
        return;
      }
      if (readexToolItemHasApplyPatchDiffPreview(item)) {
        appendReadexApplyPatchActivityItem(details, item, stateOwner, disclosureKey, {
          previewContentAccentContext
        });
        return;
      }
      if (readexToolItemShouldDisclose(item)) {
        appendReadexToolDisclosureItem(details, item, stateOwner, disclosureKey, {
          previewContentAccentContext
        });
        return;
      }
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      if (previewItems.length > 0) {
        if (previewItems.length === 1) {
        appendReadexToolStatusItem(details, item, previewItems[0], {
          suppressIcon: options?.suppressIcon === true,
          previewContentAccentContext
        });
        return;
      }
      appendReadexToolStatusItem(details, item, null, {
        suppressIcon: options?.suppressIcon === true,
        previewContentAccentContext
      });
      previewItems.forEach((preview) => {
        previewAppender(details, item, preview, previewContentAccentContext);
      });
      return;
    }

    appendReadexToolStatusItem(details, item, null, {
      suppressIcon: options?.suppressIcon === true,
      previewContentAccentContext
    });
  }

  function appendReadexToolDisclosureItem(details, item, stateOwner = null, disclosureKey = "", options = {}) {
    const initiallyExpanded = readexNestedDisclosureIsExpanded(stateOwner, disclosureKey);
    const previewContentAccentContext = options?.previewContentAccentContext || trimmed(options?.extractedPDFAccentColor);
    const previewContentAccentColor = readexToolItemPreviewContentAccentColor(item, previewContentAccentContext);
      const wrapper = document.createElement("div");
      wrapper.className = "readex-tool-activity-disclosure";

      const row = document.createElement("button");
      row.type = "button";
      row.className = [
        "readex-tool-activity-item",
        readexToolItemIsLive(item) ? "is-live" : "",
        readexToolItemIsFailed(item) ? "is-failed" : "",
        "is-preview",
        previewContentAccentColor ? "has-preview-content-accent" : ""
      ].filter(Boolean).join(" ");
      applyReadexExtractedPDFAccentVariable(row, previewContentAccentColor);
      row.setAttribute("aria-expanded", initiallyExpanded ? "true" : "false");
      appendReadexToolAvatarOrIcon(row, item, previewContentAccentColor);

      const textWrap = document.createElement("span");
      textWrap.className = "readex-tool-activity-item-text";

      const label = document.createElement("span");
      label.className = "readex-tool-activity-item-title";
      renderReadexToolItemTitle(label, item, previewContentAccentColor);
      textWrap.appendChild(label);
      row.appendChild(textWrap);

      const chevron = document.createElement("span");
      chevron.className = "readex-tool-activity-item-chevron";
      chevron.innerHTML = makeIcon("chevron-right");
      row.appendChild(chevron);

      const nested = document.createElement("div");
      nested.className = "readex-tool-activity-nested";
      nested.hidden = !initiallyExpanded;

      const detailText = readexToolItemDetailText(item);
      const childItems = readexToolItemChildItems(item);
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      if (childItems.length > 0) {
        childItems.forEach((childItem, childIndex) => {
        appendReadexActivityItem(
          nested,
          childItem,
          stateOwner,
          `${disclosureKey}:child:${childIndex}:${readexToolDisclosureStableKey(childItem, childIndex, "child")}`,
          { previewContentAccentContext }
        );
      });
      if (detailText) {
        appendReadexToolDisclosureDetail(nested, detailText, item, previewContentAccentContext);
      }
      previewItems.forEach((preview) => {
        appendReadexToolPreviewItem(nested, item, preview, previewContentAccentContext);
      });
    } else if (readexToolItemUsesExtractedPagePreviewPresentation(item)) {
      appendReadexExtractedPageRangeDetail(nested, item, previewContentAccentContext);
    } else if (detailText) {
      appendReadexToolDisclosureDetail(nested, detailText, item, previewContentAccentContext);

      previewItems.forEach((preview) => {
        appendReadexToolPreviewItem(nested, item, preview, previewContentAccentContext);
      });
    } else {
      previewItems.forEach((preview) => {
        appendReadexToolPreviewItem(nested, item, preview, previewContentAccentContext);
      });
      }

      row.addEventListener("click", (event) => {
        const target = event?.target;
        if (readexSupportTargetIsNestedReferenceControl(target)) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();
        const expanded = row.getAttribute("aria-expanded") === "true";
        const nextExpanded = !expanded;
        row.setAttribute("aria-expanded", nextExpanded ? "true" : "false");
        setReadexNestedDisclosureExpanded(stateOwner, disclosureKey, nextExpanded);
        cancelReadexAncestorDisclosureAnimations(nested);
        if (readexToolItemIsSavedAnswerWriteGroup(item)) {
          cancelReadexDisclosureAnimation(nested);
          nested.hidden = !nextExpanded;
          return;
        }
        animateReadexDisclosureElement(nested, nextExpanded, { hideOnFinish: true, reserveLayout: true });
      });

      wrapper.appendChild(row);
      wrapper.appendChild(nested);
      details.appendChild(wrapper);
    }

    function updateReadexToolActivityDetails(element, block, previewContentAccentContext = "") {
      const expanded = Boolean(element.__chatTranscriptReadexToolActivityExpanded);
      const existing = directChildByClass(element, "readex-tool-activity-details");
      if (!expanded) {
        if (existing) {
          animateReadexDisclosureElement(existing, false, { removeOnFinish: true, reserveLayout: true });
        }
        return;
      }

      const items = readexToolItems(block);
      if (!items.length) {
        removeDirectChild(element, existing);
        return;
      }

      const details = existing || document.createElement("div");
      if (existing) {
        cancelReadexDisclosureAnimation(existing);
      }
      const shouldFollowLatestWebSearch = readexWebSearchContainerShouldFollowLatest(details);
      details.className = "readex-tool-activity-details";
      details.textContent = "";
      if (items.length === 1 && readexToolItemIsWebSearchGroup(items[0])) {
        appendReadexWebSearchLines(details, items[0], null, {
          autoScrollToBottom: readexToolItemIsLive(items[0]) && shouldFollowLatestWebSearch
        });
      } else {
        items.forEach((item, index) => {
          const disclosureKey = readexToolDisclosureStableKey(item, index, "activity");
          appendReadexActivityItem(details, item, element, disclosureKey, {
            previewContentAccentContext
          });
        });
      }

      if (!existing) {
        element.appendChild(details);
        animateReadexDisclosureElement(details, true, { reserveLayout: true });
      }
    }

    function readexToolActivityIsWebSearchOnly(block) {
      const items = readexToolItems(block);
      return items.length === 1 && readexToolItemIsWebSearchGroup(items[0]);
    }

    function updateReadexToolActivityBlockElement(element, block, renderer, message, blockKey) {
      const isComplete = readexToolActivityIsComplete(block, message);
      element.className = [
        "readex-tool-activity-block",
        isComplete ? "" : "is-live",
        readexToolActivityIsWebSearchOnly(block) ? "is-web-search-only" : ""
      ].filter(Boolean).join(" ");
      element.__chatTranscriptReadexToolActivityBlock = block;
      element.__chatTranscriptReadexToolActivityMessage = message;
      const previewContentAccentContext = configureReadexExtractedPDFAccent(element, block, message, blockKey);
      configureReadexNestedDisclosureOwner(element, block);
      const primaryPreview = readexToolActivityPrimaryPreview(block);
      const activityItems = readexToolItems(block);
      const isExpandable = activityItems.some(readexToolItemIsExpandable)
        || readexToolItemsContainFoldableTextSearchRun(activityItems);
      if (!isExpandable) {
        element.__chatTranscriptReadexToolActivityExpanded = false;
      }
      configureReadexToolActivityExpansionState(element, block, blockKey, isExpandable);

      const titleText = readexToolActivityTitle(block, message);
      const supportLine = updateSupportLine(
        element,
        readexToolActivityIcon(block),
        titleText,
        isExpandable
          ? (Boolean(element.__chatTranscriptReadexToolActivityExpanded) ? "chevron-down" : "chevron-right")
          : (primaryPreview ? "chevron-right" : null)
      );
      configurePressableSupportLine(supportLine, {
        interactive: isExpandable || Boolean(primaryPreview),
        expanded: isExpandable ? Boolean(element.__chatTranscriptReadexToolActivityExpanded) : undefined,
        opensPreview: Boolean(primaryPreview)
      });
      if (supportLine) {
        supportLine.__chatTranscriptReadexPrimaryPreview = primaryPreview;
      }
      const didRenderExtractedPDFTitle = decorateReadexExtractedPDFSupportLine(
        supportLine,
        block,
        titleText,
        isComplete,
        previewContentAccentContext
      );
      const title = supportLine ? supportLine.querySelector(".support-line-title") : null;
      if (title) {
        title.classList.add("small");
        if (didRenderExtractedPDFTitle) {
          stopCodexShimmerText(title);
        } else if (isComplete) {
          clearSequentialShimmerText(title, titleText);
        } else {
          renderSequentialShimmerText(title, titleText);
        }
      }
      updateReadexToolActivityDetails(element, block, previewContentAccentContext);
    }

    function installReadexToolActivityBlockInteractions(element) {
      if (!element || element.__chatTranscriptReadexToolActivityInteractionsInstalled) {
        return;
      }
      element.__chatTranscriptReadexToolActivityInteractionsInstalled = true;

      const toggle = (event) => {
        const target = event?.target;
        if (!(target instanceof Element) || !target.closest(".support-line.is-interactive")) {
          return;
        }
        if (readexSupportTargetIsNestedReferenceControl(target)) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();

        const supportLine = target.closest(".support-line.is-interactive");
        const primaryPreview = supportLine?.__chatTranscriptReadexPrimaryPreview || null;
        if (primaryPreview) {
          if (
            event?.type === "click" &&
            !(target.closest(".readex-preview-jump-target"))
          ) {
            return;
          }
          openReadexPreviewItem(primaryPreview);
          return;
        }

        element.__chatTranscriptReadexToolActivityUserToggled = true;
        element.__chatTranscriptReadexToolActivityExpanded = !element.__chatTranscriptReadexToolActivityExpanded;
        const block = element.__chatTranscriptReadexToolActivityBlock;
        const message = element.__chatTranscriptReadexToolActivityMessage;
        const blockKey = trimmed(element.dataset.blockKey);
        updateReadexToolActivityBlockElement(element, block, resolveMarkdownRenderer(), message, blockKey);
        postReadexToolActivityExpansionState();
      };

      element.addEventListener("click", toggle);
      element.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        toggle(event);
      });
    }

    function renderReadexToolActivityBlock(block, renderer, message, blockKey) {
      const container = document.createElement("div");
      container.dataset.blockKey = blockKey;
      container.dataset.blockType = "readex_tool_activity";
      installReadexToolActivityBlockInteractions(container);
      updateReadexToolActivityBlockElement(container, block, renderer, message, blockKey);
      return container;
    }

    function readexProcessingItems(block) {
      return readexActivityItems(block);
    }

    function readexProcessingItemShouldRender(item) {
      if (!readexToolItemIsWebSearchGroup(item)) {
        return true;
      }
      return readexWebSearchActivityShouldRender(item);
    }

    function readexProcessingDisplayItems(block) {
      return readexProcessingItems(block).filter(readexProcessingItemShouldRender);
    }

    function formatReadexProcessingDuration(milliseconds) {
      const totalSeconds = Math.max(0, Math.floor((Number(milliseconds) || 0) / 1000));
      if (totalSeconds < 1) {
        return "0s";
      }
      if (totalSeconds < 60) {
        return `${totalSeconds}s`;
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

    function readexProcessingTurnStartedAtMilliseconds(block) {
      const startedAtMs = Number(block?.readexTurnStartedAtMilliseconds ?? block?.turnStartedAtMilliseconds);
      if (!Number.isFinite(startedAtMs) || startedAtMs <= 0) {
        return null;
      }
      return startedAtMs;
    }

    function readexProcessingTurnDurationMilliseconds(block) {
      const duration = Number(block?.readexTurnDurationMilliseconds ?? block?.turnDurationMilliseconds);
      if (!Number.isFinite(duration)) {
        return null;
      }
      return Math.max(0, duration);
    }

    function readexProcessingTurnElapsedMilliseconds(block) {
      const duration = readexProcessingTurnDurationMilliseconds(block);
      if (duration != null) {
        return duration;
      }
      const startedAtMs = readexProcessingTurnStartedAtMilliseconds(block);
      if (startedAtMs == null) {
        return null;
      }
      return Math.max(0, Date.now() - startedAtMs);
    }

    function readexProcessingDurationMilliseconds(block) {
      const workedForItem = readexProcessingWorkedForItem(block);
      if (workedForItem && workedForItem.completedAtMs != null) {
        return readexWorkedForElapsedMilliseconds(workedForItem);
      }
      const duration = Number(block?.durationMilliseconds);
      if (Number.isFinite(duration)) {
        return Math.max(0, duration);
      }
      return null;
    }

    function readexProcessingWorkedForItem(block) {
      const item = block?.workedForItem;
      if (!item || typeof item !== "object") {
        return null;
      }
      const startedAtMs = Number(item.startedAtMs ?? item.startedAtMilliseconds);
      if (!Number.isFinite(startedAtMs) || startedAtMs <= 0) {
        return null;
      }
      const completedAtMs = Number(item.completedAtMs ?? item.completedAtMilliseconds);
      const normalizedStatus = trimmed(item.status) === "working" ? "working" : "worked";
      return {
        status: normalizedStatus,
        startedAtMs,
        completedAtMs: Number.isFinite(completedAtMs) && completedAtMs > 0 ? completedAtMs : null
      };
    }

    function readexProcessingStartedAtMilliseconds(block) {
      const workedForItem = readexProcessingWorkedForItem(block);
      if (workedForItem) {
        return workedForItem.startedAtMs;
      }
      const startedAtMs = Number(block?.startedAtMs ?? block?.startedAtMilliseconds);
      if (!Number.isFinite(startedAtMs) || startedAtMs <= 0) {
        return null;
      }
      return startedAtMs;
    }

    function readexWorkedForElapsedMilliseconds(workedForItem) {
      if (!workedForItem) {
        return null;
      }
      const endAtMs = workedForItem.completedAtMs ?? Date.now();
      return Math.max(0, endAtMs - workedForItem.startedAtMs);
    }

    function readexProcessingStatusIsLive(status) {
      const normalized = normalizedReadexStatus(status);
      return normalized === "pending" || normalized === "processing" || normalized === "streaming" || normalized === "searching";
    }

    function readexProcessingStatusIsStopped(status) {
      return normalizedReadexStatus(status) === "interrupted";
    }

    function readexProcessingBlockIsActive(block) {
      return block?.readexProcessingActive === true;
    }

    function readexProcessingChromeRole(block) {
      return trimmed(block?.readexProcessingChromeRole);
    }

    function readexProcessingOwnsChrome(block) {
      return readexProcessingChromeRole(block) !== "continuation";
    }

    function explicitReadexProcessingGroupID(block) {
      return trimmed(block?.readexProcessingGroupId || block?.readexProcessingGroupID);
    }

    function readexProcessingGroupID(block) {
      const explicitGroupID = explicitReadexProcessingGroupID(block);
      if (explicitGroupID) {
        return explicitGroupID;
      }
      const turnStartedAtMs = readexProcessingTurnStartedAtMilliseconds(block);
      if (turnStartedAtMs != null) {
        return `turn:${turnStartedAtMs}`;
      }
      return "";
    }

    function readexProcessingGroupElements(groupID) {
      const normalizedGroupID = trimmed(groupID);
      if (!normalizedGroupID) {
        return [];
      }
      return Array.from(document.querySelectorAll(".readex-processing-block")).filter((element) => (
        trimmed(element?.dataset?.readexProcessingGroupId) === normalizedGroupID
      ));
    }

    function readexProcessingFoldGroupElements(groupID) {
      const normalizedGroupID = trimmed(groupID);
      if (!normalizedGroupID) {
        return [];
      }
      return Array.from(document.querySelectorAll("[data-readex-processing-fold-group-id]")).filter((element) => (
        trimmed(element?.dataset?.readexProcessingFoldGroupId) === normalizedGroupID
      ));
    }

    function readexProcessingGroupOwnerElement(groupID) {
      return readexProcessingGroupElements(groupID).find((element) => (
        readexProcessingOwnsChrome(element.__chatTranscriptReadexProcessingBlock)
      )) || null;
    }

    function readexProcessingGroupExpansionState(groupID) {
      const owner = readexProcessingGroupOwnerElement(groupID);
      if (typeof owner?.__chatTranscriptReadexProcessingExpanded === "boolean") {
        return owner.__chatTranscriptReadexProcessingExpanded;
      }
      return null;
    }

    function syncReadexProcessingFoldTargetElement(element, ownerElement = null) {
      if (!element) {
        return;
      }
      const groupElement = element.closest(".message-group");
      const groupID = trimmed(element?.dataset?.readexProcessingFoldGroupId);
      if (!groupID) {
        element.classList.remove("is-readex-processing-fold-collapsed");
        syncReadexProcessingFoldMessageGroup(groupElement);
        return;
      }
      const owner = ownerElement || readexProcessingGroupOwnerElement(groupID);
      if (!owner || element === owner || element.contains(owner) || owner.contains(element)) {
        element.classList.remove("is-readex-processing-fold-collapsed");
        syncReadexProcessingFoldMessageGroup(groupElement);
        return;
      }
      const expanded = typeof owner.__chatTranscriptReadexProcessingExpanded === "boolean"
        ? owner.__chatTranscriptReadexProcessingExpanded
        : true;
      element.classList.toggle("is-readex-processing-fold-collapsed", !expanded);
      syncReadexProcessingFoldMessageGroup(groupElement);
    }

    function directMessageArticlesInGroup(groupElement) {
      return Array.from(groupElement?.children || []).filter((child) => (
        child?.classList?.contains("message")
      ));
    }

    function syncReadexProcessingFoldMessageGroup(groupElement) {
      if (!groupElement?.classList?.contains("message-group")) {
        return;
      }
      const articles = directMessageArticlesInGroup(groupElement);
      const shouldCollapse = articles.length > 0 && articles.every((article) => (
        article.classList?.contains("is-readex-processing-fold-collapsed")
      ));
      groupElement.classList.toggle("is-readex-processing-fold-collapsed", shouldCollapse);
    }

    function syncReadexProcessingFoldGroupExpansion(groupID, ownerElement) {
      readexProcessingFoldGroupElements(groupID).forEach((element) => {
        syncReadexProcessingFoldTargetElement(element, ownerElement);
      });
    }

    function retargetReadexProcessingDetailsOpeningAnimation(element, reason = "") {
      const details = directChildByClass(element, "readex-processing-details");
      const retargeted = retargetReadexDisclosureOpeningAnimation(details, {
        reason: trimmed(reason)
      });
      if (retargeted) {
        postReadexProcessingToggleLayoutProbe(
          "retarget_opening_animation",
          element,
          element.__chatTranscriptReadexProcessingBlock,
          element.__chatTranscriptReadexProcessingMessage,
          { reason: trimmed(reason) }
        );
      }
      return retargeted;
    }

    window.ChatTranscriptReadexProcessingFoldController = {
      syncTarget: syncReadexProcessingFoldTargetElement,
      syncGroup: syncReadexProcessingFoldGroupExpansion,
      syncMessageGroup: syncReadexProcessingFoldMessageGroup,
      retargetOpenDetails: retargetReadexProcessingDetailsOpeningAnimation
    };

    function readexProcessingTurnTimerIsLive(block, message) {
      return readexProcessingTurnStartedAtMilliseconds(block) != null
        && readexProcessingTurnDurationMilliseconds(block) == null
        && messageIsStreaming(message);
    }

    function readexProcessingIsComplete(block, message) {
      const status = normalizedReadexStatus(block?.status);
      if (readexProcessingStatusIsStopped(status)) {
        return true;
      }
      if (readexProcessingStatusIsLive(status)) {
        return false;
      }
      if (readexProcessingBlockIsActive(block)) {
        return false;
      }
      if (readexProcessingTurnTimerIsLive(block, message)) {
        return false;
      }
      if (status === "success") {
        return true;
      }
      if (blockIsLive(block) || messageIsStreaming(message)) {
        return false;
      }
      return !readexProcessingItems(block).some(readexToolItemIsLive);
    }

    function readexProcessingFollowingMainTextElements(element) {
      const article = element?.closest?.("article.message");
      if (!article || !(element instanceof HTMLElement)) {
        return [];
      }
      const positionFollowing = typeof Node !== "undefined"
        ? Node.DOCUMENT_POSITION_FOLLOWING
        : 4;
      return Array.from(article.querySelectorAll?.("[data-block-type='main_text']") || []).filter((candidate) => (
        candidate instanceof HTMLElement &&
        candidate !== element &&
        Boolean(element.compareDocumentPosition(candidate) & positionFollowing)
      ));
    }

    function readexProcessingInternalMarkdownElements(element) {
      if (!(element instanceof HTMLElement)) {
        return [];
      }
      const details = directChildByClass(element, "readex-processing-details");
      if (!(details instanceof HTMLElement)) {
        return [];
      }
      return Array.from(details.querySelectorAll?.([
        ".readex-processing-message-text",
        ".readex-processing-progress",
        "[data-block-type='main_text']"
      ].join(", ")) || []).filter((candidate) => candidate instanceof HTMLElement);
    }

    function readexProcessingVirtualStateRefreshElements(element) {
      const elements = [
        ...readexProcessingInternalMarkdownElements(element),
        ...readexProcessingFollowingMainTextElements(element)
      ];
      const uniqueElements = [];
      const seen = new Set();
      elements.forEach((candidate) => {
        if (!(candidate instanceof HTMLElement) || seen.has(candidate)) {
          return;
        }
        seen.add(candidate);
        uniqueElements.push(candidate);
      });
      return uniqueElements;
    }

    function readexProcessingLayoutProbeEnabled() {
      return window.__chatTranscriptReadexLayoutProbeEnabled === true;
    }

    function readexProcessingProbeNumber(value) {
      const number = Number(value);
      return Number.isFinite(number) ? Math.round(number * 10) / 10 : 0;
    }

    function readexProcessingRectProbePayload(rect) {
      if (!rect) {
        return null;
      }
      return {
        x: readexProcessingProbeNumber(rect.x),
        y: readexProcessingProbeNumber(rect.y),
        width: readexProcessingProbeNumber(rect.width),
        height: readexProcessingProbeNumber(rect.height),
        top: readexProcessingProbeNumber(rect.top),
        bottom: readexProcessingProbeNumber(rect.bottom),
        left: readexProcessingProbeNumber(rect.left),
        right: readexProcessingProbeNumber(rect.right)
      };
    }

    function readexProcessingElementLayoutProbe(element) {
      if (!(element instanceof HTMLElement)) {
        return null;
      }
      const style = window.getComputedStyle(element);
      return {
        className: String(element.className || ""),
        blockKey: trimmed(element.dataset?.blockKey),
        blockType: trimmed(element.dataset?.blockType),
        itemKey: trimmed(element.dataset?.readexProcessingItemKey),
        itemType: trimmed(element.dataset?.readexProcessingItemType),
        isConnected: Boolean(element.isConnected),
        hidden: Boolean(element.hidden),
        childElementCount: element.children?.length || 0,
        childNodeCount: element.childNodes?.length || 0,
        textLength: String(element.textContent || "").length,
        htmlLength: String(element.innerHTML || "").length,
        clientHeight: readexProcessingProbeNumber(element.clientHeight),
        scrollHeight: readexProcessingProbeNumber(element.scrollHeight),
        clientWidth: readexProcessingProbeNumber(element.clientWidth),
        scrollWidth: readexProcessingProbeNumber(element.scrollWidth),
        rect: readexProcessingRectProbePayload(element.getBoundingClientRect()),
        display: style.display,
        position: style.position,
        overflowX: style.overflowX,
        overflowY: style.overflowY,
        contain: style.contain,
        contentVisibility: style.contentVisibility
      };
    }

    function readexProcessingMarkdownElementProbe(element, index) {
      return {
        index,
        layout: readexProcessingElementLayoutProbe(element),
        rememberedTextLength: String(element?.__chatTranscriptMarkdownSource || "").length,
        renderSignatureLength: String(element?.__chatTranscriptMarkdownRenderSignature || "").length
      };
    }

    function scheduleReadexProcessingLayoutOverlapProbe(element, source) {
      if (!readexProcessingLayoutProbeEnabled()) {
        return;
      }
    }

    function postReadexProcessingToggleLayoutProbe(stage, element, block, message, extra = {}) {
      if (!readexProcessingLayoutProbeEnabled()) {
        return;
      }
      const details = directChildByClass(element, "readex-processing-details");
      const internalMarkdownElements = readexProcessingInternalMarkdownElements(element);
      const followingMainTextElements = readexProcessingFollowingMainTextElements(element);
      const refreshElements = readexProcessingVirtualStateRefreshElements(element);
      try {
        postPresentationProbe({
          kind: "readex_processing_toggle_layout_probe",
          stage: trimmed(stage),
          source: "message_block_support_renderer",
          ...readexProcessingMessageProbePayload(message),
          blockKey: trimmed(element?.dataset?.blockKey),
          groupID: readexProcessingGroupID(block),
          expanded: Boolean(element?.__chatTranscriptReadexProcessingExpanded),
          ownsChrome: readexProcessingOwnsChrome(block),
          isComplete: readexProcessingIsComplete(block, message),
          element: readexProcessingElementLayoutProbe(element),
          details: readexProcessingElementLayoutProbe(details),
          internalMarkdownCount: internalMarkdownElements.length,
          internalMarkdown: internalMarkdownElements.slice(0, 12).map(readexProcessingMarkdownElementProbe),
          followingMainTextCount: followingMainTextElements.length,
          followingMainText: followingMainTextElements.slice(0, 8).map(readexProcessingMarkdownElementProbe),
          refreshElementCount: refreshElements.length,
          ...extra
        });
      } catch (_) {}
    }

    function shouldRefreshReadexProcessingVirtualState(element, block, message) {
      return element instanceof HTMLElement
        && message?.role === "assistant"
        && !messageIsStreaming(message)
        && readexProcessingIsComplete(block, message);
    }

    function refreshReadexProcessingVirtualState(element, block, message, phase) {
      if (!shouldRefreshReadexProcessingVirtualState(element, block, message)) {
        return {
          skipped: true,
          reason: "not_applicable"
        };
      }
      return {
        skipped: true,
        reason: "virtual_refresh_unavailable"
      };
    }

    function scheduleReadexProcessingVirtualStateRefresh(element, block, renderer, message) {
      if (!shouldRefreshReadexProcessingVirtualState(element, block, message)) {
        postReadexProcessingToggleLayoutProbe("refresh_skipped", element, block, message, {
          reason: "not_applicable"
        });
        return;
      }

      const requestFrame = typeof window.requestAnimationFrame === "function"
        ? window.requestAnimationFrame.bind(window)
        : (callback) => window.setTimeout(callback, 16);
      const refreshToken = {};
      element.__chatTranscriptReadexProcessingVirtualRefreshToken = refreshToken;

      const runRefresh = (phase, refreshDetailsMarkdown = false) => {
        if (element.__chatTranscriptReadexProcessingVirtualRefreshToken !== refreshToken) {
          postReadexProcessingToggleLayoutProbe(`refresh_${phase}_stale`, element, block, message, {
            refreshDetailsMarkdown
          });
          return;
        }
        postReadexProcessingToggleLayoutProbe(`refresh_${phase}_before`, element, block, message, {
          refreshDetailsMarkdown
        });
        let detailsRefresh = null;
        if (refreshDetailsMarkdown) {
          detailsRefresh = refreshReadexProcessingDetailsMarkdownLayout(element, block, renderer, message, phase);
        }
        const virtualRefresh = refreshReadexProcessingVirtualState(element, block, message, phase);
        scheduleReadexProcessingLayoutOverlapProbe(element, `readex_processing_refresh_${phase}`);
        postReadexProcessingToggleLayoutProbe(`refresh_${phase}_after`, element, block, message, {
          refreshDetailsMarkdown,
          detailsRefresh,
          virtualRefresh
        });
      };

      requestFrame(() => runRefresh("frame", false));
      window.setTimeout(
        () => runRefresh("settled", true),
        readexDisclosureAnimationConfig().durationMilliseconds + 48
      );
    }

    function readexProcessingItemIsExpandable(item) {
      return readexActivityItemIsExpandable(item, { progressItemsExpandable: true });
    }

    function readexProcessingPrimaryPreview(block) {
      const items = readexProcessingDisplayItems(block);
      if (items.length !== 1) {
        return null;
      }
      const item = items[0];
      const previewItems = Array.isArray(item?.previewItems) ? item.previewItems : [];
      if (readexProcessingItemIsExpandable(item) || previewItems.length !== 1) {
        return null;
      }
      return previewItems[0];
    }

    function readexProcessingExplicitTitleText(_block) {
      return "";
    }

    function readexProcessingTitlePrefixForStatus(_status) {
      return "已处理";
    }

    function completedReadexProcessingTitleText(durationMilliseconds, status = "") {
      const prefix = readexProcessingTitlePrefixForStatus(status);
      const duration = Number(durationMilliseconds);
      if (!Number.isFinite(duration)) {
        return prefix;
      }
      if (prefix === "已处理") {
        return `已处理 ${formatReadexProcessingDuration(duration)}`;
      }
      return `${prefix} ${formatReadexProcessingDuration(duration)}`;
    }

    function readexProcessingTitleText(block) {
      const explicitTitle = readexProcessingExplicitTitleText(block);
      if (explicitTitle) {
        return explicitTitle;
      }
      const status = normalizedReadexStatus(block?.status);
      const turnDuration = readexProcessingTurnDurationMilliseconds(block);
      if (turnDuration != null) {
        return completedReadexProcessingTitleText(turnDuration, status);
      }
      const workedForItem = readexProcessingWorkedForItem(block);
      if (workedForItem) {
        const duration = readexWorkedForElapsedMilliseconds(workedForItem);
        if (Number.isFinite(duration)) {
          return completedReadexProcessingTitleText(duration, status);
        }
      }
      const duration = readexProcessingDurationMilliseconds(block);
      if (Number.isFinite(duration)) {
        return completedReadexProcessingTitleText(duration, status);
      }
      return readexProcessingTitlePrefixForStatus(status);
    }

    function appendReadexProcessingDurationToken(parent, token) {
      const match = /^(\d+)([hms])$/.exec(trimmed(token));
      if (!match) {
        parent.appendChild(document.createTextNode(token));
        return;
      }

      const wrapper = document.createElement("span");
      wrapper.className = "readex-processing-duration-token";

      const value = document.createElement("span");
      value.className = "readex-processing-duration-value";
      value.textContent = match[1];
      wrapper.appendChild(value);

      const unit = document.createElement("span");
      unit.className = "readex-processing-duration-unit";
      unit.textContent = match[2];
      wrapper.appendChild(unit);

      parent.appendChild(wrapper);
    }

    function renderReadexProcessingTitleText(element, titleText, options = {}) {
      if (!element) {
        return;
      }
      const displayText = trimmed(titleText);
      if (options?.shimmer === true) {
        renderSequentialShimmerText(element, displayText);
        return;
      }
      stopCodexShimmerText(element);
      clearReadexShimmerPresentation(element);
      element.textContent = "";
      const match = /^已处理\s+(.+)$/.exec(displayText);
      if (!match) {
        element.textContent = displayText;
        return;
      }

      element.appendChild(document.createTextNode("已处理 "));
      const duration = document.createElement("span");
      duration.className = "readex-processing-duration";
      match[1].split(/(\s+)/).forEach((part) => {
        if (!part) {
          return;
        }
        if (/^\s+$/.test(part)) {
          duration.appendChild(document.createTextNode(part));
          return;
        }
        appendReadexProcessingDurationToken(duration, part);
      });
      element.appendChild(duration);
    }

    function readexProcessingBlockIDSet(propertyName) {
      const payload = window.__chatTranscriptPayload || window.__chatLongImagePayload || {};
      const values = Array.isArray(payload?.[propertyName])
        ? payload[propertyName]
        : [];
      return new Set(values.map((value) => trimmed(value)).filter(Boolean));
    }

    function expandedReadexProcessingBlockIDSet() {
      return readexProcessingBlockIDSet("expandedReadexProcessingBlockIDs");
    }

    function collapsedReadexProcessingBlockIDSet() {
      return readexProcessingBlockIDSet("collapsedReadexProcessingBlockIDs");
    }

    function readexProcessingBlockIDSetContains(block, idSet) {
      if (!(idSet instanceof Set) || !idSet.size) {
        return false;
      }
      const candidates = [
        readexProcessingGroupID(block),
        block?.sourceBlockId,
        block?.sourceBlockID,
        block?.id
      ].map((value) => trimmed(value)).filter(Boolean);
      return candidates.some((candidate) => idSet.has(candidate));
    }

    function readexProcessingPayloadExpansionState(block) {
      const collapsedIDs = collapsedReadexProcessingBlockIDSet();
      if (readexProcessingBlockIDSetContains(block, collapsedIDs)) {
        return false;
      }
      const expandedIDs = expandedReadexProcessingBlockIDSet();
      if (readexProcessingBlockIDSetContains(block, expandedIDs)) {
        return true;
      }
      return null;
    }

    function readexProcessingExpansionSourceID(block) {
      return explicitReadexProcessingGroupID(block) || trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || "";
    }

    function readexDisclosureSourceIDFromBlock(block) {
      return trimmed(block?.sourceBlockId) || trimmed(block?.sourceBlockID) || trimmed(block?.id);
    }

    function collectExpandedReadexProcessingSourceBlockIDs() {
      const expandedIDs = [];
      const seen = new Set();
      document.querySelectorAll(".readex-processing-block").forEach((element) => {
        const block = element.__chatTranscriptReadexProcessingBlock;
        if (!readexProcessingOwnsChrome(block)) {
          return;
        }
        if (!element.__chatTranscriptReadexProcessingExpanded) {
          return;
        }
        const sourceID = readexProcessingExpansionSourceID(block);
        if (!sourceID || seen.has(sourceID)) {
          return;
        }
        seen.add(sourceID);
        expandedIDs.push(sourceID);
      });
      return expandedIDs;
    }

    function collectCollapsedReadexProcessingSourceBlockIDs() {
      const collapsedIDs = [];
      const seen = new Set();
      document.querySelectorAll(".readex-processing-block").forEach((element) => {
        const block = element.__chatTranscriptReadexProcessingBlock;
        if (!readexProcessingOwnsChrome(block)) {
          return;
        }
        if (element.__chatTranscriptReadexProcessingExpanded) {
          return;
        }
        const sourceID = readexProcessingExpansionSourceID(block);
        if (!sourceID || seen.has(sourceID)) {
          return;
        }
        seen.add(sourceID);
        collapsedIDs.push(sourceID);
      });
      return collapsedIDs;
    }

    function postReadexProcessingExpansionState() {
      postPresentationProbe({
        kind: "readex_processing_expansion_state",
        expandedSourceBlockIds: collectExpandedReadexProcessingSourceBlockIDs(),
        collapsedSourceBlockIds: collectCollapsedReadexProcessingSourceBlockIDs()
      });
    }

    function collectReadexToolActivitySourceBlockIDs(expanded) {
      const output = [];
      const seen = new Set();
      document.querySelectorAll(".readex-tool-activity-block").forEach((element) => {
        const block = element.__chatTranscriptReadexToolActivityBlock;
        const isExpandable = readexToolItems(block).some(readexToolItemIsExpandable);
        if (!isExpandable) {
          return;
        }
        if (Boolean(element.__chatTranscriptReadexToolActivityExpanded) !== expanded) {
          return;
        }
        const sourceID = readexDisclosureSourceIDFromBlock(block);
        if (!sourceID || seen.has(sourceID)) {
          return;
        }
        seen.add(sourceID);
        output.push(sourceID);
      });
      return output;
    }

    function postReadexToolActivityExpansionState() {
      postPresentationProbe({
        kind: "readex_tool_activity_expansion_state",
        expandedSourceBlockIds: collectReadexToolActivitySourceBlockIDs(true),
        collapsedSourceBlockIds: collectReadexToolActivitySourceBlockIDs(false)
      });
    }

    function collectExpandedReadexNestedDisclosureKeysBySourceBlockID() {
      const output = {};
      document.querySelectorAll(".readex-processing-block, .readex-tool-activity-block").forEach((element) => {
        const sourceID = trimmed(element.__chatTranscriptReadexNestedDisclosureSourceID)
          || readexDisclosureSourceIDFromBlock(
            element.__chatTranscriptReadexProcessingBlock || element.__chatTranscriptReadexToolActivityBlock
          );
        const keySet = element.__chatTranscriptReadexNestedDisclosureExpandedKeys;
        if (!sourceID || !(keySet instanceof Set) || !keySet.size) {
          return;
        }
        const existing = Array.isArray(output[sourceID]) ? output[sourceID] : [];
        const seen = new Set(existing);
        keySet.forEach((key) => {
          const normalizedKey = trimmed(key);
          if (!normalizedKey || seen.has(normalizedKey)) {
            return;
          }
          seen.add(normalizedKey);
          existing.push(normalizedKey);
        });
        if (existing.length) {
          output[sourceID] = existing;
        }
      });
      return output;
    }

    function collectCollapsedReadexNestedDisclosureKeysBySourceBlockID() {
      const output = {};
      document.querySelectorAll(".readex-processing-block, .readex-tool-activity-block").forEach((element) => {
        const sourceID = trimmed(element.__chatTranscriptReadexNestedDisclosureSourceID)
          || readexDisclosureSourceIDFromBlock(
            element.__chatTranscriptReadexProcessingBlock || element.__chatTranscriptReadexToolActivityBlock
          );
        const keySet = element.__chatTranscriptReadexNestedDisclosureCollapsedKeys;
        if (!sourceID || !(keySet instanceof Set) || !keySet.size) {
          return;
        }
        const existing = Array.isArray(output[sourceID]) ? output[sourceID] : [];
        const seen = new Set(existing);
        keySet.forEach((key) => {
          const normalizedKey = trimmed(key);
          if (!normalizedKey || seen.has(normalizedKey)) {
            return;
          }
          seen.add(normalizedKey);
          existing.push(normalizedKey);
        });
        if (existing.length) {
          output[sourceID] = existing;
        }
      });
      return output;
    }

    function postReadexNestedDisclosureExpansionState() {
      postPresentationProbe({
        kind: "readex_nested_disclosure_expansion_state",
        expandedKeysBySourceBlockId: collectExpandedReadexNestedDisclosureKeysBySourceBlockID(),
        collapsedKeysBySourceBlockId: collectCollapsedReadexNestedDisclosureKeysBySourceBlockID()
      });
    }

    function clearReadexProcessingTimer(element) {
      if (!element || !element.__chatTranscriptReadexProcessingTimer) {
        return;
      }
      window.clearInterval(element.__chatTranscriptReadexProcessingTimer);
      element.__chatTranscriptReadexProcessingTimer = null;
    }

    function liveReadexProcessingElapsedMilliseconds(block) {
      const turnElapsed = readexProcessingTurnElapsedMilliseconds(block);
      if (turnElapsed != null) {
        return turnElapsed;
      }
      const workedForItem = readexProcessingWorkedForItem(block);
      if (workedForItem) {
        return readexWorkedForElapsedMilliseconds(workedForItem);
      }
      const startedAtMs = readexProcessingStartedAtMilliseconds(block);
      if (startedAtMs == null) {
        return null;
      }
      return Math.max(0, Date.now() - startedAtMs);
    }

    function liveReadexProcessingTitleText(block) {
      const explicitTitle = readexProcessingExplicitTitleText(block);
      if (explicitTitle) {
        return explicitTitle;
      }
      const milliseconds = liveReadexProcessingElapsedMilliseconds(block);
      if (milliseconds == null) {
        return "已处理";
      }
      return `已处理 ${formatReadexProcessingDuration(milliseconds)}`;
    }

    function setReadexProcessingTitleText(element, titleText, options = {}) {
      const supportLine = directChildByClass(element, "support-line");
      const title = supportLine ? supportLine.querySelector(".support-line-title") : null;
      if (title) {
        renderReadexProcessingTitleText(title, titleText, options);
      } else {
        setSupportLineTitleText(element, titleText);
      }
    }

    function syncReadexProcessingTimer(element, block, isLive) {
      if (!isLive) {
        clearReadexProcessingTimer(element);
        return;
      }

      const tick = () => {
        if (!element.isConnected) {
          clearReadexProcessingTimer(element);
          return;
        }
        setReadexProcessingTitleText(
          element,
          liveReadexProcessingTitleText(block),
          { shimmer: element.__chatTranscriptReadexProcessingTitleShimmers === true }
        );
      };

      tick();
      if (!element.__chatTranscriptReadexProcessingTimer) {
        element.__chatTranscriptReadexProcessingTimer = window.setInterval(tick, 1000);
      }
    }

    function syncReadexProcessingGroupExpansion(ownerElement) {
      const ownerBlock = ownerElement?.__chatTranscriptReadexProcessingBlock;
      if (!readexProcessingOwnsChrome(ownerBlock)) {
        return;
      }
      const groupID = readexProcessingGroupID(ownerBlock);
      if (!groupID) {
        return;
      }
      const expanded = Boolean(ownerElement.__chatTranscriptReadexProcessingExpanded);
      readexProcessingGroupElements(groupID).forEach((element) => {
        if (element === ownerElement) {
          return;
        }
        const block = element.__chatTranscriptReadexProcessingBlock;
        if (readexProcessingOwnsChrome(block)) {
          return;
        }
        element.__chatTranscriptReadexProcessingExpanded = expanded;
        updateReadexProcessingBlockElement(
          element,
          block,
          resolveMarkdownRenderer(),
          element.__chatTranscriptReadexProcessingMessage,
          trimmed(element.dataset.blockKey)
        );
      });
      syncReadexProcessingFoldGroupExpansion(groupID, ownerElement);
    }

    function updateReadexProcessingDivider(element, isVisible) {
      let divider = directChildByClass(element, "readex-processing-divider");
      if (!isVisible) {
        removeDirectChild(element, divider);
        return;
      }
      if (!divider) {
        divider = document.createElement("div");
        const details = directChildByClass(element, "readex-processing-details");
        if (details) {
          element.insertBefore(divider, details);
        } else {
          element.appendChild(divider);
        }
      }
      divider.className = "readex-processing-divider readex-chat-divider";
    }

    function appendReadexProcessingPreviewItem(details, item, preview, accentSource = "") {
      appendReadexToolPreviewItem(details, item, preview, accentSource);
    }

    function appendReadexProcessingToolItem(details, item, stateOwner = null, index = 0, previewContentAccentContext = "") {
      const disclosureKey = readexToolDisclosureStableKey(item, index, "processing");
      appendReadexActivityItem(details, item, stateOwner, disclosureKey, {
        previewAppender: appendReadexProcessingPreviewItem,
        suppressIcon: readexProcessingProgressSuppressesToolIcon(item),
        previewContentAccentContext
      });
    }

    function readexProcessingMarkdownRenderOptionsProbePayload(options) {
      const resolvedOptions = options && typeof options === "object" ? options : {};
      return {
        streaming: Boolean(resolvedOptions.streaming),
        streamingCommitImmediately: Boolean(resolvedOptions.streamingCommitImmediately),
        streamingFinalizeImmediate: Boolean(resolvedOptions.streamingFinalizeImmediate),
        progressive: Boolean(resolvedOptions.progressive),
        readexMarkdownRendererProfile: trimmed(resolvedOptions.readexMarkdownRendererProfile),
        mathRenderer: trimmed(resolvedOptions.mathRenderer),
        mathFallbackRenderer: trimmed(resolvedOptions.mathFallbackRenderer),
        readexVirtualRemeasureToken: trimmed(resolvedOptions.readexVirtualRemeasureToken)
      };
    }

    function readexProcessingMarkdownContentRenderOptionsPayload(options) {
      const resolvedOptions = options && typeof options === "object" ? options : {};
      return {
        progressive: Boolean(resolvedOptions.progressive),
        readexMarkdownRendererProfile: trimmed(resolvedOptions.readexMarkdownRendererProfile),
        mathRenderer: trimmed(resolvedOptions.mathRenderer),
        mathFallbackRenderer: trimmed(resolvedOptions.mathFallbackRenderer),
        readexVirtualRemeasureToken: trimmed(resolvedOptions.readexVirtualRemeasureToken)
      };
    }

    function readexProcessingMarkdownMetricsProbePayload(metrics) {
      return {
        engine: trimmed(metrics?.engine) || "unknown",
        displayedLength: Number(metrics?.displayedLength) || 0,
        targetLength: Number(metrics?.targetLength) || 0,
        queuedCharCount: Number(metrics?.queuedCharCount) || 0,
        renderedLength: Number(metrics?.renderedLength) || 0,
        liveTailMode: trimmed(metrics?.liveTailMode),
        stableBlockCount: Number(metrics?.stableBlockCount) || 0,
        replacedBlockCount: Number(metrics?.replacedBlockCount) || 0,
        sourceBlockCount: Number(metrics?.sourceBlockCount) || 0,
        virtualScrollEnabled: Boolean(metrics?.virtualScrollEnabled),
        virtualLogicalHeight: Number(metrics?.virtualLogicalHeight) || 0
      };
    }

    function readexProcessingMessageProbePayload(message) {
      return {
        messageID: trimmed(message?.messageID || message?.id),
        patchKey: trimmed(message?.patchKey),
        readexTurnID: trimmed(message?.readexTurnID || message?.readexTurnId),
        role: trimmed(message?.role),
        status: trimmed(message?.status || message?.effectiveStatus || message?.messageStatus),
        isStreaming: messageIsStreaming(message)
      };
    }

    function shouldProbeReadexProcessingMessageText(message) {
      return message?.role === "assistant" ||
        Boolean(trimmed(message?.readexTurnID || message?.readexTurnId || message?.patchKey));
    }

    function postReadexProcessingMessageTextRenderProbe(event, message, item, itemKey, extra = {}) {
      if (!shouldProbeReadexProcessingMessageText(message)) {
        return;
      }
      try {
        postPresentationProbe({
          kind: "dom_reconcile_probe",
          event,
          source: "message_block_support_renderer",
          ...readexProcessingMessageProbePayload(message),
          itemKey: trimmed(itemKey),
          itemType: trimmed(item?.type),
          textLength: String(item?.text || "").length,
          ...extra
        });
      } catch (_) {}
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
      if (!renderPerfProbeEnabled() || !shouldProbeReadexProcessingMessageText(message)) {
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

    function postReadexProcessingRenderPerfProbe(event, message, item, itemKey, text, payload = {}) {
      const elapsedMs = roundedProbeNumber(payload.elapsedMs);
      const mutationDelta = payload.mutationDelta || null;
      if (!shouldPostRenderPerfProbe(event, message, payload.renderOptions, elapsedMs, mutationDelta)) {
        return;
      }
      try {
        postPresentationProbe({
          kind: "render_perf",
          event,
          source: "message_block_support_renderer",
          ...readexProcessingMessageProbePayload(message),
          itemKey: trimmed(itemKey),
          itemType: trimmed(item?.type),
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
      } catch (_) {}
    }

    function readexProcessingMarkdownContentRenderSignature(markdown, options) {
      return JSON.stringify({
        markdown: String(markdown || ""),
        ...readexProcessingMarkdownContentRenderOptionsPayload(options)
      });
    }

    function readexProcessingRememberedMarkdownSource(element) {
      return typeof element?.__chatTranscriptReadexProcessingMarkdownSource === "string"
        ? element.__chatTranscriptReadexProcessingMarkdownSource
        : "";
    }

    function rememberReadexProcessingMarkdownRender(element, markdown, options) {
      if (!element) {
        return;
      }
      element.__chatTranscriptReadexProcessingMarkdownSource = String(markdown || "");
      element.__chatTranscriptMarkdownRenderSignature = readexProcessingMarkdownContentRenderSignature(markdown, options);
      element.__chatTranscriptMarkdownRenderOptions = readexProcessingMarkdownRenderOptionsProbePayload(options);
    }

    function readexProcessingMessageTextShouldStreamPatch(element, message, text) {
      const source = String(text || "");
      const previousSource = readexProcessingRememberedMarkdownSource(element);
      if (!messageIsStreaming(message)) {
        return false;
      }
      return Boolean(messageIsStreaming(message))
        || Boolean(element?.__smoothStreamingController)
        || (previousSource.length > 0 && source.startsWith(previousSource));
    }

    function readexProcessingMessageTextShouldFinalizeStreaming(element, message, text) {
      const source = String(text || "");
      const previousSource = readexProcessingRememberedMarkdownSource(element);
      if (messageIsStreaming(message) || !previousSource || !source.startsWith(previousSource)) {
        return false;
      }
      return element?.__chatTranscriptMarkdownRenderOptions?.streaming === true
        || Boolean(element?.__smoothStreamingController);
    }

    function readexProcessingMessageTextPatchRenderOptions(element, message, item, itemKey) {
      const text = item?.text;
      const stableKey = trimmed(item?.sourceBlockId)
        || trimmed(item?.sourceBlockID)
        || trimmed(item?.id)
        || trimmed(itemKey);
      const options = markdownRenderOptionsForSupport(message, stableKey);
      if (readexProcessingMessageTextShouldStreamPatch(element, message, text)) {
        options.streaming = true;
        options.streamingCommitImmediately = false;
        options.streamingFinalizeImmediate = !messageIsStreaming(message);
        options.readexStreamingLightweight = messageIsStreaming(message);
      } else if (readexProcessingMessageTextShouldFinalizeStreaming(element, message, text)) {
        options.streaming = true;
        options.streamingCommitImmediately = false;
        options.streamingFinalizeImmediate = true;
      }
      return options;
    }

    function readexProcessingMessageTextHasPendingStreaming(element) {
      const controller = element?.__smoothStreamingController || null;
      if (!controller) {
        return false;
      }
      return (controller.pendingSegments?.length || 0) > 0
        || String(controller.displayedMarkdown || "") !== String(controller.targetMarkdown || "");
    }

    function readexProcessingMessageTextFinalizeUnchangedStreaming(element, renderer, text, renderOptions) {
      if (
        renderOptions?.streamingFinalizeImmediate !== true ||
        !readexProcessingMessageTextHasPendingStreaming(element)
      ) {
        return null;
      }
      return renderMarkdownIntoElement(renderer, element, text, renderOptions);
    }

    function markdownRenderOptionsForSupport(message, blockKey) {
      const options = markdownRenderOptions(message);
      const messageKey = trimmed(message?.patchKey || message?.id || message?.messageID);
      const resolvedBlockKey = trimmed(blockKey);
      if (resolvedBlockKey) {
        options.blockKey = resolvedBlockKey;
      }
      if (messageKey || resolvedBlockKey) {
        options.readexVirtualSessionKey = [messageKey || "message", resolvedBlockKey || "support"].join(":");
      }
      const threadKey = trimmed(message?.readexTurnID || message?.readexTurnId || message?.askId || message?.askID || message?.requestId);
      if (threadKey) {
        options.readexVirtualThreadKey = threadKey;
      }
      return options;
    }

    function readexProcessingProgressItemKey(item, index) {
      const stableID = trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID) || trimmed(item?.id);
      return ["progress", stableID || String(index)].join("\u001f");
    }

    function readexProcessingMessageTextItemKey(item, index) {
      const stableID = trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID) || trimmed(item?.id);
      return ["main_text", stableID || String(index)].join("\u001f");
    }

    function readexProcessingProgressUsesToolActivityRow(item) {
      const text = trimmed(item?.text);
      return text === "正在思考" || text === "已引导对话";
    }

    function readexProcessingProgressSuppressesToolIcon(item) {
      return readexProcessingProgressUsesToolActivityRow(item);
    }

    function readexProcessingItemKey(item, index) {
      const itemType = trimmed(item?.type) || "item";
      if (itemType === "progress") {
        if (readexProcessingProgressUsesToolActivityRow(item)) {
          return ["tool", readexToolDisclosureStableKey(item, index, "processing")].join("\u001f");
        }
        return readexProcessingProgressItemKey(item, index);
      }
      if (itemType === "main_text") {
        return readexProcessingMessageTextItemKey(item, index);
      }
      if (itemType === "video_progress") {
        const stableID = trimmed(item?.sourceBlockId) || trimmed(item?.sourceBlockID) || trimmed(item?.id);
        return ["video_progress", stableID || String(index)].join("\u001f");
      }
      return ["tool", readexToolDisclosureStableKey(item, index, "processing")].join("\u001f");
    }

    function readexProcessingItemSignature(item) {
      return JSON.stringify(item || {});
    }

    function readexProcessingBlockRenderSignature(block, message) {
      return JSON.stringify({
        block,
        role: message?.role
      });
    }

    function applyReadexProcessingMarkdownRemeasureToken(options, remeasureToken) {
      const token = trimmed(remeasureToken);
      if (token) {
        options.readexVirtualRemeasureToken = token;
      }
      return options;
    }

    function readexProcessingNextMarkdownRemeasureToken(element, phase) {
      if (!(element instanceof HTMLElement)) {
        return "";
      }
      element.__chatTranscriptReadexProcessingMarkdownRemeasureSequence =
        (Number(element.__chatTranscriptReadexProcessingMarkdownRemeasureSequence) || 0) + 1;
      return [
        "readex-processing",
        trimmed(phase) || "layout",
        String(element.__chatTranscriptReadexProcessingMarkdownRemeasureSequence)
      ].join(":");
    }

    function patchReadexProcessingProgressItem(element, item, renderer, message, remeasureToken = "") {
      const note = element && element.classList.contains("readex-processing-progress")
        ? element
        : document.createElement("div");
      note.className = "readex-processing-progress";
      const renderOptions = applyReadexProcessingMarkdownRemeasureToken({
        ...markdownRenderOptionsForSupport(message, item?.sourceBlockId || item?.sourceBlockID || item?.id),
        streaming: false
      }, remeasureToken);
      const signature = readexProcessingMarkdownContentRenderSignature(item?.text, renderOptions);
      if (note.__chatTranscriptMarkdownRenderSignature !== signature) {
        renderMarkdownIntoElement(renderer, note, item.text, renderOptions);
        note.__chatTranscriptMarkdownRenderSignature = signature;
      }
      return note;
    }

    function patchReadexProcessingMessageTextItem(element, item, renderer, message, itemKey, remeasureToken = "") {
      const note = element && element.classList.contains("readex-processing-message-text")
        ? element
        : document.createElement("div");
      note.className = "readex-processing-message-text message-content";
      const text = item?.text;
      const renderOptions = readexProcessingMessageTextPatchRenderOptions(note, message, item, itemKey);
      applyReadexProcessingMarkdownRemeasureToken(renderOptions, remeasureToken);
      const signature = readexProcessingMarkdownContentRenderSignature(text, renderOptions);
      const previousTextLength = readexProcessingRememberedMarkdownSource(note).length;
      if (note.__chatTranscriptMarkdownRenderSignature !== signature) {
        const probeRenderPerf = renderPerfProbeEnabled();
        const beforeDocument = probeRenderPerf ? renderPerfDocumentSnapshot() : null;
        const beforeElement = probeRenderPerf ? elementRenderPerfPayload(note) : null;
        const startedAt = probeRenderPerf ? renderPerfNow() : 0;
        const metrics = renderMarkdownIntoElement(renderer, note, text, renderOptions);
        rememberReadexProcessingMarkdownRender(note, text, renderOptions);
        const elapsedMs = probeRenderPerf ? renderPerfNow() - startedAt : 0;
        const mutationDelta = probeRenderPerf ? renderPerfDocumentDelta(beforeDocument) : null;
        const renderOptionsPayload = readexProcessingMarkdownRenderOptionsProbePayload(renderOptions);
        const metricsPayload = readexProcessingMarkdownMetricsProbePayload(metrics);
        postReadexProcessingMessageTextRenderProbe(
          "readex_processing_message_text_markdown_render",
          message,
          item,
          itemKey,
          {
            renderPhase: "patch",
            previousTextLength,
            renderOptions: renderOptionsPayload,
            metrics: metricsPayload
          }
        );
        postReadexProcessingRenderPerfProbe(
          "readex_processing_message_text_markdown_render_perf",
          message,
          item,
          itemKey,
          text,
          {
            elapsedMs,
            previousTextLength,
            renderPhase: "patch",
            renderOptions: renderOptionsPayload,
            metrics: metricsPayload,
            beforeElement,
            afterElement: elementRenderPerfPayload(note),
            mutationDelta
          }
        );
      } else {
        const probeRenderPerf = renderPerfProbeEnabled();
        const beforeDocument = probeRenderPerf ? renderPerfDocumentSnapshot() : null;
        const beforeElement = probeRenderPerf ? elementRenderPerfPayload(note) : null;
        const startedAt = probeRenderPerf ? renderPerfNow() : 0;
        const finalizeMetrics = readexProcessingMessageTextFinalizeUnchangedStreaming(note, renderer, text, renderOptions);
        if (finalizeMetrics) {
          const elapsedMs = probeRenderPerf ? renderPerfNow() - startedAt : 0;
          const mutationDelta = probeRenderPerf ? renderPerfDocumentDelta(beforeDocument) : null;
          const renderOptionsPayload = readexProcessingMarkdownRenderOptionsProbePayload(renderOptions);
          const metricsPayload = readexProcessingMarkdownMetricsProbePayload(finalizeMetrics);
          postReadexProcessingMessageTextRenderProbe(
            "readex_processing_message_text_markdown_finalize",
            message,
            item,
            itemKey,
            {
              renderPhase: "patch",
              previousTextLength,
              renderOptions: renderOptionsPayload,
              metrics: metricsPayload
            }
          );
          postReadexProcessingRenderPerfProbe(
            "readex_processing_message_text_markdown_finalize_perf",
            message,
            item,
            itemKey,
            text,
            {
              elapsedMs,
              previousTextLength,
              renderPhase: "patch",
              renderOptions: renderOptionsPayload,
              metrics: metricsPayload,
              beforeElement,
              afterElement: elementRenderPerfPayload(note),
              mutationDelta
            }
          );
          return note;
        }
        postReadexProcessingMessageTextRenderProbe(
          "readex_processing_message_text_markdown_reuse",
          message,
          item,
          itemKey,
          {
            renderPhase: "patch",
            previousTextLength,
            renderOptions: readexProcessingMarkdownRenderOptionsProbePayload(renderOptions)
          }
        );
      }
      return note;
    }

    function patchReadexProcessingVideoProgressItem(element, item, itemKey) {
      const signature = readexProcessingItemSignature(item);
      if (
        element &&
        element.classList.contains("readex-processing-video-progress-item") &&
        element.__chatTranscriptReadexProcessingItemSignature === signature
      ) {
        return element;
      }

      const container = element && element.classList.contains("readex-processing-video-progress-item")
        ? element
        : document.createElement("div");
      container.className = "readex-processing-video-progress-item";
      container.__chatTranscriptReadexProcessingItemSignature = signature;
      container.replaceChildren(renderReadexVideoProgressBlock(item, itemKey));
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

    function findReadexProcessingBlockElement(article, blockKey) {
      const key = trimmed(blockKey);
      if (!article || !key) {
        return null;
      }
      return Array.from(article.querySelectorAll?.("[data-block-type='readex_processing']") || [])
        .find((element) => trimmed(element?.dataset?.blockKey) === key) || null;
    }

    function readexProcessingProjectedSourceID(source) {
      return trimmed(source?.sourceBlockId)
        || trimmed(source?.sourceBlockID)
        || trimmed(source?.id);
    }

    function readexProcessingProjectedMessageTextItemFromBlock(block, text) {
      const sourceID = readexProcessingProjectedSourceID(block);
      if (!block || !sourceID) {
        return null;
      }
      return {
        id: trimmed(block?.id) || sourceID,
        sourceBlockId: sourceID,
        type: "main_text",
        text: String(text ?? blockText(block) ?? ""),
        detailText: trimmed(block?.detailText),
        status: trimmed(block?.status) || "success",
        durationMilliseconds: Number.isFinite(Number(block?.durationMilliseconds))
          ? Number(block.durationMilliseconds)
          : 0,
        searchQueries: Array.isArray(block?.searchQueries) ? block.searchQueries : [],
        searchReferences: Array.isArray(block?.searchReferences) ? block.searchReferences : [],
        webSearchActions: Array.isArray(block?.webSearchActions) ? block.webSearchActions : []
      };
    }

    function readexProcessingBlockElements(article) {
      if (!article) {
        return [];
      }
      return Array.from(article.querySelectorAll?.("[data-block-type='readex_processing']") || []);
    }

    function readexProcessingMessageTextItemSourceMatches(item, sourceID) {
      return trimmed(sourceID)
        && trimmed(item?.type) === "main_text"
        && readexProcessingProjectedSourceID(item) === trimmed(sourceID);
    }

    function readexProcessingBlockUpdatingProjectedMessageTextSource(block, nextItem, sourceID) {
      if (!block || typeof block !== "object" || !Array.isArray(block.items)) {
        return block;
      }
      const normalizedSourceID = trimmed(sourceID);
      if (!normalizedSourceID) {
        return block;
      }

      let didUpdate = false;
      const nextRawItems = block.items.map((item) => {
        if (!readexProcessingMessageTextItemSourceMatches(item, normalizedSourceID)) {
          return item;
        }
        didUpdate = true;
        return {
          ...item,
          text: nextItem.text,
          detailText: nextItem.detailText,
          status: nextItem.status,
          durationMilliseconds: nextItem.durationMilliseconds,
          searchQueries: nextItem.searchQueries,
          searchReferences: nextItem.searchReferences,
          webSearchActions: nextItem.webSearchActions
        };
      });

      return didUpdate
        ? {
            ...block,
            items: nextRawItems
          }
        : block;
    }

    function applyReadexProcessingProjectedMessageTextSourceUpdate(update, renderer, messagesRoot) {
      const messageKey = trimmed(update?.messageKey);
      const sourceBlock = update?.block && typeof update.block === "object" ? update.block : null;
      const sourceID = readexProcessingProjectedSourceID(sourceBlock);
      const article = findArticleByMessageKey(messagesRoot, messageKey);
      const nextSourceItem = readexProcessingProjectedMessageTextItemFromBlock(sourceBlock, update?.text);
      if (!article || !sourceBlock || !sourceID || !nextSourceItem) {
        return {
          applied: false,
          reason: !article ? "missing_article" : (!sourceBlock ? "missing_source_block" : "missing_source_id"),
          messageKey,
          blockKey: trimmed(update?.blockID || sourceBlock?.id),
          sourceID
        };
      }

      const message = article.__chatTranscriptMessage || {};
      const blockElements = readexProcessingBlockElements(article);
      for (const blockElement of blockElements) {
        const processingBlock = blockElement.__chatTranscriptReadexProcessingBlock;
        const items = readexProcessingItems(processingBlock);
        const itemIndex = items.findIndex((item) => readexProcessingMessageTextItemSourceMatches(item, sourceID));
        if (itemIndex < 0) {
          continue;
        }

        const previousItem = items[itemIndex] || {};
        const nextItem = {
          ...previousItem,
          ...nextSourceItem,
          sourceBlockId: readexProcessingProjectedSourceID(previousItem) || sourceID
        };
        const nextProcessingBlock = readexProcessingBlockUpdatingProjectedMessageTextSource(
          processingBlock,
          nextItem,
          sourceID
        );
        if (nextProcessingBlock && typeof nextProcessingBlock === "object") {
          blockElement.__chatTranscriptReadexProcessingBlock = nextProcessingBlock;
          blockElement.__chatTranscriptReadexProcessingMessage = message;
          blockElement.__chatTranscriptSignature = readexProcessingBlockRenderSignature(nextProcessingBlock, message);
        }

        const details = directChildByClass(blockElement, "readex-processing-details");
        if (!details) {
          return {
            applied: true,
            reason: "projected_processing_details_collapsed",
            visible: false,
            messageKey,
            blockKey: trimmed(blockElement?.dataset?.blockKey),
            sourceID,
            itemID: trimmed(nextItem?.id)
          };
        }

        const itemKey = readexProcessingItemKey(nextItem, itemIndex);
        const existing = Array.from(details.children || [])
          .find((child) => trimmed(child?.dataset?.readexProcessingItemKey) === itemKey) || null;
        if (!existing) {
          return {
            applied: false,
            reason: "missing_projected_processing_item",
            messageKey,
            blockKey: trimmed(blockElement?.dataset?.blockKey),
            sourceID,
            itemKey
          };
        }

        const nextElement = patchReadexProcessingMessageTextItem(existing, nextItem, renderer, message, itemKey);
        nextElement.dataset.readexProcessingItemKey = itemKey;
        nextElement.dataset.readexProcessingItemType = "main_text";
        if (nextElement !== existing) {
          existing.replaceWith(nextElement);
        }
        return {
          applied: true,
          reason: "projected_processing_item_updated",
          visible: true,
          messageKey,
          blockKey: trimmed(blockElement?.dataset?.blockKey),
          sourceID,
          itemKey,
          itemID: trimmed(nextItem?.id),
          textLength: String(nextItem?.text || "").length
        };
      }

      return {
        applied: false,
        reason: "missing_projected_processing_source",
        messageKey,
        blockKey: trimmed(update?.blockID || sourceBlock?.id),
        sourceID
      };
    }

    function applyReadexProcessingMessageTextSourceUpdate(update, renderer, messagesRoot) {
      const messageKey = trimmed(update?.messageKey);
      const block = update?.block && typeof update.block === "object" ? update.block : null;
      const item = update?.item && typeof update.item === "object" ? update.item : null;
      const fallbackItemIndex = Number.isFinite(Number(update?.itemIndex)) ? Number(update.itemIndex) : -1;
      const blockKey = trimmed(update?.blockID || block?.id);
      const sourceID = readexProcessingProjectedSourceID(item);
      const article = findArticleByMessageKey(messagesRoot, messageKey);
      const blockElement = findReadexProcessingBlockElement(article, blockKey);
      const projectedItems = Array.isArray(block?.activityItems) ? block.activityItems : [];
      let itemIndex = projectedItems.findIndex((candidate) => readexProcessingProjectedSourceID(candidate) === sourceID);
      if (itemIndex < 0 && fallbackItemIndex >= 0) {
        itemIndex = fallbackItemIndex;
      }
      if (!article || !blockElement || !block || !item || itemIndex < 0) {
        return {
          applied: false,
          reason: !article ? "missing_article" : (!blockElement ? "missing_processing_block" : (!item ? "missing_item" : "missing_projected_item_source")),
          messageKey,
          blockKey,
          sourceID
        };
      }

      const message = article.__chatTranscriptMessage || {};
      blockElement.__chatTranscriptReadexProcessingBlock = block;
      blockElement.__chatTranscriptReadexProcessingMessage = message;
      blockElement.__chatTranscriptSignature = readexProcessingBlockRenderSignature(block, message);

      const details = directChildByClass(blockElement, "readex-processing-details");
      if (!details) {
        return {
          applied: true,
          reason: "details_collapsed",
          visible: false,
          messageKey,
          blockKey,
          itemID: trimmed(item?.id)
        };
      }

      const itemKey = readexProcessingItemKey(item, itemIndex);
      const existing = Array.from(details.children || [])
        .find((child) => trimmed(child?.dataset?.readexProcessingItemKey) === itemKey) || null;
      if (!existing) {
        return {
          applied: false,
          reason: "missing_processing_item",
          messageKey,
          blockKey,
          itemKey,
          sourceID
        };
      }
      const nextElement = patchReadexProcessingMessageTextItem(existing, item, renderer, message, itemKey);
      nextElement.dataset.readexProcessingItemKey = itemKey;
      nextElement.dataset.readexProcessingItemType = "main_text";
      if (nextElement !== existing) {
        existing.replaceWith(nextElement);
      }
      return {
        applied: true,
        reason: "updated",
        visible: true,
        messageKey,
        blockKey,
        itemKey,
        itemID: trimmed(item?.id),
        sourceID,
        textLength: String(item?.text || "").length
      };
    }

    function patchReadexProcessingToolItem(element, item, stateOwner, index, previewContentAccentContext = "") {
      const signature = readexProcessingItemSignature(item);
      if (
        element &&
        element.classList.contains("readex-processing-item-group") &&
        element.__chatTranscriptReadexProcessingItemSignature === signature
      ) {
        if (readexToolItemUsesPreviewContentAccentPresentation(item)) {
          const previewContentAccentColor = readexToolItemPreviewContentAccentColor(item, previewContentAccentContext);
          element
            .querySelectorAll(".has-preview-content-accent")
            .forEach((node) => applyReadexExtractedPDFAccentVariable(node, previewContentAccentColor));
          element
            .querySelectorAll(".readex-extracted-pdf-accent-icon, .readex-extracted-page-reference-link, .readex-tool-page-range-button, .readex-video-frame-timestamp-link")
            .forEach((node) => applyReadexExtractedPDFAccent(node, previewContentAccentColor));
        }
        return element;
      }

      const group = element && element.classList.contains("readex-processing-item-group")
        ? element
        : document.createElement("div");
      if (group === element && readexToolItemUsesPlainStatusRow(item)) {
        const row = directChildByClass(group, "readex-tool-activity-item");
        if (patchReadexToolStatusRow(row, item, {
          suppressIcon: readexProcessingProgressSuppressesToolIcon(item),
          previewContentAccentContext
        })) {
          group.className = "readex-processing-item-group";
          group.__chatTranscriptReadexProcessingItemSignature = signature;
          return group;
        }
      }
      if (group === element) {
        group.replaceChildren();
      }
      group.className = "readex-processing-item-group";
      group.__chatTranscriptReadexProcessingItemSignature = signature;
      appendReadexProcessingToolItem(group, item, stateOwner, index, previewContentAccentContext);
      return group;
    }

    function cleanupReadexProcessingDetailItem(element) {
      if (!element) {
        return;
      }
      element.remove();
    }

    function readexProcessingDetailChildIsRendererBlock(element) {
      return Boolean(trimmed(element?.dataset?.blockKey));
    }

    function readexProcessingFirstOwnedDetailItem(details) {
      return Array.from(details?.children || []).find((child) => (
        !readexProcessingDetailChildIsRendererBlock(child) &&
        trimmed(child?.dataset?.readexProcessingItemKey)
      )) || null;
    }

    function readexProcessingOwnedDetailCursor(details, firstOwnedElement = null) {
      return firstOwnedElement || details?.firstChild || null;
    }

    function insertBeforeOwnedCursor(root, element, cursor) {
      const ownedCursor = cursor && cursor.parentNode === root ? cursor : null;
      if (element === ownedCursor) {
        return element.nextSibling;
      }
      root.insertBefore(element, ownedCursor);
      return element.nextSibling;
    }

    function patchReadexProcessingDetailItems(
      details,
      items,
      renderer,
      message,
      stateOwner,
      previewContentAccentContext = "",
      markdownRemeasureToken = ""
    ) {
      const existingByKey = new Map();
      const firstOwnedElement = readexProcessingFirstOwnedDetailItem(details);
      Array.from(details.children || []).forEach((child) => {
        const key = trimmed(child.dataset?.readexProcessingItemKey);
        if (key) {
          existingByKey.set(key, child);
        }
      });

      const usedElements = new Set();
      let cursor = readexProcessingOwnedDetailCursor(details, firstOwnedElement);
      items.forEach((item, index) => {
        const itemKey = readexProcessingItemKey(item, index);
        const existing = existingByKey.get(itemKey) || null;
        let nextElement;
        if (item.type === "progress") {
          if (readexProcessingProgressUsesToolActivityRow(item)) {
            nextElement = patchReadexProcessingToolItem(existing, item, stateOwner, index, previewContentAccentContext);
            nextElement.dataset.readexProcessingItemType = "tool";
          } else {
            nextElement = patchReadexProcessingProgressItem(existing, item, renderer, message, markdownRemeasureToken);
            nextElement.dataset.readexProcessingItemType = "progress";
          }
        } else if (item.type === "main_text") {
          nextElement = patchReadexProcessingMessageTextItem(existing, item, renderer, message, itemKey, markdownRemeasureToken);
          nextElement.dataset.readexProcessingItemType = "main_text";
        } else if (item.type === "video_progress") {
          nextElement = patchReadexProcessingVideoProgressItem(existing, item, itemKey);
          nextElement.dataset.readexProcessingItemType = "video_progress";
        } else {
          nextElement = patchReadexProcessingToolItem(existing, item, stateOwner, index, previewContentAccentContext);
          nextElement.dataset.readexProcessingItemType = "tool";
        }
        nextElement.dataset.readexProcessingItemKey = itemKey;

        if (nextElement !== cursor) {
          cursor = insertBeforeOwnedCursor(details, nextElement, cursor);
        } else {
          cursor = nextElement.nextSibling;
        }
        usedElements.add(nextElement);
        existingByKey.delete(itemKey);
      });

      Array.from(details.children || []).forEach((child) => {
        if (!usedElements.has(child) && !readexProcessingDetailChildIsRendererBlock(child)) {
          cleanupReadexProcessingDetailItem(child);
        }
      });
    }

    function refreshReadexProcessingDetailsMarkdownLayout(element, block, renderer, message, phase) {
      if (!(element instanceof HTMLElement) || !element.__chatTranscriptReadexProcessingExpanded) {
        return {
          skipped: true,
          reason: "not_expanded"
        };
      }
      const details = directChildByClass(element, "readex-processing-details");
      if (!(details instanceof HTMLElement)) {
        return {
          skipped: true,
          reason: "details_missing"
        };
      }
      const token = readexProcessingNextMarkdownRemeasureToken(element, phase);
      const previewContentAccentContext = element.__chatTranscriptReadexProcessingPreviewContentAccentContext || "";
      const items = readexProcessingItems(block);
      patchReadexProcessingDetailItems(
        details,
        items,
        renderer,
        message,
        element,
        previewContentAccentContext,
        token
      );
      const retargetedOpeningAnimation = retargetReadexProcessingDetailsOpeningAnimation(
        element,
        `details-${trimmed(phase) || "toggle"}`
      );
      return {
        skipped: false,
        token,
        itemCount: items.length,
        details: readexProcessingElementLayoutProbe(details),
        retargetedOpeningAnimation
      };
    }

    function updateReadexProcessingDetails(element, block, renderer, message, options = {}) {
      const expanded = Boolean(element.__chatTranscriptReadexProcessingExpanded);
      const existing = directChildByClass(element, "readex-processing-details");
      const layoutStable = options.layoutStable === true;
      if (!expanded) {
        if (existing) {
          animateReadexDisclosureElement(existing, false, {
            removeOnFinish: true,
            reserveLayout: layoutStable
          });
        }
        return;
      }

      const items = readexProcessingItems(block);
      if (!items.length) {
        if (Array.from(existing?.children || []).some(readexProcessingDetailChildIsRendererBlock)) {
          existing.className = "readex-processing-details";
          existing.hidden = false;
          return;
        }
        removeDirectChild(element, existing);
        return;
      }

      const details = existing || document.createElement("div");
      if (existing) {
        cancelReadexDisclosureAnimation(existing);
      }
      details.className = "readex-processing-details";
      details.hidden = false;
      cleanupReadexDisclosureAnimationStyles(details);
      if (!existing) {
        element.appendChild(details);
      }
      const previewContentAccentContext = options?.previewContentAccentContext || trimmed(options?.extractedPDFAccentColor);
      patchReadexProcessingDetailItems(
        details,
        items,
        renderer,
        message,
        element,
        previewContentAccentContext
      );

      if (!existing) {
        animateReadexDisclosureElement(details, true, { reserveLayout: layoutStable });
      }
    }

    function updateReadexProcessingBlockElement(element, block, renderer, message, blockKey) {
      const isComplete = readexProcessingIsComplete(block, message);
      const ownsChrome = readexProcessingOwnsChrome(block);
      const groupID = readexProcessingGroupID(block);
      element.className = isComplete
        ? "readex-processing-block"
        : "readex-processing-block is-live";
      element.classList.toggle("is-continuation", !ownsChrome);
      if (groupID) {
        element.dataset.readexProcessingGroupId = groupID;
      } else {
        delete element.dataset.readexProcessingGroupId;
      }
      element.__chatTranscriptReadexProcessingBlock = block;
      element.__chatTranscriptReadexProcessingMessage = message;
      const previewContentAccentContext = configureReadexExtractedPDFAccent(element, block, message, blockKey);
      element.__chatTranscriptReadexProcessingPreviewContentAccentContext = previewContentAccentContext || "";
      configureReadexNestedDisclosureOwner(element, block);
      const isExpandable = true;
      const expansionStateSourceID = readexProcessingExpansionSourceID(block) || trimmed(block?.id) || trimmed(blockKey);
      if (element.__chatTranscriptReadexProcessingExpansionStateSourceID !== expansionStateSourceID) {
        element.__chatTranscriptReadexProcessingExpansionStateSourceID = expansionStateSourceID;
        element.__chatTranscriptReadexProcessingUserToggled = false;
        element.__chatTranscriptReadexProcessingExpanded = undefined;
      }
      const payloadExpansionState = readexProcessingPayloadExpansionState(block);
      if (typeof element.__chatTranscriptReadexProcessingExpanded !== "boolean") {
        element.__chatTranscriptReadexProcessingExpanded = payloadExpansionState ?? true;
      } else if (
        element.__chatTranscriptReadexProcessingUserToggled !== true
        && payloadExpansionState != null
      ) {
        element.__chatTranscriptReadexProcessingExpanded = payloadExpansionState;
      }
      if (!isExpandable) {
        element.__chatTranscriptReadexProcessingExpanded = false;
      }
      if (!ownsChrome && isExpandable) {
        const groupExpansionState = readexProcessingGroupExpansionState(groupID);
        element.__chatTranscriptReadexProcessingExpanded = typeof groupExpansionState === "boolean"
          ? groupExpansionState
          : true;
      }
      element.classList.toggle(
        "is-group-collapsed",
        !ownsChrome && isExpandable && !element.__chatTranscriptReadexProcessingExpanded
      );

      if (ownsChrome) {
        const titleText = isComplete ? readexProcessingTitleText(block) : liveReadexProcessingTitleText(block);
        const shouldShimmerTitle = false;
        element.__chatTranscriptReadexProcessingTitleShimmers = shouldShimmerTitle;
        const supportLine = updateSupportLine(
          element,
          "",
          titleText,
          isExpandable
            ? "chevron-right"
            : null
        );
        configurePressableSupportLine(supportLine, {
          interactive: isExpandable,
          expanded: isExpandable ? Boolean(element.__chatTranscriptReadexProcessingExpanded) : undefined
        });
        if (supportLine) {
          supportLine.__chatTranscriptReadexPrimaryPreview = null;
        }
        const title = supportLine ? supportLine.querySelector(".support-line-title") : null;
        if (title) {
          title.classList.add("small");
          renderReadexProcessingTitleText(title, titleText, { shimmer: shouldShimmerTitle });
        }
        syncReadexProcessingTimer(element, block, !isComplete);
        updateReadexProcessingDivider(element, isExpandable);
      } else {
        element.__chatTranscriptReadexProcessingTitleShimmers = false;
        clearReadexProcessingTimer(element);
        removeDirectChild(element, directChildByClass(element, "support-line"));
        removeDirectChild(element, directChildByClass(element, "readex-processing-divider"));
      }
      updateReadexProcessingDetails(element, block, renderer, message, {
        previewContentAccentContext
      });
      if (ownsChrome) {
        syncReadexProcessingGroupExpansion(element);
      }
    }

    function installReadexProcessingBlockInteractions(element) {
      if (!element || element.__chatTranscriptReadexProcessingInteractionsInstalled) {
        return;
      }
      element.__chatTranscriptReadexProcessingInteractionsInstalled = true;

      const toggle = (event) => {
        const target = event?.target;
        if (!(target instanceof Element) || !target.closest(".support-line.is-interactive")) {
          return;
        }
        if (readexSupportTargetIsNestedReferenceControl(target)) {
          return;
        }
        event.preventDefault();
        event.stopPropagation();

        const supportLine = target.closest(".support-line.is-interactive");
        const primaryPreview = supportLine?.__chatTranscriptReadexPrimaryPreview || null;
        if (primaryPreview) {
          openReadexPreviewItem(primaryPreview);
          return;
        }

        const block = element.__chatTranscriptReadexProcessingBlock;
        const message = element.__chatTranscriptReadexProcessingMessage;
        postReadexProcessingToggleLayoutProbe("toggle_before", element, block, message, {
          targetClassName: String(target.className || ""),
          nextExpanded: !element.__chatTranscriptReadexProcessingExpanded
        });
        element.__chatTranscriptReadexProcessingExpanded = !element.__chatTranscriptReadexProcessingExpanded;
        element.__chatTranscriptReadexProcessingUserToggled = true;
        const blockKey = trimmed(element.dataset.blockKey);
        const renderer = resolveMarkdownRenderer();
        updateReadexProcessingBlockElement(element, block, renderer, message, blockKey);
        postReadexProcessingToggleLayoutProbe("toggle_after", element, block, message, {
          targetClassName: String(target.className || "")
        });
        scheduleReadexProcessingLayoutOverlapProbe(element, "readex_processing_toggle_after");
        scheduleReadexProcessingVirtualStateRefresh(element, block, renderer, message);
        postReadexProcessingExpansionState();
      };

      element.addEventListener("click", toggle);
      element.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") {
          return;
        }
        toggle(event);
      });
    }

    function renderReadexProcessingBlock(block, renderer, message, blockKey) {
      const container = document.createElement("div");
      container.dataset.blockKey = blockKey;
      container.dataset.blockType = "readex_processing";
      installReadexProcessingBlockInteractions(container);
      updateReadexProcessingBlockElement(container, block, renderer, message, blockKey);
      return container;
    }

    function readexStoppedMarkerDurationMilliseconds(block) {
      const turnDuration = readexProcessingTurnDurationMilliseconds(block);
      if (turnDuration != null) {
        return turnDuration;
      }
      const duration = Number(block?.durationMilliseconds);
      if (Number.isFinite(duration)) {
        return Math.max(0, duration);
      }
      const elapsed = readexProcessingTurnElapsedMilliseconds(block);
      return elapsed == null ? 0 : elapsed;
    }

    function readexStoppedMarkerTitleText(block) {
      return `你在 ${formatReadexProcessingDuration(readexStoppedMarkerDurationMilliseconds(block))} 后停止了`;
    }

    function renderReadexStoppedMarkerTitleText(element, titleText) {
      if (!element) {
        return;
      }
      const displayText = trimmed(titleText);
      stopCodexShimmerText(element);
      clearReadexShimmerPresentation(element);
      element.textContent = "";
      const match = /^你在\s+(.+)\s+后停止了$/.exec(displayText);
      if (!match) {
        element.textContent = displayText;
        return;
      }

      element.appendChild(document.createTextNode("你在 "));
      const duration = document.createElement("span");
      duration.className = "readex-processing-duration";
      match[1].split(/(\s+)/).forEach((part) => {
        if (!part) {
          return;
        }
        if (/^\s+$/.test(part)) {
          duration.appendChild(document.createTextNode(part));
          return;
        }
        appendReadexProcessingDurationToken(duration, part);
      });
      element.appendChild(duration);
      element.appendChild(document.createTextNode(" 后停止了"));
    }

    function updateReadexStoppedMarkerBlockElement(element, block, blockKey) {
      element.className = "readex-stopped-marker-block";
      const titleText = readexStoppedMarkerTitleText(block);
      removeDirectChild(element, directChildByClass(element, "support-line"));
      removeDirectChild(element, directChildByClass(element, "readex-processing-divider"));
      let title = directChildByClass(element, "readex-stopped-marker-title");
      if (!title) {
        title = document.createElement("div");
      }
      title.className = "readex-stopped-marker-title readex-status-caption";
      renderReadexStoppedMarkerTitleText(title, titleText);
      if (title.parentNode !== element) {
        element.insertBefore(title, element.firstChild);
      }
      let divider = directChildByClass(element, "readex-stopped-marker-divider");
      if (!divider) {
        divider = document.createElement("div");
      }
      divider.className = "readex-stopped-marker-divider readex-status-divider readex-chat-divider";
      if (divider.parentNode !== element) {
        element.appendChild(divider);
      }
      element.dataset.blockKey = blockKey;
      element.dataset.blockType = "readex_stopped_marker";
    }

    function renderReadexStoppedMarkerBlock(block, blockKey) {
      const container = document.createElement("div");
      updateReadexStoppedMarkerBlockElement(container, block, blockKey);
      return container;
    }

    function renderSearchProgressBlock() {
      return renderSearchResultsBlock([], null, "search_progress", [], "processing");
    }

    function attachmentDisplayName(attachment) {
      if (!attachment || typeof attachment !== "object") {
        return "";
      }
      return trimmed(attachment.displayName || attachment.name || attachment.fileName);
    }

    function isImageAttachment(attachment) {
      if (!attachment || typeof attachment !== "object") {
        return false;
      }
      const mimeType = trimmed(attachment.mimeType || attachment.mediaType || attachment.type).toLowerCase();
      return attachment.kind === "importedImage" || mimeType.startsWith("image/");
    }

    function attachmentImageSource(attachment) {
      if (!attachment || typeof attachment !== "object") {
        return "";
      }

      const thumbnailSource = trimmed(attachment.thumbnailURL || attachment.thumbnailUrl || attachment.thumbnailSrc);
      if (thumbnailSource) {
        return thumbnailSource;
      }

      const url = trimmed(attachment.url || attachment.uri || attachment.link || attachment.src);
      if (url) {
        return url;
      }

      const base64 = trimmed(attachment.base64 || attachment.b64_json || attachment.b64 || attachment.data);
      if (base64) {
        if (/^data:/i.test(base64)) {
          return base64;
        }
        return `data:${trimmed(attachment.mimeType || attachment.mediaType) || "image/png"};base64,${base64}`;
      }

      const filePath = trimmed(attachment.filePath || attachment.path);
      if (!filePath) {
        return "";
      }
      const thumbnailMaxPixelSize = attachmentThumbnailMaxPixelSize(attachment);
      if (/^file:/i.test(filePath)) {
        return `chat-transcript-attachment-thumbnail://image?max=${thumbnailMaxPixelSize}&path=${encodeURIComponent(filePath)}`;
      }
      if (filePath.startsWith("/")) {
        return `chat-transcript-attachment-thumbnail://image?max=${thumbnailMaxPixelSize}&path=${encodeURIComponent(filePath)}`;
      }
      return "";
    }

    function attachmentThumbnailMaxPixelSize(attachment) {
      const raw = Number(attachment.thumbnailMaxPixelSize || attachment.thumbnailMax || attachment.maxPixelSize);
      if (!Number.isFinite(raw)) {
        return 520;
      }
      return Math.min(4096, Math.max(64, Math.round(raw)));
    }

    const attachmentImageThumbnailLayout = Object.freeze({
      maxWidth: 232,
      maxHeight: 232,
      fallbackWidth: 232,
      fallbackHeight: 176
    });

    function attachmentImageThumbnailDisplaySize(sourceWidth, sourceHeight) {
      const width = Number(sourceWidth || 0);
      const height = Number(sourceHeight || 0);
      if (!(width > 0) || !(height > 0)) {
        return {
          width: attachmentImageThumbnailLayout.fallbackWidth,
          height: attachmentImageThumbnailLayout.fallbackHeight
        };
      }
      const scale = Math.min(
        attachmentImageThumbnailLayout.maxWidth / width,
        attachmentImageThumbnailLayout.maxHeight / height
      );
      return {
        width: Math.max(1, Math.round(width * scale)),
        height: Math.max(1, Math.round(height * scale))
      };
    }

    function applyAttachmentImageThumbnailDisplaySize(item, size) {
      item.style.setProperty("--attachment-image-thumbnail-width", `${size.width}px`);
      item.style.setProperty("--attachment-image-thumbnail-height", `${size.height}px`);
    }

    function updateAttachmentImageThumbnailLayout(image, item) {
      item.classList.remove("is-missing-image");
      applyAttachmentImageThumbnailDisplaySize(
        item,
        attachmentImageThumbnailDisplaySize(image?.naturalWidth, image?.naturalHeight)
      );
    }

    function renderAttachments(attachments, messageID) {
      const safeAttachments = Array.isArray(attachments) ? attachments : [];
      if (!safeAttachments.length) {
        return null;
      }

      const root = document.createElement("div");
      root.className = "message-attachments";

      safeAttachments.forEach((attachment, attachmentIndex) => {
        const item = document.createElement("button");
        item.type = "button";
        const displayName = attachmentDisplayName(attachment);
        const imageSource = isImageAttachment(attachment) ? attachmentImageSource(attachment) : "";
        if (imageSource) {
          item.className = "attachment attachment-image";
          item.setAttribute("aria-label", displayName || "图片附件");
          applyAttachmentImageThumbnailDisplaySize(
            item,
            attachmentImageThumbnailDisplaySize(null, null)
          );

          const image = document.createElement("img");
          image.className = "attachment-image-thumbnail";
          image.alt = displayName || "图片附件";
          image.loading = "lazy";
          image.decoding = "async";
          image.addEventListener("load", () => {
            updateAttachmentImageThumbnailLayout(image, item);
          });
          image.addEventListener("error", () => {
            applyAttachmentImageThumbnailDisplaySize(
              item,
              attachmentImageThumbnailDisplaySize(null, null)
            );
            item.classList.add("is-missing-image");
          });
          image.src = imageSource;
          item.appendChild(image);
        } else {
          item.className = "attachment";

          const icon = document.createElement("span");
          icon.innerHTML = makeIcon(attachment?.kind === "importedImage" ? "photo" : "doc");
          item.appendChild(icon);

          const label = document.createElement("span");
          label.textContent = displayName;
          item.appendChild(label);
        }

        item.addEventListener("click", () => {
          postAttachmentOpen(messageID, attachmentIndex);
        });
        root.appendChild(item);
      });

      return root;
    }

    return Object.freeze({
      renderThinkingBlock,
      updateThinkingBlockElement,
      renderReasoningSummaryBlock,
      updateReasoningSummaryBlockElement,
      renderReasoningActivityBlock,
      updateReasoningActivityBlockElement,
      renderReadexProcessingBlock,
      updateReadexProcessingBlockElement,
      applyReadexProcessingMessageTextSourceUpdate,
      applyReadexProcessingProjectedMessageTextSourceUpdate,
      renderReadexStoppedMarkerBlock,
      updateReadexStoppedMarkerBlockElement,
      renderReadexContextStatusBlock,
      updateReadexContextStatusBlockElement,
      renderReadexToolActivityBlock,
      updateReadexToolActivityBlockElement,
      renderSearchResultsBlock,
      renderReadexSourcesBlock,
      updateReadexSourcesBlockElement,
      renderSearchProgressBlock,
      renderAttachments
    });
  };
})();
