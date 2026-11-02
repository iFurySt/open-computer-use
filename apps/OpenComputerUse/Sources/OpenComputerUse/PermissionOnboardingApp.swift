import AppKit
import ApplicationServices
import OpenComputerUseKit
import QuartzCore

@MainActor
enum PermissionOnboardingApp {
    private static var presentedWindowController: PermissionWindowController?

    static func launch() {
        guard !PermissionDiagnostics.current().allGranted else {
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.applicationIconImage = Branding.makeAppIconImage(size: 256)

        let delegate = PermissionOnboardingAppDelegate()
        application.delegate = delegate
        application.run()
    }

    static func present(terminateOnCompletion: Bool = true) {
        guard !PermissionDiagnostics.current().allGranted else {
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.applicationIconImage = Branding.makeAppIconImage(size: 256)

        let controller = PermissionWindowController(terminateOnCompletion: terminateOnCompletion)
        presentedWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class PermissionOnboardingAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: PermissionWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = PermissionWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class PermissionWindowController: NSWindowController {
    private let contentController = PermissionContentController()
    private lazy var accessoryPanelController = PermissionAccessoryPanelController { [weak self] in
        self?.handleAccessoryPanelBack()
    }
    private let terminateOnCompletion: Bool

    init(terminateOnCompletion: Bool = true) {
        self.terminateOnCompletion = terminateOnCompletion

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PermissionOnboardingLayout.windowWidth,
                height: PermissionOnboardingLayout.windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = PermissionSupport.currentBundleDisplayName()
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        contentViewController = contentController
        contentController.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
extension PermissionWindowController: PermissionContentControllerDelegate {
    func permissionContentController(
        _ controller: PermissionContentController,
        didRequestPermission permission: SystemPermissionKind,
        sourceFrameInScreen: CGRect?
    ) {
        if permission == .accessibility {
            PermissionSupport.requestAccessibilityPrompt()
        }

        PermissionSupport.openSystemSettings(for: permission)
        accessoryPanelController.show(for: permission, sourceFrameInScreen: sourceFrameInScreen)
        contentController.setActiveGuidance(permission)
    }

    func permissionContentControllerDidResolveGuidance(_ controller: PermissionContentController) {
        accessoryPanelController.hide()
    }

    func permissionContentControllerDidRequestRelaunch(_ controller: PermissionContentController) {
        accessoryPanelController.hide()
        relaunchCurrentAppBundle()
    }

    func permissionContentControllerDidCompleteAllPermissions(_ controller: PermissionContentController) {
        accessoryPanelController.hide()
        close()
        if terminateOnCompletion {
            NSApp.terminate(nil)
        }
    }

    private func handleAccessoryPanelBack() {
        accessoryPanelController.hide()
        contentController.setActiveGuidance(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func relaunchCurrentAppBundle() {
        guard let appURL = PermissionSupport.currentAppBundleURL() else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
        NSApp.terminate(nil)
    }
}

@MainActor
protocol PermissionContentControllerDelegate: AnyObject {
    func permissionContentController(
        _ controller: PermissionContentController,
        didRequestPermission permission: SystemPermissionKind,
        sourceFrameInScreen: CGRect?
    )
    func permissionContentControllerDidResolveGuidance(_ controller: PermissionContentController)
    func permissionContentControllerDidRequestRelaunch(_ controller: PermissionContentController)
    func permissionContentControllerDidCompleteAllPermissions(_ controller: PermissionContentController)
}

private enum PermissionOnboardingLayout {
    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 648
    static let outerHorizontalInset: CGFloat = 48
    static let outerTopInset: CGFloat = 40
    static let outerBottomInset: CGFloat = 32
    static let headerIconSize: CGFloat = 96
    static let cardWidth: CGFloat = 744
    static let cardHeight: CGFloat = 106
    static let cardCornerRadius: CGFloat = 24
    static let cardHorizontalInset: CGFloat = 20
    static let cardVerticalInset: CGFloat = 18
    static let cardIconSize: CGFloat = 54
    static let actionButtonWidth: CGFloat = 104
    static let actionButtonHeight: CGFloat = 44
}

@MainActor
final class PermissionContentController: NSViewController {
    weak var delegate: PermissionContentControllerDelegate?

    private let backgroundView = GradientBackgroundView()
    private let stackView = NSStackView()
    private let iconView = AppGlyphView()
    private let titleLabel = NSTextField(labelWithString: "Enable \(PermissionSupport.currentBundleDisplayName())")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "\(PermissionSupport.currentBundleDisplayName()) needs these permissions to use apps on your Mac.\nThese permissions are only used when you ask it to perform tasks.")
    private let cardsContainer = NSStackView()
    private let completionLabel = NSTextField(labelWithString: "All required permissions are enabled.")
    private let refreshTimerInterval: TimeInterval = 0.25
    private let relaunchPromptDelay: TimeInterval = 1.5

    private var activeGuidance: SystemPermissionKind?
    private var refreshTimer: Timer?
    private var diagnostics = PermissionDiagnostics.current()
    private var hasReportedCompletion = false
    private var requestedPermissions: [SystemPermissionKind: Date] = [:]

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        refreshUI()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshTimerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshState()
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTimer?.invalidate()
    }

    func setActiveGuidance(_ permission: SystemPermissionKind?) {
        activeGuidance = permission
        refreshUI()
    }

    private func refreshState() {
        let updated = PermissionDiagnostics.current()
        let previousGuidance = activeGuidance
        let wasAllGranted = diagnostics.allGranted
        diagnostics = updated

        if let activeGuidance, updated.isGranted(activeGuidance) {
            self.activeGuidance = nil
        }

        for permission in SystemPermissionKind.allCases where updated.isGranted(permission) {
            requestedPermissions[permission] = nil
        }

        refreshUI()

        if previousGuidance != nil, activeGuidance == nil {
            delegate?.permissionContentControllerDidResolveGuidance(self)
        }

        if updated.allGranted, !wasAllGranted, !hasReportedCompletion {
            hasReportedCompletion = true
            delegate?.permissionContentControllerDidCompleteAllPermissions(self)
        }
    }

    private func configureUI() {
        view.wantsLayer = true

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backgroundView)

        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 38, weight: .bold)
        titleLabel.textColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        titleLabel.maximumNumberOfLines = 1
        subtitleLabel.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

        cardsContainer.orientation = .vertical
        cardsContainer.alignment = .centerX
        cardsContainer.spacing = 14
        cardsContainer.translatesAutoresizingMaskIntoConstraints = false

        completionLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        completionLabel.textColor = NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.23, alpha: 1)
        completionLabel.isHidden = true

        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.addArrangedSubview(cardsContainer)
        stackView.addArrangedSubview(completionLabel)
        stackView.setCustomSpacing(16, after: iconView)
        stackView.setCustomSpacing(8, after: titleLabel)
        stackView.setCustomSpacing(24, after: subtitleLabel)
        stackView.setCustomSpacing(14, after: cardsContainer)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: PermissionOnboardingLayout.outerHorizontalInset),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PermissionOnboardingLayout.outerHorizontalInset),
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: PermissionOnboardingLayout.outerTopInset),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -PermissionOnboardingLayout.outerBottomInset),

