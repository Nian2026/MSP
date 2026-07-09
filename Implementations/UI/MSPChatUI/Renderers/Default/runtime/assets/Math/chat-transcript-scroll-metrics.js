(function () {
  window.ChatTranscriptScrollMetricsFactory = function createChatTranscriptScrollMetrics(dependencies) {
    const transcriptLiveEdgeThreshold = Number(dependencies?.transcriptLiveEdgeThreshold) || 64;

    function scrollRoot() {
      return document.scrollingElement || document.documentElement || document.body;
    }

    function clamp(value, minimum, maximum) {
      return Math.min(Math.max(value, minimum), maximum);
    }

    function maximumScrollTop(root) {
      if (!root) {
        return 0;
      }
      return Math.max((Number(root.scrollHeight) || 0) - (Number(root.clientHeight) || 0), 0);
    }

    function isNearConversationBottom(root) {
      if (!root) {
        return true;
      }
      return Math.max(maximumScrollTop(root) - (Number(root.scrollTop) || 0), 0) <= transcriptLiveEdgeThreshold;
    }

    function currentConversationDocumentHeight() {
      const page = document.getElementById("page");
      return Math.ceil(
        document.documentElement.scrollHeight ||
          document.body.scrollHeight ||
          page?.scrollHeight ||
          0
      );
    }

    function scrollViewportRect(root) {
      if (!root) {
        return null;
      }

      if (root === document.scrollingElement || root === document.documentElement || root === document.body) {
        return {
          left: 0,
          top: 0,
          width: window.innerWidth || document.documentElement.clientWidth || 0,
          height: window.innerHeight || document.documentElement.clientHeight || 0
        };
      }

      const rect = root.getBoundingClientRect();
      return {
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height
      };
    }

    function transcriptScrollSnapshot(root = scrollRoot()) {
      return {
        scrollLeft: Number(root?.scrollLeft) || 0,
        scrollTop: Number(root?.scrollTop) || 0,
        scrollWidth: Number(root?.scrollWidth) || 0,
        clientWidth: Number(root?.clientWidth) || 0,
        scrollHeight: Number(root?.scrollHeight) || 0,
        clientHeight: Number(root?.clientHeight) || 0
      };
    }

    return Object.freeze({
      scrollRoot,
      clamp,
      maximumScrollTop,
      isNearConversationBottom,
      currentConversationDocumentHeight,
      scrollViewportRect,
      transcriptScrollSnapshot
    });
  };
})();
