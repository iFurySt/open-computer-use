import AppKit
import CoreGraphics
import CoreText

// Set-of-marks: get_app_state(marks: true) outlines each actionable element on the screenshot
// and labels it with its element_index, so a vision model reads a number off the picture and
// passes it to click, set_value or the other element actions. No second index space.

/// The numbers' size in the delivered picture's pixels: about the size of the window's own text.
private let markFontSize: CGFloat = 11
/// One colour for an outline and its label, so the eye joins them; neighbours differ.
/// Each is dark enough for a white number.
private let markColors: [CGColor] = [
    CGColor(red: 0.80, green: 0.10, blue: 0.10, alpha: 1),
    CGColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1),
    CGColor(red: 0.05, green: 0.50, blue: 0.15, alpha: 1),
    CGColor(red: 0.55, green: 0.15, blue: 0.75, alpha: 1),
    CGColor(red: 0.75, green: 0.35, blue: 0.00, alpha: 1),
    CGColor(red: 0.00, green: 0.45, blue: 0.50, alpha: 1),
]
/// Actions that make an element worth a mark. AXShowMenu alone does not: web content puts it
/// on almost every group.
private let markActions: Set<String> = ["AXPress", "AXPick", "AXConfirm", "AXOpen", "AXIncrement", "AXDecrement"]
private let markFieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

/// An element's outline and the element_index drawn on it.
struct ScreenshotMark: Equatable {
    let number: Int
    let box: CGRect
}

/// The actionable elements of a tree, in index order, outlined by their window-point frames:
/// what is enabled and can be pressed, typed into or (a row) chosen by a click, and lies inside the window.
func screenshotMarks(for records: [Int: ElementRecord], windowSize: CGSize) -> [ScreenshotMark] {
    let window = CGRect(origin: .zero, size: windowSize)
    return records.values.sorted { $0.index < $1.index }.compactMap { record in
        guard !record.isSyntheticText, record.isEnabled, let frame = record.localFrame,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              !frame.isEmpty, window.intersects(frame),
              record.role.map({ markFieldRoles.contains($0) || $0 == kAXRowRole as String }) == true
                || record.rawActions.contains(where: markActions.contains)
        else { return nil }
        return ScreenshotMark(number: record.index, box: frame)
    }
}

/// The part of a size that a zoom box, given as fractions, covers: window points or capture pixels.
func zoomRegion(_ zoom: CGRect, of size: CGSize) -> CGRect {
    CGRect(x: zoom.origin.x * size.width, y: zoom.origin.y * size.height,
           width: zoom.size.width * size.width, height: zoom.size.height * size.height)
}

/// Marks given in the units of `region` (the part of the window a picture shows), moved onto
/// the pixels of a picture of `size`.
func rescaledScreenshotMarks(_ marks: [ScreenshotMark], from region: CGRect, to size: CGSize) -> [ScreenshotMark] {
    guard region.width > 0, region.height > 0 else { return [] }
    let x = size.width / region.width, y = size.height / region.height
    return marks.map {
        ScreenshotMark(number: $0.number, box: CGRect(x: ($0.box.minX - region.minX) * x, y: ($0.box.minY - region.minY) * y,
                                                      width: $0.box.width * x, height: $0.box.height * y))
    }
}

/// The picture with each mark outlined and numbered. `marks` are in the picture's pixels,
/// top-left origin; the part of a box outside the picture is left off, and a box wholly
/// outside it gets no mark. Drawn at the picture's final size, so every number keeps whole pixels.
func drawingScreenshotMarks(_ marks: [ScreenshotMark], on image: CGImage) -> CGImage? {
    let picture = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: picture)
    // From here the origin is the top-left corner, as in the boxes.
    context.translateBy(x: 0, y: picture.height)
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

    let font = NSFont.boldSystemFont(ofSize: markFontSize)
    let shown = marks.map { ($0.number, $0.box.integral.intersection(picture)) }.filter { !$0.1.isEmpty }
    let numbers = shown.map { number, _ in
        CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]))
    }
    let labels = screenshotMarkLabels(boxes: shown.map(\.1), sizes: numbers.map(labelSize), in: picture)
    // Every outline first, then every label, so no outline crosses a number.
    for (position, (_, box)) in shown.enumerated() {
        context.setStrokeColor(markColors[position % markColors.count])
        context.stroke(box.insetBy(dx: 0.5, dy: 0.5), width: 1)
    }
    for (position, label) in labels.enumerated() {
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(numbers[position], &ascent, nil, nil)
        context.setFillColor(markColors[position % markColors.count])
        context.fill(label)
        context.textPosition = CGPoint(x: label.minX + 2, y: label.minY + ascent.rounded())
        CTLineDraw(numbers[position], context)
    }
    return context.makeImage()
}

/// Where each box's number goes, in the boxes' order: outside its top-left corner, above it or
/// else to its left, when that spot is in the picture and covers no other label and no other
/// box; otherwise inside the corner, moved right past any label already there.
func screenshotMarkLabels(boxes: [CGRect], sizes: [CGSize], in picture: CGRect) -> [CGRect] {
    var labels: [CGRect] = []
    for (box, size) in zip(boxes, sizes) {
        let above = CGRect(origin: CGPoint(x: box.minX, y: box.minY - size.height), size: size)
        let left = CGRect(origin: CGPoint(x: box.minX - size.width, y: box.minY), size: size)
        let coversALabel = { (spot: CGRect) in labels.contains { $0.intersects(spot) } }
        // A box around this one (a row around its button) is not a neighbour: its corner is elsewhere.
        let coversABox = { (spot: CGRect) in boxes.contains { $0.intersects(spot) && !$0.contains(box) } }
        if let outside = [above, left].first(where: { picture.contains($0) && !coversALabel($0) && !coversABox($0) }) {
            labels.append(outside)
            continue
        }
        // Inside the corner, pulled into the picture when the box lies on its edge.
        var inside = CGRect(origin: CGPoint(x: min(box.minX, picture.maxX - size.width),
                                            y: min(box.minY, picture.maxY - size.height)), size: size)
        while coversALabel(inside) {
            inside.origin.x += size.width
        }
        labels.append(inside)
    }
    return labels
}

private func labelSize(of number: CTLine) -> CGSize {
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(number, &ascent, &descent, nil))
    return CGSize(width: (width + 4).rounded(.up), height: (ascent + descent).rounded(.up))
}