            iconView.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.headerIconSize),
            cardsContainer.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardWidth),
        ])
    }

    private func refreshUI() {
        cardsContainer.arrangedSubviews.forEach { subview in
            cardsContainer.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let orderedPermissions = SystemPermissionKind.allCases
        for permission in orderedPermissions {
            let restartRequired = restartRequired(for: permission)
            if activeGuidance == permission, !diagnostics.isGranted(permission), !restartRequired {
                let placeholder = GuidancePlaceholderView()
                cardsContainer.addArrangedSubview(placeholder)
                placeholder.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardWidth).isActive = true
                continue
            }

            let card = PermissionCardView(permission: permission, diagnostics: diagnostics, restartRequired: restartRequired)
            card.onAllow = { [weak self] requestedPermission, sourceFrameInScreen in
                guard let self else {
                    return
                }

                if self.restartRequired(for: requestedPermission) {
                    self.delegate?.permissionContentControllerDidRequestRelaunch(self)
                    return
                }

                self.requestedPermissions[requestedPermission] = Date()
                self.delegate?.permissionContentController(
                    self,
                    didRequestPermission: requestedPermission,
                    sourceFrameInScreen: sourceFrameInScreen
                )
            }
            cardsContainer.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardWidth).isActive = true
        }

        completionLabel.isHidden = !diagnostics.allGranted
    }

    private func restartRequired(for permission: SystemPermissionKind) -> Bool {
        guard !diagnostics.isGranted(permission), let requestedAt = requestedPermissions[permission] else {
            return false
        }

        return Date().timeIntervalSince(requestedAt) >= relaunchPromptDelay
    }
}

