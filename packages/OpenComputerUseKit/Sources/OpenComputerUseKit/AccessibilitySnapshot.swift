import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class ElementRecord {
    let index: Int
    let identifier: String?
    let element: AXUIElement?
    let localFrame: CGRect?
    let role: String?
    let title: String?
    let value: String?
    let rawActions: [String]
    let prettyActions: [String]
    let isSyntheticText: Bool

    init(
        index: Int,
        identifier: String?,
        element: AXUIElement?,
        localFrame: CGRect?,
        role: String? = nil,
        title: String? = nil,
        value: String? = nil,
        rawActions: [String],
        prettyActions: [String],
        isSyntheticText: Bool = false
    ) {
        self.index = index
        self.identifier = identifier
        self.element = element
        self.localFrame = localFrame
        self.role = role
        self.title = title
        self.value = value
        self.rawActions = rawActions
        self.prettyActions = prettyActions
        self.isSyntheticText = isSyntheticText
    }
}

enum SnapshotMode {
    case accessibility
    case fixture
}

enum SnapshotRecoveryPolicy: Equatable {
    case allowActivation
    case readOnly
}

public struct AccessibilityTreeLimits: Equatable, Sendable {
    public static let defaultMaxNodeCount = 1200
    public static let defaultMaxDepth = 64
    public static let defaults = AccessibilityTreeLimits(
        maxNodeCount: defaultMaxNodeCount,
        maxDepth: defaultMaxDepth
    )

    public let maxNodeCount: Int
    public let maxDepth: Int

    public init(maxNodeCount: Int = defaultMaxNodeCount, maxDepth: Int = defaultMaxDepth) {
        self.maxNodeCount = maxNodeCount
        self.maxDepth = maxDepth
    }

    public func replacing(maxNodeCount: Int? = nil, maxDepth: Int? = nil) -> AccessibilityTreeLimits {
        AccessibilityTreeLimits(
            maxNodeCount: maxNodeCount ?? self.maxNodeCount,
            maxDepth: maxDepth ?? self.maxDepth
        )
    }
}

@usableFromInline
let defaultTextLimit = 500

public struct SnapshotTextLimit: Equatable, Sendable {
    public static let maxKeyword = "max"
    public static let defaults = SnapshotTextLimit(maxCount: defaultTextLimit)
    public static let max = SnapshotTextLimit(maxCount: nil)

    public let maxCount: Int?

    public init(maxCount: Int = defaultTextLimit) {
        precondition(maxCount > 0, "text limit must be positive")
        self.maxCount = maxCount
    }

    private init(maxCount: Int?) {
        self.maxCount = maxCount
    }
}

let accessibilityTreeMaxNodeCount = AccessibilityTreeLimits.defaultMaxNodeCount
let accessibilityTreeMaxDepth = AccessibilityTreeLimits.defaultMaxDepth
let screenshotResultMaxDimension: CGFloat = 1280
private let windowVisibilityRecoveryDelay: TimeInterval = 0.7
private let axWebAreaRole = "AXWebArea"
// Chrome needs up to ~2s after AXManualAccessibility before the web tree exists.
private let webAreaRewalkAttempts = 30
private let webAreaRewalkInterval: TimeInterval = 0.1

/// Layer-0 windows ordered above `windowID` on screen, excluding this process
/// (the visual cursor overlay must not count as cover).
func coveringWindowBounds(above windowID: CGWindowID) -> [CGRect] {
    let infoList = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowID) as? [[String: Any]] ?? []
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return infoList.compactMap { info in
        guard
            let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != ownPID,
            let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
            let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else {
            return nil
        }
        return bounds
    }
}
private let axContentsAttribute = "AXContents"
private let axVisibleChildrenAttribute = "AXVisibleChildren"
private let compactGenericActionTargetMaxWidth: CGFloat = 240
private let compactGenericActionTargetMaxHeight: CGFloat = 120

public struct AppSnapshot {
    public let app: RunningAppDescriptor
    public let windowTitle: String?
    public let windowBounds: CGRect?
    let targetWindowID: CGWindowID?
    let targetWindowLayer: Int?
    public let screenshotData: Data?
    @available(*, deprecated, message: "Use screenshotData; screenshots may be JPEG")
    public var screenshotPNGData: Data? {
        guard let data = screenshotData, data.starts(with: [0x89, 0x50, 0x4e, 0x47]) else { return nil }
        return data
    }
    let mode: SnapshotMode
    let treeLines: [String]
    let focusedSummary: String?
    let focusedElement: AXUIElement?
    let selectedText: String?
    /// The AX window the tree was rendered from (nil for fixture snapshots).
    let windowElement: AXUIElement?

    let elements: [Int: ElementRecord]
    var screenshotNote: String? = nil
    var observation: SnapshotObservationOptions = .defaults

    public var renderedText: String {
        renderedText(style: .fullState)
    }

    public func renderedText(style: SnapshotTextStyle) -> String {
        var lines: [String] = []
        let displayTitle = displayWindowTitle(windowTitle, appName: app.name)
        let appReference = app.bundleIdentifier ?? app.name

        lines.append("App=\(appReference) (pid \(app.pid))")
        lines.append("Window: \(quoted(displayTitle)), App: \(app.name).")
        lines.append(contentsOf: treeLines)
        if !observation.includeAX {
            lines.append(SnapshotObservationOptions.accessibilityOmittedNote)
        }

        if let selectedText, !selectedText.isEmpty {
            lines.append("")
            lines.append("Selected text: [\(selectedText)]")
        } else if let focusedSummary {
            lines.append("")
            lines.append("The focused UI element is \(focusedSummary).")
        }

        return lines.joined(separator: "\n")
    }
}

public enum SnapshotTextStyle {
    case fullState
    case actionResult
}

enum SnapshotBuilder {
    static func build(
        for app: RunningAppDescriptor,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation,
        observation: SnapshotObservationOptions = .defaults
    ) throws -> AppSnapshot {
        try observation.validate()
        if app.name == FixtureBridge.appName, let fixtureState = try FixtureBridge.readState() {
            return buildFixtureSnapshot(app: app, state: fixtureState, observation: observation)
        }

        try requireUsableComputerUseSession()

        let permissions = PermissionDiagnostics.current()
        guard permissions.accessibilityTrusted else {
            throw ComputerUseError.permissionDenied("Accessibility permission is required. Run `open-computer-use doctor` and grant access to Open Computer Use.")
        }

        let appElement = AXUIElementCreateApplication(app.pid)
        let lazyWebAccessibility = observation.includeAX && (enableBestEffortAccessibilityModes(appElement)
            || appHasLazyWebAccessibility(bundleURL: app.runningApplication.bundleURL))
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
        var focusedWindow = preferredFocusedWindow(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide)
        if focusedWindow == nil,
           recoveryPolicy == .allowActivation,
           recoverVisibleWindow(for: app, appElement: appElement, preferredWindow: nil) {
            focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
            focusedWindow = preferredFocusedWindow(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide)
        }

        var rootWindow: AXUIElement
        guard let resolvedFocusedWindow = focusedWindow else {
            throw ComputerUseError.stateUnavailable(computerUseNoWindowFoundMessage)
        }
        rootWindow = resolvedFocusedWindow

        var windowTitle = stringValue(of: rootWindow, attribute: kAXTitleAttribute)
        // Bind the AX window to its CGWindowID directly when the SPI allows it, so
        // the tree, the capture and every element frame refer to the same window;
        // the title/area heuristics remain the fallback.
        var windowCapture = TimingLog.measure("snapshot.window_capture") {
            WindowCapture.resolve(for: app.pid, exactWindowID: SkyLightSPI.shared.windowID(for: rootWindow), capture: observation.includeScreenshot)
                ?? WindowCapture.resolve(for: app.pid, titleHint: windowTitle, capture: observation.includeScreenshot)
        }
        if windowCapture == nil,
           recoveryPolicy == .allowActivation,
           recoverVisibleWindow(for: app, appElement: appElement, preferredWindow: rootWindow) {
            focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
            if let recoveredWindow = preferredFocusedWindow(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide) {
                rootWindow = recoveredWindow
                windowTitle = stringValue(of: recoveredWindow, attribute: kAXTitleAttribute)
                windowCapture = WindowCapture.resolve(for: app.pid, exactWindowID: SkyLightSPI.shared.windowID(for: recoveredWindow), capture: observation.includeScreenshot)
                    ?? WindowCapture.resolve(for: app.pid, titleHint: windowTitle, capture: observation.includeScreenshot)
            }
        }

        guard let windowCapture else {
            throw ComputerUseError.stateUnavailable(computerUseNoWindowFoundMessage)
        }

        return buildAccessibilitySnapshot(
            app: app,
            appElement: appElement,
            rootElement: rootWindow,
            windowTitle: windowTitle,
            windowCapture: windowCapture,
            focusedApplication: focusedApplication,
            systemWide: systemWide,
            textLimit: textLimit,
            treeLimits: treeLimits,
            lazyWebAccessibility: lazyWebAccessibility,
            observation: observation
        )
    }

    private static func buildAccessibilitySnapshot(
        app: RunningAppDescriptor,
        appElement: AXUIElement,
        rootElement: AXUIElement,
        windowTitle: String?,
        windowCapture: WindowCapture,
        focusedApplication: AXUIElement?,
        systemWide: AXUIElement,
        textLimit: SnapshotTextLimit,
        treeLimits: AccessibilityTreeLimits,
        lazyWebAccessibility: Bool,
        observation: SnapshotObservationOptions
    ) -> AppSnapshot {
        let windowBounds = windowCapture.bounds
        let screenshot = observation.includeScreenshot ? windowCapture.screenshotResult()
            : ScreenshotEncodingResult(data: nil, note: SnapshotObservationOptions.screenshotOmittedNote)
        let screenshotData = screenshot.data
        guard observation.includeAX else {
            return AppSnapshot(app: app, windowTitle: windowTitle, windowBounds: windowBounds,
                               targetWindowID: windowCapture.windowID, targetWindowLayer: windowCapture.layer,
                               screenshotData: screenshotData, mode: .accessibility, treeLines: [],
                               focusedSummary: nil, focusedElement: nil, selectedText: nil,
                               windowElement: rootElement, elements: [:], screenshotNote: screenshot.note,
                               observation: observation)
        }
        let focusedElement = preferredFocusedElement(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide)
        let selectedText = focusedElement.flatMap { copySelectedText($0, textLimit: textLimit) }
        let context = RenderContext(
            windowBounds: windowBounds,
            focusedElement: focusedElement,
            textLimit: textLimit,
            treeLimits: treeLimits
        )

        var renderer = TreeRenderer(context: context)
        TimingLog.measure("snapshot.tree_walk") { renderer.render(rootElement) }

        // Pin the window's visible state (WindowServer occlusion notifications
        // off) so covering it or moving it to another Space later does not hide
        // its content. Only possible while it is currently unoccluded.
        let pinned = WindowOcclusionKeepAlive.shared.keepVisible(windowID: windowCapture.windowID, bounds: windowBounds)

        // Engines that accept AXManualAccessibility build their web tree lazily
        // and drop it while hidden. Re-walk briefly while the window is visible;
        // when it is hidden, say so instead of waiting.
        var occlusionNote: String?
        if lazyWebAccessibility, !renderer.hasWebArea {
            if pinned {
                for _ in 0..<webAreaRewalkAttempts {
                    Thread.sleep(forTimeInterval: webAreaRewalkInterval)
                    renderer = TreeRenderer(context: context)
                    renderer.render(rootElement)
                    if renderer.hasWebArea {
                        break
                    }
                }
            } else {
                occlusionNote = "Note: this window is covered or on another Space, so the app hides its web content and it is not in the tree. Bring the window into view once (covering it afterwards keeps working), or call get_app_state with window_placement=agent_display to park it on the agent's own display."
            }
        }

        if let menuBar = copyElement(appElement, attribute: kAXMenuBarAttribute),
           !CFEqual(menuBar, rootElement)
        {
            renderer.render(menuBar)
        }

        var treeLines = renderer.lines
        if let occlusionNote {
            treeLines.append(occlusionNote)
        }

        return AppSnapshot(
            app: app,
            windowTitle: windowTitle,
            windowBounds: windowBounds,
            targetWindowID: windowCapture.windowID,
            targetWindowLayer: windowCapture.layer,
            screenshotData: screenshotData,
            mode: .accessibility,
            treeLines: treeLines,
            focusedSummary: renderer.focusedSummary,
            focusedElement: focusedElement,
            selectedText: selectedText,
            windowElement: rootElement,
            elements: renderer.records,
            screenshotNote: screenshot.note,
            observation: observation
        )
    }

