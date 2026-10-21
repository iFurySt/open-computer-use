import CoreGraphics

/// Builds the note shown when the target window does not intersect any active
/// display. The comparison is purely geometric, so it is unit-testable and
/// never touches the window server.
func windowDisplayNote(windowBounds: CGRect?, activeDisplayBounds: [CGRect]) -> String? {
    guard let windowBounds, !windowBounds.isEmpty, !activeDisplayBounds.isEmpty else {
        return nil
    }

    let isOnDisplay = activeDisplayBounds.contains { $0.intersects(windowBounds) }
    guard !isOnDisplay else { return nil }

    let x = Int(windowBounds.origin.x.rounded())
    let y = Int(windowBounds.origin.y.rounded())
    let width = Int(windowBounds.width.rounded())
    let height = Int(windowBounds.height.rounded())

    return """
    --- display note ---
    The target window is outside every active display (x=\(x), y=\(y), width=\(width), height=\(height)). Off-display windows commonly expose only their window chrome in the accessibility tree, and coordinate actions may not land. Move the window onto a display, or call get_app_state with window_placement=agent_display, before relying on element frames.
    """
}

/// Active display bounds in Quartz global coordinates, matching the coordinate
/// space of `CGWindowList` window bounds.
func activeDisplayBounds() -> [CGRect] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        return []
    }

    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
    var actualCount: UInt32 = 0
    guard CGGetActiveDisplayList(count, &displayIDs, &actualCount) == .success else {
        return []
    }

    return displayIDs.prefix(Int(actualCount)).map { CGDisplayBounds($0) }
}