@MainActor
final class PermissionCardView: NSView {
    var onAllow: ((SystemPermissionKind, CGRect?) -> Void)?

    private let permission: SystemPermissionKind
    private let diagnostics: PermissionDiagnostics
    private let restartRequired: Bool
    private weak var actionButton: PrimaryActionButton?

    init(permission: SystemPermissionKind, diagnostics: PermissionDiagnostics, restartRequired: Bool = false) {
        self.permission = permission
        self.diagnostics = diagnostics
        self.restartRequired = restartRequired
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = PermissionOnboardingLayout.cardCornerRadius
        layer?.backgroundColor = NSColor(calibratedWhite: 0.99, alpha: 0.92).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.1).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false

        let iconBackground = NSView()
        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = PermissionOnboardingLayout.cardIconSize / 2
        iconBackground.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.92).cgColor
        iconBackground.layer?.borderWidth = 2
        iconBackground.layer?.borderColor = (
            permission == .accessibility
            ? NSColor.systemBlue.withAlphaComponent(0.28)
            : NSColor(calibratedWhite: 0.82, alpha: 1)
        ).cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = permission == .accessibility ? NSColor.systemBlue : NSColor.systemGray
        icon.image = NSImage(systemSymbolName: permission.symbolName, accessibilityDescription: permission.title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        iconBackground.addSubview(icon)

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let title = NSTextField(labelWithString: permission.title)
        title.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        title.textColor = NSColor(calibratedWhite: 0.18, alpha: 1)

        let subtitle = NSTextField(labelWithString: restartRequired ? "Restart to finish enabling this permission" : permission.subtitle)
        subtitle.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        subtitle.textColor = NSColor(calibratedWhite: 0.42, alpha: 1)

        labels.addArrangedSubview(title)
        labels.addArrangedSubview(subtitle)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(iconBackground)
        content.addArrangedSubview(labels)
        content.addArrangedSubview(spacer)

        if diagnostics.isGranted(permission) {
            let done = StatusChipView(text: "Done", foreground: NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.23, alpha: 1), background: NSColor(calibratedRed: 0.93, green: 0.98, blue: 0.94, alpha: 1))
            content.addArrangedSubview(done)
        } else {
            let button = PrimaryActionButton(title: restartRequired ? "Restart" : "Allow", target: self, action: #selector(handleAllow))
            actionButton = button
            content.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.actionButtonWidth).isActive = true
            button.heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.actionButtonHeight).isActive = true
        }

        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardHeight),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PermissionOnboardingLayout.cardHorizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PermissionOnboardingLayout.cardHorizontalInset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: PermissionOnboardingLayout.cardVerticalInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PermissionOnboardingLayout.cardVerticalInset),

            iconBackground.widthAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardIconSize),
            iconBackground.heightAnchor.constraint(equalToConstant: PermissionOnboardingLayout.cardIconSize),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
        ])
    }

    @objc
    private func handleAllow() {
        onAllow?(permission, actionButtonScreenFrame())
    }

    private func actionButtonScreenFrame() -> CGRect? {
        guard let actionButton, let window = actionButton.window else {
            return nil
        }

        let frameInWindow = actionButton.convert(actionButton.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}

@MainActor
final class GuidancePlaceholderView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = PermissionOnboardingLayout.cardCornerRadius
        layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 0.6).cgColor

        let label = NSTextField(labelWithString: "COMPLETE IN SYSTEM SETTINGS")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 82),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let borderRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(
            roundedRect: borderRect,
            xRadius: PermissionOnboardingLayout.cardCornerRadius,
            yRadius: PermissionOnboardingLayout.cardCornerRadius
        )
        path.setLineDash([6, 6], count: 2, phase: 0)
        path.lineWidth = 1.5
        NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
        path.stroke()
    }
}

