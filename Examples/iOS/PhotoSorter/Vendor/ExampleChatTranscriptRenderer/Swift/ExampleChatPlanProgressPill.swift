import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum ExampleChatCodexPlanStepStatus: String, Hashable, Sendable {
    case pending
    case inProgress
    case completed
}

struct ExampleChatCodexPlanStep: Hashable, Sendable {
    var step: String
    var status: ExampleChatCodexPlanStepStatus
}

struct ExampleChatCodexPlanProgressStep: Hashable, Sendable {
    var step: String
    var sourceStatus: ExampleChatCodexPlanStepStatus
    var displayStatus: ExampleChatCodexPlanStepStatus
}

struct ExampleChatCodexPlanProgressPresentation: Hashable, Sendable {
    var totalStepCount: Int
    var completedStepCount: Int
    var currentStepNumber: Int
    var progressFraction: Double
    var steps: [ExampleChatCodexPlanProgressStep]
}

struct ExampleChatCodexPlanUpdate: Hashable, Sendable {
    var threadID: String
    var turnID: String
    var explanation: String?
    var steps: [ExampleChatCodexPlanStep]

    var progressPresentation: ExampleChatCodexPlanProgressPresentation {
        let totalStepCount = steps.count
        let completedStepCount = steps.filter { $0.status == .completed }.count
        let runningIndex = steps.firstIndex { $0.status == .inProgress }
            ?? inferredRunningStepIndex(
                completedStepCount: completedStepCount,
                totalStepCount: totalStepCount
            )
        let displaySteps = steps.enumerated().map { index, step in
            ExampleChatCodexPlanProgressStep(
                step: step.step,
                sourceStatus: step.status,
                displayStatus: index == runningIndex ? .inProgress : step.status
            )
        }
        let currentStepNumber = runningIndex.map { $0 + 1 }
            ?? (totalStepCount == 0 ? 0 : totalStepCount)
        let progressFraction = totalStepCount == 0
            ? 0
            : min(max(Double(completedStepCount) / Double(totalStepCount), 0), 1)
        return ExampleChatCodexPlanProgressPresentation(
            totalStepCount: totalStepCount,
            completedStepCount: completedStepCount,
            currentStepNumber: currentStepNumber,
            progressFraction: progressFraction,
            steps: displaySteps
        )
    }

    private func inferredRunningStepIndex(
        completedStepCount: Int,
        totalStepCount: Int
    ) -> Int? {
        guard totalStepCount > 0,
              completedStepCount < totalStepCount else {
            return nil
        }
        return min(max(completedStepCount, 0), totalStepCount - 1)
    }
}

struct ExampleChatPlanProgressPillLayoutMetrics: Hashable, Sendable {
    static let reservedHeight: CGFloat = 0
    static let defaultScrollToBottomButtonPadding: CGFloat = 16

    static func composerTopLift(
        at scale: CGFloat,
        composerTopPadding: CGFloat
    ) -> CGFloat {
        max(0, composerTopPadding) + overlayHeight(at: scale) + composerTopGap(at: scale)
    }

    static func estimatedPillHeight(at scale: CGFloat) -> CGFloat {
        let scale = min(max(scale, 0.75), 1.6)
        return max(18 * scale, ExampleChatPlanProgressDonutMetrics.diameter(at: scale)) + 18 * scale
    }

    static func overlayHeight(at scale: CGFloat) -> CGFloat {
        estimatedPillHeight(at: scale) + popoverSourceTopClearance(at: scale)
    }

    static func composerTopGap(at scale: CGFloat) -> CGFloat {
        max(7, 8 * scale)
    }

    static func popoverSourceTopClearance(at scale: CGFloat) -> CGFloat {
        max(4, 5 * min(max(scale, 0.75), 1.6))
    }

    static func scrollToBottomButtonBottomPadding(
        at scale: CGFloat,
        hasActivePlanProgress: Bool
    ) -> CGFloat {
        guard hasActivePlanProgress else { return defaultScrollToBottomButtonPadding }
        let scale = min(max(scale, 0.75), 1.6)
        return max(
            defaultScrollToBottomButtonPadding,
            overlayHeight(at: scale) + composerTopGap(at: scale) + 8 * scale
        )
    }
}

@MainActor
struct ExampleChatPlanProgressPillSlot: View {
    let update: ExampleChatCodexPlanUpdate?
    let isGenerating: Bool
    let zoomScale: CGFloat
    let horizontalPadding: CGFloat

    private var scale: CGFloat {
        min(max(zoomScale, 0.75), 1.6)
    }