    private static func recoverVisibleWindow(for app: RunningAppDescriptor, appElement: AXUIElement, preferredWindow: AXUIElement?) -> Bool {
        var recovered = false

        if let runningApplication = NSRunningApplication(processIdentifier: app.pid) {
            recovered = runningApplication.unhide() || recovered
            recovered = runningApplication.activate(options: [.activateAllWindows]) || recovered
        }

        if let bundleIdentifier = app.bundleIdentifier {
            recovered = openBundleIdentifier(bundleIdentifier) || recovered
        }

        if let window = preferredWindow ?? firstAnyWindow(for: appElement) {
            recovered = unminimize(window) || recovered
            recovered = raise(window) || recovered
            recovered = setBoolAttribute(named: kAXMainAttribute as String, on: window) || recovered
            recovered = setBoolAttribute(named: kAXFocusedAttribute as String, on: window) || recovered
        }

        if recovered {
            Thread.sleep(forTimeInterval: windowVisibilityRecoveryDelay)
        }

        return recovered
    }

    private static func openBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func firstWindow(for appElement: AXUIElement) -> AXUIElement? {
        guard let windows = copyArray(appElement, attribute: kAXWindowsAttribute) else {
            return nil
        }

        return windows.first(where: isUsableWindowElement(_:))
    }

    private static func firstAnyWindow(for appElement: AXUIElement) -> AXUIElement? {
        copyElement(appElement, attribute: kAXFocusedWindowAttribute)
            ?? copyArray(appElement, attribute: kAXWindowsAttribute)?.first(where: { stringValue(of: $0, attribute: kAXRoleAttribute) == kAXWindowRole as String })
    }

    private static func unminimize(_ window: AXUIElement) -> Bool {
        guard boolValue(of: window, attribute: kAXMinimizedAttribute) == true else {
            return false
        }

        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    }

    private static func raise(_ window: AXUIElement) -> Bool {
        guard copyActions(window)?.contains(where: { $0.caseInsensitiveCompare(kAXRaiseAction as String) == .orderedSame }) == true else {
            return false
        }

        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    private static func setBoolAttribute(named attribute: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue) == .success
    }

    private static func preferredFocusedWindow(appElement: AXUIElement, appPID: pid_t, focusedApplication: AXUIElement?, systemWide: AXUIElement) -> AXUIElement? {
        if let focusedApplication, pid(of: focusedApplication) == appPID {
            return usableWindowElement(from: copyElement(systemWide, attribute: kAXFocusedWindowAttribute))
                ?? usableWindowElement(from: copyElement(focusedApplication, attribute: kAXFocusedWindowAttribute))
                ?? firstWindow(for: focusedApplication)
                ?? usableWindowElement(from: copyElement(appElement, attribute: kAXFocusedWindowAttribute))
                ?? firstWindow(for: appElement)
        }

        return usableWindowElement(from: copyElement(appElement, attribute: kAXFocusedWindowAttribute)) ?? firstWindow(for: appElement)
    }

    private static func usableWindowElement(from element: AXUIElement?) -> AXUIElement? {
        guard let element, isUsableWindowElement(element) else {
            return nil
        }

        return element
    }

    private static func isUsableWindowElement(_ element: AXUIElement) -> Bool {
        stringValue(of: element, attribute: kAXRoleAttribute) == kAXWindowRole as String
            && boolValue(of: element, attribute: kAXMinimizedAttribute) != true
    }

    private static func preferredFocusedElement(appElement: AXUIElement, appPID: pid_t, focusedApplication: AXUIElement?, systemWide: AXUIElement) -> AXUIElement? {
        if let focusedApplication, pid(of: focusedApplication) == appPID {
            return copyElement(systemWide, attribute: kAXFocusedUIElementAttribute)
                ?? copyElement(focusedApplication, attribute: kAXFocusedUIElementAttribute)
                ?? copyElement(appElement, attribute: kAXFocusedUIElementAttribute)
        }

        return copyElement(appElement, attribute: kAXFocusedUIElementAttribute)
    }

    static func buildFixtureSnapshot(app: RunningAppDescriptor, state: FixtureAppState,
                                     observation: SnapshotObservationOptions = .defaults) -> AppSnapshot {
        var lines: [String] = []

        var records: [Int: ElementRecord] = [:]
        let focusedIdentifier = state.focusedIdentifier
        var focusedSummary: String?

        for element in (observation.includeAX ? state.elements.sorted(by: { $0.index < $1.index }) : []) {
            let titleSegment = element.title.map { " \($0)" } ?? ""
            let valueSegment = element.value.map { " Value: \($0)" } ?? ""
            let actionsSegment = element.actions.isEmpty ? "" : " Secondary Actions: \(element.actions.joined(separator: ", "))"
            let focusSegment = focusedIdentifier == element.identifier ? " (focused)" : ""
            lines.append("\(String(repeating: "    ", count: element.index == 0 ? 0 : 1))\(element.index) \(element.role)\(titleSegment)\(focusSegment) ID: \(element.identifier)\(valueSegment)\(actionsSegment) Frame: \(element.frame.cgRect.renderedLocalFrame)")

            let record = ElementRecord(
                index: element.index,
                identifier: element.identifier,
                element: nil,
                localFrame: element.frame.cgRect,
                role: element.role,
                rawActions: element.actions,
                prettyActions: element.actions
            )
            records[element.index] = record

            if focusedIdentifier == element.identifier {
                focusedSummary = "\(element.index) \(element.role)"
            }
        }

        return AppSnapshot(
            app: app,
            windowTitle: state.windowTitle,
            windowBounds: state.windowBounds.cgRect,
            targetWindowID: nil,
            targetWindowLayer: nil,
            screenshotData: nil,
            mode: .fixture,
            treeLines: lines,
            focusedSummary: focusedSummary,
            focusedElement: nil,
            selectedText: observation.includeAX ? state.selectedText : nil,
            windowElement: nil,
            elements: records,
            screenshotNote: observation.includeScreenshot ? nil : SnapshotObservationOptions.screenshotOmittedNote,
            observation: observation
        )
    }
}

/// Returns `true` when the app accepts `AXManualAccessibility`, i.e. it builds
/// its (web) accessibility tree lazily on request. Native AppKit apps report
/// the attribute as unsupported, which is the app-agnostic signal used instead
/// of bundle-identifier lists.
@discardableResult
private func enableBestEffortAccessibilityModes(_ appElement: AXUIElement) -> Bool {
    // Chromium/Electron apps may withhold parts of their AX tree until manual
    // accessibility is enabled. These private attributes are best-effort and
    // harmlessly fail on apps that do not support them.
    let manual = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    return manual == .success
}

private struct WindowCapture {
    let windowID: CGWindowID
    let layer: Int
    let bounds: CGRect
    let image: CGImage?
    var imageConfig = ImageCaptureConfig.defaults

    /// Exact binding: the window the AX tree was walked from.
    static func resolve(for pid: pid_t, exactWindowID: CGWindowID?, capture: Bool = true) -> WindowCapture? {
        guard let exactWindowID,
              let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }
        for info in infoList {
            guard
                let number = info[kCGWindowNumber as String] as? NSNumber, number.uint32Value == exactWindowID,
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                let layer = info[kCGWindowLayer as String] as? Int,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary), !bounds.isEmpty
            else {
                continue
            }
            let config = capture ? ImageCaptureConfig.current : .defaults
            return WindowCapture(windowID: exactWindowID, layer: layer, bounds: bounds, image: capture ? captureImage(windowID: exactWindowID, bounds: bounds, config: config) : nil, imageConfig: config)
        }
        return nil
    }

    static func resolve(for pid: pid_t, titleHint: String?, capture: Bool = true) -> WindowCapture? {
        // On-screen windows first (front-to-back order is meaningful there);
        // fall back to every window of the pid so a window on another Space
        // still resolves instead of triggering the activate-and-raise recovery.
        resolve(for: pid, titleHint: titleHint, options: [.optionOnScreenOnly], capture: capture)
            ?? resolve(for: pid, titleHint: titleHint, options: [.optionAll], capture: capture)
    }

    private static func resolve(for pid: pid_t, titleHint: String?, options: CGWindowListOption, capture: Bool) -> WindowCapture? {
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates = infoList.enumerated().compactMap { offset, info -> WindowCaptureCandidate? in
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == pid,
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let layer = info[kCGWindowLayer as String] as? Int,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return nil
            }

            let title = info[kCGWindowName as String] as? String
            let area = Int(bounds.width * bounds.height)
            return WindowCaptureCandidate(
                windowID: CGWindowID(number.uint32Value),
                layer: layer,
                bounds: bounds,
                title: title,
                area: area,
                frontToBackIndex: offset
            )
        }

        guard let best = preferredWindowCaptureCandidate(candidates, titleHint: titleHint) else {
            return nil
        }

        let config = capture ? ImageCaptureConfig.current : .defaults
        let image = capture ? captureImage(windowID: best.windowID, bounds: best.bounds, config: config) : nil

        return WindowCapture(windowID: best.windowID, layer: best.layer, bounds: best.bounds, image: image, imageConfig: config)
    }

    /// WindowServer's hardware window capture first (any Space, covered or not,
    /// ~10-40ms), ScreenCaptureKit when it is unavailable.
    private static func captureImage(windowID: CGWindowID, bounds: CGRect, config: ImageCaptureConfig) -> CGImage? {
        if !LockedUseActionScope.requiresScreenCaptureKit,
           let image = TimingLog.measure("snapshot.capture_hw", { SkyLightSPI.shared.hardwareCaptureWindow(windowID) }) {
            return image
        }
        return TimingLog.measure("snapshot.capture_sck") { captureImageWithScreenCaptureKit(windowID: windowID, bounds: bounds, config: config) }
    }

    private static func captureImageWithScreenCaptureKit(windowID: CGWindowID, bounds: CGRect, config: ImageCaptureConfig) -> CGImage? {
        try? BlockingAsyncBridge.run(timeout: config.captureTimeout) {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = shareableContent.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let configuration = SCStreamConfiguration()
            let scaleFactor = bestEffortScaleFactor(for: bounds)
            let captureSize = window.frame.isEmpty ? bounds.size : window.frame.size
            configuration.width = max(1, Int(ceil(captureSize.width * scaleFactor)))
            configuration.height = max(1, Int(ceil(captureSize.height * scaleFactor)))
            configuration.showsCursor = false
            configuration.scalesToFit = false
            configuration.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: window)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    private static func bestEffortScaleFactor(for bounds: CGRect) -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.intersects(bounds) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }

    func screenshotResult() -> ScreenshotEncodingResult {
        guard let image else { return ScreenshotEncodingResult(data: nil, note: nil) }
        return encodeScreenshot(for: image, config: imageConfig)
    }

}

