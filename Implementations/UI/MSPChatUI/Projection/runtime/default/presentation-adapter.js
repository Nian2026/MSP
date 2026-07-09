(function (root, factory) {
  const api = factory({
    actions: root.MSPChatUIDefaultActionPolicyAdapter
  });
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  root.MSPChatUIDefaultPresentationAdapter = api;
})(typeof globalThis !== "undefined" ? globalThis : window, function ({ actions }) {
  function number(value) {
    return Number.isFinite(value) ? value : null;
  }

  function bottomPadding(finalPresentation, source, basePadding) {
    const slack = number(source.bottomSlackPx ?? source.bottomSafeAreaInsetPx);
    if (slack == null) return finalPresentation.pagePaddingBottom;
    const current = number(finalPresentation.pagePaddingBottom) ?? number(basePadding) ?? 0;
    return current + Math.max(0, slack);
  }

  function presentation(defaultPresentation, source = {}) {
    const theme = source.theme || defaultPresentation.theme || "light";
    const themeOverride = defaultPresentation.themeOverrides?.[theme] || {};
    const profile = source.markdownProfile || source.readexMarkdownRendererProfile;
    const base = {
      ...defaultPresentation,
      ...themeOverride,
      ...source,
      theme,
      readexMarkdownRendererProfile: profile || defaultPresentation.readexMarkdownRendererProfile,
      readexMarkstreamCodeTheme: source.codeTheme || themeOverride.readexMarkstreamCodeTheme || defaultPresentation.readexMarkstreamCodeTheme,
      style: {
        ...(defaultPresentation.style || {}),
        ...(themeOverride.style || {}),
        ...(source.style || {})
      }
    };
    return {
      ...base,
      pagePaddingBottom: bottomPadding(base, source, themeOverride.pagePaddingBottom || defaultPresentation.pagePaddingBottom),
      messageActionPolicy: actions.messageActionPolicy(defaultPresentation, source)
    };
  }

  return Object.freeze({
    presentation
  });
});