    var body: some View {
        if isGenerating,
           let update,
           !update.steps.isEmpty {
            HStack {
                Spacer(minLength: 0)
                ExampleChatPlanProgressPill(
                    update: update,
                    zoomScale: zoomScale
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalPadding)
            .fixedSize(horizontal: false, vertical: true)
            .frame(
                height: ExampleChatPlanProgressPillLayoutMetrics.overlayHeight(at: scale),
                alignment: .center
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .zIndex(3)
        }
    }
}

@MainActor
private struct ExampleChatPlanProgressPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let update: ExampleChatCodexPlanUpdate
    let zoomScale: CGFloat

    @State private var showsTooltip = false
    #if canImport(AppKit)
    @State private var isHoveringPill = false
    @State private var isHoveringTooltip = false
    @State private var tooltipShowTask: Task<Void, Never>?
    @State private var tooltipHideTask: Task<Void, Never>?
    #endif

    private var scale: CGFloat {
        min(max(zoomScale, 0.75), 1.6)
    }

    private var presentation: ExampleChatCodexPlanProgressPresentation {
        update.progressPresentation
    }

    private var accentColor: Color {
        ExampleChatPlanProgressAccent.color(for: update.turnID)
    }

    var body: some View {
        #if canImport(AppKit)
        popoverSource
            .onHover { hovering in
                setPillHovered(hovering)
            }
            .popover(isPresented: $showsTooltip, arrowEdge: .bottom) {
                tooltip
            }
            .onDisappear {
                cancelTooltipTasks()
                showsTooltip = false
                isHoveringPill = false
                isHoveringTooltip = false
            }
            .accessibilityLabel("任务计划进度")
            .accessibilityValue("第 \(presentation.currentStepNumber) 步，共 \(presentation.totalStepCount) 步")
        #else
        popoverSource
            .onTapGesture {
                showsTooltip.toggle()
            }
            .popover(isPresented: $showsTooltip, arrowEdge: .bottom) {
                tooltip
            }
            .onDisappear {
                showsTooltip = false
            }
            .accessibilityLabel("任务计划进度")
            .accessibilityValue("第 \(presentation.currentStepNumber) 步，共 \(presentation.totalStepCount) 步")
        #endif
    }

    private var pillChrome: some View {
        HStack(spacing: 9 * scale) {
            ExampleChatPlanProgressDonut(
                progress: CGFloat(presentation.progressFraction),
                accentColor: accentColor,
                scale: scale
            )

            Text("第 \(presentation.currentStepNumber) / \(presentation.totalStepCount) 步")
                .font(.system(size: 16 * scale, weight: .semibold))
                .foregroundStyle(pillTextColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 17 * scale)
        .padding(.vertical, 9 * scale)
        .background(pillFill, in: Capsule())
        .overlay(
            Capsule()
                .stroke(pillStroke, lineWidth: 1)
        )
        .contentShape(Capsule())
    }

    private var popoverSource: some View {
        pillChrome
            .padding(.top, ExampleChatPlanProgressPillLayoutMetrics.popoverSourceTopClearance(at: scale))
    }

    private var tooltip: some View {
        ExampleChatPlanProgressTooltipView(
            update: update,
            accentColor: accentColor,
            zoomScale: scale,
            maximumHeight: ExampleChatPlanProgressTooltipPopoverMetrics.maximumHeight(at: scale)
        )
        .frame(width: ExampleChatPlanProgressTooltipPopoverMetrics.width(at: scale))
        #if canImport(AppKit)
        .background {
            ExampleChatPopoverHoverTrackingView { hovering in
                setTooltipHovered(hovering)
            }
        }
        .onHover { hovering in
            setTooltipHovered(hovering)
        }
        .onDisappear {
            isHoveringTooltip = false
        }
        #endif
        .presentationCompactAdaptation(.popover)
    }

    private var pillFill: Color {
        colorScheme == .dark
            ? ExampleChatPlanProgressPlatformColor.controlBackground.opacity(0.98)
            : Color.white.opacity(0.98)
    }

    private var pillStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.20)
            : Color.black.opacity(0.12)
    }

