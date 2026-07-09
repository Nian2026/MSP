(function () {
  window.ChatTranscriptHostBridgeFactory = function createChatTranscriptHostBridge() {
    function transcriptPresentation() {
      return window.__chatTranscriptPresentation || null;
    }

    function hasMessageActionHandler() {
      const nativeHandler = window.webkit?.messageHandlers?.messageAction;
      return Boolean(nativeHandler && typeof nativeHandler.postMessage === "function");
    }

    function isInteractiveTranscript() {
      return Boolean(transcriptPresentation()) && hasMessageActionHandler();
    }

    function transcriptUIState() {
      if (!window.__chatTranscriptUIState) {
        window.__chatTranscriptUIState = {
          editingMessageId: null,
          editDraftByMessageId: {},
          expandedThinkingBlockState: {},
          visibleUserToolbarMessageIDs: {},
          toolbarShowTimeouts: {},
          toolbarHideTimeouts: {},
          tooltipTimeout: null,
          tooltipButton: null,
          copiedExpirations: {},
          copiedResetTimeouts: {},
          activeCitationPreviewBlockKey: null,
          readexMemoryCitationExpandedMessageIDs: {},
          activeModelPickerMessageId: null,
          hasDeferredLiveRender: false,
          deferredLiveRenderFrame: 0,
          lastUserScrollGestureAt: 0,
          lastDisplayWindowExpansionRequestAt: 0
        };
      }
      return window.__chatTranscriptUIState;
    }

    const alwaysPostPresentationProbeKinds = new Set([
      "code_block_mindmap_state",
      "display_window",
      "native_overlay",
      "readex_nested_disclosure_expansion_state",
      "readex_processing_expansion_state",
      "readex_tool_activity_expansion_state",
      "scroll_state"
    ]);

    function trimmed(value) {
      return String(value || "").trim();
    }

    function debugPresentationProbeEnabled() {
      return window.__chatTranscriptDebugPresentationProbesEnabled === true ||
        window.__chatTranscriptScrollPerfProbeEnabled === true ||
        window.__chatTranscriptRenderPerfProbeEnabled === true ||
        window.__chatTranscriptReadexLayoutProbeEnabled === true ||
        window.__chatTranscriptReadexReferenceProbeEnabled === true;
    }

    function shouldPostPresentationProbe(payload) {
      const kind = trimmed(payload?.kind);
      if (alwaysPostPresentationProbeKinds.has(kind)) {
        return true;
      }
      return debugPresentationProbeEnabled();
    }

    function postMessageAction(payload) {
      const nativeHandler = window.webkit?.messageHandlers?.messageAction;
      if (!nativeHandler || typeof nativeHandler.postMessage !== "function") {
        return;
      }
      nativeHandler.postMessage(payload);
    }

    function postAttachmentOpen(messageID, attachmentIndex) {
      const nativeHandler = window.webkit?.messageHandlers?.openAttachment;
      if (!nativeHandler || typeof nativeHandler.postMessage !== "function") {
        return;
      }
      nativeHandler.postMessage({
        messageID,
        attachmentIndex
      });
    }

    function postLayoutLabComponentSelection(role) {
      const nativeHandler = window.webkit?.messageHandlers?.selectLayoutLabComponent;
      if (!nativeHandler || typeof nativeHandler.postMessage !== "function") {
        return;
      }
      nativeHandler.postMessage({ role });
    }

    function postPresentationProbe(payload) {
      const nativeHandler = window.webkit?.messageHandlers?.presentationProbe;
      if (!nativeHandler || typeof nativeHandler.postMessage !== "function") {
        return;
      }
      if (!shouldPostPresentationProbe(payload)) {
        return;
      }
      nativeHandler.postMessage(payload);
    }

    return Object.freeze({
      transcriptPresentation,
      hasMessageActionHandler,
      isInteractiveTranscript,
      transcriptUIState,
      postMessageAction,
      postAttachmentOpen,
      postLayoutLabComponentSelection,
      postPresentationProbe
    });
  };
})();
