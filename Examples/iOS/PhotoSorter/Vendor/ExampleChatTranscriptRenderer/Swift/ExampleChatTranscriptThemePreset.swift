import Foundation

enum ExampleChatTranscriptThemePreset {
    static func presentation(
        isGenerating: Bool,
        interfaceTheme: PhotoSorterInterfaceTheme = .light
    ) -> [String: Any] {
        let colors = colors(interfaceTheme: interfaceTheme)
        return [
            "theme": interfaceTheme.rawValue,
            "chatTranscriptTheme": "codex",
            "chatMarkdownRendererProfile": NSNull(),
            "chatMessageFontWeight": 430,
            "style": style(interfaceTheme: interfaceTheme),
            "pageZoom": 1,
            "layoutLabVisible": false,
            "assistantBubbleSelected": false,
            "userBubbleSelected": false,
            "usesContainerRelativeMessageLayout": false,
            "containerRelativeBubbleBaseWidth": 320,
            "containerRelativeGrowthReserveRatio": 0.18,
            "containerRelativeMinimumGrowthReserve": 72,
            "containerRelativeMaximumGrowthReserve": 72,
            "bodyFontSize": 15.5,
            "roleFontSize": 12,
            "metaFontSize": 11,
            "supportFontSize": 14,
            "messageGap": 12,
            "pagePaddingX": 12,
            "pagePaddingY": 18,
            "pagePaddingTop": 56.5,
            "pagePaddingBottom": 18,
            "assistantBubbleMaxWidth": 760,
            "userBubbleMaxWidth": 620,
            "assistantBubbleOffsetX": 0,
            "userBubbleOffsetX": 0,
            "assistantBubbleOffsetY": 0,
            "userBubbleOffsetY": 0,
            "assistantBubblePaddingX": 0,
            "userBubblePaddingX": 12,
            "assistantBubblePaddingY": 0,
            "userBubblePaddingY": 9,
            "assistantBubbleCornerRadius": 14,
            "generatedImageCornerRadius": 10,
            "userBubbleCornerRadius": 18,
            "assistantContentBaseWidth": 760,
            "userContentBaseWidth": 620,
            "assistantContentMaxWidth": 760,
            "userContentMaxWidth": 620,
            "assistantContentOffsetX": 0,
            "userContentOffsetX": 0,
            "assistantContentOffsetY": 0,
            "userContentOffsetY": 0,
            "showsAssistantBubbleBackground": false,
            "showsUserBubbleBackground": true,
            "assistantBubbleBackgroundColor": colors.assistantBubbleBackground,
            "userBubbleBackgroundColor": colors.userBubbleBackground,
            "searchHighlightColor": colors.searchHighlight,
            "searchActiveHighlightColor": colors.searchActiveHighlight,
            "searchActiveHighlightRingColor": colors.searchActiveHighlightRing,
            "searchActiveHighlightTextColor": colors.searchActiveHighlightText,
            "explanationAnchorBackgroundColor": colors.explanationAnchorBackground,
            "explanationAnchorContainerBackgroundColor": colors.explanationAnchorContainerBackground,
            "explanationAnchorDecorationColor": colors.explanationAnchorDecoration,
            "explanationAnchorActiveBackgroundColor": colors.explanationAnchorActiveBackground,
            "explanationAnchorActiveContainerBackgroundColor": colors.explanationAnchorActiveContainerBackground,
            "explanationAnchorActiveDecorationColor": colors.explanationAnchorActiveDecoration,
            "explanationAnchorActiveRingColor": colors.explanationAnchorActiveRing,
            "searchHighlightRange": 1,
            "searchActiveHighlightRange": 1,
            "focusedMessageID": NSNull(),
            "isConversationGenerating": isGenerating,
            "assistantModelOptions": [],
            "messageActionPolicy": [
                "assistantActions": [],
                "userActions": []
            ],
            "toolbarHoverFill": colors.toolbarHoverFill,
            "controlBackground": colors.controlBackground,
            "tooltipBorder": colors.tooltipBorder,
            "historyEditorTopColor": colors.historyEditorTop,
            "historyEditorBottomColor": colors.historyEditorBottom,
            "historyEditorStroke": colors.historyEditorStroke,
            "historyEditorShadow": colors.historyEditorShadow,
            "assistantActionRowOffsetX": 0,
            "assistantActionRowOffsetY": 0,
            "assistantActionRowScale": 1,
            "assistantActionHighlightWidthScale": 1,
            "assistantActionHighlightHeightScale": 1,
            "userActionRowOffsetX": 0,
            "userActionRowOffsetY": 0,
            "userActionRowScale": 1,
            "userActionHighlightWidthScale": 1,
            "userActionHighlightHeightScale": 1,
            "historyEditorCornerRadius": 24,
            "historyEditorFontSize": 15,
            "historyEditorInsetWidth": 12,
            "historyEditorInsetHeight": 8,
            "historyEditorLineFragmentPadding": 0,
            "historyEditorVerticalOffset": 0,
            "historyEditorMaximumHeight": 132
        ]
    }

