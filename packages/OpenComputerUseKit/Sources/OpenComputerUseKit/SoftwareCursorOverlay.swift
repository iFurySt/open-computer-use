import AppKit
import CoreGraphics
import Foundation
import QuartzCore

public enum VisualCursorSupport {
    public static var isEnabled: Bool {
        visualCursorEnabled(environment: ProcessInfo.processInfo.environment)
    }

    /// Cursor animations are cosmetic, so an off-main caller (a tool call) does
    /// not wait for them. The main queue plays them in order: it does not start
    /// the next block while an animation pumps the run loop inside the current
    /// one. A backlog reaches `adaptiveCursorTempo` as a zero gap, so the cursor
    /// speeds up to catch up. On the main thread (one-shot CLI) nothing would
    /// drain a queue before exit, so the action plays inline.
    static func performOnMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body()
            }
            return
        }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                body()
            }
        }
    }
}

func visualCursorEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_VISUAL_CURSOR"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return true
    }

    return !["0", "false", "no", "off"].contains(rawValue)
}

func defaultVisualCursorInitialTipPosition(
    windowOrigin: CGPoint = .zero,
    tipAnchor: CGPoint = SoftwareCursorGlyphMetrics.tipAnchor
) -> CGPoint {
    return CGPoint(
        x: windowOrigin.x + tipAnchor.x,
        y: windowOrigin.y + tipAnchor.y
    )
}

func visualCursorRenderBaseHeading(
    artworkNeutralHeading: CGFloat = SoftwareCursorGlyphMetrics.targetNeutralHeading
) -> CGFloat {
    artworkNeutralHeading
}

func visualCursorAppKitForwardHeading(
    renderRotation: CGFloat,
    artworkNeutralHeading: CGFloat = SoftwareCursorGlyphMetrics.targetNeutralHeading
) -> CGFloat {
    -artworkNeutralHeading - renderRotation
}

func visualCursorRuntimeRenderYAxisMultiplier() -> CGFloat {
    // Window placement uses AppKit global coordinates, but glyph render state is
    // still interpreted as CursorMotion's y-down screen state before drawing.
    -1
}

func visualCursorScreenStateVelocity(
    fromRuntimeVelocity velocity: CGVector,
    yAxisMultiplier: CGFloat
) -> CGVector {
    CGVector(dx: velocity.dx, dy: velocity.dy * yAxisMultiplier)
}

/// Tempo multiplier for the next cursor action: 1 when the cursor has been idle
/// for `relaxedGap`, shrinking toward `floor` as actions arrive back to back, the
/// way a hand speeds up through a burst of clicks. `gap` is the idle time since
/// the previous action finished.
func adaptiveCursorTempo(previous: Double, gap: TimeInterval, relaxedGap: TimeInterval = 2, floor: Double) -> Double {
    let calm = min(max(gap / relaxedGap, 0), 1)
    let recovered = previous + (1 - previous) * calm
    return max(min(floor, 1), recovered * (0.6 + 0.4 * calm))
}

func visualCursorPostInteractionIdleTimeout() -> TimeInterval {
    30
}

func visualCursorIdleRotationAmplitude() -> CGFloat {
    0.09
}

public struct VisualCursorObservationPoint: Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(point: CGPoint) {
        x = point.x
        y = point.y
    }
}

public struct VisualCursorObservationSnapshot: Codable, Sendable {
    public let phase: String
    public let tipPosition: VisualCursorObservationPoint?
    public let restingTipPosition: VisualCursorObservationPoint?
    public let rotation: Double?
    public let timestamp: Double

    public init(
        phase: String,
        tipPosition: CGPoint?,
        restingTipPosition: CGPoint?,
        rotation: CGFloat?,
        timestamp: CFTimeInterval
    ) {
        self.phase = phase
        self.tipPosition = tipPosition.map(VisualCursorObservationPoint.init(point:))
        self.restingTipPosition = restingTipPosition.map(VisualCursorObservationPoint.init(point:))
        self.rotation = rotation.map(Double.init)
        self.timestamp = timestamp
    }
}

struct VisualCursorIdlePose {
    let tipPosition: CGPoint
    let angleOffset: CGFloat
}

func visualCursorIdlePose(restingTipPosition: CGPoint, phase: CGFloat) -> VisualCursorIdlePose {
    VisualCursorIdlePose(
        tipPosition: restingTipPosition,
        angleOffset: sin(phase * 0.8) * visualCursorIdleRotationAmplitude()
    )
}

