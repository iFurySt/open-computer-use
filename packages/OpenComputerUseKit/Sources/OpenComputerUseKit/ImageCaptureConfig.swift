import Foundation
import CoreGraphics
import Darwin

/// Shared path resolution for native calls and app-agent request forwarding.
public enum OCUConfiguration {
    public static let environmentKeys: Set<String> = [
        "OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED",
        "OPEN_COMPUTER_USE_CONFIG_FILE", "OPEN_COMPUTER_USE_IMAGE_FORMAT",
        "OPEN_COMPUTER_USE_IMAGE_JPEG_QUALITY", "OPEN_COMPUTER_USE_IMAGE_CAPTURE_TIMEOUT",
        "OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION",
        "OPEN_COMPUTER_USE_IMAGE_SCALE_DOWN_AFTER_MAX_SIZE",
        "OPEN_COMPUTER_USE_IMAGE_DISCARD_BELOW_PIXEL_COUNT",
    ]
    public static var environment: [String: String] {
        let keys = environmentKeys.union(["HOME", "XDG_CONFIG_HOME"])
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            getenv(key).map { (key, String(cString: $0)) }
        })
    }
    public static func fileURL(environment: [String: String]) throws -> URL {
        if let override = environment["OPEN_COMPUTER_USE_CONFIG_FILE"], !override.isEmpty {
            guard override.hasPrefix("/") else { throw ConfigError.invalidPath }
            return URL(fileURLWithPath: override)
        }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path) + "/.config"
        guard base.hasPrefix("/") else { throw ConfigError.invalidPath }
        return URL(fileURLWithPath: base).appendingPathComponent("ocu/config.json")
    }
    enum ConfigError: Error { case invalidPath }
}

struct ImageCaptureConfig: Equatable {
    var format = "png"
    var jpegQuality: CGFloat = 0.8
    var captureTimeout: TimeInterval = 5
    var scaleDownAfterMaxSize = true
    var discardBelowPixelCount = 64
    var maxDimension: CGFloat? = 1280
    static let defaults = ImageCaptureConfig()

    static var current: ImageCaptureConfig {
        let env = OCUConfiguration.environment
        var document: [String: Any] = [:]
        do {
            let url = try OCUConfiguration.fileURL(environment: env)
            if FileManager.default.fileExists(atPath: url.path) {
                guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      root["image"] == nil || root["image"] is [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                document = root["image"] as? [String: Any] ?? [:]
            }
        } catch {
            warn("Cannot read config: \(error). Using environment/defaults.")
        }
        return resolve(image: document, environment: env, warning: warn)
    }

    static func resolve(image: [String: Any], environment: [String: String], warning: (String) -> Void = { _ in }) -> ImageCaptureConfig {
        var image = image
        // Compatibility for settings persisted by the first configuration implementation.
        if image["maxLongEdgePixels"] == nil { image["maxLongEdgePixels"] = image["maxDimension"] }
        var result = defaults
        func number(_ name: String, _ envKey: String, _ fallback: Double, min: Double, max: Double, integer: Bool = false) -> Double {
            func valid(_ value: Any, text: Bool) -> Double? {
                let n: Double?
                if text, let raw = value as? String { n = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
                else if let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() { n = raw.doubleValue }
                else { n = nil }
                guard let n, n.isFinite, n >= min, n <= max, !integer || n.rounded(.down) == n else { return nil }
                return n
            }
            var value = fallback
            if let raw = image[name], !(raw is NSNull) {
                if let n = valid(raw, text: false) { value = n } else { warning("Invalid image.\(name); using default") }
            }
            if let raw = environment[envKey], raw != "null" {
                if let n = valid(raw, text: true) { value = n } else { warning("Invalid \(envKey); using file/default") }
            }
            return value
        }
        if let value = image["format"] {
            if let value = value as? String, ["png", "jpg", "jpeg", "webp"].contains(value) { result.format = value == "jpeg" ? "jpg" : value }
            else { warning("Invalid image.format; using png") }
        }
        if let value = environment["OPEN_COMPUTER_USE_IMAGE_FORMAT"] {
            if ["png", "jpg", "jpeg", "webp"].contains(value) { result.format = value == "jpeg" ? "jpg" : value }
            else { warning("Invalid OPEN_COMPUTER_USE_IMAGE_FORMAT; using file/default") }
        }
        result.jpegQuality = number("jpegQuality", "OPEN_COMPUTER_USE_IMAGE_JPEG_QUALITY", 0.8, min: 0, max: 1)
        result.captureTimeout = number("captureTimeout", "OPEN_COMPUTER_USE_IMAGE_CAPTURE_TIMEOUT", 5, min: 0.01, max: 300)
        result.maxDimension = number("maxLongEdgePixels", "OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION", 1280, min: 1, max: 16384, integer: true)
        func boolean(_ name: String, _ key: String, _ fallback: Bool) -> Bool {
            var value = fallback
            if let raw = image[name] {
                if let raw = raw as? NSNumber, CFGetTypeID(raw) == CFBooleanGetTypeID() { value = raw.boolValue }
                else { warning("Invalid image.\(name); using default") }
            }
            if let raw = environment[key] {
                if raw == "true" || raw == "false" { value = raw == "true" }
                else { warning("Invalid \(key); using file/default") }
            }
            return value
        }
        func disabled(_ name: String, _ key: String) -> Bool {
            if let raw = environment[key] {
                if raw == "null" { return true }
                let upper = 16384.0
                if let n = Double(raw), n.isFinite, n >= 1, n <= upper, n.rounded(.down) == n { return false }
            }
            return image[name] is NSNull
        }
        result.scaleDownAfterMaxSize = boolean("scaleDownAfterMaxSize", "OPEN_COMPUTER_USE_IMAGE_SCALE_DOWN_AFTER_MAX_SIZE", true)
        result.discardBelowPixelCount = Int(number("discardBelowPixelCount", "OPEN_COMPUTER_USE_IMAGE_DISCARD_BELOW_PIXEL_COUNT", 64, min: 0, max: 268435456, integer: true))
        if disabled("maxLongEdgePixels", "OPEN_COMPUTER_USE_IMAGE_MAX_DIMENSION") { result.maxDimension = nil }
        return result
    }
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("ocu config: \(message)\n".utf8))
    }
}
