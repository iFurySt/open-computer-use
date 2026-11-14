import CoreServices
import XCTest
@testable import OpenComputerUseKit

final class AppDiscoveryTests: XCTestCase {
    /// list_apps asks Spotlight only for bundles used in the window and reads the values from the query. It must list
    /// what a scan of every application bundle, read item by item, lists.
    func testRecentAppsMatchAFullSpotlightScan() {
        let cutoff = AppDiscovery.recentUsageCutoff()
        let listed = AppDiscovery.SpotlightAppIndex.recentApps(cutoffDate: cutoff).map {
            "\($0.bundleIdentifier) \($0.lastUsed.map { "\($0)" } ?? "-") \($0.uses ?? -1)"
        }
        XCTAssertEqual(listed, fullScan(cutoff: cutoff))
    }

    private func fullScan(cutoff: Date) -> [String] {
        let ranking = "kMDItemLastUsedDate_Ranking" as CFString, uses = "kMDItemUseCount" as CFString
        let text = #"kMDItemContentType == "com.apple.application-bundle" && kMDItemFSName == "*.app""#
        guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, [ranking, uses] as CFArray) else { return [] }
        let scopes = ["/Applications", "/System/Applications", "/System/Library/CoreServices",
                      NSString(string: "~/Applications").expandingTildeInPath].filter { FileManager.default.fileExists(atPath: $0) }
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        MDQuerySetSortOptionFlagsForAttribute(query, ranking, kMDQueryReverseSortOrderFlag.rawValue)
        MDQuerySetSortOptionFlagsForAttribute(query, uses, kMDQueryReverseSortOrderFlag.rawValue)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var seen: Set<String> = []
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            let item = unsafeBitCast(MDQueryGetResultAtIndex(query, index)!, to: MDItem.self)
            guard let id = MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String, !id.isEmpty,
                  seen.insert(id.lowercased()).inserted,
                  let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
            let bundle = Bundle(url: URL(fileURLWithPath: path))
            guard bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true,
                  bundle?.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
                  let lastUsed = MDItemCopyAttribute(item, ranking) as? Date ?? MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                  lastUsed >= cutoff else { return nil }
            return "\(id) \(lastUsed) \((MDItemCopyAttribute(item, uses) as? NSNumber)?.intValue ?? -1)"
        }
    }
}
