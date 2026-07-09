(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript message article renderer dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript message article renderer dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptMessageArticleRendererFactory = function createChatTranscriptMessageArticleRenderer(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const effectiveMessageStatus = requiredFunction(dependencies, "effectiveMessageStatus");
    const messageRenderSignature = requiredFunction(dependencies, "messageRenderSignature");
    const headerSignature = requiredFunction(dependencies, "headerSignature");
    const renderMessageHeader = requiredFunction(dependencies, "renderMessageHeader");
    const isInteractiveTranscript = requiredFunction(dependencies, "isInteractiveTranscript");
    const transcriptUIState = requiredFunction(dependencies, "transcriptUIState");
    const renderUserEditor = requiredFunction(dependencies, "renderUserEditor");
    const renderUserEditFooter = requiredFunction(dependencies, "renderUserEditFooter");
    const canShowUserToolbar = requiredFunction(dependencies, "canShowUserToolbar");
    const renderAssistantActions = requiredFunction(dependencies, "renderAssistantActions");
    const renderMemoryCitationStrip = requiredFunction(dependencies, "renderMemoryCitationStrip");
    const patchMemoryCitationStrip = requiredFunction(dependencies, "patchMemoryCitationStrip");
    const renderUserActions = requiredFunction(dependencies, "renderUserActions");
    const patchReadexAssistantFooterActions = requiredFunction(dependencies, "patchReadexAssistantFooterActions");
    const postPresentationProbe = requiredFunction(dependencies, "postPresentationProbe");
    const attachMessageInteractions = requiredFunction(dependencies, "attachMessageInteractions");
    const directChildByClass = requiredFunction(dependencies, "directChildByClass");
    const replaceElementIfSignatureChanged = requiredFunction(dependencies, "replaceElementIfSignatureChanged");
    const currentMessageForArticle = requiredFunction(dependencies, "currentMessageForArticle");
    const messageContent = requiredObject(dependencies, "messageContent");
    const renderBlocks = requiredFunction(messageContent, "renderBlocks");
    const reconcileBlocks = requiredFunction(messageContent, "reconcileBlocks");
    const reconcileStoppedBoundary = requiredFunction(messageContent, "reconcileStoppedBoundary");
    const readexAssistantFooterActionProbeEvents = Object.freeze({
      reconcileBegin: { event: "reconcile_begin" },
      reconcilePreserved: { event: "reconcile_preserved" },
      reconcileFallbackReplace: { event: "reconcile_fallback_replace" }
    });

    function normalizedMessageRole(value) {
      const role = trimmed(value);
      if (role === "assistant" || role === "steered") {
        return role;
      }
      return "user";
    }

    function isSteeredConversationMessage(message) {
      return normalizedMessageRole(message?.role) === "steered";
    }

    function readexAssistantFooterActionProbeMessage(message) {
      return {
        messageID: trimmed(message?.messageID || message?.id),
        role: normalizedMessageRole(message?.role),
        patchKey: trimmed(message?.patchKey),
        readexTurnID: trimmed(message?.readexTurnID || message?.readexTurnId),
        isLastAssistant: Boolean(message?.__chatTranscriptIsLastAssistantMessage)
      };
    }

    function isReadexAssistantFooterActionsElement(element) {
      return Boolean(
        element?.classList?.contains("readex-assistant-footer-surface") ||
        element?.classList?.contains("readex-assistant-footer-actions")
      );
    }

    function messageActionsProbeKind(element) {
      if (!element) {
        return "none";
      }
      if (element?.classList?.contains("readex-assistant-footer-surface")) {
        return "readex_footer_surface";
      }
      if (element?.classList?.contains("readex-assistant-footer-actions")) {
        return "readex_footer_actions";
      }
      if (element?.classList?.contains("message-actions")) {
        return "message_actions";
      }
      return "unknown";
    }

    function messageActionsProbePayload(element) {
      if (!(element instanceof HTMLElement)) {
        return {
          kind: messageActionsProbeKind(element),
          connected: false,
          className: "",
          actionCount: 0,
          actions: ""
        };
      }
      const actions = Array.from(element.querySelectorAll(".message-action-button"))
        .map((button) => trimmed(button?.dataset?.action))
        .filter(Boolean);
      return {
        kind: messageActionsProbeKind(element),
        connected: element.isConnected === true,
        className: typeof element.className === "string" ? element.className : "",
        actionCount: actions.length,
        actions: actions.join(",")
      };
    }

    function shouldProbeReadexAssistantFooterActions(existingActions, nextActions) {
      return isReadexAssistantFooterActionsElement(existingActions) ||
        isReadexAssistantFooterActionsElement(nextActions);
    }

      function postReadexAssistantFooterActionProbe(event, message, extra = {}) {
        postPresentationProbe({
          kind: "readex_assistant_footer_action_probe",
          event,
          source: "message_article_renderer",
          ...readexAssistantFooterActionProbeMessage(message),
          ...extra
        });
      }

      function postArticleDOMReconcileProbe(event, message, extra = {}) {
        postPresentationProbe({
          kind: "dom_reconcile_probe",
          event,
          source: "message_article_renderer",
          ...readexAssistantFooterActionProbeMessage(message),
          ...extra
        });
      }

    function configureMessageGroupShell(groupElement, group) {
      groupElement.className = "message-group";
      groupElement.dataset.groupKey = group.key;
      groupElement.dataset.groupRole = normalizedMessageRole(group.role);
    }

    function configureMessageArticleShell(article, message, key) {
      const role = normalizedMessageRole(message.role);
      article.className = `message ${role}`;
      article.dataset.messageKey = key;
      article.dataset.messageRole = role;
      article.dataset.messageStatus = effectiveMessageStatus(message);
      article.classList.toggle(
        "is-last-assistant-message",
        role === "assistant" && message?.__chatTranscriptIsLastAssistantMessage === true
      );
      const foldGroupID = trimmed(message.readexProcessingFoldGroupId || message.readexProcessingFoldGroupID);
      if (foldGroupID) {
        article.dataset.readexProcessingFoldGroupId = foldGroupID;
        article.classList.add("readex-processing-fold-target");
        const controller = window.ChatTranscriptReadexProcessingFoldController;
        if (controller && typeof controller.syncTarget === "function") {
          controller.syncTarget(article);
        }
      } else {
        delete article.dataset.readexProcessingFoldGroupId;
        article.classList.remove("readex-processing-fold-target");
        article.classList.remove("is-readex-processing-fold-collapsed");
      }
      if (trimmed(message.id)) {
        article.dataset.messageId = trimmed(message.id);
      } else {
        delete article.dataset.messageId;
      }
    }

    function isMessageActionsElement(element) {
      return Boolean(
        element?.classList?.contains("message-actions") ||
        isReadexAssistantFooterActionsElement(element)
      );
    }

    function removeMessageActionsChildren(container) {
      Array.from(container?.children || []).forEach((child) => {
        if (isMessageActionsElement(child)) {
          child.remove();
        }
      });
    }

    function renderMessageActions(message) {
      if (isSteeredConversationMessage(message)) {
        return null;
      }

      return message.role === "assistant"
        ? renderAssistantActions(message)
        : renderUserActions(message);
    }

    function messageActionsMount(bubble, actions) {
      if (isReadexAssistantFooterActionsElement(actions)) {
        return directChildByClass(bubble, "message-layout") || bubble;
      }
      return bubble;
    }

    function replaceMessageActions(bubble, message, options = {}) {
      if (options?.preserveReadexFooter === true) {
        reconcileMessageActions(bubble, message);
        return;
      }
      const layout = directChildByClass(bubble, "message-layout");
      removeMessageActionsChildren(bubble);
      removeMessageActionsChildren(layout);

      const actions = renderMessageActions(message);
      if (actions) {
        messageActionsMount(bubble, actions).appendChild(actions);
      }
    }

    function existingMessageActions(bubble) {
      const layout = directChildByClass(bubble, "message-layout");
      return directChildByClass(layout, "readex-assistant-footer-surface") ||
        directChildByClass(layout, "readex-assistant-footer-actions") ||
        directChildByClass(bubble, "message-actions") ||
        null;
    }

    function reconcileMessageActions(bubble, message) {
      const existingActions = existingMessageActions(bubble);
      const nextActions = renderMessageActions(message);
      const shouldProbe = shouldProbeReadexAssistantFooterActions(existingActions, nextActions);

      if (shouldProbe) {
        postReadexAssistantFooterActionProbe(
          readexAssistantFooterActionProbeEvents.reconcileBegin.event,
          message,
          {
            existingActions: messageActionsProbePayload(existingActions),
            nextActions: messageActionsProbePayload(nextActions)
          }
        );
      }

      if (!existingActions) {
        if (nextActions) {
          messageActionsMount(bubble, nextActions).appendChild(nextActions);
        }
        if (shouldProbe) {
          postReadexAssistantFooterActionProbe(
            readexAssistantFooterActionProbeEvents.reconcileFallbackReplace.event,
            message,
            {
              reason: nextActions ? "missing_existing" : "missing_existing_and_next",
              existingActions: messageActionsProbePayload(existingActions),
              nextActions: messageActionsProbePayload(nextActions)
            }
          );
        }
        return;
      }

      if (!nextActions) {
        if (shouldProbe) {
          postReadexAssistantFooterActionProbe(
            readexAssistantFooterActionProbeEvents.reconcileFallbackReplace.event,
            message,
            {
              reason: "missing_next",
              existingActions: messageActionsProbePayload(existingActions),
              nextActions: messageActionsProbePayload(nextActions)
            }
          );
        }
        existingActions.remove();
        return;
      }

      if (patchReadexAssistantFooterActions(existingActions, nextActions)) {
        if (shouldProbe) {
          postReadexAssistantFooterActionProbe(
            readexAssistantFooterActionProbeEvents.reconcilePreserved.event,
            message,
            {
              existingActions: messageActionsProbePayload(existingActions),
              nextActions: messageActionsProbePayload(nextActions)
            }
          );
        }
        return;
      }

      if (shouldProbe) {
        postReadexAssistantFooterActionProbe(
          readexAssistantFooterActionProbeEvents.reconcileFallbackReplace.event,
          message,
          {
            reason: "patch_rejected",
            existingActions: messageActionsProbePayload(existingActions),
            nextActions: messageActionsProbePayload(nextActions)
          }
        );
      }
      existingActions.remove();
      messageActionsMount(bubble, nextActions).appendChild(nextActions);
    }

    function existingMemoryCitationStrip(layout) {
      return directChildByClass(layout, "readex-memory-citation-strip");
    }

    function insertMemoryCitationStrip(layout, strip) {
      if (!(strip instanceof HTMLElement) || strip.parentNode === layout) {
        return;
      }
      const footer = directChildByClass(layout, "readex-assistant-footer-surface") ||
        directChildByClass(layout, "readex-assistant-footer-actions");
      if (footer) {
        layout.insertBefore(strip, footer);
      } else {
        layout.appendChild(strip);
      }
    }

    function syncMemoryCitationStrip(layout, message) {
      const strip = patchMemoryCitationStrip(existingMemoryCitationStrip(layout), message);
      insertMemoryCitationStrip(layout, strip);
    }

    function syncUserEditFooter(article, message) {
      const existingFooter = directChildByClass(article, "message-edit-footer");
      const isEditingUserMessage =
        Boolean(isInteractiveTranscript()) &&
        message.role === "user" &&
        transcriptUIState().editingMessageId === message.id;

      if (!isEditingUserMessage) {
        if (existingFooter) {
          existingFooter.remove();
        }
        return;
      }

      const footer = renderUserEditFooter(message);
      if (existingFooter) {
        existingFooter.replaceWith(footer);
      } else {
        article.appendChild(footer);
      }
    }

    function syncArticleToolbarVisibility(article, message) {
      if (!article) {
        return null;
      }

      if (
        message.role === "user" &&
        canShowUserToolbar(message) &&
        transcriptUIState().visibleUserToolbarMessageIDs[message.id]
      ) {
        article.classList.add("actions-visible");
      } else {
        article.classList.remove("actions-visible");
      }

      return article;
    }

      function renderMessageArticle(message, renderer, key) {
        postArticleDOMReconcileProbe("article_render", message, {
          messageKey: trimmed(key),
          renderReason: "direct_render"
        });
        if (isSteeredConversationMessage(message)) {
          return renderSteeredConversationArticle(message, key);
        }

      const article = document.createElement("article");
      configureMessageArticleShell(article, message, key);
      article.__chatTranscriptMessage = message;

      const bubble = document.createElement("div");
      bubble.className = "message-bubble";

      const layout = document.createElement("div");
      layout.className = "message-layout";

      const header = renderMessageHeader(message);
      header.__chatTranscriptSignature = headerSignature(message);
      layout.appendChild(header);

      const main = document.createElement("div");
      main.className = "message-main";

      const isEditingUserMessage =
        Boolean(isInteractiveTranscript()) &&
        message.role === "user" &&
        transcriptUIState().editingMessageId === message.id;

      if (isEditingUserMessage) {
        main.appendChild(renderUserEditor(message));
      } else {
        renderBlocks(main, message, renderer);
      }

      layout.appendChild(main);
      const memoryCitationStrip = renderMemoryCitationStrip(message);
      if (memoryCitationStrip) {
        layout.appendChild(memoryCitationStrip);
      }
      bubble.appendChild(layout);

      replaceMessageActions(bubble, message, { preserveReadexFooter: false });
      reconcileStoppedBoundary(bubble, message);

      article.appendChild(bubble);

      if (isEditingUserMessage) {
        article.appendChild(renderUserEditFooter(message));
      }

      if (message.role === "user" && canShowUserToolbar(message) && transcriptUIState().visibleUserToolbarMessageIDs[message.id]) {
        article.classList.add("actions-visible");
      }

      attachMessageInteractions(article);
      article.__chatTranscriptSignature = messageRenderSignature(message);
      return article;
    }

    function renderSteeredConversationArticle(message, key) {
      const article = document.createElement("article");
      configureMessageArticleShell(article, message, key);
      article.__chatTranscriptMessage = message;

      const marker = document.createElement("div");
      marker.className = "message-steered-conversation";

      const before = document.createElement("span");
      before.className = "message-steered-conversation-line";
      marker.appendChild(before);

      const label = document.createElement("span");
      label.className = "message-steered-conversation-label";
      label.textContent = trimmed(message.content) || "已引导对话";
      marker.appendChild(label);

      const after = document.createElement("span");
      after.className = "message-steered-conversation-line";
      marker.appendChild(after);

      article.appendChild(marker);
      article.__chatTranscriptSignature = messageRenderSignature(message);
      return article;
    }

      function patchMessageArticle(article, message, renderer, key) {
        if (!article) {
          postArticleDOMReconcileProbe("article_patch_return_null", message, {
            messageKey: trimmed(key),
            reason: "missing_article"
          });
          return null;
        }

        if (isSteeredConversationMessage(message)) {
          if (!article.classList?.contains("steered")) {
            postArticleDOMReconcileProbe("article_patch_return_null", message, {
              messageKey: trimmed(key),
              reason: "steered_shell_mismatch",
              existingClassName: typeof article.className === "string" ? article.className : ""
            });
            return null;
          }
        configureMessageArticleShell(article, message, key);
        article.__chatTranscriptMessage = message;
        const label = article.querySelector(".message-steered-conversation-label");
        if (label instanceof HTMLElement) {
          label.textContent = trimmed(message.content) || "已引导对话";
        }
          article.__chatTranscriptSignature = messageRenderSignature(message);
          postArticleDOMReconcileProbe("article_patch_preserved", message, {
            messageKey: trimmed(key),
            shell: "steered"
          });
          return article;
        }

        if (article.classList?.contains("steered")) {
          postArticleDOMReconcileProbe("article_patch_return_null", message, {
            messageKey: trimmed(key),
            reason: "existing_steered_shell"
          });
          return null;
        }

      configureMessageArticleShell(article, message, key);
      article.__chatTranscriptMessage = message;

      const bubble = directChildByClass(article, "message-bubble");
        const layout = directChildByClass(bubble, "message-layout");
        const main = directChildByClass(layout, "message-main");
        if (!bubble || !layout || !main) {
          postArticleDOMReconcileProbe("article_patch_return_null", message, {
            messageKey: trimmed(key),
            reason: "missing_shell_part",
            hasBubble: Boolean(bubble),
            hasLayout: Boolean(layout),
            hasMain: Boolean(main)
          });
          return null;
        }

      const currentHeader = directChildByClass(layout, "message-header");
      const nextHeaderSignature = headerSignature(message);
      const header = replaceElementIfSignatureChanged(
        currentHeader,
        nextHeaderSignature,
        () => renderMessageHeader(message)
      );
      if (header && header.parentNode !== layout) {
        layout.insertBefore(header, layout.firstChild);
      }

      const isEditingUserMessage =
        Boolean(isInteractiveTranscript()) &&
        message.role === "user" &&
        transcriptUIState().editingMessageId === message.id;

      if (isEditingUserMessage) {
        Array.from(main.children || []).forEach((child) => {
          child.remove();
        });
        main.appendChild(renderUserEditor(message));
      } else {
        reconcileBlocks(main, message, renderer);
      }

      syncMemoryCitationStrip(layout, message);
      reconcileMessageActions(bubble, message);
      reconcileStoppedBoundary(bubble, message);
      syncUserEditFooter(article, message);
        syncArticleToolbarVisibility(article, message);

        article.__chatTranscriptSignature = messageRenderSignature(message);
        postArticleDOMReconcileProbe("article_patch_preserved", message, {
          messageKey: trimmed(key),
          shell: "message",
          headerReplaced: Boolean(header && header.parentNode !== layout),
          editingUserMessage: isEditingUserMessage
        });
        return article;
      }

    function syncMessageArticleChrome(article, message, key) {
      if (!article || !message || article.classList?.contains("steered") || isSteeredConversationMessage(message)) {
        return false;
      }

      configureMessageArticleShell(article, message, key);
      article.__chatTranscriptMessage = message;

      const bubble = directChildByClass(article, "message-bubble");
      const layout = directChildByClass(bubble, "message-layout");
      if (!bubble || !layout) {
        postArticleDOMReconcileProbe("article_chrome_sync_return_false", message, {
          messageKey: trimmed(key),
          reason: "missing_shell_part",
          hasBubble: Boolean(bubble),
          hasLayout: Boolean(layout)
        });
        return false;
      }

      const currentHeader = directChildByClass(layout, "message-header");
      const nextHeaderSignature = headerSignature(message);
      const header = replaceElementIfSignatureChanged(
        currentHeader,
        nextHeaderSignature,
        () => renderMessageHeader(message)
      );
      if (header && header.parentNode !== layout) {
        layout.insertBefore(header, layout.firstChild);
      }

      reconcileMessageActions(bubble, message);
      syncMemoryCitationStrip(layout, message);
      reconcileStoppedBoundary(bubble, message);
      syncUserEditFooter(article, message);
      syncArticleToolbarVisibility(article, message);
      article.__chatTranscriptSignature = messageRenderSignature(message);
      postArticleDOMReconcileProbe("article_chrome_sync_preserved", message, {
        messageKey: trimmed(key),
        headerReplaced: Boolean(header && header.parentNode !== layout)
      });
      return true;
    }

    function refreshPresentationSensitiveMessageUI() {
      Array.from(document.querySelectorAll("article.message")).forEach((article) => {
        if (!(article instanceof HTMLElement)) {
          return;
        }

        const message = currentMessageForArticle(article);
        if (!message) {
          return;
        }

        const bubble = directChildByClass(article, "message-bubble");
        if (!bubble) {
          return;
        }

        reconcileMessageActions(bubble, message);
        const layout = directChildByClass(bubble, "message-layout");
        if (layout) {
          syncMemoryCitationStrip(layout, message);
        }
        reconcileStoppedBoundary(bubble, message);
        syncUserEditFooter(article, message);
        syncArticleToolbarVisibility(article, message);
        article.__chatTranscriptSignature = messageRenderSignature(message);
      });
    }

    return Object.freeze({
      configureMessageGroupShell,
      configureMessageArticleShell,
      renderMessageArticle,
      patchMessageArticle,
      syncMessageArticleChrome,
      refreshPresentationSensitiveMessageUI
    });
  };
})();
