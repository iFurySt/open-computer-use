import AppKit
import CoreGraphics
import Foundation

struct SoftwareCursorGlyphRenderState {
    let rotation: CGFloat
    let cursorBodyOffset: CGVector
    let fogOffset: CGVector
    let fogOpacity: CGFloat
    let fogScale: CGFloat
    let clickProgress: CGFloat

    init(
        rotation: CGFloat,
        cursorBodyOffset: CGVector,
        fogOffset: CGVector,
        fogOpacity: CGFloat,
        fogScale: CGFloat,
        clickProgress: CGFloat
    ) {
        self.rotation = rotation
        self.cursorBodyOffset = cursorBodyOffset
        self.fogOffset = fogOffset
        self.fogOpacity = fogOpacity
        self.fogScale = fogScale
        self.clickProgress = clickProgress
    }

    var appKitDrawingState: SoftwareCursorGlyphRenderState {
        SoftwareCursorGlyphRenderState(
            rotation: -rotation,
            cursorBodyOffset: CGVector(dx: cursorBodyOffset.dx, dy: -cursorBodyOffset.dy),
            fogOffset: CGVector(dx: fogOffset.dx, dy: -fogOffset.dy),
            fogOpacity: fogOpacity,
            fogScale: fogScale,
            clickProgress: clickProgress
        )
    }
}

enum SoftwareCursorGlyphMetrics {
    static let windowSize = CGSize(width: 126, height: 126)
    static let tipAnchor = CGPoint(x: 60.35, y: 70.3)
    static let referenceImageResourceName = "official-software-cursor-window-252"

    static let pointerSize = CGSize(width: 21, height: 21)
    static let pointerOffset = CGPoint(x: 2.6, y: -3.2)
    static let targetNeutralHeading = -(3 * CGFloat.pi / 4)

    /// Screen-space (y down) heading the fallback contour must be authored at so that
    /// `pointerArtworkRotation` lands its apex on `targetNeutralHeading`.
    ///
    /// The previous -96.5 deg made the fallback point straight down (+132 deg measured) while the
    /// reference artwork rests facing upper-left, so users who run the CLI without the bundled
    /// `Resources` (every non-app build) saw a pointer rotated ~135 deg away from the cursor.
    static let proceduralContourNeutralHeading = -(CGFloat.pi / 4)
    static let pointerArtworkRotation = targetNeutralHeading - proceduralContourNeutralHeading
}

private enum SoftwareCursorGlyphColors {
    static let pointerFill = NSColor(calibratedRed: 0.38, green: 0.36, blue: 0.35, alpha: 0.98)
    static let pointerStroke = NSColor(calibratedWhite: 0.90, alpha: 0.92)
}

enum SoftwareCursorGlyphRenderer {
    nonisolated(unsafe) private static let referenceImage = loadReferenceCursorWindowImage()

    static func draw(
        in bounds: CGRect,
        context: CGContext,
        state: SoftwareCursorGlyphRenderState,
        usesReferenceArtwork: Bool = true
    ) {
        let drawingState = state.appKitDrawingState

        if let referenceImage, usesReferenceArtwork {
            drawReferenceImage(
                referenceImage,
                in: bounds,
                context: context,
                state: drawingState
            )
            return
        }

        let pulse = drawingState.clickProgress
        let fogCenter = CGPoint(
            x: bounds.midX + drawingState.fogOffset.dx,
            y: bounds.midY + drawingState.fogOffset.dy
        )
        let pointerCenter = CGPoint(
            x: bounds.midX + SoftwareCursorGlyphMetrics.pointerOffset.x + drawingState.cursorBodyOffset.dx,
            y: bounds.midY + SoftwareCursorGlyphMetrics.pointerOffset.y + drawingState.cursorBodyOffset.dy + (pulse * 0.35)
        )

        drawFog(
            in: context,
            center: fogCenter,
            pulse: pulse,
            fogOpacity: state.fogOpacity,
            fogScale: state.fogScale
        )
        drawPointer(
            in: context,
            center: pointerCenter,
            rotation: drawingState.rotation,
            clickProgress: pulse,
            cursorBodyOffset: drawingState.cursorBodyOffset,
            boundsMidpoint: CGPoint(x: bounds.midX, y: bounds.midY)
        )
    }

    private static func drawReferenceImage(
        _ image: NSImage,
        in bounds: CGRect,
        context: CGContext,
        state: SoftwareCursorGlyphRenderState
    ) {
        let motionCompression = min(hypot(state.cursorBodyOffset.dx, state.cursorBodyOffset.dy) * 0.008, 0.018)
        let pulseCompression = state.clickProgress * 0.03

        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(
            x: bounds.midX + state.cursorBodyOffset.dx,
            y: bounds.midY + state.cursorBodyOffset.dy
        )
        context.rotate(by: state.rotation)
        context.scaleBy(
            x: 1 - motionCompression - pulseCompression,
            y: 1 + (pulseCompression * 0.4)
        )
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        context.restoreGState()
    }

    private static func drawFog(
        in context: CGContext,
        center: CGPoint,
        pulse: CGFloat,
        fogOpacity: CGFloat,
        fogScale: CGFloat
    ) {
        let radius = ((66 * fogScale) / 2) + (pulse * 1.2)
        let glowRadius = radius * (0.30 + (pulse * 0.025))
        let opacityMultiplier = max(0.28, min(fogOpacity / 0.12, 2.2))
        let colors = [
            NSColor(calibratedRed: 0.38, green: 0.36, blue: 0.35, alpha: (0.40 + (pulse * 0.02)) * opacityMultiplier).cgColor,
            NSColor(calibratedRed: 0.43, green: 0.41, blue: 0.40, alpha: (0.28 + (pulse * 0.015)) * opacityMultiplier).cgColor,
            NSColor(calibratedRed: 0.46, green: 0.44, blue: 0.43, alpha: 0.11 * opacityMultiplier).cgColor,
            NSColor(calibratedWhite: 0.60, alpha: 0.0).cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 0.50, 0.82, 1]
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            return
        }