struct WindowCaptureCandidate {
    let windowID: CGWindowID
    let layer: Int
    let bounds: CGRect
    let title: String?
    let area: Int
    let frontToBackIndex: Int
}

func preferredWindowCaptureCandidate(_ candidates: [WindowCaptureCandidate], titleHint: String?) -> WindowCaptureCandidate? {
    let usable = candidates
        .filter { $0.layer == 0 && $0.area >= 20_000 }
        .sorted { lhs, rhs in
            lhs.frontToBackIndex < rhs.frontToBackIndex
        }

    guard !usable.isEmpty else {
        return candidates.sorted { lhs, rhs in
            lhs.area > rhs.area
        }.first
    }

    guard let titleHint, !titleHint.isEmpty,
          let hinted = usable.first(where: { $0.title == titleHint })
    else {
        return usable.first
    }

    guard let frontmost = usable.first else {
        return hinted
    }

    if frontmost.windowID != hinted.windowID,
       frontmost.bounds.intersects(hinted.bounds)
    {
        return frontmost
    }

    return hinted
}

func boundedScreenshotPNGData(
    for image: CGImage,
    maxDimension: CGFloat = screenshotResultMaxDimension
) -> Data? {
    boundedScreenshotData(for: image, config: ImageCaptureConfig(
        discardBelowPixelCount: 0, maxDimension: maxDimension
    ))
}

struct ScreenshotEncodingResult {
    let data: Data?
    let note: String?
}

func boundedScreenshotData(for image: CGImage, config: ImageCaptureConfig) -> Data? {
    encodeScreenshot(for: image, config: config).data
}

func encodeScreenshot(for image: CGImage, config: ImageCaptureConfig) -> ScreenshotEncodingResult {
    func omitted(_ reason: String) -> ScreenshotEncodingResult { .init(data: nil, note: "Screenshot omitted: " + reason) }
    guard image.width > 0, image.height > 0 else { return omitted("invalid dimensions") }
    guard config.maxDimension.map({ $0.isFinite && $0 >= 1 && $0.rounded(.down) == $0 }) ?? true else {
        return omitted("invalid image configuration")
    }
    func isTiny(_ width: Int, _ height: Int) -> Bool {
        Double(width) * Double(height) < Double(config.discardBelowPixelCount)
    }
    if isTiny(image.width, image.height) {
        return omitted("\(image.width)×\(image.height) has fewer than \(config.discardBelowPixelCount) pixels")
    }
    let longEdge = CGFloat(max(image.width, image.height))
    if let maximum = config.maxDimension, longEdge > maximum, !config.scaleDownAfterMaxSize {
        return omitted("long edge \(Int(longEdge)) exceeds maxLongEdgePixels \(Int(maximum)); scaleDownAfterMaxSize is false")
    }
    func encode(_ image: CGImage) -> Data? {
        switch config.format {
        case "png": return pngData(for: image)
        case "webp": return losslessWebPData(for: image)
        case "jpg", "jpeg": return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: config.jpegQuality])
        default: return nil
        }
    }
    let scale = min(1, (config.maxDimension ?? longEdge) / longEdge)
    let width = max(1, Int((CGFloat(image.width) * scale).rounded(.down)))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded(.down)))
    if isTiny(width, height) {
        return omitted("resizing would fall below discardBelowPixelCount \(config.discardBelowPixelCount)")
    }
    guard let resized = scale == 1 ? image : resizedCGImage(image, scale: scale),
          let data = encode(resized) else { return omitted("\(config.format) encoding failed") }
    return .init(data: data, note: nil)
}

private func pngData(for image: CGImage) -> Data? {
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])
}

private func resizedCGImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let width = max(1, Int((CGFloat(image.width) * scale).rounded(.down)))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded(.down)))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

private final class AsyncResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

enum BlockingAsyncBridge {
    static func run<T>(timeout: TimeInterval? = nil, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = AsyncResultBox<T>()

        let task = Task.detached {
            do {
                resultBox.result = .success(try await operation())
            } catch {
                resultBox.result = .failure(error)
            }

            semaphore.signal()
        }

        guard waitForSignal(semaphore, timeout: timeout) else {
            task.cancel()
            throw ComputerUseError.message("ScreenCaptureKit screenshot task timed out after \(timeout ?? 0) seconds.")
        }

        return try resultBox.result?.get() ?? {
            throw ComputerUseError.message("ScreenCaptureKit screenshot task finished without producing a result.")
        }()
    }

    private static func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval?) -> Bool {
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }

        if Thread.isMainThread {
            while semaphore.wait(timeout: .now()) == .timedOut {
                if let deadline, Date() >= deadline {
                    return false
                }

                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            return true
        }

        if let timeout {
            return semaphore.wait(timeout: .now() + timeout) == .success
        }

        semaphore.wait()
        return true
    }
}

private struct RenderContext {
    let windowBounds: CGRect?
    let focusedElement: AXUIElement?
    let textLimit: SnapshotTextLimit
    let treeLimits: AccessibilityTreeLimits
}

private struct TreeRenderer {
    let context: RenderContext
    var hasWebArea = false
    var nextIndex = 0
    var lines: [String] = []
    var records: [Int: ElementRecord] = [:]
    var identifierIndex: [String: String] = [:]
    var focusedSummary: String?

    init(context: RenderContext) {
        self.context = context
    }