@MainActor
final class PermissionAccessoryPanelController {
    private let onBack: () -> Void
    private let windowContextProvider: () -> SystemSettingsWindowContext?
    private let animationTimeProvider: () -> CFTimeInterval
    private let trackingInterval: TimeInterval = 0.15
    private let launchAnimationDuration: TimeInterval = 0.72
    private let launchAnimationResponse = 0.72
    private let launchAnimationDampingFraction = 1.0
    private let launchInitialAlpha: CGFloat = 0.9
    private var panel: NSPanel?
    private var currentPermission: SystemPermissionKind?
    private var workspaceObserver: NSObjectProtocol?
    private var globalDragMonitor: Any?
    private var localDragMonitor: Any?
    private var orderedWindowNumber: Int?
    private var trackingTimer: Timer?
    private var pendingSourceFrameInScreen: CGRect?
    private var didPresentCurrentPanel = false
    private var launchDisplayLink: CADisplayLink?
    private var launchStartTime: CFTimeInterval = 0
    private var launchFromFrame = NSRect.zero
    private var launchToFrame = NSRect.zero
    private var isAnimatingLaunch = false
    private var launchSettleGeneration = 0

    private enum Layout {
        static let panelWidth: CGFloat = 530
        static let panelHeight: CGFloat = 109
        static let screenHorizontalInset: CGFloat = 16
        static let screenBottomInset: CGFloat = 12
        static let windowBottomOverlap: CGFloat = 6
        static let contentLeadingInset: CGFloat = 26
        static let contentTrailingInset: CGFloat = 28
        static let sidebarWidthRatio: CGFloat = 0.29
        static let sidebarWidthMin: CGFloat = 214
        static let sidebarWidthMax: CGFloat = 272
    }

    struct SystemSettingsWindowContext {
        let bounds: CGRect
        let windowNumber: Int
        let permissionListFrame: CGRect?

        init(bounds: CGRect, windowNumber: Int, permissionListFrame: CGRect? = nil) {
            self.bounds = bounds
            self.windowNumber = windowNumber
            self.permissionListFrame = permissionListFrame
        }
    }

    init(
        onBack: @escaping () -> Void,
        windowContextProvider: (() -> SystemSettingsWindowContext?)? = nil,
        animationTimeProvider: @escaping () -> CFTimeInterval = CACurrentMediaTime
    ) {
        self.onBack = onBack
        let reader = PermissionSettingsWindowReader()
        self.windowContextProvider = windowContextProvider ?? { reader.context() }
        self.animationTimeProvider = animationTimeProvider
    }

    func show(for permission: SystemPermissionKind, sourceFrameInScreen: CGRect?) {
        currentPermission = permission
        pendingSourceFrameInScreen = sourceFrameInScreen
        didPresentCurrentPanel = false

        let panel = panel ?? makePanel()
        self.panel = panel

        if let contentView = panel.contentView as? PermissionAccessoryPanelView {
            contentView.configure(permission: permission)
        }

        installObserversIfNeeded()
        startTrackingTimer()
        updatePanelVisibility()
    }

    func hide() {
        stopLaunchAnimation()
        stopTrackingTimer()
        removeObservers()
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        currentPermission = nil
        orderedWindowNumber = nil
        pendingSourceFrameInScreen = nil
        didPresentCurrentPanel = false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.contentView = PermissionAccessoryPanelView(onBack: onBack)
        return panel
    }