    private var pillTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.84)
            : Color.black.opacity(0.72)
    }

    #if canImport(AppKit)
    fileprivate func setPillHovered(_ hovering: Bool) {
        isHoveringPill = hovering
        if hovering {
            scheduleTooltipShow()
        } else {
            scheduleTooltipHide()
        }
    }

    private func setTooltipHovered(_ hovering: Bool) {
        isHoveringTooltip = hovering
        if hovering {
            showTooltipImmediately()
        } else {
            scheduleTooltipHide()
        }
    }

    private func scheduleTooltipShow() {
        tooltipHideTask?.cancel()
        tooltipHideTask = nil
        tooltipShowTask?.cancel()
        tooltipShowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            showsTooltip = true
            tooltipShowTask = nil
        }
    }

    private func showTooltipImmediately() {
        tooltipShowTask?.cancel()
        tooltipShowTask = nil
        tooltipHideTask?.cancel()
        tooltipHideTask = nil
        showsTooltip = true
    }

    private func scheduleTooltipHide() {
        tooltipShowTask?.cancel()
        tooltipShowTask = nil
        tooltipHideTask?.cancel()
        tooltipHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            if !isHoveringPill && !isHoveringTooltip {
                showsTooltip = false
            }
            tooltipHideTask = nil
        }
    }

    private func cancelTooltipTasks() {
        tooltipShowTask?.cancel()
        tooltipShowTask = nil
        tooltipHideTask?.cancel()
        tooltipHideTask = nil
    }
    #endif
}

struct ExampleChatPlanProgressDonutMetrics: Hashable, Sendable {
    static let trackOpacity = 0.28

    static func diameter(at scale: CGFloat) -> CGFloat {
        max(12, 17 * min(max(scale, 0.75), 1.6))
    }

    static func lineWidth(at scale: CGFloat) -> CGFloat {
        max(2.0, 3.2 * min(max(scale, 0.75), 1.6))
    }
}

struct ExampleChatPlanProgressTooltipPopoverMetrics: Hashable, Sendable {
    static let usesSystemPopoverChrome = true

    static func width(at scale: CGFloat) -> CGFloat {
        340 * min(max(scale, 0.75), 1.6)
    }

    static func maximumHeight(at scale: CGFloat) -> CGFloat {
        460 * min(max(scale, 0.75), 1.6)
    }

    static func contentPadding(at scale: CGFloat) -> CGFloat {
        18 * min(max(scale, 0.75), 1.6)
    }
}

@MainActor
private struct ExampleChatPlanProgressDonut: View {
    let progress: CGFloat
    let accentColor: Color
    let scale: CGFloat

    private var clampedProgress: CGFloat {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    accentColor.opacity(ExampleChatPlanProgressDonutMetrics.trackOpacity),
                    lineWidth: lineWidth
                )

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    accentColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.32), value: clampedProgress)
        }
        .frame(
            width: ExampleChatPlanProgressDonutMetrics.diameter(at: scale),
            height: ExampleChatPlanProgressDonutMetrics.diameter(at: scale)
        )
    }

    private var lineWidth: CGFloat {
        ExampleChatPlanProgressDonutMetrics.lineWidth(at: scale)
    }
}

@MainActor
private struct ExampleChatPlanProgressTooltipView: View {
    let update: ExampleChatCodexPlanUpdate
    let accentColor: Color
    let zoomScale: CGFloat
    let maximumHeight: CGFloat

    private var scale: CGFloat {
        min(max(zoomScale, 0.75), 1.6)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                if let explanation = update.explanation,
                   !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(explanation)
                        .font(.system(size: 15 * scale, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.54))
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2 * scale)
                }

                ForEach(update.steps.indices, id: \.self) { index in
                    ExampleChatPlanProgressTooltipRow(
                        step: update.progressPresentation.steps[index],
                        accentColor: accentColor,
                        scale: scale
                    )
                }
            }
            .padding(ExampleChatPlanProgressTooltipPopoverMetrics.contentPadding(at: scale))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maximumHeight)
    }
}

@MainActor
private struct ExampleChatPlanProgressTooltipRow: View {
    let step: ExampleChatCodexPlanProgressStep
    let accentColor: Color
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 8 * scale) {
            ExampleChatPlanStepStatusIcon(
                status: step.displayStatus,
                accentColor: iconColor,
                scale: scale
            )
            .frame(
                width: ExampleChatPlanStepStatusVisualMetrics.iconDiameter(at: scale),
                height: ExampleChatPlanStepStatusVisualMetrics.iconDiameter(at: scale)
            )
            .padding(.top, ExampleChatPlanStepStatusVisualMetrics.iconTopPadding(at: scale))

            Text(step.step)
                .font(.system(size: 18 * scale, weight: .semibold))
                .foregroundStyle(textColor)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
        .padding(.vertical, 3 * scale)
        .opacity(rowOpacity)
    }

    private var textColor: Color {
        accentColor.opacity(ExampleChatPlanStepStatusVisualMetrics.textOpacity(for: step.displayStatus))
    }

    private var iconColor: Color {
        accentColor.opacity(ExampleChatPlanStepStatusVisualMetrics.iconOpacity(for: step.displayStatus))
    }

    private var rowOpacity: Double {
        ExampleChatPlanStepStatusVisualMetrics.rowOpacity(for: step.displayStatus)
    }
}

