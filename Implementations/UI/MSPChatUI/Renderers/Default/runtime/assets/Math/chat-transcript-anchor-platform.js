(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript anchor platform dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptAnchorPlatformFactory = function createChatTranscriptAnchorPlatform(dependencies) {
    const postPresentationProbe = requiredFunction(dependencies, "postPresentationProbe");
    const findMessageElement = requiredFunction(dependencies, "findMessageElement");
    const scrollRoot = requiredFunction(dependencies, "scrollRoot");
    const clamp = requiredFunction(dependencies, "clamp");
    const maximumScrollTop = requiredFunction(dependencies, "maximumScrollTop");
    const scrollViewportRect = requiredFunction(dependencies, "scrollViewportRect");

    function anchorElementForPoint(x, y) {
      let element = document.elementFromPoint(x, y);
      while (element && element !== document.body) {
        const classList = element.classList;
        if (
          classList &&
          (
            classList.contains("message-content") ||
            classList.contains("assistant-fragment") ||
            classList.contains("thinking-content") ||
            classList.contains("message-header") ||
            classList.contains("message-footer") ||
            classList.contains("attachment") ||
            classList.contains("message-layout") ||
            classList.contains("message-main") ||
            classList.contains("message")
          )
        ) {
          const rect = element.getBoundingClientRect();
          if (rect.width > 0 && rect.height > 0) {
            return element;
          }
        }
        element = element.parentElement;
      }
      return null;
    }

    function normalizedMessageID(messageID) {
      return typeof messageID === "string" ? messageID.trim() : "";
    }

    function capturePresentationAnchor() {
      const root = scrollRoot();
      const viewport = scrollViewportRect(root);
      if (!root || !viewport || viewport.width <= 0 || viewport.height <= 0) {
        return null;
      }

      const topOffset = Number(root.scrollTop) || 0;
      const scrollHeight = Number(root.scrollHeight) || 0;
      const clientHeight = Number(root.clientHeight) || 0;
      if (topOffset <= 1 || clientHeight <= 0 || scrollHeight <= clientHeight + 1) {
        return null;
      }

      const maximumTopOffset = maximumScrollTop(root);
      const xFractions = [0.5, 0.38, 0.62, 0.24, 0.76];
      const yFractions = [0.48, 0.36, 0.6];
      const horizontalInset = Math.min(Math.max(viewport.width * 0.08, 12), 48);
      const verticalInset = Math.min(Math.max(viewport.height * 0.08, 12), 72);

      for (const yFraction of yFractions) {
        const pointY = clamp(
          viewport.top + viewport.height * yFraction,
          viewport.top + verticalInset,
          viewport.top + Math.max(viewport.height - verticalInset, verticalInset)
        );

        for (const xFraction of xFractions) {
          const pointX = clamp(
            viewport.left + viewport.width * xFraction,
            viewport.left + horizontalInset,
            viewport.left + Math.max(viewport.width - horizontalInset, horizontalInset)
          );
          const element = anchorElementForPoint(pointX, pointY);
          if (!element) {
            continue;
          }

          const rect = element.getBoundingClientRect();
          const messageElement = element.closest(".message");
          const messageRect = messageElement instanceof Element ? messageElement.getBoundingClientRect() : null;
          return {
            element,
            messageID: normalizedMessageID(messageElement?.dataset?.messageId),
            messageOffsetYWithinMessage: messageRect ? pointY - messageRect.top : null,
            viewportY: pointY - viewport.top,
            offsetYWithinElement: pointY - rect.top,
            role: element.closest(".message")?.classList?.contains("assistant")
              ? "assistant"
              : (element.closest(".message")?.classList?.contains("user") ? "user" : "unknown"),
            className: typeof element.className === "string" ? element.className : "",
            fallbackScrollTop: clamp(topOffset, 0, maximumTopOffset),
            distanceFromBottom: maximumTopOffset - topOffset
          };
        }
      }

      return {
        element: null,
        messageID: "",
        messageOffsetYWithinMessage: null,
        viewportY: viewport.height * 0.48,
        offsetYWithinElement: 0,
        role: "none",
        className: "",
        fallbackScrollTop: clamp(topOffset, 0, maximumTopOffset),
        distanceFromBottom: maximumTopOffset - topOffset
      };
    }

    function restorePresentationAnchor(anchor) {
      const root = scrollRoot();
      const viewport = scrollViewportRect(root);
      if (!root || !viewport || !anchor) {
        return;
      }

      const maxScrollTop = maximumScrollTop(root);
      if (maxScrollTop <= 0) {
        return;
      }

      if (anchor.element && anchor.element.isConnected) {
        const rect = anchor.element.getBoundingClientRect();
        if (rect.width > 0 && rect.height > 0) {
          const currentAnchorY = rect.top + anchor.offsetYWithinElement;
          const desiredAnchorY = viewport.top + anchor.viewportY;
          const delta = currentAnchorY - desiredAnchorY;
          postPresentationProbe({
            stage: "restore-before-adjust",
            scrollTop: Number(root.scrollTop) || 0,
            scrollHeight: Number(root.scrollHeight) || 0,
            clientHeight: Number(root.clientHeight) || 0,
            anchorRole: anchor.role || "unknown",
            anchorClass: anchor.className || "",
            viewportY: anchor.viewportY || 0,
            anchorOffset: anchor.offsetYWithinElement || 0,
            delta
          });
          if (Number.isFinite(delta) && Math.abs(delta) > 0.5) {
            root.scrollTop = clamp((Number(root.scrollTop) || 0) + delta, 0, maxScrollTop);
          }
          postPresentationProbe({
            stage: "restore-after-adjust",
            scrollTop: Number(root.scrollTop) || 0,
            scrollHeight: Number(root.scrollHeight) || 0,
            clientHeight: Number(root.clientHeight) || 0,
            anchorRole: anchor.role || "unknown",
            anchorClass: anchor.className || "",
            viewportY: anchor.viewportY || 0,
            anchorOffset: anchor.offsetYWithinElement || 0,
            delta
          });
          return;
        }
      }

      const anchorMessageID = normalizedMessageID(anchor?.messageID);
      if (anchorMessageID) {
        const messageElement = findMessageElement(anchorMessageID);
        if (messageElement) {
          const rect = messageElement.getBoundingClientRect();
          if (rect.width > 0 && rect.height > 0) {
            const messageOffset = Number.isFinite(anchor.messageOffsetYWithinMessage)
              ? clamp(anchor.messageOffsetYWithinMessage, 0, rect.height)
              : rect.height * 0.48;
            const currentAnchorY = rect.top + messageOffset;
            const desiredAnchorY = viewport.top + (anchor.viewportY || 0);
            const delta = currentAnchorY - desiredAnchorY;
            postPresentationProbe({
              stage: "restore-message-before-adjust",
              scrollTop: Number(root.scrollTop) || 0,
              scrollHeight: Number(root.scrollHeight) || 0,
              clientHeight: Number(root.clientHeight) || 0,
              anchorRole: anchor.role || "unknown",
              anchorClass: anchor.className || "",
              viewportY: anchor.viewportY || 0,
              anchorOffset: messageOffset,
              delta
            });
            if (Number.isFinite(delta) && Math.abs(delta) > 0.5) {
              root.scrollTop = clamp((Number(root.scrollTop) || 0) + delta, 0, maxScrollTop);
            }
            postPresentationProbe({
              stage: "restore-message-after-adjust",
              scrollTop: Number(root.scrollTop) || 0,
              scrollHeight: Number(root.scrollHeight) || 0,
              clientHeight: Number(root.clientHeight) || 0,
              anchorRole: anchor.role || "unknown",
              anchorClass: anchor.className || "",
              viewportY: anchor.viewportY || 0,
              anchorOffset: messageOffset,
              delta
            });
            return;
          }
        }
      }

      if (Number.isFinite(anchor.fallbackScrollTop)) {
        const fallbackTarget = clamp(anchor.fallbackScrollTop, 0, maxScrollTop);
        postPresentationProbe({
          stage: "restore-fallback-before-adjust",
          scrollTop: Number(root.scrollTop) || 0,
          scrollHeight: Number(root.scrollHeight) || 0,
          clientHeight: Number(root.clientHeight) || 0,
          anchorRole: anchor.role || "unknown",
          anchorClass: anchor.className || "",
          viewportY: anchor.viewportY || 0,
          anchorOffset: anchor.offsetYWithinElement || 0,
          delta: fallbackTarget - (Number(root.scrollTop) || 0)
        });
        root.scrollTop = fallbackTarget;
        postPresentationProbe({
          stage: "restore-fallback-after-adjust",
          scrollTop: Number(root.scrollTop) || 0,
          scrollHeight: Number(root.scrollHeight) || 0,
          clientHeight: Number(root.clientHeight) || 0,
          anchorRole: anchor.role || "unknown",
          anchorClass: anchor.className || "",
          viewportY: anchor.viewportY || 0,
          anchorOffset: anchor.offsetYWithinElement || 0,
          delta: 0
        });
      }
    }

    function transcriptAnchorSnapshot(anchor) {
      return {
        anchorRole: anchor?.role || "none",
        anchorClass: anchor?.className || "",
        anchorMessageID: normalizedMessageID(anchor?.messageID),
        anchorDistanceFromBottom: Number(anchor?.distanceFromBottom) || 0,
        anchorViewportY: Number(anchor?.viewportY) || 0,
        anchorOffset: Number(anchor?.offsetYWithinElement) || 0
      };
    }

    return Object.freeze({
      anchorElementForPoint,
      capturePresentationAnchor,
      restorePresentationAnchor,
      transcriptAnchorSnapshot
    });
  };
})();