    private func installObserversIfNeeded() {
        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updatePanelVisibility()
                    self?.refreshPosition()
                }
            }
        }

        if globalDragMonitor == nil {
            globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshPosition()
                }
            }
        }

        if localDragMonitor == nil {
            localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.refreshPosition()
                }
                return event
            }
        }
    }

    private func removeObservers() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }

        if let globalDragMonitor {
            NSEvent.removeMonitor(globalDragMonitor)
            self.globalDragMonitor = nil
        }

        if let localDragMonitor {
            NSEvent.removeMonitor(localDragMonitor)
            self.localDragMonitor = nil
        }
    }

    private func startTrackingTimer() {
        stopTrackingTimer()
        let timer = Timer(timeInterval: trackingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTrackingTimer() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    func refresh() {
        updatePanelVisibility()
        refreshPosition()
    }

    private func refreshPosition() {
        guard let panel, currentPermission != nil, panel.isVisible,
              let windowContext = windowContextProvider() else {
            return
        }

        position(panel: panel, windowContext: windowContext)
    }

    private func updatePanelVisibility() {
        guard let panel, currentPermission != nil else {
            return
        }

        guard let windowContext = windowContextProvider() else {
            stopLaunchAnimation()
            panel.orderOut(nil)
            return
        }

        let panelWasVisible = panel.isVisible

        if didPresentCurrentPanel == false {
            presentPanel(
                panel: panel,
                from: pendingSourceFrameInScreen,
                relativeTo: windowContext
            )
            didPresentCurrentPanel = true
        } else {
            let previousOrderedWindowNumber = orderedWindowNumber
            orderedWindowNumber = windowContext.windowNumber
            position(panel: panel, windowContext: windowContext)
            if !isAnimatingLaunch {
                panel.alphaValue = 1
            }
            if previousOrderedWindowNumber != windowContext.windowNumber || panelWasVisible == false {
                panel.order(.above, relativeTo: windowContext.windowNumber)
            }
        }

    }

    private func position(panel: NSPanel, windowContext: SystemSettingsWindowContext) {
        guard let origin = preferredPanelOrigin(
            for: panelSize(for: windowContext),
            windowContext: windowContext
        ) else {
            return
        }

        if isAnimatingLaunch {
            launchToFrame = NSRect(origin: origin, size: panelSize(for: windowContext))
            return
        }

        // A hidden panel may retain an interrupted animation's smaller frame.
        let targetFrame = NSRect(origin: origin, size: panelSize(for: windowContext))
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true)
        }
    }

    private func presentPanel(
        panel: NSPanel,
        from sourceFrameInScreen: CGRect?,
        relativeTo windowContext: SystemSettingsWindowContext
    ) {
        guard let targetOrigin = preferredPanelOrigin(
            for: panelSize(for: windowContext),
            windowContext: windowContext
        ) else {
            return
        }

        let targetFrame = NSRect(origin: targetOrigin, size: panelSize(for: windowContext))
        orderedWindowNumber = windowContext.windowNumber

        guard let sourceFrameInScreen, sourceFrameInScreen.isEmpty == false else {
            stopLaunchAnimation()
            panel.alphaValue = 1
            panel.setFrame(targetFrame, display: false)
            panel.order(.above, relativeTo: windowContext.windowNumber)
            return
        }

        stopLaunchAnimation()
        isAnimatingLaunch = true
        launchFromFrame = sourceFrameInScreen
        launchToFrame = targetFrame
        launchStartTime = animationTimeProvider()
        launchSettleGeneration += 1

        panel.alphaValue = launchInitialAlpha
        panel.setFrame(sourceFrameInScreen, display: false)
        panel.order(.above, relativeTo: windowContext.windowNumber)
        stepLaunchAnimation()

        let displayLink = panel.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink.add(to: .main, forMode: .common)
        launchDisplayLink = displayLink
        scheduleLaunchSettlePasses(for: launchSettleGeneration)
    }

    @objc
    private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        stepLaunchAnimation()
    }

    func stepLaunchAnimation() {
        guard let panel else {
            stopLaunchAnimation()
            return
        }

        let elapsed = max(0, animationTimeProvider() - launchStartTime)
        if elapsed >= launchAnimationDuration {
            isAnimatingLaunch = false
            stopLaunchAnimation()
            panel.alphaValue = 1
            updateLaunchTargetFrameIfNeeded()
            panel.setFrame(launchToFrame, display: true)
            if let orderedWindowNumber {
                panel.order(.above, relativeTo: orderedWindowNumber)
            }
            return
        }

        let progress = springProgress(at: elapsed)
        panel.alphaValue = launchInitialAlpha + ((1 - launchInitialAlpha) * progress)
        panel.setFrame(curvedFrame(from: launchFromFrame, to: launchToFrame, progress: progress), display: true)
        if let orderedWindowNumber {
            panel.order(.above, relativeTo: orderedWindowNumber)
        }
    }

    private func stopLaunchAnimation() {
        isAnimatingLaunch = false
        launchDisplayLink?.invalidate()
        launchDisplayLink = nil
    }

    private func updateLaunchTargetFrameIfNeeded() {
        guard
            let windowContext = windowContextProvider(),
            let origin = preferredPanelOrigin(for: panelSize(for: windowContext), windowContext: windowContext)
        else {
            return
        }

        orderedWindowNumber = windowContext.windowNumber
        launchToFrame = NSRect(origin: origin, size: panelSize(for: windowContext))
    }

    private func scheduleLaunchSettlePasses(for generation: Int) {
        let delays: [TimeInterval] = [0.18, 0.42, 0.84, 1.2]

        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.currentPermission != nil, self.launchSettleGeneration == generation else {
                        return
                    }
                    self.updatePanelVisibility()
                    self.refreshPosition()
                }
            }
        }
    }

    private func springProgress(at elapsed: TimeInterval) -> CGFloat {
        let omega = (2 * Double.pi) / launchAnimationResponse
        let t = max(0, elapsed)
        let progress: Double

        if abs(launchAnimationDampingFraction - 1) < 0.0001 {
            progress = 1 - exp(-omega * t) * (1 + (omega * t))
        } else {
            progress = min(1, t / launchAnimationDuration)
        }

        return min(max(progress, 0), 1)
    }

    private func curvedFrame(from: NSRect, to: NSRect, progress: CGFloat) -> NSRect {
        let size = NSSize(
            width: from.size.width + ((to.size.width - from.size.width) * progress),
            height: from.size.height + ((to.size.height - from.size.height) * progress)
        )

        let startCenter = CGPoint(x: from.midX, y: from.midY)
        let endCenter = CGPoint(x: to.midX, y: to.midY)
        let midPoint = CGPoint(
            x: (startCenter.x + endCenter.x) * 0.5,
            y: max(startCenter.y, endCenter.y)
        )
        let distance = hypot(endCenter.x - startCenter.x, endCenter.y - startCenter.y)
        let lift = min(140, max(44, distance * 0.18))
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y + lift)
        let inverse = 1 - progress
        let center = CGPoint(
            x: (inverse * inverse * startCenter.x) + (2 * inverse * progress * controlPoint.x) + (progress * progress * endCenter.x),
            y: (inverse * inverse * startCenter.y) + (2 * inverse * progress * controlPoint.y) + (progress * progress * endCenter.y)
        )

        return NSRect(
            x: center.x - (size.width * 0.5),
            y: center.y - (size.height * 0.5),
            width: size.width,
            height: size.height
        )
    }

    private func panelSize(for context: SystemSettingsWindowContext) -> CGSize {
        CGSize(width: min(Layout.panelWidth, context.permissionListFrame?.width ?? Layout.panelWidth), height: Layout.panelHeight)
    }

    private func preferredPanelOrigin(
        for panelSize: CGSize,
        windowContext: SystemSettingsWindowContext
    ) -> CGPoint? {
        let referenceRect = windowContext.permissionListFrame ?? windowContext.bounds
        let visibleFrame = targetVisibleScreenFrame(for: referenceRect) ?? windowContext.bounds
        let trackRect = windowContext.permissionListFrame ?? systemSettingsContentTrackRect(in: windowContext.bounds)
        let x = clamp(
            trackRect.midX - (panelSize.width / 2),
            lower: visibleFrame.minX + Layout.screenHorizontalInset,
            upper: visibleFrame.maxX - panelSize.width - Layout.screenHorizontalInset
        )
        let edgeOffset = windowContext.permissionListFrame == nil ? Layout.windowBottomOverlap : -8
        let desiredY = referenceRect.minY - panelSize.height + edgeOffset
        let y = max(
            visibleFrame.minY + Layout.screenBottomInset,
            desiredY
        )
        return CGPoint(x: x, y: y)
    }

    private func systemSettingsContentTrackRect(in windowBounds: CGRect) -> CGRect {
        // Fallback when Accessibility cannot provide the list controls.
        let sidebarWidth = clamp(
            windowBounds.width * Layout.sidebarWidthRatio,
            lower: Layout.sidebarWidthMin,
            upper: Layout.sidebarWidthMax
        )
        let contentMinX = min(
            windowBounds.maxX - Layout.contentTrailingInset - 1,
            windowBounds.minX + sidebarWidth + Layout.contentLeadingInset
        )
        let contentMaxX = max(contentMinX + 1, windowBounds.maxX - Layout.contentTrailingInset)
        return CGRect(
            x: contentMinX,
            y: windowBounds.minY,
            width: contentMaxX - contentMinX,
            height: windowBounds.height
        )
    }

    private func targetVisibleScreenFrame(for rect: CGRect) -> CGRect? {
        NSScreen.screens.filter { $0.visibleFrame.intersects(rect) }.max {
            let left = $0.visibleFrame.intersection(rect)
            let right = $1.visibleFrame.intersection(rect)
            return left.width * left.height < right.width * right.height
        }?.visibleFrame
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else {
            return lower
        }

        return min(max(value, lower), upper)
    }
}

