export type MSPChatUIRole = "user" | "assistant" | "system" | "tool";
export type MSPChatUIStatus = "pending" | "running" | "success" | "failed" | "cancelled";

export interface MSPChatUITimeline {
  schema?: "msp.chat-ui.timeline.v1";
  id?: string;
  title?: string;
  revision?: number;
  presentation?: MSPChatUIPresentation;
  messages: MSPChatUIMessage[];
}

export type MSPChatUIRuntimeEvent =
  | { type: "timeline.replace"; timeline: MSPChatUITimeline }
  | { type: "presentation.update"; presentation: MSPChatUIPresentation }
  | { type: "message.upsert"; message: MSPChatUIMessage; messageID?: string }
  | { type: "message.remove"; messageID: string }
  | { type: "message.status"; messageID: string; status: MSPChatUIStatus }
  | { type: "message.patch"; messageID: string; patch: Partial<MSPChatUIMessage> }
  | { type: "block.upsert"; messageID: string; block: MSPChatUIBlock; blockID?: string }
  | { type: "block.remove"; messageID: string; blockID: string }
  | { type: "block.status"; messageID: string; blockID: string; status: MSPChatUIStatus }
  | { type: "block.patch"; messageID: string; blockID: string; patch: Partial<MSPChatUIBlock> }
  | { type: "stream.delta"; messageID: string; blockID: string; textDelta: string; status?: MSPChatUIStatus }
  | { type: "tool.lifecycle"; messageID: string; blockID: string; status: MSPChatUIStatus; toolCall: Partial<MSPChatUIToolCallBlock> }
  | { type: "interaction.collapse"; messageID: string; blockID: string; collapsed: boolean }
  | { type: "selection.update"; selection: Record<string, unknown> | null }
  | { type: "scroll.sync" };

export interface MSPChatUIMessage {
  id: string;
  role: MSPChatUIRole;
  status?: MSPChatUIStatus;
  modelName?: string;
  createdAt?: string;
  updatedAt?: string;
  timeText?: string;
  completedGoalDurationMs?: number;
  memoryCitation?: Record<string, unknown>;
  hasRenderPatches?: boolean;
  hasEnabledRenderPatches?: boolean;
  blocks: MSPChatUIBlock[];
}

export type MSPChatUIBlock =
  | MSPChatUIMarkdownBlock
  | MSPChatUIToolCallBlock
  | MSPChatUIToolGroupBlock
  | MSPChatUIProcessingBlock
  | MSPChatUIReasoningBlock
  | MSPChatUIProgressBlock
  | MSPChatUIVideoProgressBlock
  | MSPChatUIProposedPlanBlock
  | MSPChatUIAttachmentBlock
  | MSPChatUIImageBlock
  | MSPChatUINoticeBlock
  | MSPChatUISearchResultsBlock
  | MSPChatUISearchProgressBlock
  | MSPChatUISourcesBlock
  | MSPChatUITextSelectionBlock
  | MSPChatUIFooterBlock;

export interface MSPChatUIBaseBlock {
  id: string;
  status?: MSPChatUIStatus;
}

export interface MSPChatUIMarkdownBlock extends MSPChatUIBaseBlock {
  type: "markdown";
  text: string;
  streaming?: boolean;
}

export interface MSPChatUIToolCallBlock extends MSPChatUIBaseBlock {
  type: "toolCall";
  toolName: string;
  title?: string;
  detailText?: string;
  durationMs?: number;
  outputText?: string;
  errorText?: string;
}

export interface MSPChatUIToolGroupBlock extends MSPChatUIBaseBlock {
  type: "toolGroup";
  title?: string;
  toolCalls: MSPChatUIToolCallBlock[];
}

export type MSPChatUIActivityItemType = "tool" | "webSearch" | "progress" | "mainText" | "videoProgress" | "operationSummary" | "subagent";