    mutating func render(_ root: AXUIElement, depth: Int = 0, ancestors: [AXUIElement] = []) {
        guard shouldContinueRendering(nextIndex: nextIndex, depth: depth, limits: context.treeLimits) else {
            return
        }

        guard !ancestors.contains(where: { CFEqual($0, root) }) else {
            return
        }
        let nextAncestors = ancestors + [root]

        let index = nextIndex

        let role = stringValue(of: root, attribute: kAXRoleAttribute) ?? "AXUnknown"
        if role == axWebAreaRole {
            hasWebArea = true
        }
        let subrole = stringValue(of: root, attribute: kAXSubroleAttribute)
        let baseRoleText = roleDescription(of: root, role: role, subrole: subrole)
        let label = stringValue(of: root, attribute: kAXDescriptionAttribute)
            .map { sanitizeText($0, textLimit: context.textLimit) }
        let help = stringValue(of: root, attribute: kAXHelpAttribute)
            .map { sanitizeText($0, textLimit: context.textLimit) }
        let value = sanitizedValue(of: root, textLimit: context.textLimit)
        let axIdentifier = displayIdentifier(stringValue(of: root, attribute: kAXIdentifierAttribute))
        let traits = summarizeTraits(of: root)
        let actions = copyActions(root) ?? []
        let exposesPrimaryClickAction = hasPrimaryClickAction(actions)
        let prettyActions = meaningfulActions(actions, role: role)
        let placeholder = placeholderValue(of: root, textLimit: context.textLimit)
        let webAreaDepth = webAreaDepth(role: role, ancestors: ancestors)
        let localFrame = resolveLocalFrame(of: root, windowBounds: context.windowBounds)
        let rowTexts = role == kAXRowRole as String ? flattenedRowTexts(of: root, textLimit: context.textLimit) : []
        let childElements = children(of: root)
        let hasActionableLinkDescendant =
            (role == kAXGroupRole as String || role == kAXUnknownRole as String)
            && exposesPrimaryClickAction
            && containsActionableLinkDescendant(
                in: childElements,
                textLimit: context.textLimit
            )
        let rendersCompactGenericActionTarget = shouldRenderCompactGenericActionTarget(
            role: role,
            hasPrimaryClickAction: exposesPrimaryClickAction,
            localFrame: localFrame,
            hasActionableLinkDescendant: hasActionableLinkDescendant
        )
        let genericTextSummary: String?
        if hasActionableLinkDescendant {
            genericTextSummary = nil
        } else {
            genericTextSummary = summarizedGenericText(
                of: root,
                role: role,
                childElements: childElements,
                textLimit: context.textLimit,
                minimumTextCount: rendersCompactGenericActionTarget ? 1 : 2
            )
        }
        let summaryImageChildren = genericTextSummary == nil ? [] : summaryImageDescendants(of: root)
        let rendersSummaryAsChildren = !rendersCompactGenericActionTarget
            && shouldRenderGenericTextSummaryAsChildren(
                genericTextSummary,
                summaryImageCount: summaryImageChildren.count
            )
        let title = preferredDisplayTitle(
            for: root,
            role: role,
            label: label,
            identifier: axIdentifier,
            explicitValue: value,
            rowTexts: rowTexts,
            textLimit: context.textLimit
        )
        let linkText = role == "AXLink" ? markdownLinkText(for: root, title: title, label: label, value: value, textLimit: context.textLimit) : nil
        let displayTitle = linkText ?? title
        let inlineRowSummary = outlineRowSummary(for: root, role: role)
        let hidesChildren = shouldSuppressChildren(
            role: role,
            title: displayTitle,
            label: label,
            help: help,
            value: value,
            identifier: axIdentifier,
            traits: traits,
            actions: prettyActions,
            children: childElements,
            genericTextSummary: genericTextSummary
        )
        let roleText = displayRoleText(
            baseRoleText: baseRoleText,
            role: role,
            title: displayTitle,
            label: label,
            suppressChildren: hidesChildren
        )

        if shouldElideNode(
            role: role,
            title: displayTitle,
            label: label,
            value: value,
            identifier: axIdentifier,
            traits: traits,
            actions: prettyActions,
            childCount: childElements.count,
            genericTextSummary: genericTextSummary,
            webAreaDepth: webAreaDepth,
            preservesCompactGenericActionTarget: rendersCompactGenericActionTarget
        ) {
            for child in childElements {
                render(child, depth: depth, ancestors: nextAncestors)
            }
            return
        }

        nextIndex += 1

        let traitsSegment = traits.isEmpty ? "" : " (\(traits.joined(separator: ", ")))"
        let titleSegment = displayTitle.map { " \($0)" } ?? ""
        let rowSummary = inlineRowSummary ?? (rendersSummaryAsChildren ? nil : genericTextSummary)
        let rowSummarySegment = rowSummary.map { " \($0)" } ?? ""
        let labelSegment = formattedLabelSegment(label, title: displayTitle, linkText: linkText, textLimit: context.textLimit)
        let helpSegment = {
            guard let help else {
                return ""
            }
            if help == displayTitle || help == label {
                return ""
            }
            return " Help: \(help)"
        }()
        let urlSegment = formattedURLSegment(for: root, title: displayTitle, label: label, textLimit: context.textLimit)
        let identifierSegment = displayIdentifierSegment(for: root, role: role, identifier: axIdentifier, title: displayTitle)
        let rawValueSegment = formattedValueSegment(for: root, roleText: roleText, title: displayTitle, value: value)
        let valueSegment = formattedValueSegmentWithSeparator(
            rawValueSegment,
            precedingSegments: [labelSegment, helpSegment, urlSegment, identifierSegment]
        )
        let placeholderSegment = formattedPlaceholderSegment(
            placeholder,
            title: displayTitle,
            label: label,
            value: value,
            precedingSegments: [labelSegment, helpSegment, urlSegment, identifierSegment, valueSegment]
        )
        let frameSegment = rendersCompactGenericActionTarget
            ? localFrame.map { " Frame: \($0.renderedLocalFrame)" } ?? ""
            : ""
        let actionsPrefix = shouldCommaSeparateActions(
            title: displayTitle,
            inlineRowSummary: inlineRowSummary,
            genericTextSummary: genericTextSummary,
            segments: [labelSegment, helpSegment, urlSegment, identifierSegment, valueSegment, placeholderSegment]
        ) ? ", Secondary Actions: " : " Secondary Actions: "
        let actionsSegment = prettyActions.isEmpty ? "" : "\(actionsPrefix)\(prettyActions.joined(separator: ", "))"
        let renderedRoleText = rendersCompactGenericActionTarget ? "button" : roleText
        let linePrefix = renderedRoleText.isEmpty ? "\(index)" : "\(index) \(renderedRoleText)"

        let lineBody = "\(linePrefix)\(traitsSegment)\(titleSegment)\(rowSummarySegment)\(labelSegment)\(helpSegment)\(urlSegment)\(identifierSegment)\(valueSegment)\(placeholderSegment)\(frameSegment)"
        lines.append("\(String(repeating: "\t", count: depth))\(lineBody)\(actionsSegment)")

        let record = ElementRecord(
            index: index,
            identifier: axIdentifier,
            element: root,
            localFrame: localFrame,
            role: role,
            rawActions: actions,
            prettyActions: prettyActions
        )
        records[index] = record

        if let axIdentifier, let localFrame {
            identifierIndex[axIdentifier] = "\(axIdentifier) -> \(index) @ \(localFrame.renderedLocalFrame)"
        }

        if let focusedElement = context.focusedElement, CFEqual(focusedElement, root) {
            focusedSummary = lineBody
        }

        if role == kAXRowRole as String, boolValue(of: root, attribute: kAXSelectedAttribute) != true {
            for text in Array(rowTexts.dropFirst()) {
                lines.append(text)
            }
            return
        }

        if rendersSummaryAsChildren, let genericTextSummary {
            renderSyntheticText(genericTextSummary, representedBy: root, depth: depth + 1)
            for image in summaryImageChildren {
                render(image, depth: depth + 1, ancestors: nextAncestors)
            }
            return
        }

        if hidesChildren {
            return
        }

        for child in childElements {
            render(child, depth: depth + 1, ancestors: nextAncestors)
        }
    }

    private mutating func renderSyntheticText(_ text: String, representedBy element: AXUIElement, depth: Int) {
        guard shouldContinueRendering(nextIndex: nextIndex, depth: depth, limits: context.treeLimits) else {
            return
        }

        let index = nextIndex
        nextIndex += 1
        lines.append("\(String(repeating: "\t", count: depth))\(index) text \(text)")

        records[index] = ElementRecord(
            index: index,
            identifier: nil,
            element: element,
            localFrame: resolveLocalFrame(of: element, windowBounds: context.windowBounds),
            rawActions: [],
            prettyActions: [],
            isSyntheticText: true
        )
    }

    private func opaqueIdentifier(for element: AXUIElement) -> String {
        String(CFHash(element))
    }

    private func webAreaDepth(role: String, ancestors: [AXUIElement]) -> Int? {
        if role == axWebAreaRole {
            return 0
        }

        guard let webAreaIndex = ancestors.firstIndex(where: { ancestor in
            stringValue(of: ancestor, attribute: kAXRoleAttribute) == axWebAreaRole
        }) else {
            return nil
        }

        return ancestors.count - webAreaIndex
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        let role = stringValue(of: element, attribute: kAXRoleAttribute)
        let rows = copyArray(element, attribute: kAXRowsAttribute) ?? []
        let visibleChildren = copyArray(element, attribute: axVisibleChildrenAttribute) ?? []
        let attributes = childTraversalAttributes(
            role: role,
            hasRows: !rows.isEmpty,
            hasVisibleChildren: !visibleChildren.isEmpty
        )
        var children: [AXUIElement] = []

        for attribute in attributes {
            let sourceValues: [AXUIElement]
            if attribute == kAXRowsAttribute {
                sourceValues = rows
            } else if attribute == axVisibleChildrenAttribute {
                sourceValues = visibleChildren
            } else {
                sourceValues = copyArray(element, attribute: attribute) ?? []
            }

            let values = attribute == kAXRowsAttribute ? visibleRows(in: sourceValues, parent: element) : sourceValues

            for child in values {
                if shouldSkipChild(child, of: element) {
                    continue
                }

                if !children.contains(where: { CFEqual($0, child) }) {
                    children.append(child)
                }
            }
        }

        return children
    }

    private func containsActionableLinkDescendant(
        in elements: [AXUIElement],
        textLimit: SnapshotTextLimit,
        ancestors: [AXUIElement] = [],
        depth: Int = 0
    ) -> Bool {
        guard depth < 8 else {
            return false
        }

        for element in elements {
            guard !ancestors.contains(where: { CFEqual($0, element) }) else {
                continue
            }

            let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
            if role == "AXLink",
               let url = urlValue(of: element, attribute: kAXURLAttribute, textLimit: textLimit),
               !url.isEmpty
            {
                return true
            }

            if containsActionableLinkDescendant(
                in: children(of: element),
                textLimit: textLimit,
                ancestors: ancestors + [element],
                depth: depth + 1
            ) {
                return true
            }
        }

        return false
    }
}

func childTraversalAttributes(role: String?, hasRows: Bool, hasVisibleChildren: Bool) -> [String] {
    var attributes: [String] = []
    if !(hasRows && usesRowsAsPrimaryRole(role)) && !(hasVisibleChildren && usesVisibleChildrenAsPrimaryRole(role)) {
        attributes.append(kAXChildrenAttribute)
    }
    attributes.append(kAXRowsAttribute)
    attributes.append(axContentsAttribute)
    attributes.append(axVisibleChildrenAttribute)
    return attributes
}

private func usesRowsAsPrimaryRole(_ role: String?) -> Bool {
    return [
        kAXOutlineRole as String,
        kAXListRole as String,
        kAXTableRole as String,
        "AXBrowser",
    ].contains(role)
}

private func usesVisibleChildrenAsPrimaryRole(_ role: String?) -> Bool {
    role == kAXListRole as String
}

private func shouldSkipChild(_ child: AXUIElement, of parent: AXUIElement) -> Bool {
    let parentRole = stringValue(of: parent, attribute: kAXRoleAttribute)
    guard parentRole == kAXMenuBarRole as String else {
        return false
    }

    return stringValue(of: child, attribute: kAXTitleAttribute) == "Apple"
}

func shouldContinueRendering(
    nextIndex: Int,
    depth: Int,
    limits: AccessibilityTreeLimits = .defaults
) -> Bool {
    nextIndex < limits.maxNodeCount && depth < limits.maxDepth
}

private func summarizeTraits(of element: AXUIElement) -> [String] {
    var values: [String] = []

    if boolValue(of: element, attribute: kAXSelectedAttribute) == true {
        values.append("selected")
    }

    if boolValue(of: element, attribute: kAXExpandedAttribute) == true {
        values.append("expanded")
    }

    if boolValue(of: element, attribute: kAXEnabledAttribute) == false {
        values.append("disabled")
    }

    if isSettable(of: element, attribute: kAXValueAttribute) {
        values.append("settable")
    }

    if let valueType = valueTypeTrait(of: element) {
        values.append(valueType)
    }

    return values
}

private func valueTypeTrait(of element: AXUIElement) -> String? {
    guard isSettable(of: element, attribute: kAXValueAttribute) else {
        return nil
    }

    guard let value = attributeValue(of: element, attribute: kAXValueAttribute) else {
        return nil
    }

    if CFGetTypeID(value) == CFStringGetTypeID() {
        return "string"
    }

    if value is NSNumber {
        if numericValueRepresentsBoolean(for: element, value: value) {
            return "boolean"
        }

        return "float"
    }

    return nil
}

private func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let value else {
        return nil
    }

    return (value as! AXUIElement)
}

private func copyArray(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let value else {
        return nil
    }

    return value as? [AXUIElement]
}

private func copyActions(_ element: AXUIElement) -> [String]? {
    var actions: CFArray?
    let error = AXUIElementCopyActionNames(element, &actions)
    guard error == .success else {
        return nil
    }

    return actions as? [String]
}

private func attributeValue(of element: AXUIElement, attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else {
        return nil
    }

    return value
}

private func stringValue(of element: AXUIElement, attribute: String) -> String? {
    guard let value = attributeValue(of: element, attribute: attribute) else {
        return nil
    }

    if CFGetTypeID(value) == CFStringGetTypeID() {
        guard let string = value as? String else {
            return nil
        }

        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }

    return nil
}

private func copySelectedText(_ element: AXUIElement, textLimit: SnapshotTextLimit = .defaults) -> String? {
    guard let value = stringValue(of: element, attribute: kAXSelectedTextAttribute) else {
        return nil
    }

    let sanitized = sanitizeText(value, textLimit: textLimit)
    return sanitized.isEmpty ? nil : sanitized
}