@MainActor
final class PermissionAccessoryPanelView: NSView {
    private let onBack: () -> Void
    private let instructionLabel = NSTextField(labelWithString: "")
    private let dragTileView = DraggableAppTileView()

    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    private func setup() {
        let materialView = NSVisualEffectView()
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 20
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.5
        materialView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        addSubview(materialView)

        let tintView = NSView()
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8).cgColor
        materialView.addSubview(tintView)

        let backChrome = NSView()
        backChrome.translatesAutoresizingMaskIntoConstraints = false
        backChrome.wantsLayer = true
        backChrome.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        backChrome.layer?.cornerRadius = 16
        materialView.addSubview(backChrome)

        let backButton = AccessoryBackButton(target: self, action: #selector(handleBack))
        backChrome.addSubview(backButton)

        let arrow = NSImageView()
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Drag upward")
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .bold)
        arrow.contentTintColor = NSColor.systemBlue

        instructionLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        instructionLabel.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.lineBreakMode = .byTruncatingTail
        instructionLabel.maximumNumberOfLines = 1
        instructionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dragTileView.translatesAutoresizingMaskIntoConstraints = false

        materialView.addSubview(arrow)
        materialView.addSubview(instructionLabel)
        materialView.addSubview(dragTileView)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: materialView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),

            backChrome.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 18),
            backChrome.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 52),
            backChrome.widthAnchor.constraint(equalToConstant: 32),
            backChrome.heightAnchor.constraint(equalToConstant: 32),

            backButton.centerXAnchor.constraint(equalTo: backChrome.centerXAnchor),
            backButton.centerYAnchor.constraint(equalTo: backChrome.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 14),
            backButton.heightAnchor.constraint(equalToConstant: 14),

            arrow.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 35),
            arrow.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 10),
            arrow.widthAnchor.constraint(equalToConstant: 28),
            arrow.heightAnchor.constraint(equalToConstant: 28),

            instructionLabel.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 10),
            instructionLabel.centerYAnchor.constraint(equalTo: arrow.centerYAnchor),
            instructionLabel.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -22),

            dragTileView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 64),
            dragTileView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -21),
            dragTileView.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 47),
            dragTileView.heightAnchor.constraint(equalToConstant: 43)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(permission: SystemPermissionKind) {
        instructionLabel.stringValue = permission.dragInstruction
    }

    @objc
    private func handleBack() {
        onBack()
    }
}