    static func style(interfaceTheme: PhotoSorterInterfaceTheme = .light) -> [String: Any] {
        let colors = colors(interfaceTheme: interfaceTheme)
        return [
            "appBackground": colors.appBackground,
            "summaryBackground": colors.summaryBackground,
            "summaryBorder": colors.summaryBorder,
            "title": colors.title,
            "secondary": colors.secondary,
            "assistantBackground": colors.assistantBackground,
            "assistantBorder": colors.assistantBorder,
            "userBackground": colors.userBackground,
            "userBorder": colors.userBorder,
            "assistantAccent": colors.assistantAccent,
            "userAccent": colors.userAccent,
            "chipBackground": colors.chipBackground,
            "text": colors.title,
            "border": colors.border,
            "codeBackground": colors.codeBackground,
            "codeBackgroundSoft": colors.codeBackgroundSoft,
            "blockquoteBorder": colors.blockquoteBorder,
            "showsAssistantBubbleBackground": false,
            "showsUserBubbleBackground": true,
            "generatedImageCornerRadius": 10,
            "messageCodeBlockCornerRadius": 10,
            "chatThinkingIndicatorFontSize": 13.5,
            "chatToolActivityFontSize": 15,
            "chatToolActivityLineSpacing": 6,
            "chatToolFinalAnswerSpacing": 8,
            "chatThinkingIndicatorVerticalOffset": 2,
            "chatDividerColor": colors.chatDivider,
            "chatDividerThickness": 1
        ]
    }

    private struct TranscriptColors {
        var appBackground: String
        var summaryBackground: String
        var summaryBorder: String
        var title: String
        var secondary: String
        var assistantBackground: String
        var assistantBorder: String
        var userBackground: String
        var userBorder: String
        var assistantAccent: String
        var userAccent: String
        var chipBackground: String
        var border: String
        var codeBackground: String
        var codeBackgroundSoft: String
        var blockquoteBorder: String
        var assistantBubbleBackground: String
        var userBubbleBackground: String
        var searchHighlight: String
        var searchActiveHighlight: String
        var searchActiveHighlightRing: String
        var searchActiveHighlightText: String
        var explanationAnchorBackground: String
        var explanationAnchorContainerBackground: String
        var explanationAnchorDecoration: String
        var explanationAnchorActiveBackground: String
        var explanationAnchorActiveContainerBackground: String
        var explanationAnchorActiveDecoration: String
        var explanationAnchorActiveRing: String
        var toolbarHoverFill: String
        var controlBackground: String
        var tooltipBorder: String
        var historyEditorTop: String
        var historyEditorBottom: String
        var historyEditorStroke: String
        var historyEditorShadow: String
        var chatDivider: String
    }

