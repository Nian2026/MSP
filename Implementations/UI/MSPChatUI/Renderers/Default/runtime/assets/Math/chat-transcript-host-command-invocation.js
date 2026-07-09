try {
  const commandBridge = window.__chatTranscriptCommandBridge;
  if (!commandBridge || typeof commandBridge.execute !== "function") {
    throw new Error("Chat transcript command bridge unavailable");
  }
  return {
    ok: true,
    result: commandBridge.execute(command, payload, options || {}),
    bootstrapState: window.__chatTranscriptRuntimeBootstrap || null
  };
} catch (error) {
  const commandBridge = window.__chatTranscriptCommandBridge;
  return {
    ok: false,
    command,
    errorName: error?.name || "Error",
    errorMessage: error?.message || String(error),
    errorStack: typeof error?.stack === "string" ? error.stack : "",
    hasCommandBridgeFactory: typeof window.ChatTranscriptCommandBridgeFactory,
    hasCommandBridgeObject: typeof commandBridge,
    hasCommandBridgeExecute: typeof commandBridge?.execute,
    availableCommands: typeof commandBridge?.availableCommands === "function" ? commandBridge.availableCommands() : [],
    hasFoundationStageFactory: typeof window.ChatTranscriptBootstrapFoundationStageFactory,
    hasInteractionStageFactory: typeof window.ChatTranscriptBootstrapInteractionStageFactory,
    hasDocumentStageFactory: typeof window.ChatTranscriptBootstrapDocumentStageFactory,
    hasRenderStageFactory: typeof window.ChatTranscriptBootstrapRenderStageFactory,
    hasRuntimeStageFactory: typeof window.ChatTranscriptBootstrapRuntimeStageFactory,
    hasLegacyRuntimeBindingsFactory: typeof window.ChatTranscriptBootstrapLegacyRuntimeBindingsFactory,
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
    hasRuntimeBridgeObject: typeof window.__chatTranscriptRuntimeBridge,
    hasRuntimeBridgeRenderConversationPreservingScroll: typeof window.__chatTranscriptRuntimeBridge?.renderConversationPreservingScroll,
    hasRuntimeBridgeRenderConversation: typeof window.__chatTranscriptRuntimeBridge?.renderConversation,
    hasRuntimeObject: typeof window.__chatTranscriptRuntime,
    hasRuntimeRenderConversationPreservingScroll: typeof window.__chatTranscriptRuntime?.renderConversationPreservingScroll,
    bootstrapState: window.__chatTranscriptRuntimeBootstrap || null
  };
}