export interface MSPChatUIActivityItem {
  id?: string;
  type?: MSPChatUIActivityItemType;
  status?: MSPChatUIStatus;
  text?: string;
  title?: string;
  detailText?: string;
  toolName?: string;
  agentName?: string;
  threadID?: string;
  durationMs?: number;
  progress?: number;
  result?: unknown;
  arguments?: unknown;
  previewItems?: unknown[];
  childItems?: MSPChatUIActivityItem[];
  searchQueries?: string[];
  searchReferences?: unknown[];
  webSearchActions?: unknown[];
}

export interface MSPChatUIProcessingBlock extends MSPChatUIBaseBlock {
  type: "processing";
  title?: string;
  active?: boolean;
  groupID?: string;
  chromeRole?: "owner" | "continuation" | string;
  startedAtMs?: number;
  durationMs?: number;
  items: MSPChatUIActivityItem[];
}

export interface MSPChatUIReasoningBlock extends MSPChatUIBaseBlock {
  type: "reasoning";
  text: string;
}

export interface MSPChatUIProgressBlock extends MSPChatUIBaseBlock {
  type: "progress";
  title: string;
  detailText?: string;
  progress?: number;
}

export interface MSPChatUIVideoProgressBlock extends MSPChatUIBaseBlock {
  type: "videoProgress";
  title?: string;
  detailText?: string;
  progress?: number;
  items?: unknown[];
}

export interface MSPChatUIProposedPlanBlock extends MSPChatUIBaseBlock {
  type: "proposedPlan";
  text: string;
  phaseTitle?: string;
}

export interface MSPChatUIAttachmentBlock extends MSPChatUIBaseBlock { type: "attachment"; attachments: Array<string | Record<string, unknown>>; }

export interface MSPChatUIImageBlock extends MSPChatUIBaseBlock {
  type: "image";
  images: Array<string | Record<string, unknown>>;
}

export interface MSPChatUINoticeBlock extends MSPChatUIBaseBlock {
  type: "notice";
  text: string;
}

export interface MSPChatUISearchResultsBlock extends MSPChatUIBaseBlock {
  type: "searchResults";
  searchQueries?: string[];
  searchReferences?: unknown[];
  webSearchActions?: unknown[];
}

export interface MSPChatUISearchProgressBlock extends MSPChatUIBaseBlock { type: "searchProgress"; title?: string; detailText?: string; searchQueries?: string[]; webSearchActions?: unknown[]; }

export interface MSPChatUISourcesBlock extends MSPChatUIBaseBlock {
  type: "sources";
  sources?: unknown[];
  references?: unknown[];
}

export interface MSPChatUITextSelectionBlock extends MSPChatUIBaseBlock {
  type: "textSelection";
  textSelection: Record<string, unknown>;
}

export interface MSPChatUIFooterBlock extends MSPChatUIBaseBlock {
  type: "footer";
  text: string;
}

export interface MSPChatUIPresentation {
  theme?: "light" | "dark";
  markdownProfile?: "markstream-readex-fade" | string;
  codeTheme?: string;
  collapsedBlocks?: Record<string, boolean>;
  expandedBlocks?: Record<string, boolean>;
  style?: Record<string, unknown>;
  displayWindow?: { startIndex: number; displayCount: number } | null;
  bottomSlackPx?: number;
  bottomSafeAreaInsetPx?: number;
  messageActions?: {
    enabled?: boolean;
    assistantPlacement?: "footer" | "inline" | "none";
    assistant?: MSPChatUIMessageAction[];
    user?: MSPChatUIMessageAction[];
  };
  assistantModelOptions?: unknown[];
  isConversationGenerating?: boolean;
}

export type MSPChatUIMessageAction = "copy" | "branch" | "regenerate" | "edit" | "delete" | "modelPicker" | "inspectRenderPatch" | "toggleRenderPatch" | string;

export type MSPChatUIRenderOperation =
  | { kind: "fullRender"; payload: unknown; presentation: unknown }
  | { kind: "payloadPatch"; patch: unknown; presentation?: unknown }
  | { kind: "directStreamingUpdate"; update: unknown; presentation?: unknown }
  | { kind: "presentationOnlyUpdate"; presentation: unknown }
  | { kind: "scrollSync" };