public func visualCursorObservationFileURL(environment: [String: String]) -> URL? {
    guard
        let rawPath = environment["OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !rawPath.isEmpty
    else {
        return nil
    }

    return URL(fileURLWithPath: rawPath)
}

public let openComputerUseTurnEndedNotificationName = Notification.Name("com.ifuryst.opencomputeruse.turn-ended")

public func postOpenComputerUseTurnEndedNotification() {
    DistributedNotificationCenter.default().postNotificationName(
        openComputerUseTurnEndedNotificationName,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

@MainActor
public func resetOpenComputerUseVisualCursor() {
    SoftwareCursorOverlay.reset()
}

struct CursorTargetWindow: Equatable, Sendable {
    let windowID: CGWindowID
    let layer: Int
}

struct CursorWindowGeometry {
    let windowSize: CGSize
    let tipAnchor: CGPoint

    func origin(forTipPosition tipPosition: CGPoint) -> CGPoint {
        CGPoint(
            x: tipPosition.x - tipAnchor.x,
            y: tipPosition.y - tipAnchor.y
        )
    }

    func tipPosition(forOrigin origin: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x + tipAnchor.x,
            y: origin.y + tipAnchor.y
        )
    }
}

private struct CursorArtwork {
    let geometry: CursorWindowGeometry
    static let active = CursorArtwork(
        geometry: CursorWindowGeometry(
            windowSize: SoftwareCursorGlyphMetrics.windowSize,
            tipAnchor: SoftwareCursorGlyphMetrics.tipAnchor
        ),
    )
}

@MainActor
enum SoftwareCursorOverlay {
    private static let artwork = CursorArtwork.active
    private static let renderBaseHeading = visualCursorRenderBaseHeading()
    private static let renderYAxisMultiplier = visualCursorRuntimeRenderYAxisMultiplier()
    private static var panel: CursorPanel?
    private static var cursorView: SoftwareCursorView?
    private static var restingTipPosition: CGPoint?
    private static var displayedTipPosition: CGPoint?
    private static var activeTargetWindow: CursorTargetWindow?
    /// Window frame the current target point was derived from; lets a move
    /// under the cursor be detected and re-derived instead of ignored.
    private static var restingAnchor: CursorRestingAnchor?
    private static var lastAnchorFrame: CGRect?
    private static var visualDynamicsState: CursorVisualDynamicsState?
    private static var idleTimer: Timer?
    private static var hideTimer: Timer?
    private static var idlePhase: CGFloat = 0
    private static var observationPhase = "hidden"
    private static var tempo: Double = 1
    private static var lastInteractionEnd: CFTimeInterval?

    static func moveCursor(
        to targetPoint: CGPoint,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        prepareWindowIfNeeded()
        stopIdleAnimation()
        cancelPendingHide()
        configureOrdering(relativeTo: targetWindow)

        adoptAnchor(anchor)
        lastAnchorFrame = anchor.flatMap { CursorWindowFrameTracker.liveFrame(for: $0.windowID) } ?? anchor?.windowBounds
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        let isFreshStart = displayedTipPosition == nil
        let startPoint = displayedTipPosition ?? defaultInitialTipPosition()
        let now = CACurrentMediaTime()
        tempo = adaptiveCursorTempo(
            previous: tempo,
            gap: lastInteractionEnd.map { now - $0 } ?? .infinity,
            floor: burstTempoFloor
        )
        defer { lastInteractionEnd = CACurrentMediaTime() }

        observationPhase = "moving"
        panel?.alphaValue = 1
        if isFreshStart {
            visualDynamicsState = CursorVisualDynamicsAnimator.state(at: startPoint, time: CGFloat(dynamicsTime(at: now)))
            placeCursor(using: initialRenderState(at: startPoint), clickProgress: 0)
        } else {
            seedVisualDynamicsIfNeeded(at: startPoint, time: now)
            placeCursor(
                using: advanceVisualDynamics(
                    toward: startPoint,
                    at: now
                ),
                clickProgress: 0
            )
        }

        if distanceBetween(startPoint, constrainedTarget) > 2 {
            animateMove(from: startPoint, to: constrainedTarget, relativeTo: targetWindow)
        }
    }

    static func pulseClick(
        at targetPoint: CGPoint,
        clickCount: Int,
        mouseButton: MouseButtonKind,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        configureOrdering(relativeTo: targetWindow)
        stopIdleAnimation()
        adoptAnchor(anchor)
        _ = reanchorIfWindowMoved()
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        let now = CACurrentMediaTime()
        seedVisualDynamicsIfNeeded(at: constrainedTarget, time: now)
        restingTipPosition = constrainedTarget
        observationPhase = "pulse"
        animateClickPulse(at: constrainedTarget, clickCount: max(clickCount, 1), mouseButton: mouseButton)
        lastInteractionEnd = CACurrentMediaTime()
        startIdleAnimation()
        scheduleHide(after: visualCursorPostInteractionIdleTimeout())
    }

    static func settle(
        at targetPoint: CGPoint,
        in targetWindow: CursorTargetWindow?,
        anchor: CursorRestingAnchor? = nil
    ) {
        guard VisualCursorSupport.isEnabled, canPresentOverlay else {
            return
        }

        configureOrdering(relativeTo: targetWindow)
        adoptAnchor(anchor)
        _ = reanchorIfWindowMoved()
        let constrainedTarget = clampTipPosition(liveTargetPoint(targetPoint, anchor: anchor))
        restingTipPosition = constrainedTarget
        observationPhase = "settling"
        placeCursor(
            using: advanceVisualDynamics(
                toward: constrainedTarget,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
        startIdleAnimation()
        scheduleHide(after: visualCursorPostInteractionIdleTimeout())
    }

    static func reset() {
        stopIdleAnimation()
        cancelPendingHide()
        displayedTipPosition = nil
        restingTipPosition = nil
        activeTargetWindow = nil
        restingAnchor = nil
        lastAnchorFrame = nil
        CursorWindowFrameTracker.forgetAll()
        visualDynamicsState = nil
        tempo = 1
        lastInteractionEnd = nil
        observationPhase = "hidden"
        writeObservationSnapshot(tipPosition: nil, rotation: nil)
        panel?.orderOut(nil)
    }

    /// Re-derive a target point that was computed from a snapshot taken before
    /// the window moved. Element frames are window-relative, so the anchored
    /// point follows the window instead of staying on the display it just left.
    private static func liveTargetPoint(_ targetPoint: CGPoint, anchor: CursorRestingAnchor?) -> CGPoint {
        guard let anchor,
              let liveFrame = CursorWindowFrameTracker.liveFrame(for: anchor.windowID),
              let screenStatePoint = anchor.screenStatePoint(liveFrame: liveFrame)
        else {
            return targetPoint
        }

        return screenStatePointToAppKitGlobalPoint(
            fromScreenStatePoint: screenStatePoint,
            screenMappings: currentVisualCursorScreenMappings()
        )
    }

    private static func adoptAnchor(_ anchor: CursorRestingAnchor?) {
        if restingAnchor != anchor {
            restingAnchor = anchor
            lastAnchorFrame = anchor?.windowBounds
        }
        if anchor == nil { CursorWindowFrameTracker.forgetAll() }
    }

    /// Relocate the visible tip, not just its spring target. Otherwise an old
    /// travel velocity can leave it on the previous display after reanchoring.
    @discardableResult
    private static func reanchorIfWindowMoved() -> Bool {
        guard let anchor = restingAnchor,
              let liveFrame = CursorWindowFrameTracker.liveFrame(for: anchor.windowID),
              liveFrame != lastAnchorFrame,
              let screenStatePoint = anchor.screenStatePoint(liveFrame: liveFrame)
        else {
            return false
        }

        let constrainedTarget = clampTipPosition(
            screenStatePointToAppKitGlobalPoint(
                fromScreenStatePoint: screenStatePoint,
                screenMappings: currentVisualCursorScreenMappings()
            )
        )
        lastAnchorFrame = liveFrame
        restingTipPosition = constrainedTarget
        visualDynamicsState = CursorVisualDynamicsAnimator.state(at: constrainedTarget, time: CGFloat(dynamicsTime(at: CACurrentMediaTime())))
        observationPhase = "reanchored"
        placeCursor(
            using: initialRenderState(at: constrainedTarget),
            clickProgress: 0
        )
        return true
    }

    private static var canPresentOverlay: Bool {
        !NSScreen.screens.isEmpty
    }

    private static func prepareWindowIfNeeded() {
        guard panel == nil else {
            return
        }

        let panel = CursorPanel(
            contentRect: CGRect(origin: .zero, size: artwork.geometry.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .normal
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none

        let view = SoftwareCursorView(frame: CGRect(origin: .zero, size: artwork.geometry.windowSize))
        panel.contentView = view

        self.panel = panel
        self.cursorView = view
    }

    private static func configureOrdering(relativeTo targetWindow: CursorTargetWindow?) {
        configureOrdering(relativeTo: targetWindow, forceReorder: false)
    }

    private static func configureOrdering(relativeTo targetWindow: CursorTargetWindow?, forceReorder: Bool) {
        guard let panel else {
            return
        }

        let effectiveTargetWindow = targetWindow.flatMap { targetWindow in
            isWindowPresent(targetWindow.windowID) ? targetWindow : nil
        }

        let desiredLevel = NSWindow.Level(rawValue: effectiveTargetWindow?.layer ?? 0)
        if panel.level != desiredLevel {
            panel.level = desiredLevel
        }

        if shouldReorderCursorPanel(
            activeTargetWindow: activeTargetWindow,
            effectiveTargetWindow: effectiveTargetWindow,
            panelIsVisible: panel.isVisible,
            forceReorder: forceReorder
        ) {
            if let effectiveTargetWindow {
                panel.order(.above, relativeTo: Int(effectiveTargetWindow.windowID))
            } else {
                panel.orderFront(nil)
            }
            activeTargetWindow = effectiveTargetWindow
        }
    }

    /// Lowest tempo a burst of back-to-back actions can reach (see
    /// `adaptiveCursorTempo`). Default 0.15; OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR
    /// overrides it, 1 turns the speed-up off.
    static let burstTempoFloor: Double = {
        guard let raw = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR"],
              let value = Double(raw) else { return 0.15 }
        return min(max(value, 0), 1)
    }()

    // The drawn tip follows the path through the visual-dynamics springs. Those
    // run on this clock, not wall time: while a move or pulse plays it advances
    // 1 / tempo times faster, so a sped-up animation is the full-length one
    // played faster and still lands on the target. On wall time the springs
    // trail a sped-up glide, so the click pulse starts short of the target.
    private static var dynamicsClock: CFTimeInterval = 0
    private static var dynamicsClockWall: CFTimeInterval?
    private static var dynamicsRate: Double = 1

    private static func dynamicsTime(at wall: CFTimeInterval) -> CFTimeInterval {
        if let last = dynamicsClockWall {
            dynamicsClock += max(0, wall - last) * dynamicsRate
        }
        dynamicsClockWall = wall
        return dynamicsClock
    }

    private static func paceDynamics(_ paced: Bool) {
        _ = dynamicsTime(at: CACurrentMediaTime())
        dynamicsRate = paced ? 1 / max(tempo, 0.001) : 1
    }

    private static func animateMove(from start: CGPoint, to end: CGPoint, relativeTo targetWindow: CursorTargetWindow?) {
        let candidate = bestMotionCandidate(from: start, to: end, relativeTo: targetWindow)
        let path = candidate.path
        // Use the recovered official progress spring timing instead of the older
        // distance-compressed local duration, otherwise medium and long moves feel
        // noticeably faster than the bundled app.
        let duration = OfficialCursorMotionModel.calibratedTravelDuration(
            distance: distanceBetween(start, end),
            measurement: candidate.measurement
        ) * tempo
        let springTargetDuration = OfficialCursorMotionModel.closeEnoughTime
        paceDynamics(true)
        defer { paceDynamics(false) }
        let startTime = CACurrentMediaTime()
        var progress: CGFloat = 0
        var springState = CursorMotionSpringState()

        while true {
            refreshActiveOrderingIfNeeded()

            if reanchorIfWindowMoved() {
                return
            }

            let elapsed = CGFloat(CACurrentMediaTime() - startTime)
            let normalizedElapsed = (elapsed / max(duration, 0.001)).clamped(to: 0...1)
            let springTime = normalizedElapsed * springTargetDuration
            (progress, springState) = CursorMotionProgressAnimator.advance(
                current: progress,
                state: springState,
                to: springTime
            )

            let sample = path.sample(at: progress)
            placeCursor(
                using: advanceVisualDynamics(
                    toward: sample.point,
                    at: CACurrentMediaTime()
                ),
                clickProgress: 0
            )

            if normalizedElapsed >= 1 || CursorMotionProgressAnimator.isCloseEnough(progress: progress) {
                break
            }

            pumpFrame()
        }

        placeCursor(
            using: advanceVisualDynamics(
                toward: end,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
    }

    private static func bestMotionCandidate(from start: CGPoint, to end: CGPoint, relativeTo targetWindow: CursorTargetWindow?) -> CursorMotionCandidate {
        let bounds = motionBounds(from: start, to: end)
        let candidates = HeadingDrivenCursorMotionModel.makeCandidates(
            start: start,
            end: end,
            bounds: bounds,
            startForward: currentForwardVector(),
            endForward: restingForwardVector()
        )
        let defaultCandidate = HeadingDrivenCursorMotionModel.chooseBestCandidate(from: candidates)
            ?? CursorMotionCandidate(
                identifier: "legacy-fallback",
                kind: .base,
                side: 0,
                tableAScale: nil,
                tableBScale: nil,
                path: CursorMotionPath(start: start, end: end),
                measurement: CursorMotionPath(start: start, end: end).measure(bounds: bounds),
                score: 0
            )

        guard let targetWindow else {
            return defaultCandidate
        }

        let excludingWindowNumber = max(panel?.windowNumber ?? 0, 0)
        let evaluations = candidates.map { candidate in
            (
                candidate: candidate,
                hitCount: windowConstraintHitCount(
                    for: candidate.path,
                    relativeTo: targetWindow,
                    excludingWindowNumber: excludingWindowNumber
                )
            )
        }

        let totalSampleCount = candidates.first?.path.sampledConstraintPoints().count ?? 0
        let bestHitCount = evaluations.map(\.hitCount).max() ?? 0

        if bestHitCount == totalSampleCount, bestHitCount > 0 {
            return evaluations
                .filter { $0.hitCount == bestHitCount }
                .map(\.candidate)
                .sorted(by: candidatePreference)
                .first ?? defaultCandidate
        }

        if bestHitCount > 0 {
            return evaluations
                .filter { $0.hitCount == bestHitCount }
                .map(\.candidate)
                .sorted(by: candidatePreference)
                .first ?? defaultCandidate
        }

        return defaultCandidate
    }

    private static func currentForwardVector() -> CGVector {
        let renderRotation = cursorView?.rotation ?? 0
        return forwardVector(renderRotation: renderRotation)
    }

    private static func restingForwardVector() -> CGVector {
        forwardVector(renderRotation: 0)
    }

    private static func forwardVector(renderRotation: CGFloat) -> CGVector {
        let angle = visualCursorAppKitForwardHeading(renderRotation: renderRotation)
        return CGVector(dx: cos(angle), dy: sin(angle))
    }

    private static func windowConstraintHitCount(
        for path: CursorMotionPath,
        relativeTo targetWindow: CursorTargetWindow,
        excludingWindowNumber: Int
    ) -> Int {
        path.sampledConstraintPoints().reduce(into: 0) { result, point in
            if windowID(at: point, excludingWindowNumber: excludingWindowNumber) == targetWindow.windowID {
                result += 1
            }
        }
    }

    private static func motionBounds(from start: CGPoint, to end: CGPoint) -> CGRect? {
        let startScreen = screen(containing: start) ?? NSScreen.main ?? NSScreen.screens.first
        let endScreen = screen(containing: end) ?? startScreen

        switch (startScreen, endScreen) {
        case let (startScreen?, endScreen?) where startScreen === endScreen:
            return startScreen.visibleFrame
        case let (startScreen?, endScreen?):
            return startScreen.visibleFrame.union(endScreen.visibleFrame)
        case let (screen?, nil), let (nil, screen?):
            return screen.visibleFrame
        default:
            return nil
        }
    }

    private static func candidatePreference(_ lhs: CursorMotionCandidate, _ rhs: CursorMotionCandidate) -> Bool {
        if lhs.measurement.staysInBounds != rhs.measurement.staysInBounds {
            return lhs.measurement.staysInBounds && !rhs.measurement.staysInBounds
        }
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        return lhs.identifier < rhs.identifier
    }

    private static func windowID(at point: CGPoint, excludingWindowNumber: Int) -> CGWindowID? {
        let windowNumber = NSWindow.windowNumber(
            at: NSPoint(x: point.x, y: point.y),
            belowWindowWithWindowNumber: excludingWindowNumber
        )

        guard windowNumber > 0 else {
            return nil
        }

        return CGWindowID(windowNumber)
    }

    private static func isWindowPresent(_ windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        else {
            return false
        }

        return !windowInfo.isEmpty
    }

    private static func refreshActiveOrderingIfNeeded() {
        guard let activeTargetWindow else {
            return
        }

        if isWindowPresent(activeTargetWindow.windowID) {
            configureOrdering(relativeTo: activeTargetWindow, forceReorder: true)
            return
        }

        configureOrdering(relativeTo: nil)
    }

    private static func animateClickPulse(at point: CGPoint, clickCount: Int, mouseButton: MouseButtonKind) {
        let pulseBias: CGFloat = mouseButton == .right ? 0.82 : 1
        paceDynamics(true)
        defer { paceDynamics(false) }

        for pulse in 0..<clickCount {
            let duration = 0.16 * tempo
            let startTime = CACurrentMediaTime()

            while true {
                _ = reanchorIfWindowMoved()
                let elapsed = CACurrentMediaTime() - startTime
                let rawProgress = min(max(elapsed / duration, 0), 1)
                let clickProgress = sin(rawProgress * .pi) * pulseBias

                placeCursor(
                    using: advanceVisualDynamics(
                        toward: restingTipPosition ?? point,
                        at: CACurrentMediaTime()
                    ),
                    clickProgress: clickProgress
                )

                if rawProgress >= 1 {
                    break
                }

                pumpFrame()
            }

            if pulse < clickCount - 1 {
                pause(for: 0.05 * tempo)
            }
        }

        placeCursor(
            using: advanceVisualDynamics(
                toward: restingTipPosition ?? point,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
    }

    private static func startIdleAnimation() {
        stopIdleAnimation()
        guard canPresentOverlay, let restingTipPosition else {
            return
        }

        observationPhase = "idle"
        idlePhase = 0
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard panel != nil, cursorView != nil else {
                    return
                }

                refreshActiveOrderingIfNeeded()
                _ = reanchorIfWindowMoved()
                guard let currentTipPosition = self.restingTipPosition else { return }

                observationPhase = "idle"
                idlePhase += 0.05
                let idlePose = visualCursorIdlePose(
                    restingTipPosition: currentTipPosition,
                    phase: idlePhase
                )

                placeCursor(
                    using: advanceVisualDynamics(
                        toward: idlePose.tipPosition,
                        idleAngleOffset: idlePose.angleOffset,
                        at: CACurrentMediaTime()
                    ),
                    clickProgress: 0
                )
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer

        placeCursor(
            using: advanceVisualDynamics(
                toward: restingTipPosition,
                at: CACurrentMediaTime()
            ),
            clickProgress: 0
        )
    }

    private static func stopIdleAnimation() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private static func scheduleHide(after delay: TimeInterval) {
        cancelPendingHide()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                hideOverlay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private static func cancelPendingHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private static func hideOverlay() {
        guard let panel else {
            return
        }

        stopIdleAnimation()
        cancelPendingHide()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
                displayedTipPosition = nil
                restingTipPosition = nil
                activeTargetWindow = nil
                restingAnchor = nil
                lastAnchorFrame = nil
                CursorWindowFrameTracker.forgetAll()
                visualDynamicsState = nil
                observationPhase = "hidden"
                writeObservationSnapshot(tipPosition: nil, rotation: nil)
            }
        }
    }

    private static func defaultInitialTipPosition() -> CGPoint {
        defaultVisualCursorInitialTipPosition(
            windowOrigin: .zero,
            tipAnchor: artwork.geometry.tipAnchor
        )
    }

    private static func initialRenderState(at tipPosition: CGPoint) -> CursorVisualRenderState {
        CursorVisualRenderState(
            tipPosition: tipPosition,
            rotation: 0,
            cursorBodyOffset: CGVector(dx: 0, dy: 0),
            fogOffset: CGVector(dx: 0, dy: 0),
            fogOpacity: CursorVisualDynamicsConfiguration.officialInspired.fogOpacityBase,
            fogScale: 1
        )
    }

    private static func seedVisualDynamicsIfNeeded(at tipPosition: CGPoint, time: CFTimeInterval) {
        guard visualDynamicsState == nil else {
            return
        }

        visualDynamicsState = CursorVisualDynamicsAnimator.state(
            at: tipPosition,
            time: CGFloat(dynamicsTime(at: time))
        )
    }

    private static func advanceVisualDynamics(
        toward targetTipPosition: CGPoint,
        idleAngleOffset: CGFloat = 0,
        at time: CFTimeInterval
    ) -> CursorVisualRenderState {
        let clampedTarget = clampTipPosition(targetTipPosition)
        seedVisualDynamicsIfNeeded(at: clampedTarget, time: time)
        let time = dynamicsTime(at: time)

        let result = CursorVisualDynamicsAnimator.advance(
            state: visualDynamicsState ?? CursorVisualDynamicsAnimator.state(at: clampedTarget, time: CGFloat(time)),
            targetTipPosition: clampedTarget,
            targetTime: CGFloat(time),
            idleAngleOffset: idleAngleOffset,
            baseHeading: renderBaseHeading,
            renderYAxisMultiplier: renderYAxisMultiplier
        )
        visualDynamicsState = result.state
        return result.renderState
    }

    private static func placeCursor(using renderState: CursorVisualRenderState, clickProgress: CGFloat) {
        guard let panel, let cursorView else {
            return
        }

        panel.setFrameOrigin(artwork.geometry.origin(forTipPosition: renderState.tipPosition))
        cursorView.rotation = renderState.rotation
        cursorView.cursorBodyOffset = renderState.cursorBodyOffset
        cursorView.fogOffset = renderState.fogOffset
        cursorView.fogOpacity = renderState.fogOpacity
        cursorView.fogScale = renderState.fogScale
        cursorView.clickProgress = clickProgress
        cursorView.needsDisplay = true
        displayedTipPosition = renderState.tipPosition
        writeObservationSnapshot(
            tipPosition: renderState.tipPosition,
            rotation: renderState.rotation
        )
    }

    private static func writeObservationSnapshot(tipPosition: CGPoint?, rotation: CGFloat?) {
        guard
            let url = visualCursorObservationFileURL(environment: ProcessInfo.processInfo.environment)
        else {
            return
        }

        let snapshot = VisualCursorObservationSnapshot(
            phase: observationPhase,
            tipPosition: tipPosition,
            restingTipPosition: restingTipPosition,
            rotation: rotation,
            timestamp: CACurrentMediaTime()
        )

        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Observation is debug-only and must not affect tool execution.
        }
    }

    private static func clampTipPosition(_ tipPosition: CGPoint) -> CGPoint {
        guard let screen = screen(containing: tipPosition) ?? NSScreen.main ?? NSScreen.screens.first else {
            return tipPosition
        }

        let visibleFrame = screen.visibleFrame
        let minX = visibleFrame.minX + artwork.geometry.tipAnchor.x
        let maxX = visibleFrame.maxX - (artwork.geometry.windowSize.width - artwork.geometry.tipAnchor.x)
        let minY = visibleFrame.minY + artwork.geometry.tipAnchor.y
        let maxY = visibleFrame.maxY - (artwork.geometry.windowSize.height - artwork.geometry.tipAnchor.y)

        return CGPoint(
            x: tipPosition.x.clamped(to: minX...maxX),
            y: tipPosition.y.clamped(to: minY...maxY)
        )
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func pumpFrame() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1 / 120))
    }

    private static func pause(for duration: TimeInterval) {
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < duration {
            pumpFrame()
        }
    }

    private static func distanceBetween(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}

func shouldReorderCursorPanel(
    activeTargetWindow: CursorTargetWindow?,
    effectiveTargetWindow: CursorTargetWindow?,
    panelIsVisible: Bool,
    forceReorder: Bool
) -> Bool {
    forceReorder || activeTargetWindow != effectiveTargetWindow || panelIsVisible == false
}

private final class CursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SoftwareCursorView: NSView {
    var rotation: CGFloat = 0
    var cursorBodyOffset: CGVector = CGVector(dx: 0, dy: 0)
    var fogOffset: CGVector = CGVector(dx: 0, dy: 0)
    var fogOpacity: CGFloat = 0.12
    var fogScale: CGFloat = 1
    var clickProgress: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        SoftwareCursorGlyphRenderer.draw(
            in: bounds,
            context: context,
            state: SoftwareCursorGlyphRenderState(
                rotation: rotation,
                cursorBodyOffset: cursorBodyOffset,
                fogOffset: fogOffset,
                fogOpacity: fogOpacity,
                fogScale: fogScale,
                clickProgress: clickProgress
            )
        )
    }
}
