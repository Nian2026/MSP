(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIDefaultActionPolicyAdapter = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function () {
  const ASSISTANT_DEFAULT = ["copy", "branch", "regenerate", "modelPicker"];
  const USER_DEFAULT = ["regenerate", "edit", "branch", "copy"];
  const ASSISTANT_MAP = {
    copy: "copyMessage",
    branch: "branchConversation",
    regenerate: "regenerateAssistantMessage",
    modelPicker: "toggleAssistantModelPicker",
    inspectRenderPatch: "openRenderPatchInspection",
    toggleRenderPatch: "setRenderPatchesEnabled",
    delete: "deleteAssistantMessage"
  };
  const USER_MAP = {
    copy: "copyMessage",
    branch: "branchConversation",
    regenerate: "regenerateUserMessage",
    edit: "editUserMessage",
    delete: "deleteUserMessage"
  };

  function sourceActions(source) {
    return source?.messageActions && typeof source.messageActions === "object" ? source.messageActions : {};
  }

  function mapAction(value, roleMap) {
    const key = typeof value === "string" ? value.trim() : "";
    return roleMap[key] || key;
  }

  function actionList(values, defaults, roleMap) {
    return (Array.isArray(values) ? values : defaults)
      .map((value) => mapAction(value, roleMap))
      .filter(Boolean);
  }

  function assistantPlacement(actions) {
    const value = typeof actions.assistantPlacement === "string" ? actions.assistantPlacement : "footer";
    if (value === "inline") return "";
    if (value === "none") return "none";
    return "readexAssistantFooter";
  }

  function messageActionPolicy(defaultPresentation, sourcePresentation = {}) {
    if (sourcePresentation.messageActionPolicy && typeof sourcePresentation.messageActionPolicy === "object") {
      return sourcePresentation.messageActionPolicy;
    }
    const defaults = sourceActions(defaultPresentation);
    const source = sourceActions(sourcePresentation);
    const merged = { ...defaults, ...source };
    if (merged.enabled === false) {
      return { assistantActions: [], userActions: [], assistantPlacement: "none" };
    }
    return {
      assistantActions: actionList(merged.assistant, ASSISTANT_DEFAULT, ASSISTANT_MAP),
      userActions: actionList(merged.user, USER_DEFAULT, USER_MAP),
      assistantPlacement: assistantPlacement(merged)
    };
  }

  return Object.freeze({
    messageActionPolicy
  });
});