struct ExampleChatPlanStepStatusVisualMetrics: Hashable, Sendable {
    static let spinnerRotationPeriodSeconds: TimeInterval = 1.1

    static func iconDiameter(at scale: CGFloat) -> CGFloat {
        13 * scale
    }

    static func iconTopPadding(at scale: CGFloat) -> CGFloat {
        5 * scale
    }

    static func lineWidth(at scale: CGFloat) -> CGFloat {
        max(1.2, 1.6 * scale)
    }

    static func checkmarkFontSize(at scale: CGFloat) -> CGFloat {
        7 * scale
    }

    static func textOpacity(for status: ExampleChatCodexPlanStepStatus) -> Double {
        status == .completed ? 0.72 : 0.96
    }

    static func iconOpacity(for status: ExampleChatCodexPlanStepStatus) -> Double {
        status == .completed ? 0.76 : 0.96
    }

    static func rowOpacity(for status: ExampleChatCodexPlanStepStatus) -> Double {
        status == .completed ? 0.90 : 1
    }
}

@MainActor
private struct ExampleChatPlanStepStatusIcon: View {
    let status: ExampleChatCodexPlanStepStatus
    let accentColor: Color
    let scale: CGFloat

    var body: some View {
        ZStack {
            switch status {
            case .completed:
                Circle()
                    .stroke(accentColor.opacity(0.90), lineWidth: lineWidth)
                Image(systemName: "checkmark")
                    .font(.system(size: ExampleChatPlanStepStatusVisualMetrics.checkmarkFontSize(at: scale), weight: .bold))
                    .foregroundStyle(accentColor)
            case .inProgress:
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    Circle()
                        .trim(from: 0, to: 0.76)
                        .stroke(
                            accentColor,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(rotationAngle(at: context.date)))
                }
            case .pending:
                Circle()
                    .stroke(accentColor, lineWidth: lineWidth)
            }
        }
    }

    private var lineWidth: CGFloat {
        ExampleChatPlanStepStatusVisualMetrics.lineWidth(at: scale)
    }

    private func rotationAngle(at date: Date) -> Double {
        let period = ExampleChatPlanStepStatusVisualMetrics.spinnerRotationPeriodSeconds
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return progress * 360
    }
}

private enum ExampleChatPlanProgressAccent {
    static func color(for seed: String) -> Color {
        palette[stableIndex(for: seed, count: palette.count)]
    }

    private static let palette: [Color] = [
        Color(red: 0.00, green: 0.48, blue: 1.00),
        Color(red: 0.19, green: 0.69, blue: 0.78),
        Color(red: 0.20, green: 0.78, blue: 0.35),
        Color(red: 1.00, green: 0.58, blue: 0.00),
        Color(red: 1.00, green: 0.18, blue: 0.33),
        Color(red: 0.35, green: 0.34, blue: 0.84),
        Color(red: 0.69, green: 0.32, blue: 0.87),
        Color(red: 0.20, green: 0.68, blue: 0.90)
    ]

    private static func stableIndex(for seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash = 5381
        for scalar in seed.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return (hash == Int.min ? 0 : abs(hash)) % count
    }
}

private enum ExampleChatPlanProgressPlatformColor {
    static var controlBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.primary.opacity(0.06)
        #endif
    }

    static var windowBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.primary.opacity(0.08)
        #endif
    }
}

#if canImport(AppKit)
private struct ExampleChatPopoverHoverTrackingView: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView {
        HoverView(onHoverChanged: onHoverChanged)
    }

    func updateNSView(_ nsView: HoverView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }

    final class HoverView: NSView {
        var onHoverChanged: (Bool) -> Void
        private var trackingArea: NSTrackingArea?
        private var isHovering = false

        init(onHoverChanged: @escaping (Bool) -> Void) {
            self.onHoverChanged = onHoverChanged
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited
            ]
            let nextTrackingArea = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(nextTrackingArea)
            trackingArea = nextTrackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            guard !isHovering else { return }
            isHovering = true
            onHoverChanged(true)
        }

        override func mouseExited(with event: NSEvent) {
            guard isHovering else { return }
            isHovering = false
            onHoverChanged(false)
        }
    }
}
#endif
