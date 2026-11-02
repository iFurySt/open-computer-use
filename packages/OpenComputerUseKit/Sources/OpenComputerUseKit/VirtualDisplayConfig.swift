import Foundation

/// Virtual displays change the system display arrangement, so creating one
/// requires an explicit host setting in addition to the tool argument.
struct VirtualDisplayConfig: Equatable {
    static let environmentKey = "OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED"
    var enabled = false

    static var current: VirtualDisplayConfig {
        let environment = OCUConfiguration.environment
        var document: [String: Any] = [:]
        do {
            let url = try OCUConfiguration.fileURL(environment: environment)
            if FileManager.default.fileExists(atPath: url.path) {
                guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                document = root
            }
        } catch {
            warn("Cannot read virtual display config: \(error). Using environment/defaults.")
        }
        return resolve(document: document, environment: environment, warning: warn)
    }

    static func resolve(document: [String: Any], environment: [String: String], warning: (String) -> Void = { _ in }) -> VirtualDisplayConfig {
        if let value = environment[environmentKey] {
            if value == "true" || value == "false" { return VirtualDisplayConfig(enabled: value == "true") }
            warning("Invalid \(environmentKey); disabling virtual displays")
            return VirtualDisplayConfig()
        }
        guard let section = document["virtualDisplay"] else { return VirtualDisplayConfig() }
        guard let section = section as? [String: Any] else {
            warning("Invalid virtualDisplay config; disabling virtual displays")
            return VirtualDisplayConfig()
        }
        guard let value = section["enabled"] else { return VirtualDisplayConfig() }
        guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
            warning("Invalid virtualDisplay.enabled; disabling virtual displays")
            return VirtualDisplayConfig()
        }
        return VirtualDisplayConfig(enabled: boolean.boolValue)
    }

    func requireEnabled() throws {
        guard enabled else {
            throw ComputerUseError.message("window_placement 'agent_display' is disabled by virtualDisplay.enabled")
        }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("ocu config: \(message)\n".utf8))
    }
}
