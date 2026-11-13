import Foundation

/// Date comparisons that bypass `Date`'s `Comparable` witness.
///
/// On Xcode 26.6 (Swift 6.4.2) / macOS 27.2, debug (`-Onone`) builds resolve the
/// `Date >= Date` / `Date < Date` witness to a null pointer and crash with SIGSEGV
/// (`list_apps`, `BlockingAsyncBridge.waitForSignal`, ...). Release builds inline the
/// comparison and are unaffected. Comparing the underlying reference intervals is
/// semantically identical and works in both configurations.
package extension Date {
    /// `self < other` without the `Comparable` witness.
    func isBefore(_ other: Date) -> Bool {
        timeIntervalSinceReferenceDate < other.timeIntervalSinceReferenceDate
    }

    /// `self >= other` without the `Comparable` witness.
    func isAtOrAfter(_ other: Date) -> Bool {
        timeIntervalSinceReferenceDate >= other.timeIntervalSinceReferenceDate
    }
}