private func boolValue(of element: AXUIElement, attribute: String) -> Bool? {
    guard let value = attributeValue(of: element, attribute: attribute) else {
        return nil
    }

    return value as? Bool
}

private func pid(of element: AXUIElement) -> pid_t {
    var processIdentifier: pid_t = 0
    AXUIElementGetPid(element, &processIdentifier)
    return processIdentifier
}

private func isSettable(of element: AXUIElement, attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    return error == .success && settable.boolValue
}

private func sanitizedValue(of element: AXUIElement, textLimit: SnapshotTextLimit = .defaults) -> String? {
    if let string = stringValue(of: element, attribute: kAXValueAttribute) {
        let sanitized = sanitizeText(string, textLimit: textLimit)
        return sanitized.isEmpty ? nil : sanitized
    }

    guard let value = attributeValue(of: element, attribute: kAXValueAttribute) else {
        return nil
    }

    if let number = value as? NSNumber {
        if numericValueRepresentsBoolean(for: element, value: value) {
            return number.boolValue ? "on" : "off"
        }

        return number.stringValue
    }

    return nil
}

private func placeholderValue(of element: AXUIElement, textLimit: SnapshotTextLimit = .defaults) -> String? {
    for attribute in ["AXPlaceholderValue", "AXPlaceholder"] {
        if let string = stringValue(of: element, attribute: attribute) {
            let sanitized = sanitizeText(string, textLimit: textLimit)
            if !sanitized.isEmpty {
                return sanitized
            }
        }
    }

    return nil
}

private func numericValueRepresentsBoolean(for element: AXUIElement, value: CFTypeRef) -> Bool {
    guard let number = value as? NSNumber else {
        return false
    }

    guard number == 0 || number == 1 else {
        return false
    }

    let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
    let roleText = roleDescription(
        of: element,
        role: role,
        subrole: stringValue(of: element, attribute: kAXSubroleAttribute)
    )

    return roleText == "tab"
        || role == kAXCheckBoxRole as String
        || role == kAXRadioButtonRole as String
}

private func preferredDisplayTitle(
    for element: AXUIElement,
    role: String,
    label: String?,
    identifier: String?,
    explicitValue: String?,
    rowTexts: [String],
    textLimit: SnapshotTextLimit = .defaults
) -> String? {
    if let title = stringValue(of: element, attribute: kAXTitleAttribute), !title.isEmpty {
        return sanitizeText(title, textLimit: textLimit)
    }

    if role == kAXRowRole as String {
        return rowTexts.first
    }

    if (role == kAXOutlineRole as String || role == kAXListRole as String), let identifier {
        return identifier
    }

    if (role == kAXButtonRole as String || role == kAXPopUpButtonRole as String), let label, !label.isEmpty {
        return sanitizeText(label, textLimit: textLimit)
    }

    if role == kAXImageRole as String, let label, !label.isEmpty {
        return sanitizeText(label, textLimit: textLimit)
    }

    if (role == kAXGroupRole as String || role == kAXUnknownRole as String || role == "AXWebArea"),
       let label,
       !label.isEmpty
    {
        return sanitizeText(label, textLimit: textLimit)
    }

    guard roleDescription(of: element, role: role, subrole: stringValue(of: element, attribute: kAXSubroleAttribute)) == "search text field" else {
        return nil
    }

    return explicitValue
}

private func markdownLinkText(
    for element: AXUIElement,
    title: String?,
    label: String?,
    value: String?,
    textLimit: SnapshotTextLimit = .defaults
) -> String? {
    guard let url = urlValue(of: element, attribute: kAXURLAttribute, textLimit: textLimit), !url.isEmpty else {
        return nil
    }

    let text = [label, title, value]
        .compactMap { candidate -> String? in
            guard let candidate else {
                return nil
            }
            let sanitized = sanitizeText(candidate, textLimit: textLimit)
            return sanitized.isEmpty ? nil : sanitized
        }
        .first

    guard let text else {
        return nil
    }

    return "[\(markdownEscapedLinkText(text))](\(url))"
}

private func markdownEscapedLinkText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
}

private func outlineRowSummary(for element: AXUIElement, role: String) -> String? {
    guard role == kAXOutlineRole as String || role == kAXListRole as String else {
        return nil
    }

    guard let allRows = copyArray(element, attribute: kAXRowsAttribute), !allRows.isEmpty else {
        return nil
    }

    let visibleRows = visibleRows(in: allRows, parent: element)
    guard !visibleRows.isEmpty, visibleRows.count < allRows.count else {
        return nil
    }

    return "(showing 0-\(visibleRows.count - 1) of \(allRows.count) items)"
}

private func formattedValueSegment(for element: AXUIElement, roleText: String, title: String?, value: String?) -> String {
    guard let value, !value.isEmpty else {
        return ""
    }

    if roleText == "search text field", title == value {
        return ""
    }

    if title == nil, let role = stringValue(of: element, attribute: kAXRoleAttribute), role == kAXStaticTextRole as String {
        return " \(value)"
    }

    if ["scroll bar", "value indicator"].contains(roleText) {
        return " \(value)"
    }

    if roleText == "text entry area" {
        return " \(value)"
    }

    return " Value: \(value)"
}

func formattedLabelSegment(
    _ label: String?,
    title: String?,
    linkText: String?,
    textLimit: SnapshotTextLimit = .defaults
) -> String {
    guard let label, label != title else {
        return ""
    }

    let sanitizedLabel = sanitizeText(label, textLimit: textLimit)
    guard !sanitizedLabel.isEmpty, sanitizedLabel != title else {
        return ""
    }

    let comparableLabel = markdownEscapedLinkText(sanitizedLabel)
    if let linkText, linkText.hasPrefix("[\(comparableLabel)](") {
        return ""
    }

    return " Description: \(sanitizedLabel)"
}

private func formattedValueSegmentWithSeparator(_ valueSegment: String, precedingSegments: [String]) -> String {
    guard valueSegment.hasPrefix(" Value:"), precedingSegments.contains(where: { !$0.isEmpty }) else {
        return valueSegment
    }

    return ",\(valueSegment)"
}

func formattedPlaceholderSegment(_ placeholder: String?, title: String?, label: String?, value: String?, precedingSegments: [String]) -> String {
    guard let placeholder, !placeholder.isEmpty else {
        return ""
    }

    if placeholder == title || placeholder == label || placeholder == value {
        return ""
    }

    let prefix = precedingSegments.contains(where: { !$0.isEmpty }) || title != nil ? ", Placeholder: " : " Placeholder: "
    return "\(prefix)\(placeholder)"
}

private func shouldCommaSeparateActions(
    title: String?,
    inlineRowSummary: String?,
    genericTextSummary: String?,
    segments: [String]
) -> Bool {
    title != nil
        || inlineRowSummary != nil
        || genericTextSummary != nil
        || segments.contains(where: { !$0.isEmpty })
}

private func formattedURLSegment(
    for element: AXUIElement,
    title: String?,
    label: String?,
    textLimit: SnapshotTextLimit = .defaults
) -> String {
    guard stringValue(of: element, attribute: kAXRoleAttribute) == "AXWebArea" else {
        return ""
    }

    guard let url = urlValue(of: element, attribute: kAXURLAttribute, textLimit: textLimit), !url.isEmpty else {
        return ""
    }

    if url == title || url == label {
        return ""
    }

    return ", URL: \(url)"
}

private func urlValue(
    of element: AXUIElement,
    attribute: String,
    textLimit: SnapshotTextLimit = .defaults
) -> String? {
    guard let value = attributeValue(of: element, attribute: attribute) else {
        return nil
    }

    if CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String {
        let sanitized = sanitizeText(string, textLimit: textLimit)
        return sanitized.isEmpty ? nil : sanitized
    }

    if CFGetTypeID(value) == CFURLGetTypeID(), let url = value as? URL {
        let sanitized = sanitizeText(url.absoluteString, textLimit: textLimit)
        return sanitized.isEmpty ? nil : sanitized
    }

    return nil
}

private func displayIdentifierSegment(for element: AXUIElement, role: String, identifier: String?, title: String?) -> String {
    guard let identifier else {
        return ""
    }

    if (role == kAXOutlineRole as String || role == kAXListRole as String), title == identifier {
        return ""
    }

    return " ID: \(identifier)"
}

private func resolveLocalFrame(of element: AXUIElement, windowBounds: CGRect?) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
    let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
    guard
        positionError == .success,
        sizeError == .success,
        let positionValue,
        let sizeValue
    else {
        return nil
    }

    let positionAXValue = positionValue as! AXValue
    let sizeAXValue = sizeValue as! AXValue
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionAXValue, .cgPoint, &position), AXValueGetValue(sizeAXValue, .cgSize, &size) else {
        return nil
    }

    let frame = CGRect(origin: position, size: size)

    guard let windowBounds else {
        return frame
    }

    return windowRelativeFrame(elementFrame: frame, windowBounds: windowBounds)
}

func shouldElideNode(
    role: String,
    title: String?,
    label: String?,
    value: String?,
    identifier: String?,
    traits: [String],
    actions: [String],
    childCount: Int,
    genericTextSummary: String? = nil,
    webAreaDepth: Int? = nil,
    preservesCompactGenericActionTarget: Bool = false
) -> Bool {
    let genericRoles = [kAXGroupRole as String, kAXUnknownRole as String]
    guard genericRoles.contains(role) else {
        return false
    }

    if preservesCompactGenericActionTarget {
        return false
    }

    if genericTextSummary != nil {
        return false
    }

    if shouldPreserveWebAreaGenericContainer(childCount: childCount, webAreaDepth: webAreaDepth) {
        return false
    }

    if childCount == 1,
       title == nil,
       label == nil,
       value == nil,
       identifier == nil,
       actions.isEmpty,
       traitsAreNonDescriptiveWrapperTraits(traits)
    {
        return true
    }

    return title == nil
        && label == nil
        && value == nil
        && identifier == nil
        && traits.isEmpty
        && actions.isEmpty
}

func shouldPreserveWebAreaGenericContainer(childCount: Int, webAreaDepth: Int?) -> Bool {
    guard childCount > 0, webAreaDepth != nil else {
        return false
    }

    return childCount > 1
}

private func traitsAreNonDescriptiveWrapperTraits(_ traits: [String]) -> Bool {
    traits.isEmpty || traits == ["settable", "string"]
}

func hasPrimaryClickAction(_ actions: [String]) -> Bool {
    let primaryActions = [
        kAXPressAction as String,
        kAXConfirmAction as String,
        "AXOpen",
    ]

    return actions.contains { action in
        primaryActions.contains { $0.caseInsensitiveCompare(action) == .orderedSame }
    }
}

