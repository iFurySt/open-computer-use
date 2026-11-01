import AppKit
import CoreImage
import OpenDirectory
import OpenComputerUseKit

/// How the lock-screen shield looks. `minimal` is a plain black surface with no
/// wallpaper, avatar, badge or text, for people who do not want a bright screen
/// while an agent works. The user opts in with
/// `defaults write com.ifuryst.opencomputeruse LockedUseShieldStyle minimal`.
enum ShieldStyle: String {
    case standard, minimal
    static var current: ShieldStyle {
        let raw = UserDefaults(suiteName: "com.ifuryst.opencomputeruse")?.string(forKey: "LockedUseShieldStyle")
        return raw.flatMap(ShieldStyle.init(rawValue:)) ?? .standard
    }
}

/// Local wallpaper files only: never captures the user's desktop or windows.
@MainActor
final class ShieldAppearance: NSView {
    private let style = ShieldStyle.current
    private let wallpaper: NSImage?
    private let diagnostic = NSTextField(labelWithString: "")
    override var isOpaque: Bool { true }

    init(frame: NSRect, screen: NSScreen, message: String) {
        wallpaper = ShieldStyle.current == .minimal ? nil : Self.wallpaper(for: screen)
        super.init(frame: frame)
        if ShieldStyle.current == .minimal { return }
        let avatar = NSImageView()
        avatar.image = Self.avatar() ?? NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        avatar.imageScaling = .scaleAxesIndependently
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 40
        avatar.layer?.masksToBounds = true
        avatar.layer?.backgroundColor = NSColor.darkGray.cgColor
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 20
        badge.layer?.masksToBounds = true
        badge.layer?.borderWidth = 0.5
        badge.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        badge.layer?.backgroundColor = NSColor.darkGray.cgColor
        // Expand the icon's transparent export padding inside the circular
        // clip so its colored artwork fills the badge rather than floating.
        let logo = NSImageView(frame: NSRect(x: -4, y: -4, width: 48, height: 48))
        logo.image = Bundle.main.url(forResource: "OCUShieldLogo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        logo.imageScaling = .scaleAxesIndependently
        badge.addSubview(logo)
        let title = NSTextField(labelWithString: "Open Computer Use is Using Your Mac")
        let subtitle = NSTextField(labelWithString: "Press any key or click to unlock")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 15, weight: .medium)
        diagnostic.font = .systemFont(ofSize: 12)
        for label in [title, subtitle, diagnostic] {
            label.alignment = .center
            label.textColor = .white
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        for view in [avatar, badge, title, subtitle, diagnostic] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -55),
            avatar.widthAnchor.constraint(equalToConstant: 80), avatar.heightAnchor.constraint(equalToConstant: 80),
            badge.widthAnchor.constraint(equalToConstant: 40), badge.heightAnchor.constraint(equalToConstant: 40),
            badge.centerXAnchor.constraint(equalTo: avatar.trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: avatar.bottomAnchor, constant: -8),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 35),
            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            diagnostic.centerXAnchor.constraint(equalTo: centerXAnchor),
            diagnostic.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20)
        ])
        updateMessage(message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func updateMessage(_ message: String) {
        if style == .minimal { return }
        // Only isolated diagnostics have a changing detail. Protected sessions
        // retain exactly the same two lines through authentication and exit.
        diagnostic.stringValue = message == LockedUseShieldStatus.message ? "" : message
    }

    override func draw(_ dirtyRect: NSRect) {
        if style == .minimal { NSColor.black.setFill(); bounds.fill(); return }
        NSColor(calibratedRed: 0.16, green: 0.21, blue: 0.29, alpha: 1).setFill()
        bounds.fill()
        if let wallpaper, wallpaper.size.width > 0, wallpaper.size.height > 0 {
            // The surface overscans the display for the system unlock animation;
            // keep the wallpaper's scale tied to the physical display area.
            let target = NSRect(x: bounds.width / 6, y: bounds.height / 6,
                                width: bounds.width / 1.5, height: bounds.height / 1.5)
            let scale = max(target.width / wallpaper.size.width, target.height / wallpaper.size.height)
            let size = NSSize(width: wallpaper.size.width * scale, height: wallpaper.size.height * scale)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            wallpaper.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
    }

    private static func wallpaper(for screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL,
              let input = CIImage(contentsOf: url), !input.extent.isEmpty else { return nil }
        // Bound work in both independent guardians; clamp edges before blur.
        let scale = min(1, 1600 / max(input.extent.width, input.extent.height))
        let image = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18]).cropped(to: image.extent)
        guard let output = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(blurred, from: image.extent) else { return nil }
        return NSImage(cgImage: output, size: image.extent.size)
    }

    private static func avatar() -> NSImage? {
        // Query only the current local account. No password or Keychain access.
        guard let node = try? ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                           attributes: [kODAttributeTypeJPEGPhoto, kODAttributeTypePicture]) else { return nil }
        if let values = try? record.values(forAttribute: kODAttributeTypeJPEGPhoto),
           let data = values.first as? Data, let image = NSImage(data: data) { return image }
        if let values = try? record.values(forAttribute: kODAttributeTypePicture),
           let path = values.first as? String { return NSImage(contentsOfFile: path) }
        return nil
    }
}
