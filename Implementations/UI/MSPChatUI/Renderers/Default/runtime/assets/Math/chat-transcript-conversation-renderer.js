(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript conversation renderer dependency: ${name}`);
    }
    return value;
  }

  function requiredObject(dependencies, name) {
    const value = dependencies?.[name];
    if (!value || typeof value !== "object") {
      throw new Error(`Missing ChatTranscript conversation renderer dependency: ${name}`);
    }
    return value;
  }

  function optionalFunction(dependencies, name) {
    const value = dependencies?.[name];
    return typeof value === "function" ? value : function () {};
  }

  window.ChatTranscriptConversationRendererFactory = function createChatTranscriptConversationRenderer(dependencies) {
    const rendererComponents = requiredObject(dependencies, "rendererComponents");
    const Message = requiredObject(rendererComponents, "Message");
    const configureMessageGroupShell = requiredFunction(dependencies, "configureMessageGroupShell");
    const currentConversationDocumentHeight = requiredFunction(dependencies, "currentConversationDocumentHeight");
    const transcriptDisplayMessages = requiredFunction(dependencies, "transcriptDisplayMessages");
    const groupedConversationMessages = requiredFunction(dependencies, "groupedConversationMessages");
    const renderBranchNotice = requiredFunction(dependencies, "renderBranchNotice");
    const patchBranchNotice = requiredFunction(dependencies, "patchBranchNotice");
    const afterMessagesUpdated = optionalFunction(dependencies, "afterMessagesUpdated");
    const postPresentationProbe = optionalFunction(dependencies, "postPresentationProbe");

    function trimmed(value) {
      return String(value || "").trim();
    }

    function domProbeMessagePayload(message, key = "") {
      return {
        messageID: trimmed(message?.messageID || message?.id),
        messageKey: trimmed(key || message?.patchKey || message?.id),
        patchKey: trimmed(message?.patchKey),
        readexTurnID: trimmed(message?.readexTurnID || message?.readexTurnId),
        role: trimmed(message?.role),
        status: trimmed(message?.status || message?.effectiveStatus || message?.messageStatus)
      };
    }

    function postDOMReconcileProbe(event, payload = {}) {
      postPresentationProbe({
        kind: "dom_reconcile_probe",
        event,
        source: "conversation_renderer",
        ...payload
      });
    }

    function groupProbePayload(group, groupElement = null) {
      return {
        groupKey: trimmed(group?.key || groupElement?.dataset?.groupKey),
        groupRole: trimmed(group?.role || groupElement?.dataset?.groupRole),
        itemCount: Array.isArray(group?.items) ? group.items.length : 0,
        existingArticleCount: groupElement?.querySelectorAll?.("article.message")?.length || 0
      };
    }

    function syncReadexProcessingFoldMessageGroupShell(groupElement) {
      const controller = window.ChatTranscriptReadexProcessingFoldController;
      if (controller && typeof controller.syncMessageGroup === "function") {
        controller.syncMessageGroup(groupElement);
      }
    }

    function childReconcileKey(child) {
      if (!child || !child.dataset) {
        return "";
      }
      return child.dataset.messageKey || child.dataset.branchNoticeKey || child.dataset.messageId || "";
    }

    function normalizedBranchNoticeText(message) {
      return typeof message?.branchNoticeText === "string" ? message.branchNoticeText.trim() : "";
    }

    function branchNoticeKey(messageKey) {
      return `${messageKey}::branch-notice`;
    }

    function markLastAssistantMessage(groups) {
      let lastAssistantEntry = null;
      groups.forEach((group) => {
        (group.items || []).forEach((entry) => {
          if (entry?.message) {
            entry.message.__chatTranscriptIsLastAssistantMessage = false;
          }
          if (entry?.message?.role === "assistant") {
            lastAssistantEntry = entry;
          }
        });
      });
      if (lastAssistantEntry?.message) {
        lastAssistantEntry.message.__chatTranscriptIsLastAssistantMessage = true;
      }
    }

    function syncLastAssistantArticleClasses(messagesRoot, groups) {
      let lastAssistantKey = "";
      groups.forEach((group) => {
        (group.items || []).forEach((entry) => {
          if (entry?.message?.role === "assistant") {
            lastAssistantKey = entry.key || "";
          }
        });
      });
      Array.from(messagesRoot.querySelectorAll?.(".message.assistant") || []).forEach((article) => {
        article.classList.toggle(
          "is-last-assistant-message",
          Boolean(lastAssistantKey) && article.dataset.messageKey === lastAssistantKey
        );
      });
    }

    function reconcileMessageArticles(groupElement, group, renderer, changedMessageKeys = null, forcePatchAll = false) {
      if (!groupElement || !group) {
        return null;
      }

      configureMessageGroupShell(groupElement, group);
      const existingByKey = new Map(
        Array.from(groupElement.children || [])
          .map((child) => [childReconcileKey(child), child])
          .filter(([key]) => Boolean(key))
      );
      let cursor = groupElement.firstChild;

      group.items.forEach((entry) => {
        const nextSignature = Message.signature(entry.message);
        let article = existingByKey.get(entry.key) || null;
        let articleAction = "preserved_unchanged";
        let fallbackReason = "";

        if (!article) {
          article = Message.render(entry.message, renderer, entry.key);
          articleAction = "render_missing";
        } else if (
          forcePatchAll ||
          !article.__chatTranscriptSignature ||
          !changedMessageKeys ||
          changedMessageKeys.has(entry.key)
        ) {
          const previousArticle = article;
          const patchedArticle = Message.patch(article, entry.message, renderer, entry.key);
          if (patchedArticle) {
            article = patchedArticle;
            articleAction = article === previousArticle ? "patch_preserved" : "patch_replaced";
          } else {
            article = Message.render(entry.message, renderer, entry.key);
            articleAction = "patch_fallback_render";
            fallbackReason = "message_patch_returned_null";
          }
        }

        article.__chatTranscriptSignature = nextSignature;
        if (article !== cursor) {
          postDOMReconcileProbe("article_move", {
            ...groupProbePayload(group, groupElement),
            ...domProbeMessagePayload(entry.message, entry.key),
            action: articleAction,
            fallbackReason,
            forcePatchAll,
            hadExistingArticle: Boolean(existingByKey.get(entry.key))
          });
          groupElement.insertBefore(article, cursor);
        }
        postDOMReconcileProbe("article_reconcile", {
          ...groupProbePayload(group, groupElement),
          ...domProbeMessagePayload(entry.message, entry.key),
          action: articleAction,
          fallbackReason,
          forcePatchAll,
          changedMessage: changedMessageKeys instanceof Set ? changedMessageKeys.has(entry.key) : true,
          hadSignature: Boolean(article.__chatTranscriptSignature)
        });
        cursor = article.nextSibling;
        existingByKey.delete(entry.key);

        const noticeText = normalizedBranchNoticeText(entry.message);
        const noticeKey = branchNoticeKey(entry.key);
        if (noticeText) {
          let notice = existingByKey.get(noticeKey) || null;
          notice = patchBranchNotice(notice, noticeKey, noticeText);
          if (notice !== cursor) {
            groupElement.insertBefore(notice, cursor);
          }
          cursor = notice.nextSibling;
          existingByKey.delete(noticeKey);
        } else {
          const staleNotice = existingByKey.get(noticeKey);
          if (staleNotice) {
            if (cursor === staleNotice) {
              cursor = staleNotice.nextSibling;
            }
            staleNotice.remove();
            existingByKey.delete(noticeKey);
          }
        }
      });

      while (cursor) {
        const next = cursor.nextSibling;
        postDOMReconcileProbe("article_remove_stale", {
          ...groupProbePayload(group, groupElement),
          staleKey: childReconcileKey(cursor),
          staleRole: trimmed(cursor?.dataset?.messageRole),
          staleMessageID: trimmed(cursor?.dataset?.messageId),
          staleMessageKey: trimmed(cursor?.dataset?.messageKey)
        });
        cursor.remove();
        cursor = next;
      }

      return groupElement;
    }

    function renderMessageGroup(group, renderer) {
      const groupElement = document.createElement("section");
      return reconcileMessageArticles(groupElement, group, renderer, null, true);
    }

    function patchMessageGroup(groupElement, group, renderer, changedMessageKeys) {
      if (!groupElement) {
        return null;
      }
      return reconcileMessageArticles(groupElement, group, renderer, changedMessageKeys, false);
    }

    const MessageGroup = Object.freeze({
      render: renderMessageGroup,
      patch: patchMessageGroup,
      reconcileArticles: reconcileMessageArticles
    });

    function groupHasChangedMessage(group, changedMessageKeys) {
      if (!group || !(changedMessageKeys instanceof Set) || !changedMessageKeys.size) {
        return false;
      }
      return (Array.isArray(group.items) ? group.items : []).some((entry) => changedMessageKeys.has(entry?.key));
    }

    function runAfterMessagesUpdated(reason, messagesRoot, displayMessages, groups, patchState = null) {
      afterMessagesUpdated({
        reason,
        messagesRoot,
        messages: displayMessages,
        groups,
        ...(patchState ? { patchState } : {})
      });
      syncLastAssistantArticleClasses(messagesRoot, groups);
    }

    function reconcileMessagesDirect(messagesRoot, displayMessages, groups, renderer) {
      const existingByKey = new Map(
        Array.from(messagesRoot.children || [])
          .map((child) => [child.dataset.groupKey || "", child])
      );
      let cursor = messagesRoot.firstChild;

      groups.forEach((group) => {
        let groupElement = existingByKey.get(group.key) || null;
        if (!groupElement) {
          groupElement = MessageGroup.render(group, renderer);
          postDOMReconcileProbe("group_reconcile_render_missing", {
            ...groupProbePayload(group, groupElement),
            reason: "missing_existing"
          });
        } else {
          const previousGroupElement = groupElement;
          const patchedGroupElement = MessageGroup.reconcileArticles(groupElement, group, renderer, null, true);
          if (patchedGroupElement) {
            groupElement = patchedGroupElement;
            postDOMReconcileProbe("group_reconcile_preserved", {
              ...groupProbePayload(group, groupElement),
              replacedGroup: groupElement !== previousGroupElement
            });
          } else {
            groupElement = MessageGroup.render(group, renderer);
            postDOMReconcileProbe("group_reconcile_fallback_render", {
              ...groupProbePayload(group, groupElement),
              reason: "reconcile_articles_returned_null"
            });
          }
        }

        if (groupElement !== cursor) {
          postDOMReconcileProbe("group_move", {
            ...groupProbePayload(group, groupElement),
            reason: "reconcile"
          });
          messagesRoot.insertBefore(groupElement, cursor);
        }
        syncReadexProcessingFoldMessageGroupShell(groupElement);
        cursor = groupElement.nextSibling;
        existingByKey.delete(group.key);
      });

      while (cursor) {
        const next = cursor.nextSibling;
        postDOMReconcileProbe("group_remove_stale", {
          groupKey: trimmed(cursor?.dataset?.groupKey),
          groupRole: trimmed(cursor?.dataset?.groupRole),
          reason: "reconcile"
        });
        cursor.remove();
        cursor = next;
      }

      runAfterMessagesUpdated("reconcile", messagesRoot, displayMessages, groups);
    }

    function reconcileMessages(messagesRoot, messages, renderer) {
      const displayMessages = transcriptDisplayMessages(messages);
      const groups = groupedConversationMessages(displayMessages);
      markLastAssistantMessage(groups);
      reconcileMessagesDirect(messagesRoot, displayMessages, groups, renderer);
      return currentConversationDocumentHeight();
    }

    function applyMessagePatchDirect(messagesRoot, patchState, renderer, displayMessages, groups) {
      const existingByKey = new Map(
        Array.from(messagesRoot.children || [])
          .map((child) => [child.dataset.groupKey || "", child])
      );
      let cursor = messagesRoot.firstChild;

      groups.forEach((group) => {
        let groupElement = existingByKey.get(group.key) || null;
        if (!groupElement) {
          groupElement = MessageGroup.render(group, renderer);
          postDOMReconcileProbe("group_patch_render_missing", {
            ...groupProbePayload(group, groupElement),
            reason: "missing_existing"
          });
        } else if (
          !patchState.changedGroupKeys ||
          patchState.changedGroupKeys.has(group.key) ||
          groupHasChangedMessage(group, patchState.changedMessageKeys)
        ) {
          const previousGroupElement = groupElement;
          const patchedGroupElement = MessageGroup.patch(groupElement, group, renderer, patchState.changedMessageKeys);
          if (patchedGroupElement) {
            groupElement = patchedGroupElement;
            postDOMReconcileProbe("group_patch_preserved", {
              ...groupProbePayload(group, groupElement),
              changedGroup: patchState.changedGroupKeys instanceof Set ? patchState.changedGroupKeys.has(group.key) : true,
              hasChangedMessage: groupHasChangedMessage(group, patchState.changedMessageKeys),
              replacedGroup: groupElement !== previousGroupElement
            });
          } else {
            groupElement = MessageGroup.render(group, renderer);
            postDOMReconcileProbe("group_patch_fallback_render", {
              ...groupProbePayload(group, groupElement),
              reason: "message_group_patch_returned_null"
            });
          }
        } else {
          configureMessageGroupShell(groupElement, group);
          postDOMReconcileProbe("group_patch_shell_only", {
            ...groupProbePayload(group, groupElement)
          });
        }

        if (groupElement !== cursor) {
          postDOMReconcileProbe("group_move", {
            ...groupProbePayload(group, groupElement),
            reason: "patch"
          });
          messagesRoot.insertBefore(groupElement, cursor);
        }
        syncReadexProcessingFoldMessageGroupShell(groupElement);
        cursor = groupElement.nextSibling;
        existingByKey.delete(group.key);
      });

      existingByKey.forEach((groupElement) => {
        postDOMReconcileProbe("group_remove_stale", {
          groupKey: trimmed(groupElement?.dataset?.groupKey),
          groupRole: trimmed(groupElement?.dataset?.groupRole),
          reason: "patch"
        });
        groupElement.remove();
      });
      runAfterMessagesUpdated("patch", messagesRoot, displayMessages, groups, patchState);
      return currentConversationDocumentHeight();
    }

    function applyMessagePatch(messagesRoot, patchState, renderer) {
      if (!messagesRoot || !patchState) {
        return currentConversationDocumentHeight();
      }

      const orderedMessages = patchState.orderedMessageKeys
        .map((key) => patchState.messageByKey.get(key))
        .filter(Boolean);
      const displayMessages = transcriptDisplayMessages(orderedMessages);
      const groups = groupedConversationMessages(displayMessages);
      markLastAssistantMessage(groups);
      return applyMessagePatchDirect(messagesRoot, patchState, renderer, displayMessages, groups);
    }

    return Object.freeze({
      MessageGroup,
      reconcile: reconcileMessages,
      applyPatch: applyMessagePatch,
      computeDisplayMessages: requiredFunction(dependencies, "computeTranscriptDisplayMessages"),
      displayMessages: transcriptDisplayMessages,
      groupedMessages: groupedConversationMessages
    });
  };
})();