@MainActor
final class DraggableAppTileView: NSView, NSDraggingSource {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let iconRect = CGRect(x: 12, y: 8, width: 28, height: 28)
        let icon = currentIcon()
        icon.draw(in: iconRect)

        let title = currentTitle()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.26, alpha: 1),
        ]
        title.draw(at: CGPoint(x: 52, y: 12), withAttributes: attributes)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let bundleURL = PermissionSupport.currentAppBundleURL() else {
            NSSound.beep()
            return
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: snapshotImage())
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    private func currentIcon() -> NSImage {
        if let bundleURL = PermissionSupport.currentAppBundleURL() {
            if let bundle = Bundle(url: bundleURL),
               PermissionSupport.isOpenComputerUseBundleIdentifier(bundle.bundleIdentifier)
            {
                return Branding.makeAppIconImage(size: 128)
            }

            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        return Branding.makeAppIconImage(size: 128)
    }

    private func currentTitle() -> String {
        if let bundleURL = PermissionSupport.currentAppBundleURL() {
            if let bundle = Bundle(url: bundleURL) {
                let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                let bundleName = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
                return displayName ?? bundleName ?? PermissionSupport.bundleDisplayName
            }

            return PermissionSupport.bundleDisplayName
        }

        return PermissionSupport.bundleDisplayName
    }

    private func snapshotImage() -> NSImage {
        let bitmap = bitmapImageRepForCachingDisplay(in: bounds) ?? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

@MainActor
enum Branding {
    static func makeAppIconImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let canvasInset = size * (92.0 / 1024.0)
        let rect = CGRect(origin: .zero, size: image.size).insetBy(dx: canvasInset, dy: canvasInset)
        let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22)

        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.12, green: 0.67, blue: 0.99, alpha: 1),
            NSColor(calibratedRed: 0.94, green: 0.74, blue: 0.93, alpha: 1),
        ])!
        gradient.draw(in: tile, angle: 20)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 256, y: rect.minY + rect.height * (1 - y / 256))
        }

        func scale(_ value: CGFloat) -> CGFloat {
            rect.width * value / 256
        }

        let arc = NSBezierPath()
        arc.move(to: point(74, 156))
        arc.curve(
            to: point(182, 88),
            controlPoint1: point(78, 112),
            controlPoint2: point(136, 72)
        )
        arc.lineWidth = scale(12)
        arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.72).setStroke()
        arc.stroke()

        let pointerShadow = NSBezierPath()
        pointerShadow.move(to: point(129, 102))
        pointerShadow.line(to: point(129, 181))
        pointerShadow.line(to: point(149, 162))
        pointerShadow.line(to: point(161, 193))
        pointerShadow.line(to: point(176, 186))
        pointerShadow.line(to: point(164, 157))
        pointerShadow.line(to: point(192, 152))
        pointerShadow.close()
        NSColor.white.withAlphaComponent(0.14).setFill()
        pointerShadow.fill()

        let pointer = NSBezierPath()
        pointer.move(to: point(126, 98))
        pointer.line(to: point(126, 177))
        pointer.line(to: point(146, 158))
        pointer.line(to: point(158, 189))
        pointer.line(to: point(173, 182))
        pointer.line(to: point(161, 153))
        pointer.line(to: point(189, 148))
        pointer.close()
        pointer.lineWidth = scale(6)
        pointer.lineJoinStyle = .round
        pointer.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.94).setFill()
        pointer.fill()
        NSColor.white.setStroke()
        pointer.stroke()

        image.unlockFocus()
        return image
    }
}

