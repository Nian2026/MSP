(function () {
  window.ChatTranscriptStylePlatformFactory = function createChatTranscriptStylePlatform() {
    function applyPayloadStyle(style) {
      if (!style) {
        return;
      }

      const root = document.documentElement;
      const variableMappings = {
        "--app-bg": style.appBackground,
        "--title": style.title,
        "--secondary": style.secondary,
        "--assistant-bg": style.assistantBackground,
        "--assistant-border": style.assistantBorder,
        "--user-bg": style.userBackground,
        "--user-border": style.userBorder,
        "--assistant-accent": style.assistantAccent,
        "--user-accent": style.userAccent,
        "--chip-bg": style.chipBackground,
        "--code-bg": style.codeBackground,
        "--quote-border": style.blockquoteBorder,
        "--math-bg": style.codeBackgroundSoft,
        "--message-link-gradient-top": style.messageLinkGradientTop,
        "--message-link-gradient-mid": style.messageLinkGradientMid,
        "--message-link-gradient-bottom": style.messageLinkGradientBottom,
        "--message-link-hover-gradient-top": style.messageLinkHoverGradientTop,
        "--message-link-hover-gradient-mid": style.messageLinkHoverGradientMid,
        "--message-link-hover-gradient-bottom": style.messageLinkHoverGradientBottom,
        "--message-link-arrow-color": style.messageLinkArrowColor,
        "--message-link-hover-arrow-color": style.messageLinkHoverArrowColor,
        "--readex-chat-divider-color": style.chatDividerColor || style.readexChatDividerColor
      };

      Object.entries(variableMappings).forEach(([key, value]) => {
        if (typeof value === "string" && value.trim()) {
          root.style.setProperty(key, value);
        }
      });

      const numericMappings = {
        "--message-link-font-weight": style.messageLinkFontWeight,
        "--message-link-arrow-font-weight": style.messageLinkArrowFontWeight
      };
      Object.entries(numericMappings).forEach(([key, value]) => {
        const numericValue = Number(value);
        if (Number.isFinite(numericValue)) {
          root.style.setProperty(key, `${numericValue}`);
        }
      });

      const pixelMappings = {
        "--chat-code-block-corner-radius": style.messageCodeBlockCornerRadius,
        "--readex-thinking-indicator-font-size": style.chatThinkingIndicatorFontSize ?? style.readexThinkingIndicatorFontSize,
        "--readex-tool-activity-font-size": style.chatToolActivityFontSize ?? style.readexToolActivityFontSize,
        "--readex-tool-activity-line-spacing": style.chatToolActivityLineSpacing ?? style.readexToolActivityLineSpacing,
        "--readex-tool-final-answer-spacing": style.chatToolFinalAnswerSpacing ?? style.readexToolFinalAnswerSpacing,
        "--readex-thinking-indicator-offset-y": style.chatThinkingIndicatorVerticalOffset ?? style.readexThinkingIndicatorVerticalOffset,
        "--readex-chat-divider-thickness": style.chatDividerThickness ?? style.readexChatDividerThickness
      };
      Object.entries(pixelMappings).forEach(([key, value]) => {
        const numericValue = Number(value);
        if (Number.isFinite(numericValue)) {
          root.style.setProperty(key, `${numericValue}px`);
        }
      });

      if (typeof style.messageLinkShowsArrow === "boolean") {
        root.style.setProperty(
          "--message-link-arrow-display",
          style.messageLinkShowsArrow ? "inline-block" : "none"
        );
      }

      const emMappings = {
        "--message-link-arrow-font-size": style.messageLinkArrowFontSize,
        "--message-link-arrow-margin-left": style.messageLinkArrowMarginLeft,
        "--message-link-arrow-offset-y": style.messageLinkArrowOffsetY
      };
      Object.entries(emMappings).forEach(([key, value]) => {
        const numericValue = Number(value);
        if (Number.isFinite(numericValue)) {
          root.style.setProperty(key, `${numericValue}em`);
        }
      });
    }

    function applyHighlightTheme(theme) {
      const lightThemeLink = document.getElementById("highlight-theme-light");
      const darkThemeLink = document.getElementById("highlight-theme-dark");
      if (!(lightThemeLink instanceof HTMLLinkElement) || !(darkThemeLink instanceof HTMLLinkElement)) {
        return;
      }
      const isDark = theme === "dark";
      lightThemeLink.disabled = isDark;
      darkThemeLink.disabled = !isDark;
    }

    function applyConversationPresentationStyle(presentation) {
      const root = document.documentElement;
      if (!presentation || !root) {
        return;
      }

      root.setAttribute("data-theme", presentation.theme === "dark" ? "dark" : "light");
      const readexTranscriptTheme = typeof presentation.chatTranscriptTheme === "string"
        ? presentation.chatTranscriptTheme.trim()
        : typeof presentation.readexTranscriptTheme === "string"
        ? presentation.readexTranscriptTheme.trim()
        : "";
      if (readexTranscriptTheme) {
        root.setAttribute("data-readex-transcript-theme", readexTranscriptTheme);
      } else {
        root.removeAttribute("data-readex-transcript-theme");
      }
      applyHighlightTheme(presentation.theme === "dark" ? "dark" : "light");
      applyPayloadStyle(presentation.style);

      const numericMappings = {
        "--chat-body-font-size": presentation.bodyFontSize,
        "--chat-role-font-size": presentation.roleFontSize,
        "--chat-meta-font-size": presentation.metaFontSize,
        "--chat-support-font-size": presentation.supportFontSize,
        "--chat-message-gap": presentation.messageGap,
        "--chat-page-padding-x": presentation.pagePaddingX,
        "--chat-page-padding-y": presentation.pagePaddingY,
        "--chat-page-padding-top": presentation.pagePaddingTop,
        "--chat-page-padding-bottom": presentation.pagePaddingBottom,
        "--chat-container-relative-bubble-base-width": presentation.containerRelativeBubbleBaseWidth,
        "--chat-container-relative-growth-reserve-ratio": presentation.containerRelativeGrowthReserveRatio,
        "--chat-container-relative-growth-reserve-min": presentation.containerRelativeMinimumGrowthReserve,
        "--chat-container-relative-growth-reserve-max": presentation.containerRelativeMaximumGrowthReserve,
        "--chat-assistant-bubble-max-width": presentation.assistantBubbleMaxWidth,
        "--chat-user-bubble-max-width": presentation.userBubbleMaxWidth,
        "--chat-assistant-bubble-offset-x": presentation.assistantBubbleOffsetX,
        "--chat-user-bubble-offset-x": presentation.userBubbleOffsetX,
        "--chat-assistant-bubble-offset-y": presentation.assistantBubbleOffsetY,
        "--chat-user-bubble-offset-y": presentation.userBubbleOffsetY,
        "--chat-assistant-bubble-padding-x": presentation.assistantBubblePaddingX,
        "--chat-user-bubble-padding-x": presentation.userBubblePaddingX,
        "--chat-assistant-bubble-padding-y": presentation.assistantBubblePaddingY,
        "--chat-user-bubble-padding-y": presentation.userBubblePaddingY,
        "--chat-assistant-bubble-corner-radius": presentation.assistantBubbleCornerRadius,
        "--chat-generated-image-corner-radius": presentation.generatedImageCornerRadius,
        "--chat-user-bubble-corner-radius": presentation.userBubbleCornerRadius,
        "--chat-assistant-content-base-width": presentation.assistantContentBaseWidth,
        "--chat-user-content-base-width": presentation.userContentBaseWidth,
        "--chat-assistant-content-max-width": presentation.assistantContentMaxWidth,
        "--chat-user-content-max-width": presentation.userContentMaxWidth,
        "--chat-assistant-content-offset-x": presentation.assistantContentOffsetX,
        "--chat-user-content-offset-x": presentation.userContentOffsetX,
        "--chat-assistant-content-offset-y": presentation.assistantContentOffsetY,
        "--chat-user-content-offset-y": presentation.userContentOffsetY,
        "--chat-page-zoom-factor": presentation.pageZoom,
        "--chat-fixed-scale": presentation.pageZoom > 0 ? 1 / presentation.pageZoom : 1,
        "--chat-history-editor-corner-radius": presentation.historyEditorCornerRadius,
        "--chat-history-editor-font-size": presentation.historyEditorFontSize,
        "--chat-assistant-action-offset-x": presentation.assistantActionRowOffsetX,
        "--chat-assistant-action-offset-y": presentation.assistantActionRowOffsetY,
        "--chat-assistant-action-size-scale": presentation.assistantActionRowScale,
        "--chat-assistant-action-highlight-width-scale": presentation.assistantActionHighlightWidthScale,
        "--chat-assistant-action-highlight-height-scale": presentation.assistantActionHighlightHeightScale,
        "--chat-user-action-offset-x": presentation.userActionRowOffsetX,
        "--chat-user-action-offset-y": presentation.userActionRowOffsetY,
        "--chat-user-action-size-scale": presentation.userActionRowScale,
        "--chat-user-action-highlight-width-scale": presentation.userActionHighlightWidthScale,
        "--chat-user-action-highlight-height-scale": presentation.userActionHighlightHeightScale,
        "--chat-history-editor-inset-width": presentation.historyEditorInsetWidth,
        "--chat-history-editor-inset-height": presentation.historyEditorInsetHeight,
        "--chat-history-editor-line-fragment-padding": presentation.historyEditorLineFragmentPadding,
        "--chat-history-editor-vertical-offset": presentation.historyEditorVerticalOffset,
        "--chat-history-editor-maximum-height": presentation.historyEditorMaximumHeight,
        "--chat-readex-message-font-weight": presentation.chatMessageFontWeight ?? presentation.readexMessageFontWeight,
        "--chat-search-highlight-range": presentation.searchHighlightRange,
        "--chat-search-active-highlight-range": presentation.searchActiveHighlightRange
      };

      const unitlessNumericKeys = new Set([
        "--chat-page-zoom-factor",
        "--chat-fixed-scale",
        "--chat-container-relative-growth-reserve-ratio",
        "--chat-assistant-action-size-scale",
        "--chat-user-action-size-scale",
        "--chat-assistant-action-highlight-width-scale",
        "--chat-assistant-action-highlight-height-scale",
        "--chat-user-action-highlight-width-scale",
        "--chat-user-action-highlight-height-scale",
        "--chat-readex-message-font-weight"
      ]);

      Object.entries(numericMappings).forEach(([key, value]) => {
        const numericValue = Number(value);
        if (Number.isFinite(numericValue)) {
          root.style.setProperty(key, `${numericValue}${unitlessNumericKeys.has(key) ? "" : "px"}`);
        }
      });

      const stringMappings = {
        "--chat-toolbar-hover-fill": presentation.toolbarHoverFill,
        "--chat-control-bg": presentation.controlBackground,
        "--chat-tooltip-border": presentation.tooltipBorder,
        "--chat-history-editor-top": presentation.historyEditorTopColor,
        "--chat-history-editor-bottom": presentation.historyEditorBottomColor,
        "--chat-history-editor-stroke": presentation.historyEditorStroke,
        "--chat-history-editor-shadow": presentation.historyEditorShadow,
        "--chat-assistant-bubble-bg": presentation.assistantBubbleBackgroundColor,
        "--chat-user-bubble-bg": presentation.userBubbleBackgroundColor,
        "--chat-search-highlight-color": presentation.searchHighlightColor,
        "--chat-search-active-highlight-color": presentation.searchActiveHighlightColor,
        "--chat-search-active-highlight-ring-color": presentation.searchActiveHighlightRingColor,
        "--chat-search-active-highlight-text-color": presentation.searchActiveHighlightTextColor,
        "--chat-explanation-anchor-bg": presentation.explanationAnchorBackgroundColor,
        "--chat-explanation-anchor-container-bg": presentation.explanationAnchorContainerBackgroundColor,
        "--chat-explanation-anchor-decoration": presentation.explanationAnchorDecorationColor,
        "--chat-explanation-anchor-active-bg": presentation.explanationAnchorActiveBackgroundColor,
        "--chat-explanation-anchor-active-container-bg": presentation.explanationAnchorActiveContainerBackgroundColor,
        "--chat-explanation-anchor-active-decoration": presentation.explanationAnchorActiveDecorationColor,
        "--chat-explanation-anchor-active-ring": presentation.explanationAnchorActiveRingColor
      };

      Object.entries(stringMappings).forEach(([key, value]) => {
        if (typeof value === "string" && value.trim()) {
          root.style.setProperty(key, value);
        }
      });

      root.toggleAttribute("data-assistant-bubble-background-visible", Boolean(presentation.showsAssistantBubbleBackground));
      root.toggleAttribute("data-user-bubble-background-visible", Boolean(presentation.showsUserBubbleBackground));
      root.toggleAttribute("data-container-relative-message-layout", Boolean(presentation.usesContainerRelativeMessageLayout));
    }

    return Object.freeze({
      applyConversationPresentationStyle,
      applyPayloadStyle,
      applyHighlightTheme
    });
  };
})();