func shouldRenderCompactGenericActionTarget(
    role: String,
    hasPrimaryClickAction: Bool,
    localFrame: CGRect?,
    hasActionableLinkDescendant: Bool = false
) -> Bool {
    guard hasPrimaryClickAction else {
        return false
    }

    // A URL-bearing AXLink is the navigation target. Do not hide it behind a
    // generic action wrapper that happens to expose AXPress as well.
    guard !hasActionableLinkDescendant else {
        return false
    }

    guard role == kAXGroupRole as String || role == kAXUnknownRole as String else {
        return false
    }

    guard let localFrame,
          localFrame.width > 0,
          localFrame.height > 0,
          localFrame.width <= compactGenericActionTargetMaxWidth,
          localFrame.height <= compactGenericActionTargetMaxHeight
    else {
        return false
    }

    return true
}

private func shouldSuppressChildren(
    role: String,
    title: String?,
    label: String?,
    help: String?,
    value: String?,
    identifier: String?,
    traits: [String],
    actions: [String],
    children: [AXUIElement],
    genericTextSummary: String?
) -> Bool {
    if role == kAXMenuBarItemRole as String {
        return true
    }

    if role == "AXLink", title?.hasPrefix("[") == true {
        return true
    }

    return genericTextSummary != nil
}

private func summarizedGenericText(
    of element: AXUIElement,
    role: String,
    childElements: [AXUIElement],
    textLimit: SnapshotTextLimit = .defaults,
    minimumTextCount: Int = 2
) -> String? {
    guard role == kAXGroupRole as String || role == kAXUnknownRole as String else {
        return nil
    }

    guard !childElements.isEmpty else {
        return nil
    }

    guard isPlainGenericTextContainer(element, children: childElements) else {
        return nil
    }

    // A page that bolds the letters typed draws one name as a run of one-letter texts, a blank
    // one between words; spelled, the run reads as the one name the picture shows.
    let pieces = descendantTextsForSummary(of: element, textLimit: textLimit, keepsBlanks: true)
    let texts = spellingSplitLetters(pieces)
    let spelled = texts.count < pieces.filter { !$0.isEmpty }.count
    guard texts.count >= minimumTextCount || spelled else {
        return nil
    }

    guard shouldMergeTextOnlySiblings(texts) else {
        return nil
    }

    let joined = sanitizeText(texts.joined(separator: " "), textLimit: textLimit)
        .replacingOccurrences(of: " : ", with: " :  ")
    return joined.isEmpty ? nil : joined
}

private func summaryImageDescendants(of element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 4 else {
        return []
    }

    let children = copyArray(element, attribute: kAXChildrenAttribute) ?? []
    var images: [AXUIElement] = []

    for child in children {
        let role = stringValue(of: child, attribute: kAXRoleAttribute) ?? ""
        if role == kAXImageRole as String {
            if !images.contains(where: { CFEqual($0, child) }) {
                images.append(child)
            }
        } else {
            for image in summaryImageDescendants(of: child, depth: depth + 1) {
                if !images.contains(where: { CFEqual($0, image) }) {
                    images.append(image)
                }
            }
        }

        if images.count >= 4 {
            return Array(images.prefix(4))
        }
    }

    return images
}

func shouldRenderGenericTextSummaryAsChildren(_ genericTextSummary: String?, summaryImageCount: Int) -> Bool {
    genericTextSummary != nil && summaryImageCount > 0
}

/// The texts a group holds, with each run of one-letter pieces spelled as the words it draws:
/// a blank piece inside a run is the space between two words. Other pieces stay as they are,
/// blanks outside a run are dropped, and a run with no lowercase letter stays letters (a
/// calendar's "S M T W T F S" is not a word).
func spellingSplitLetters(_ pieces: [String]) -> [String] {
    var texts: [String] = [], run = ""
    func close() {
        let words = run.split(whereSeparator: \.isWhitespace)
        if run.contains(where: \.isLowercase) {
            texts.append(words.joined(separator: " "))
        } else {
            texts.append(contentsOf: words.flatMap { $0.map(String.init) })
        }
        run = ""
    }
    for piece in pieces {
        if piece.count <= 1 { run += piece.isEmpty ? " " : piece } else { close(); texts.append(piece) }
    }
    close()
    return texts
}

func shouldMergeTextOnlySiblings(_ texts: [String]) -> Bool {
    if texts.contains("日期") && texts.contains("时间") {
        return false
    }

    if texts.contains(where: isSiblingCounterText(_:)) {
        return false
    }

    if texts.contains(where: isStandaloneTimeRangeText(_:)) {
        return false
    }

    let totalLength = texts.reduce(0) { $0 + $1.count }
    return texts.count <= 8 && totalLength <= 220
}