@MainActor
final class GradientBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let gradient = NSGradient(colors: [
            NSColor(calibratedWhite: 0.985, alpha: 1),
            NSColor(calibratedRed: 0.95, green: 0.97, blue: 1, alpha: 1),
            NSColor(calibratedRed: 0.98, green: 0.94, blue: 1, alpha: 1),
        ])!
        gradient.draw(in: bounds, angle: 15)
    }
}

@MainActor
final class AppGlyphView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = Branding.makeAppIconImage(size: PermissionOnboardingLayout.headerIconSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class StatusChipView: NSView {
    init(text: String, foreground: NSColor, background: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = background.cgColor

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = foreground
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let check = NSImageView()
        check.translatesAutoresizingMaskIntoConstraints = false
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: text)
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        check.contentTintColor = foreground
        addSubview(check)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class PrimaryActionButton: NSButton {
    override var isHighlighted: Bool {
        didSet {
            updateAppearance()
        }
    }

    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        updateAttributedTitle()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    private func updateAttributedTitle() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private func updateAppearance() {
        layer?.backgroundColor = (
            isHighlighted
            ? NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.94, alpha: 1)
            : NSColor(calibratedRed: 0.06, green: 0.49, blue: 0.99, alpha: 1)
        ).cgColor
        alphaValue = isEnabled ? 1 : 0.45
    }
}

@MainActor
final class AccessoryBackButton: NSButton {
    override var isHighlighted: Bool {
        didSet {
            alphaValue = isHighlighted ? 0.66 : 1
        }
    }

    init(target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        focusRingType = .none
        image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        contentTintColor = NSColor.labelColor.withAlphaComponent(0.72)
        if let cell = cell as? NSButtonCell {
            cell.imagePosition = .imageOnly
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
