(function () {
  function requiredFunction(dependencies, name) {
    const value = dependencies?.[name];
    if (typeof value !== "function") {
      throw new Error(`Missing ChatTranscript conversation layout dependency: ${name}`);
    }
    return value;
  }

  window.ChatTranscriptConversationLayoutFactory = function createChatTranscriptConversationLayout(dependencies) {
    const trimmed = requiredFunction(dependencies, "trimmed");
    const messageDOMKey = requiredFunction(dependencies, "messageDOMKey");

    function normalizedMessageRole(value) {
      const role = trimmed(value);
      if (role === "assistant" || role === "steered") {
        return role;
      }
      return "user";
    }

    function normalizeDisplayWindow(rawWindow) {
      if (!rawWindow || typeof rawWindow !== "object") {
        return null;
      }

      const displayCount = Number(rawWindow.displayCount ?? rawWindow.count ?? rawWindow.limit);
      if (!Number.isFinite(displayCount) || displayCount <= 0) {
        return null;
      }

      const startIndex = Number(rawWindow.startIndex ?? rawWindow.offset ?? 0);
      return {
        startIndex: Number.isFinite(startIndex) ? Math.max(0, Math.floor(startIndex)) : 0,
        displayCount: Math.max(1, Math.floor(displayCount))
      };
    }

    function messageGroupKey(message, index) {
      const role = normalizedMessageRole(message?.role);
      const replyToMessageID = trimmed(message?.replyToMessageID);
      if (role === "assistant" && replyToMessageID) {
        return `assistant:${replyToMessageID}`;
      }

      const messageID = trimmed(message?.id);
      if (role === "assistant") {
        return `assistant:${messageID || index}`;
      }
      if (role === "steered") {
        return `steered:${messageID || index}`;
      }
      return `user:${messageID || index}`;
    }

    function buildDerivedConversationGroups(messages) {
      const groups = [];
      const groupByKey = new Map();

      (Array.isArray(messages) ? messages : []).forEach((message, index) => {
        const groupKey = messageGroupKey(message, index);
        let group = groupByKey.get(groupKey);
        if (!group) {
          group = {
            key: groupKey,
            role: normalizedMessageRole(message?.role),
            replyToMessageID: trimmed(message?.replyToMessageID),
            items: []
          };
          groupByKey.set(groupKey, group);
          groups.push(group);
        }

        group.items.push({
          key: messageDOMKey(message, index),
          message
        });
      });

      return groups;
    }

    function payloadConversationGroups(messages, rawGroups) {
      const catalog = Array.isArray(rawGroups) ? rawGroups : [];
      if (!catalog.length) {
        return null;
      }

      const messageByID = new Map();
      const orderedMessages = Array.isArray(messages) ? messages : [];
      orderedMessages.forEach((message, index) => {
        const messageID = trimmed(message?.id);
        if (!messageID || messageByID.has(messageID)) {
          return;
        }
        messageByID.set(messageID, {
          index,
          message
        });
      });

      const groups = [];
      const consumedMessageIDs = new Set();

      catalog.forEach((group) => {
        const groupID = trimmed(group?.id);
        const messageIDs = Array.isArray(group?.messageIDs)
          ? group.messageIDs.filter((messageID) => typeof messageID === "string" && messageID.trim().length > 0)
          : [];
        if (!groupID || !messageIDs.length) {
          return;
        }

        const items = messageIDs
          .map((messageID) => {
            const entry = messageByID.get(messageID);
            if (!entry) {
              return null;
            }
            consumedMessageIDs.add(messageID);
            return {
              key: messageDOMKey(entry.message, entry.index),
              message: entry.message
            };
          })
          .filter(Boolean);

        if (!items.length) {
          return;
        }

        groups.push({
          key: groupID,
          role: normalizedMessageRole(group?.role),
          replyToMessageID: trimmed(group?.replyToMessageID),
          items
        });
      });

      if (consumedMessageIDs.size !== messageByID.size) {
        return null;
      }

      return groups;
    }

    function computeDisplayMessages(messages, displayWindow) {
      const orderedMessages = Array.isArray(messages) ? messages : [];
      if (!displayWindow) {
        return orderedMessages;
      }

      const displayMessages = [];
      const groupKeysByRole = {
        assistant: new Set(),
        steered: new Set(),
        user: new Set()
      };
      const groupLimit = Math.max(1, displayWindow.displayCount);
      const initialIndex = Math.min(
        Math.max(orderedMessages.length - 1 - displayWindow.startIndex, -1),
        orderedMessages.length - 1
      );

      function includedGroupCount() {
        return groupKeysByRole.assistant.size + groupKeysByRole.steered.size + groupKeysByRole.user.size;
      }

      function displayWindowGroupKey(message, index) {
        const fallbackKey = messageDOMKey(message, index);
        const role = normalizedMessageRole(message?.role);
        if (role === "assistant") {
          return trimmed(message.replyToMessageID) ||
            trimmed(message.askId) ||
            trimmed(message.askID) ||
            trimmed(message.requestId) ||
            fallbackKey;
        }
        if (role === "steered") {
          return trimmed(message?.id) || trimmed(message?.patchKey) || fallbackKey;
        }
        return trimmed(message?.id) || trimmed(message?.patchKey) || fallbackKey;
      }

      function includeMessage(message, index) {
        if (!message) {
          return;
        }
        const role = normalizedMessageRole(message.role);
        const keySet = groupKeysByRole[role] || groupKeysByRole.user;
        const groupKey = displayWindowGroupKey(message, index);
        if (!keySet.has(groupKey)) {
          keySet.add(groupKey);
          displayMessages.push(message);
          return;
        }
        if (role === "assistant") {
          displayMessages.push(message);
        }
      }

      for (
        let index = initialIndex;
        index >= 0 && includedGroupCount() < groupLimit;
        index -= 1
      ) {
        includeMessage(orderedMessages[index], index);
      }

      return displayMessages.reverse();
    }

    function displayWindowFromPayload(payload, fallbackDisplayWindow = window.__chatTranscriptDisplayWindow) {
      const rawWindow = payload && Object.prototype.hasOwnProperty.call(payload, "displayWindow")
        ? payload.displayWindow
        : fallbackDisplayWindow;
      return normalizeDisplayWindow(rawWindow);
    }

    function displayMessages(messages, payload, fallbackDisplayWindow = window.__chatTranscriptDisplayWindow) {
      return computeDisplayMessages(
        messages,
        displayWindowFromPayload(payload, fallbackDisplayWindow)
      );
    }

    function groupedMessages(messages, rawGroups) {
      return payloadConversationGroups(messages, rawGroups) || buildDerivedConversationGroups(messages);
    }

    return Object.freeze({
      normalizeDisplayWindow,
      buildDerivedConversationGroups,
      payloadConversationGroups,
      computeDisplayMessages,
      displayWindowFromPayload,
      displayMessages,
      groupedMessages
    });
  };
})();