private func isSiblingCounterText(_ text: String) -> Bool {
    text.range(of: #"^\d+\s*/\s*\d+$"#, options: .regularExpression) != nil
}

private func isStandaloneTimeRangeText(_ text: String) -> Bool {
    text.range(of: #"^\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
}

private func isPlainGenericTextContainer(_ element: AXUIElement, children: [AXUIElement], depth: Int = 0) -> Bool {
    for child in children {
        let childRole = stringValue(of: child, attribute: kAXRoleAttribute) ?? ""

        if childRole == kAXStaticTextRole as String || childRole == kAXImageRole as String {
            continue
        }

        if childRole == "AXLink", summaryTextForLink(child) != nil {
            continue
        }

        if childRole == kAXGroupRole as String || childRole == kAXUnknownRole as String {
            // Crossing this boundary would collapse the actionable child into its parent's text summary.
            if isGenericPrimaryActionSummaryBoundary(
                role: childRole,
                actions: copyActions(child) ?? []
            ) {
                return false
            }

            guard depth < 3 else {
                return false
            }

            if isPlainGenericTextContainer(child, children: copyArray(child, attribute: kAXChildrenAttribute) ?? [], depth: depth + 1) {
                continue
            }
        }

        return false
    }

    return true
}

func isGenericPrimaryActionSummaryBoundary(role: String, actions: [String]) -> Bool {
    let genericRoles = [kAXGroupRole as String, kAXUnknownRole as String]
    return genericRoles.contains(role) && hasPrimaryClickAction(actions)
}

func displayRoleText(
    baseRoleText: String,
    role: String,
    title: String?,
    label: String?,
    suppressChildren: Bool
) -> String {
    if role == kAXMenuBarItemRole as String {
        return ""
    }

    if role == "AXLink" {
        return baseRoleText
    }

    if suppressChildren {
        return "container"
    }

    if baseRoleText == "radio group", role == kAXRadioGroupRole as String, title == nil, label != nil {
        return ""
    }

    return baseRoleText
}

func windowRelativeFrame(elementFrame: CGRect, windowBounds: CGRect) -> CGRect {
    CGRect(
        x: elementFrame.minX - windowBounds.minX,
        y: elementFrame.minY - windowBounds.minY,
        width: elementFrame.width,
        height: elementFrame.height
    )
}

private func roleDescription(of element: AXUIElement, role: String, subrole: String?) -> String {
    if role == kAXRowRole as String {
        return "row"
    }

    if role == kAXGroupRole as String {
        return "container"
    }

    if role == kAXMenuBarItemRole as String {
        return ""
    }

    if role == "AXLink" {
        return "link"
    }

    if role == "AXWebArea" {
        return stringValue(of: element, attribute: kAXRoleDescriptionAttribute) ?? "HTML 内容"
    }

    if let roleDescription = stringValue(of: element, attribute: kAXRoleDescriptionAttribute), !roleDescription.isEmpty {
        return roleDescription.lowercased()
    }

    if let subrole, subrole == kAXStandardWindowSubrole as String {
        return "standard window"
    }

    return humanizeAXToken(role)
}

func meaningfulActions(_ values: [String], role: String) -> [String] {
    let rawActions = meaningfulRawActions(values, role: role)
    let names = rawActions.map(secondaryActionDisplayName(_:))
    return names.indices.map { index in
        let collides = names.indices.contains { other in
            other != index && secondaryActionNamesEquivalent(names[index], names[other])
        }
        // Exact raw-action lookup takes precedence over display-name lookup,
        // including actions omitted from the rendered list.
        let shadowsRawAction = values.contains { rawAction in
            rawAction != rawActions[index]
                && rawAction.caseInsensitiveCompare(names[index]) == .orderedSame
        }
        return collides || shadowsRawAction ? rawActions[index] : names[index]
    }
}

func meaningfulRawActions(_ values: [String], role: String) -> [String] {
    values
        .filter {
            var ignored = [
                kAXPressAction as String,
                "AXShowDefaultUI",
                "AXShowAlternateUI",
                "AXShowMenu",
                "AXConfirm",
                "AXScrollToVisible",
            ]

            if [
                kAXMenuBarRole as String,
                kAXMenuBarItemRole as String,
                kAXMenuRole as String,
                kAXMenuItemRole as String,
            ].contains(role) {
                ignored.append(contentsOf: ["AXCancel", "AXPick"])
            }

            return !ignored.contains($0)
        }
        .filter {
            guard role == kAXScrollAreaRole as String else {
                return true
            }

            if values.contains("AXScrollUpByPage") || values.contains("AXScrollDownByPage") {
                return $0 != "AXScrollLeftByPage" && $0 != "AXScrollRightByPage"
            }

            return true
        }
}

func secondaryActionDisplayName(_ value: String) -> String {
    if let name = accessibilityActionDescriptionName(value) {
        return name
    }

    if value == "AXZoomWindow" {
        return "zoom the window"
    }

    let stripped = value.hasPrefix("AX") ? String(value.dropFirst(2)) : value
    let withoutPage = stripped.replacingOccurrences(of: "ByPage", with: "")
    return splitCamelCase(withoutPage)
}

func secondaryActionNamesEquivalent(_ lhs: String, _ rhs: String) -> Bool {
    !normalizedSecondaryActionCandidates(lhs).isDisjoint(with: normalizedSecondaryActionCandidates(rhs))
}

func accessibilityActionDescriptionName(_ value: String) -> String? {
    guard let nameStart = actionDescriptionValueStart(label: "name", in: value) else {
        return nil
    }

    let nameEnd = ["target", "selector", "button clicked"]
        .compactMap { actionDescriptionLabelStart(label: $0, in: value, from: nameStart) }
        .min() ?? value.endIndex
    let name = value[nameStart..<nameEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

private func actionDescriptionValueStart(label: String, in value: String) -> String.Index? {
    var searchStart = value.startIndex
    while let range = value.range(of: label, options: .caseInsensitive, range: searchStart..<value.endIndex) {
        if range.lowerBound != value.startIndex, !value[value.index(before: range.lowerBound)].isWhitespace {
            searchStart = range.upperBound
            continue
        }

        var cursor = range.upperBound
        while cursor < value.endIndex, value[cursor].isWhitespace {
            cursor = value.index(after: cursor)
        }
        guard cursor < value.endIndex, value[cursor] == ":" else {
            searchStart = range.upperBound
            continue
        }
        cursor = value.index(after: cursor)
        while cursor < value.endIndex, value[cursor].isWhitespace {
            cursor = value.index(after: cursor)
        }
        return cursor
    }
    return nil
}

private func actionDescriptionLabelStart(label: String, in value: String, from start: String.Index) -> String.Index? {
    var searchStart = start
    while let range = value.range(of: label, options: .caseInsensitive, range: searchStart..<value.endIndex) {
        if range.lowerBound != value.startIndex, !value[value.index(before: range.lowerBound)].isWhitespace {
            searchStart = range.upperBound
            continue
        }

        var cursor = range.upperBound
        while cursor < value.endIndex, value[cursor].isWhitespace {
            cursor = value.index(after: cursor)
        }
        guard cursor < value.endIndex, value[cursor] == ":" else {
            searchStart = range.upperBound
            continue
        }
        return range.lowerBound
    }
    return nil
}

private func normalizedSecondaryActionCandidates(_ value: String) -> Set<String> {
    var candidates = Set<String>()
    let normalized = normalizedSecondaryActionName(value)
    if !normalized.isEmpty {
        candidates.insert(normalized)
    }
    if let descriptionName = accessibilityActionDescriptionName(value) {
        candidates.insert(normalizedSecondaryActionName(descriptionName))
    }
    return candidates
}

private func normalizedSecondaryActionName(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

private func humanizeAXToken(_ value: String) -> String {
    let stripped = value.hasPrefix("AX") ? String(value.dropFirst(2)) : value
    return splitCamelCase(stripped).lowercased()
}

private func splitCamelCase(_ value: String) -> String {
    var result = ""
    for character in value {
        if character.isUppercase, !result.isEmpty {
            result.append(" ")
        }
        result.append(character)
    }
    return result
}

func sanitizeText(_ value: String, textLimit: SnapshotTextLimit = .defaults) -> String {
    let collapsed = value
        .replacingOccurrences(of: "\n", with: "\\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if let maxCount = textLimit.maxCount, collapsed.count > maxCount {
        return String(collapsed.prefix(maxCount)) + "..."
    }

    return collapsed
}

private func flattenedRowTexts(
    of element: AXUIElement,
    textLimit: SnapshotTextLimit = .defaults
) -> [String] {
    let cells = copyArray(element, attribute: kAXChildrenAttribute) ?? []
    let texts = cells
        .flatMap { descendantTexts(of: $0, textLimit: textLimit) }
        .map { sanitizeText($0, textLimit: textLimit) }
        .filter { !$0.isEmpty }

    var unique: [String] = []
    var seen: Set<String> = []
    for text in texts {
        if seen.insert(text).inserted {
            unique.append(text)
        }
    }

    return unique
}

private func descendantTexts(
    of element: AXUIElement,
    depth: Int = 0,
    textLimit: SnapshotTextLimit = .defaults
) -> [String] {
    guard depth < 4 else {
        return []
    }

    var values: [String] = []
    let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
    if role == kAXStaticTextRole as String || role == kAXTextFieldRole as String {
        if let value = sanitizedValue(of: element, textLimit: textLimit) {
            values.append(value)
        } else if let title = stringValue(of: element, attribute: kAXTitleAttribute) {
            values.append(sanitizeText(title, textLimit: textLimit))
        }
    }

    for child in copyArray(element, attribute: kAXChildrenAttribute) ?? [] {
        values.append(contentsOf: descendantTexts(of: child, depth: depth + 1, textLimit: textLimit))
    }

    return values
}

private func descendantTextsForSummary(
    of element: AXUIElement,
    depth: Int = 0,
    textLimit: SnapshotTextLimit = .defaults,
    keepsBlanks: Bool = false
) -> [String] {
    guard depth < 8 else {
        return []
    }

    let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
    if role == "AXLink", let linkText = summaryTextForLink(element, textLimit: textLimit) {
        return [linkText]
    }

    if role == kAXStaticTextRole as String || role == kAXTextFieldRole as String {
        if let value = sanitizedValue(of: element, textLimit: textLimit), !value.isEmpty {
            return [value]
        }

        if let title = stringValue(of: element, attribute: kAXTitleAttribute) {
            let sanitized = sanitizeText(title, textLimit: textLimit)
            return sanitized.isEmpty ? [] : [sanitized]
        }
    }

    let texts = (copyArray(element, attribute: kAXChildrenAttribute) ?? [])
        .flatMap { descendantTextsForSummary(of: $0, depth: depth + 1, textLimit: textLimit, keepsBlanks: keepsBlanks) }
    // A blank static text is kept as "": between letters it is the space between two words.
    return keepsBlanks && texts.isEmpty && role == kAXStaticTextRole as String ? [""] : texts
}

private func summaryTextForLink(
    _ element: AXUIElement,
    textLimit: SnapshotTextLimit = .defaults
) -> String? {
    guard let url = urlValue(of: element, attribute: kAXURLAttribute, textLimit: textLimit), !url.isEmpty else {
        return nil
    }

    let childText = (copyArray(element, attribute: kAXChildrenAttribute) ?? [])
        .flatMap { descendantTextsForSummary(of: $0, textLimit: textLimit) }
        .joined(separator: " ")
    let sanitized = sanitizeText(childText, textLimit: textLimit)
    guard !sanitized.isEmpty else {
        return nil
    }

    return summaryMarkdownLinkText(text: sanitized, url: url)
}

func summaryMarkdownLinkText(text: String, url: String) -> String {
    "[\(markdownEscapedLinkText(text))](\(url))"
}

private func visibleRows(in rows: [AXUIElement], parent: AXUIElement) -> [AXUIElement] {
    guard let parentFrame = resolveLocalFrame(of: parent, windowBounds: nil) else {
        return Array(rows.prefix(20))
    }

    let visible = rows.filter { row in
        guard let rowFrame = resolveLocalFrame(of: row, windowBounds: nil) else {
            return false
        }

        return rowFrame.intersects(parentFrame)
    }

    if visible.isEmpty {
        return Array(rows.prefix(20))
    }

    return Array(visible.prefix(20))
}

private func displayIdentifier(_ value: String?) -> String? {
    guard let value, !value.isEmpty, !value.hasPrefix("_NS:") else {
        return nil
    }

    return value
}

private func displayWindowTitle(_ value: String?, appName: String) -> String {
    guard let value, !value.isEmpty else {
        return appName
    }

    if value.hasPrefix("\(appName) –") {
        return appName
    }

    return value
}

private func quoted(_ value: String) -> String {
    "\"\(value)\""
}

private extension CGRect {
    var renderedLocalFrame: String {
        "x=\(Int(origin.x)), y=\(Int(origin.y)), w=\(Int(width)), h=\(Int(height))"
    }
}

enum TargetedAX {
    struct Criteria {
        var text: String?
        var exact: Bool
        var role: String?
        var limit: Int
        var maxNodes: Int
    }

    struct WindowContext {
        let app: RunningAppDescriptor
        let appElement: AXUIElement
        let windowElement: AXUIElement
        let windowID: CGWindowID?
        var windowLayer: Int?
        var windowBounds: CGRect?
        let focusedElement: AXUIElement?
    }

    struct SearchResult {
        let records: [ElementRecord]
        let truncated: Bool
        let stopReason: String?
        let visitedNodes: Int
    }

}

extension SnapshotBuilder {
    /// Resolve a target window read-only: no activation, no raise, no screenshot.
    /// Mirrors the window-finding prologue of `build` without the tree walk or
    /// capture, so it never redirects input or steals focus. `windowID` selects a
    /// specific window; otherwise the app's current focused window is used.
    static func resolveTargetWindow(for app: RunningAppDescriptor, windowID: CGWindowID? = nil) throws -> TargetedAX.WindowContext {
        if app.name == FixtureBridge.appName {
            throw ComputerUseError.message("targeted lookup is not supported for fixture apps")
        }

        guard PermissionDiagnostics.current().accessibilityTrusted else {
            throw ComputerUseError.permissionDenied("Accessibility permission is required. Run `open-computer-use doctor` and grant access to Open Computer Use.")
        }

        let appElement = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        _ = enableBestEffortAccessibilityModes(appElement)
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        let focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)

        let rootWindow: AXUIElement
        if let windowID, let named = windowElement(for: windowID, appElement: appElement) {
            rootWindow = named
        } else if let windowID {
            throw ComputerUseError.stateUnavailable("window_id \(windowID) is not a current window of \(app.bundleIdentifier ?? app.name).")
        } else if let focused = preferredFocusedWindow(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide) {
            rootWindow = focused
        } else {
            throw ComputerUseError.stateUnavailable(computerUseNoWindowFoundMessage)
        }

        AXUIElementSetMessagingTimeout(rootWindow, 0.1)
        guard let axWindowID = SkyLightSPI.shared.windowID(for: rootWindow),
              let meta = WindowCapture.resolve(for: app.pid, exactWindowID: axWindowID, capture: false) else {
            throw ComputerUseError.stateUnavailable("query could not bind this AX window to its current window geometry")
        }
        let focusedElement = preferredFocusedElement(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide)

        return TargetedAX.WindowContext(
            app: app,
            appElement: appElement,
            windowElement: rootWindow,
            windowID: meta.windowID,
            windowLayer: meta.layer,
            windowBounds: meta.bounds,
            focusedElement: focusedElement
        )
    }

    /// Current window bounds and element frame for a queried control, so an action
    /// lands correctly even if the window moved after the query.
    static func currentGeometry(of record: ElementRecord, in context: TargetedAX.WindowContext,
                                criteria: TargetedAX.Criteria) throws -> (TargetedAX.WindowContext, ElementRecord) {
        guard !context.app.runningApplication.isTerminated, let element = record.element else {
            throw ComputerUseError.stateUnavailable("Query target is no longer available; run query again")
        }
        let freshContext = try resolveTargetWindow(for: context.app, windowID: context.windowID)
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard belongsToWindow(element, window: freshContext.windowElement),
              let bounds = freshContext.windowBounds else {
            throw ComputerUseError.stateUnavailable("Query target no longer belongs to its window; run query again")
        }
        let scan = batchScan(element)
        var budget = criteria.maxNodes
        guard scan.role == record.role,
              displayIdentifier(scan.identifier) == record.identifier,
              targetedRecordMatches(criteria, role: scan.role, title: scan.title, description: scan.description, value: scan.value,
                                    help: scan.help, identifier: displayIdentifier(scan.identifier))
                || (ownText(scan) == nil
                    && targetedRecordMatches(criteria, role: scan.role, title: heldText(of: element, budget: &budget), description: nil, value: nil)),
              let frame = scan.globalFrame, !frame.isEmpty, frame.intersects(bounds) else {
            throw ComputerUseError.stateUnavailable("Query target changed or its current position is unavailable; run query again")
        }
        let fresh = makeRecord(element, scan: scan, windowBounds: bounds, index: record.index)
        return (freshContext, fresh)
    }

    private static func belongsToWindow(_ element: AXUIElement, window: AXUIElement) -> Bool {
        if CFEqual(element, window) { return true }
        if let owner = copyElement(element, attribute: kAXWindowAttribute) { return CFEqual(owner, window) }
        var current = element
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        for _ in 0..<64 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            AXUIElementSetMessagingTimeout(current, 0.05)
            guard let parent = copyElement(current, attribute: kAXParentAttribute), !CFEqual(parent, current) else { return false }
            if CFEqual(parent, window) { return true }
            current = parent
        }
        return false
    }

    private static func windowElement(for windowID: CGWindowID, appElement: AXUIElement) -> AXUIElement? {
        copyArray(appElement, attribute: kAXWindowsAttribute)?.first {
            SkyLightSPI.shared.windowID(for: $0) == windowID
        }
    }

    // Attributes read for every visited node, in one batched IPC call. Position
    // and size ride along so we can (a) skip descending into off-screen subtrees
    // and (b) fill the record's frame without another round trip.
    private static let searchScanAttributes: [String] = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXIdentifierAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXHelpAttribute as String,
    ]

    /// Use one bounded traversal so every app has the same visibility and match rules.
    static func targetedSearch(_ criteria: TargetedAX.Criteria, in context: TargetedAX.WindowContext) throws -> TargetedAX.SearchResult {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let expired = { ProcessInfo.processInfo.systemUptime >= deadline }
        var scans: [AXSearchNode: NodeScan] = [:]
        var records: [AXSearchNode: ElementRecord] = [:]
        var order: [AXSearchNode] = []
        var shown: Set<AXSearchNode> = []
        var held: [AXSearchNode: [AXSearchNode]] = [:]
        var textTruncated = false
        var clip: CGRect?
        let root = AXSearchNode(element: context.windowElement)
        let result = try boundedTargetedWalk(root: root, maxNodes: criteria.maxNodes, limit: criteria.limit,
                                            expired: expired, inspect: { node in
            AXUIElementSetMessagingTimeout(node.element, 0.05)
            let scan = batchScan(node.element)
            guard scan.role != nil else { throw ComputerUseError.stateUnavailable("AX node could not be read") }
            scans[node] = scan
            order.append(node)
            if node == root { clip = scan.globalFrame }
            let visible = scan.globalFrame.map { frame in frame.isEmpty || clip.map { frame.intersects($0) } ?? true } ?? true
            if visible { shown.insert(node) }
            if visible, criteria.text != nil, [scan.title, scan.description, scan.value, scan.help].contains(where: { ($0?.count ?? 0) > 1000 }) { textTruncated = true }
            let matches = visible && targetedRecordMatches(criteria, role: scan.role, title: scan.title, description: scan.description, value: scan.value,
                                                           help: scan.help, identifier: displayIdentifier(scan.identifier))
            if matches { records[node] = makeRecord(node.element, scan: scan, windowBounds: context.windowBounds) }
            return (matches, visible)
        }, children: { node, remaining in
            guard !expired() else { return ([], true) }
            let role = scans[node]?.role
            let attributes = role.map { largeContainerRoles.contains($0) } == true
                ? [axVisibleChildrenAttribute, kAXChildrenAttribute as String]
                : [kAXChildrenAttribute as String, "AXContents"]
            for attribute in attributes {
                var count: CFIndex = 0
                let error = AXUIElementGetAttributeValueCount(node.element, attribute as CFString, &count)
                if error == .attributeUnsupported || error == .noValue { continue }
                guard error == .success else { throw ComputerUseError.stateUnavailable("AX child count could not be read") }
                guard count > 0, remaining > 0 else { return ([], count > 0) }
                var values: CFArray?
                guard AXUIElementCopyAttributeValues(node.element, attribute as CFString, 0, min(count, remaining), &values) == .success,
                      let elements = values as? [AXUIElement] else {
                    throw ComputerUseError.stateUnavailable("AX children could not be read")
                }
                let nodes = elements.map { AXSearchNode(element: $0) }
                held[node] = nodes
                return (nodes, count > remaining)
            }
            return ([], false)
        })
        var reason = result.stopReason ?? (textTruncated ? "text_limit" : nil)
        var found = result.matches.compactMap { records[$0] }
        // A node with no text of its own is named by the text it holds, read from the scans the
        // walk already took: no AX call per node.
        if found.count < criteria.limit, criteria.text?.isEmpty == false {
            let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            let named = namedByHeldText(criteria, roles: order.map { scans[$0]?.role },
                                        own: order.map { scans[$0].flatMap(ownText) },
                                        children: order.map { (held[$0] ?? []).compactMap { position[$0] } })
            for hit in named where shown.contains(order[hit.node]) && records[order[hit.node]] == nil {
                let node = order[hit.node]
                found.append(makeRecord(node.element, scan: scans[node]!, windowBounds: context.windowBounds, title: hit.text))
                if found.count >= criteria.limit { reason = reason ?? "limit"; break }
            }
        }
        return .init(records: found, truncated: reason != nil, stopReason: reason, visitedNodes: result.visitedNodes)
    }

    /// What a node shows or says itself; nil when only what it holds can name it.
    private static func ownText(_ scan: NodeScan) -> String? {
        [scan.title, scan.description, scan.value].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The text a node holds, read again before acting on a node the search named by it.
    private static func heldText(of element: AXUIElement, budget: inout Int) -> String {
        AXUIElementSetMessagingTimeout(element, 0.05)
        budget -= 1
        let scan = batchScan(element)
        if let own = ownText(scan) { return own }
        var pieces: [String] = []
        for child in copyArray(element, attribute: kAXChildrenAttribute) ?? [] where budget > 0 {
            pieces.append(heldText(of: child, budget: &budget))
        }
        return spellingSplitLetters(pieces).joined(separator: " ")
    }

    private struct AXSearchNode: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    private static let largeContainerRoles: Set<String> = [
        kAXTableRole as String, kAXOutlineRole as String, kAXListRole as String,
        "AXBrowser", "AXCollection", "AXGrid",
    ]

    private struct NodeScan {
        let role: String?
        let title: String?
        let description: String?
        let value: String?
        let identifier: String?
        let globalFrame: CGRect?
        let help: String?
    }

    /// Read the scan attributes in a single `AXUIElementCopyMultipleAttributeValues`
    /// IPC call (falls back to individual reads if the batch call is unsupported).
    private static func batchScan(_ element: AXUIElement) -> NodeScan {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            searchScanAttributes as CFArray,
            AXCopyMultipleAttributeOptions(),
            &values
        )
        let raw: [AnyObject]
        if error == .success, let array = values as? [AnyObject], array.count == searchScanAttributes.count {
            raw = array
        } else {
            raw = searchScanAttributes.map { attribute -> AnyObject in
                var v: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, attribute as CFString, &v)
                return v ?? (NSNull() as AnyObject)
            }
        }
        func str(_ i: Int) -> String? { (raw[i] as? String).map { String($0.prefix(1001)) } }
        return NodeScan(
            role: str(0), title: str(1), description: str(2), value: str(3), identifier: str(4),
            globalFrame: axFrame(position: raw[5], size: raw[6]),
            help: str(7)
        )
    }

    private static func axFrame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width >= 0, extent.height >= 0 else {
            return nil
        }
        return CGRect(origin: point, size: extent)
    }

    private static func makeRecord(_ element: AXUIElement, scan: NodeScan, windowBounds: CGRect?, index: Int = 0, title: String? = nil) -> ElementRecord {
        let rawActions = copyActions(element) ?? []
        // Reuse the frame from the batched scan; window-relative when we have bounds.
        let localFrame: CGRect?
        if let frame = scan.globalFrame {
            localFrame = windowBounds.map { windowRelativeFrame(elementFrame: frame, windowBounds: $0) } ?? frame
        } else {
            localFrame = resolveLocalFrame(of: element, windowBounds: windowBounds)
        }
        return ElementRecord(
            index: index, // reassigned by the caller when registered
            identifier: displayIdentifier(scan.identifier),
            element: element,
            localFrame: localFrame,
            role: scan.role,
            title: (title ?? [scan.title, scan.description, scan.help].compactMap { $0 }.first { !$0.isEmpty }).map { String($0.prefix(1000)) },
            value: scan.value.map { String($0.prefix(1000)) },
            rawActions: rawActions,
            prettyActions: scan.role.map { meaningfulActions(rawActions, role: $0) } ?? rawActions
        )
    }


}