        context.saveGState()
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()

        let coreColors = [
            NSColor(calibratedRed: 0.41, green: 0.39, blue: 0.38, alpha: (0.020 + (pulse * 0.006)) * opacityMultiplier).cgColor,
            NSColor(calibratedRed: 0.44, green: 0.41, blue: 0.40, alpha: 0.008 * opacityMultiplier).cgColor,
            NSColor(calibratedWhite: 0.80, alpha: 0.0).cgColor,
        ] as CFArray
        let coreLocations: [CGFloat] = [0, 0.62, 1]
        guard let coreGradient = CGGradient(colorsSpace: colorSpace, colors: coreColors, locations: coreLocations) else {
            return
        }

        context.saveGState()
        context.drawRadialGradient(
            coreGradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: glowRadius,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private static func drawPointer(
        in context: CGContext,
        center: CGPoint,
        rotation: CGFloat,
        clickProgress: CGFloat,
        cursorBodyOffset: CGVector,
        boundsMidpoint: CGPoint
    ) {
        let pointerRect = CGRect(
            x: center.x - (SoftwareCursorGlyphMetrics.pointerSize.width / 2),
            y: center.y - (SoftwareCursorGlyphMetrics.pointerSize.height / 2),
            width: SoftwareCursorGlyphMetrics.pointerSize.width,
            height: SoftwareCursorGlyphMetrics.pointerSize.height
        )
        let outerPath = pointerPath(in: pointerRect)

        context.saveGState()
        context.translateBy(
            x: boundsMidpoint.x + cursorBodyOffset.dx,
            y: boundsMidpoint.y + cursorBodyOffset.dy
        )
        context.rotate(by: rotation)
        context.scaleBy(x: 1 - (clickProgress * 0.04), y: 1 + (clickProgress * 0.02))
        context.translateBy(
            x: -(boundsMidpoint.x + cursorBodyOffset.dx),
            y: -(boundsMidpoint.y + cursorBodyOffset.dy)
        )
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: SoftwareCursorGlyphMetrics.pointerArtworkRotation)
        context.translateBy(x: -center.x, y: -center.y)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3.2 + (clickProgress * 1.4)
        shadow.shadowOffset = CGSize(width: 0, height: -0.35)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.11)
        shadow.set()
        NSColor.black.withAlphaComponent(0.05).setFill()
        outerPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        SoftwareCursorGlyphColors.pointerFill.setFill()
        outerPath.fill()

        SoftwareCursorGlyphColors.pointerStroke.setStroke()
        outerPath.lineWidth = 1.55
        outerPath.lineJoinStyle = .round
        outerPath.lineCapStyle = .round
        outerPath.stroke()

        context.restoreGState()
    }

    private static func pointerPath(in rect: CGRect) -> NSBezierPath {
        let contourRows: [(y: CGFloat, minX: CGFloat, maxX: CGFloat)] = [
            (39, 17, 21), (38, 16, 22), (37, 15, 22), (36, 15, 23), (35, 15, 24),
            (34, 15, 24), (33, 14, 25), (32, 14, 25), (31, 14, 26), (30, 14, 27),
            (29, 13, 29), (28, 13, 31), (27, 13, 34), (26, 13, 36), (25, 13, 37),
            (24, 12, 37), (23, 12, 37), (22, 12, 37), (21, 12, 37), (20, 12, 36),
            (19, 11, 36), (18, 11, 34), (17, 11, 32), (16, 11, 30), (15, 10, 27),
            (14, 10, 25), (13, 10, 23), (12, 11, 21), (11, 11, 19), (10, 13, 16),
        ]
        let sourceMinX: CGFloat = 10
        let sourceMaxX: CGFloat = 38
        let sourceMinY: CGFloat = 10
        let sourceMaxY: CGFloat = 39

        func mappedPoint(x: CGFloat, y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + ((x - sourceMinX) / (sourceMaxX - sourceMinX) * rect.width),
                y: rect.minY + ((y - sourceMinY) / (sourceMaxY - sourceMinY) * rect.height)
            )
        }

        let leftBoundary = contourRows.map { mappedPoint(x: $0.minX, y: $0.y) }
        let rightBoundary = contourRows.reversed().map { mappedPoint(x: $0.maxX, y: $0.y) }

        let path = NSBezierPath()
        path.move(to: leftBoundary[0])
        leftBoundary.dropFirst().forEach { path.line(to: $0) }
        rightBoundary.forEach { path.line(to: $0) }
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}

func loadReferenceCursorWindowImage() -> NSImage? {
    if let bundledReference = Bundle.main.url(
        forResource: SoftwareCursorGlyphMetrics.referenceImageResourceName,
        withExtension: "png"
    ), let image = NSImage(contentsOf: bundledReference) {
        return image
    }

    let fileURL = URL(fileURLWithPath: #filePath).standardizedFileURL
    let repoRoot = fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let referenceURL = repoRoot
        .appendingPathComponent("docs/references/codex-computer-use-reverse-engineering/assets/extracted-2026-04-19/\(SoftwareCursorGlyphMetrics.referenceImageResourceName).png")

    return NSImage(contentsOf: referenceURL)
}
