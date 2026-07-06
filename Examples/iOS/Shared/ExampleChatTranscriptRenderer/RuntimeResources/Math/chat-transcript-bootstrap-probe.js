return {
  reason,
  readyState: document.readyState,
  visualState: (() => {
    const rectPayload = (element) => {
      if (!element || typeof element.getBoundingClientRect !== "function") {
        return null;
      }
      const rect = element.getBoundingClientRect();
      return {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height
      };
    };
    const htmlStyle = window.getComputedStyle(document.documentElement);
    const bodyStyle = document.body ? window.getComputedStyle(document.body) : null;
    const page = document.getElementById("page");
    const messages = document.getElementById("messages");
    return {
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      devicePixelRatio: window.devicePixelRatio,
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      documentScrollHeight: document.documentElement?.scrollHeight || 0,
      bodyScrollHeight: document.body?.scrollHeight || 0,
      htmlBackground: htmlStyle.backgroundColor,
      bodyBackground: bodyStyle?.backgroundColor || "",
      appBackgroundVariable: htmlStyle.getPropertyValue("--app-bg").trim(),
      theme: document.documentElement.getAttribute("data-theme") || "",
      bodyChildCount: document.body?.children.length || 0,
      messageChildCount: messages?.children.length || 0,
      pageRect: rectPayload(page),
      messagesRect: rectPayload(messages)
    };
  })(),
  scriptCount: document.scripts.length,
  inlineScriptCount: Array.from(document.scripts).filter((script) => !script.src).length,
  criticalExternalScripts: Array.from(document.scripts)
    .map((script) => script.getAttribute("src") || "")
    .filter((src) => /chat-|unified-markdown/.test(src)),
  inlineScriptMarkers: (() => {
    const inlineScripts = Array.from(document.scripts)
      .filter((script) => !script.src)
      .map((script) => script.textContent || "");
    const hasMarker = (marker) => inlineScripts.some((text) => text.includes(marker));
    return {
      markdownRendererScript: hasMarker("window.ChatMarkdownRenderer"),
      rendererComponentsScript: hasMarker("window.ChatTranscriptRendererComponentCatalog"),
      messageBlockModelScript: hasMarker("window.ChatTranscriptMessageBlockModelFactory"),
      messageBlockRendererScript: hasMarker("window.ChatTranscriptMessageBlockRendererFactory"),
      messageArticleRendererScript: hasMarker("window.ChatTranscriptMessageArticleRendererFactory"),
      foundationStageScript: hasMarker("window.ChatTranscriptBootstrapFoundationStageFactory"),
      interactionStageScript: hasMarker("window.ChatTranscriptBootstrapInteractionStageFactory"),
      documentStageScript: hasMarker("window.ChatTranscriptBootstrapDocumentStageFactory"),
      renderStageScript: hasMarker("window.ChatTranscriptBootstrapRenderStageFactory"),
      runtimeStageScript: hasMarker("window.ChatTranscriptBootstrapRuntimeStageFactory"),
      legacyRuntimeBindingsScript: hasMarker("window.ChatTranscriptBootstrapLegacyRuntimeBindingsFactory"),
      commandBridgeScript: hasMarker("window.ChatTranscriptCommandBridgeFactory"),
      bootstrapSupportScript: hasMarker("window.ChatTranscriptBootstrapSupportFactory"),
      bootstrapLifecycleScript: hasMarker("window.ChatTranscriptBootstrapLifecycleFactory"),
      bootstrapEntryScript: hasMarker("window.ChatTranscriptBootstrapEntryFactory"),
      payloadModelScript: hasMarker("window.ChatTranscriptPayloadModelFactory"),
      payloadPatcherScript: hasMarker("window.ChatTranscriptPayloadPatcherFactory"),
      payloadStoreScript: hasMarker("window.ChatTranscriptPayloadStoreFactory"),
      runtimeScript: hasMarker("window.ChatTranscriptRuntimeFactory"),
      runtimeBridgeScript: hasMarker("windowObject.__chatTranscriptRuntimeBridge = runtimeBridge")
    };
  })(),
  hasFoundationStageFactory: typeof window.ChatTranscriptBootstrapFoundationStageFactory,
  hasInteractionStageFactory: typeof window.ChatTranscriptBootstrapInteractionStageFactory,
  hasDocumentStageFactory: typeof window.ChatTranscriptBootstrapDocumentStageFactory,
  hasRenderStageFactory: typeof window.ChatTranscriptBootstrapRenderStageFactory,
  hasRuntimeStageFactory: typeof window.ChatTranscriptBootstrapRuntimeStageFactory,
  hasLegacyRuntimeBindingsFactory: typeof window.ChatTranscriptBootstrapLegacyRuntimeBindingsFactory,
  hasCommandBridgeFactory: typeof window.ChatTranscriptCommandBridgeFactory,
  hasBootstrapSupportFactory: typeof window.ChatTranscriptBootstrapSupportFactory,
  hasBootstrapLifecycleFactory: typeof window.ChatTranscriptBootstrapLifecycleFactory,
  hasBootstrapEntryFactory: typeof window.ChatTranscriptBootstrapEntryFactory,
  hasPayloadModelFactory: typeof window.ChatTranscriptPayloadModelFactory,
  hasPayloadPatcherFactory: typeof window.ChatTranscriptPayloadPatcherFactory,
  hasPayloadStoreFactory: typeof window.ChatTranscriptPayloadStoreFactory,
  hasMessageBlockModelFactory: typeof window.ChatTranscriptMessageBlockModelFactory,
  hasMessageBlockRendererFactory: typeof window.ChatTranscriptMessageBlockRendererFactory,
  hasMessageArticleRendererFactory: typeof window.ChatTranscriptMessageArticleRendererFactory,
  hasRendererComponentCatalog: typeof window.ChatTranscriptRendererComponentCatalog,
  hasRuntimeFactory: typeof window.ChatTranscriptRuntimeFactory,
  hasCommandBridgeObject: typeof window.__chatTranscriptCommandBridge,
  hasCommandBridgeExecute: typeof window.__chatTranscriptCommandBridge?.execute,
  hasRuntimeBridgeObject: typeof window.__chatTranscriptRuntimeBridge,
  hasRuntimeBridgeRenderConversationPreservingScroll: typeof window.__chatTranscriptRuntimeBridge?.renderConversationPreservingScroll,
  hasRuntimeBridgeApplyPatchPreservingScroll: typeof window.__chatTranscriptRuntimeBridge?.applyPatchPreservingScroll,
  hasRuntimeBridgeSetConversationPresentation: typeof window.__chatTranscriptRuntimeBridge?.setConversationPresentation,
  hasRuntimeBridgeScrollConversationToBottom: typeof window.__chatTranscriptRuntimeBridge?.scrollConversationToBottom,
  hasRuntimeBridgeScrollConversationToMessage: typeof window.__chatTranscriptRuntimeBridge?.scrollConversationToMessage,
  hasRuntimeObject: typeof window.__chatTranscriptRuntime,
  hasRuntimeRenderConversationPreservingScroll: typeof window.__chatTranscriptRuntime?.renderConversationPreservingScroll,
  hasRuntimeApplyPatchPreservingScroll: typeof window.__chatTranscriptRuntime?.applyPatchPreservingScroll,
  hasRuntimeSetConversationPresentation: typeof window.__chatTranscriptRuntime?.setConversationPresentation,
  hasRuntimeScrollConversationToBottom: typeof window.__chatTranscriptRuntime?.scrollConversationToBottom,
  hasRuntimeScrollConversationToMessage: typeof window.__chatTranscriptRuntime?.scrollConversationToMessage,
  hasMarkdownRenderer: typeof window.ChatMarkdownRenderer,
  bootstrapState: window.__chatTranscriptRuntimeBootstrap || null
};
