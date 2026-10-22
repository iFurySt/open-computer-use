import CoreGraphics
import Foundation

public struct SnapshotObservationOptions: Equatable, Sendable {
    public var includeAX: Bool
    public var includeScreenshot: Bool
    /// Draw each actionable element's index on the screenshot.
    public var marks: Bool
    /// The part of the window the screenshot shows, as fractions of its width and height.
    public var zoom: CGRect?

    public static let defaults = SnapshotObservationOptions()
    public static let accessibilityOmittedNote = "Accessibility omitted; previous element indexes invalidated. Read AX before element-targeted actions."
    public static let screenshotOmittedNote = "Screenshot omitted by include_screenshot=false"

    public init(includeAX: Bool = true, includeScreenshot: Bool = true, marks: Bool = false, zoom: CGRect? = nil) {
        self.includeAX = includeAX
        self.includeScreenshot = includeScreenshot
        self.marks = marks
        self.zoom = zoom
    }

    public func validate() throws {
        guard includeAX || includeScreenshot else {
            throw ComputerUseError.invalidArguments("At least one of include_ax or include_screenshot must be true")
        }
        // The marks are element indexes drawn on the screenshot; without either there is nothing to draw.
        if marks, !(includeAX && includeScreenshot) {
            throw ComputerUseError.invalidArguments("marks requires include_ax and include_screenshot")
        }
        if let zoom {
            guard includeScreenshot else {
                throw ComputerUseError.invalidArguments("zoom requires include_screenshot")
            }
            // origin and size as given: CGRect.width standardizes a negative width away.
            let (x, y, width, height) = (zoom.origin.x, zoom.origin.y, zoom.size.width, zoom.size.height)
            guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
                  x + width <= 1 + 1e-9, y + height <= 1 + 1e-9
            else {
                throw ComputerUseError.invalidArguments("zoom must be fractions of the window: x and y at least 0, width and height above 0, x + width and y + height at most 1")
            }
        }
    }
}