    private static func colors(interfaceTheme: PhotoSorterInterfaceTheme) -> TranscriptColors {
        switch interfaceTheme {
        case .light:
            return TranscriptColors(
                appBackground: "rgba(0,0,0,0)",
                summaryBackground: "rgba(255,255,255,0.75)",
                summaryBorder: "rgba(0,0,0,0.08)",
                title: "rgba(20,20,24,1)",
                secondary: "rgba(92,92,100,1)",
                assistantBackground: "rgba(0,0,0,0)",
                assistantBorder: "rgba(0,0,0,0)",
                userBackground: "rgba(0,0,0,0.055)",
                userBorder: "rgba(0,0,0,0.04)",
                assistantAccent: "rgba(31,120,201,1)",
                userAccent: "rgba(227,107,28,1)",
                chipBackground: "rgba(0,0,0,0.055)",
                border: "rgba(0,0,0,0.12)",
                codeBackground: "rgba(18,32,49,0.08)",
                codeBackgroundSoft: "rgba(18,32,49,0.06)",
                blockquoteBorder: "rgba(18,84,145,0.22)",
                assistantBubbleBackground: "rgba(0,0,0,0)",
                userBubbleBackground: "rgba(0,0,0,0.055)",
                searchHighlight: "rgba(255,206,84,0.56)",
                searchActiveHighlight: "rgba(255,145,48,0.92)",
                searchActiveHighlightRing: "rgba(255,145,48,0.28)",
                searchActiveHighlightText: "rgba(20,20,24,1)",
                explanationAnchorBackground: "rgba(255,206,84,0.24)",
                explanationAnchorContainerBackground: "rgba(255,206,84,0.16)",
                explanationAnchorDecoration: "rgba(255,206,84,0.70)",
                explanationAnchorActiveBackground: "rgba(255,145,48,0.34)",
                explanationAnchorActiveContainerBackground: "rgba(255,145,48,0.30)",
                explanationAnchorActiveDecoration: "rgba(255,145,48,0.85)",
                explanationAnchorActiveRing: "rgba(255,145,48,0.28)",
                toolbarHoverFill: "rgba(0,0,0,0.08)",
                controlBackground: "rgba(255,255,255,0.82)",
                tooltipBorder: "rgba(0,0,0,0.08)",
                historyEditorTop: "rgba(255,255,255,1)",
                historyEditorBottom: "rgba(247,247,250,1)",
                historyEditorStroke: "rgba(0,0,0,0.08)",
                historyEditorShadow: "rgba(0,0,0,0.08)",
                chatDivider: "rgba(0,0,0,0.08)"
            )
        case .dark:
            return TranscriptColors(
                appBackground: "rgba(0,0,0,0)",
                summaryBackground: "rgba(28,34,44,0.76)",
                summaryBorder: "rgba(255,255,255,0.10)",
                title: "rgba(255,255,255,0.96)",
                secondary: "rgba(255,255,255,0.70)",
                assistantBackground: "rgba(0,0,0,0)",
                assistantBorder: "rgba(0,0,0,0)",
                userBackground: "rgba(255,255,255,0.10)",
                userBorder: "rgba(255,255,255,0.10)",
                assistantAccent: "rgba(120,181,242,1)",
                userAccent: "rgba(255,193,126,1)",
                chipBackground: "rgba(255,255,255,0.08)",
                border: "rgba(255,255,255,0.14)",
                codeBackground: "rgba(255,255,255,0.10)",
                codeBackgroundSoft: "rgba(255,255,255,0.08)",
                blockquoteBorder: "rgba(120,174,255,0.34)",
                assistantBubbleBackground: "rgba(0,0,0,0)",
                userBubbleBackground: "rgba(255,255,255,0.10)",
                searchHighlight: "rgba(255,214,102,0.42)",
                searchActiveHighlight: "rgba(255,171,64,0.88)",
                searchActiveHighlightRing: "rgba(255,206,120,0.42)",
                searchActiveHighlightText: "#211300",
                explanationAnchorBackground: "rgba(10,132,255,0.24)",
                explanationAnchorContainerBackground: "rgba(10,132,255,0.16)",
                explanationAnchorDecoration: "rgba(10,132,255,0.70)",
                explanationAnchorActiveBackground: "rgba(255,204,0,0.34)",
                explanationAnchorActiveContainerBackground: "rgba(255,204,0,0.30)",
                explanationAnchorActiveDecoration: "rgba(255,149,0,0.85)",
                explanationAnchorActiveRing: "rgba(255,149,0,0.28)",
                toolbarHoverFill: "rgba(255,255,255,0.10)",
                controlBackground: "rgba(28,34,44,0.82)",
                tooltipBorder: "rgba(255,255,255,0.14)",
                historyEditorTop: "rgba(30,36,46,1)",
                historyEditorBottom: "rgba(18,23,31,1)",
                historyEditorStroke: "rgba(255,255,255,0.12)",
                historyEditorShadow: "rgba(0,0,0,0.42)",
                chatDivider: "rgba(255,255,255,0.16)"
            )
        }
    }
}