/// Pure record filter, factored out so it is unit-testable without a live
/// accessibility tree. `text` matches title/description/value, the tooltip (AXHelp)
/// or the identifier the tree prints as `ID:` (substring, or a full match when
/// `exact`); `role` matches the AX role (the AX prefix optional).
func targetedRecordMatches(
    _ criteria: TargetedAX.Criteria,
    role: String?,
    title: String?,
    description: String?,
    value: String?,
    help: String? = nil,
    identifier: String? = nil
) -> Bool {
    if let wantedRole = criteria.role, !targetedRoleEquals(role, wantedRole) {
        return false
    }
    if let wantedText = criteria.text, !wantedText.isEmpty {
        let fields = [title, description, value, help, identifier]
        let hit = fields.contains { field in
            guard let field else { return false }
            if criteria.exact {
                return field.caseInsensitiveCompare(wantedText) == .orderedSame
            }
            return field.range(of: wantedText, options: .caseInsensitive) != nil
        }
        if !hit { return false }
    }
    return true
}

/// Nodes with no text of their own, named by the text they hold, as a person reads it: a page
/// that bolds the letters typed draws one result as a nameless box of one-letter texts ("R",
/// "e", "l"…), and then no node carries the name the picture shows. `own[i]` is node i's own
/// text, `children[i]` the nodes it holds, which come after it in walk order. Returns the
/// smallest such nodes that match, each with the text it holds.
func namedByHeldText(_ criteria: TargetedAX.Criteria, roles: [String?], own: [String?], children: [[Int]]) -> [(node: Int, text: String)] {
    guard criteria.text?.isEmpty == false else { return [] }
    var text = [String](repeating: "", count: own.count)
    var covered = [Bool](repeating: false, count: own.count)
    var hits: [(node: Int, text: String)] = []
    for node in own.indices.reversed() {
        text[node] = own[node] ?? spellingSplitLetters(children[node].map { text[$0] }).joined(separator: " ")
        let matches = targetedRecordMatches(criteria, role: roles[node], title: text[node], description: nil, value: nil)
        let below = children[node].contains { covered[$0] }
        if matches, !below, own[node] == nil { hits.append((node, text[node])) }
        covered[node] = matches || below
    }
    return hits.reversed()
}

/// Role match tolerant of the `AX` prefix ("button" matches "AXButton").
func targetedRoleEquals(_ actual: String?, _ wanted: String) -> Bool {
    guard let actual else { return false }
    func normalize(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespaces).lowercased()
        if r.hasPrefix("ax") { r.removeFirst(2) }
        return r
    }
    return normalize(actual) == normalize(wanted)
}
