import AppKit
import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

/// The overlay draws the bundled reference artwork when the app bundle ships its `Resources`,
/// and the procedural contour everywhere else (every CLI, Linux and plain `swift build`
/// invocation). Both paths must rest on the same heading, otherwise the fallback pointer points
/// away from the system cursor.
final class SoftwareCursorGlyphDirectionTests: XCTestCase {
    private let tolerance: CGFloat = 15

    func testFallbackMatchesReferenceArtworkHeading() throws {
        guard loadReferenceCursorWindowImage() != nil else {
            throw XCTSkip("reference cursor artwork is not present in this environment")
        }
        let artwork = try apexHeading(usesReferenceArtwork: true)
        let fallback = try apexHeading(usesReferenceArtwork: false)
        XCTAssertEqual(
            fallback,
            artwork,
            accuracy: tolerance,
            "procedural fallback must not be rotated relative to the reference artwork"
        )
    }

    func testFallbackRestsOnTargetHeading() throws {
        let fallback = try apexHeading(usesReferenceArtwork: false)
        XCTAssertEqual(
            fallback,
            SoftwareCursorGlyphMetrics.targetNeutralHeading * 180 / .pi,
            accuracy: tolerance,
            "fallback pointer should face upper-left like the reference artwork"
        )
    }

    /// Heading, in y-down degrees, of the sharpest convex-hull vertex of the rendered pointer.
    ///
    /// The tip is the one corner of the outline that collapses to a point; averaging "farthest
    /// pixel" instead flips between the tip and the two splayed legs, which is why this measured
    /// the geometry rather than the centroid distance.
    private func apexHeading(usesReferenceArtwork: Bool) throws -> CGFloat {
        let size = SoftwareCursorGlyphMetrics.windowSize
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        SoftwareCursorGlyphRenderer.draw(
            in: CGRect(origin: .zero, size: size),
            context: context,
            state: SoftwareCursorGlyphRenderState(
                rotation: 0,
                cursorBodyOffset: CGVector(dx: 0, dy: 0),
                fogOffset: CGVector(dx: 0, dy: 0),
                fogOpacity: 0,
                fogScale: 1,
                clickProgress: 0
            ),
            usesReferenceArtwork: usesReferenceArtwork
        )
        NSGraphicsContext.restoreGraphicsState()

        // The pointer stroke clears this threshold; the fog never reaches it.
        var outline: [CGPoint] = []
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let luminance = (Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])) / 3
                if luminance > 120 {
                    outline.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                }
            }
        }
        XCTAssertGreaterThan(outline.count, 10, "no pointer pixels rendered")

        let hull = convexHull(outline)
        XCTAssertGreaterThan(hull.count, 3, "pointer outline has no hull")

        let centroid = outline.reduce(into: CGPoint.zero) { sum, point in
            sum.x += point.x
            sum.y += point.y
        }
        let center = CGPoint(x: centroid.x / CGFloat(outline.count), y: centroid.y / CGFloat(outline.count))

        var sharpest = (interiorAngle: CGFloat.infinity, heading: CGFloat.zero)
        for index in hull.indices {
            let previous = hull[(index + hull.count - 1) % hull.count]
            let corner = hull[index]
            let next = hull[(index + 1) % hull.count]
            let incoming = CGVector(dx: previous.x - corner.x, dy: previous.y - corner.y)
            let outgoing = CGVector(dx: next.x - corner.x, dy: next.y - corner.y)
            let cosine = (incoming.dx * outgoing.dx + incoming.dy * outgoing.dy)
                / (hypot(incoming.dx, incoming.dy) * hypot(outgoing.dx, outgoing.dy))
            let interiorAngle = acos(max(-1, min(1, cosine)))
            if interiorAngle < sharpest.interiorAngle {
                sharpest = (interiorAngle, atan2(corner.y - center.y, corner.x - center.x) * 180 / .pi)
            }
        }
        return sharpest.heading
    }

    private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ origin: CGPoint, _ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
            (lhs.x - origin.x) * (rhs.y - origin.y) - (lhs.y - origin.y) * (rhs.x - origin.x)
        }
        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}
