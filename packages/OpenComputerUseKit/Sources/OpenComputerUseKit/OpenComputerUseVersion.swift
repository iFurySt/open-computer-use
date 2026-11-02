import Foundation

public let openComputerUseVersion = "1.1.3"

public func resolvedOpenComputerUseVersion(bundle: Bundle = .main) -> String {
    if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return version
    }

    return openComputerUseVersion
}
