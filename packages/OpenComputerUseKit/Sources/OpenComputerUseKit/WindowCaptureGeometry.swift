import CoreGraphics

/// 窗口截图的几何约束：硬件截图只含屏内部分，出屏或跨屏的窗口必须走整窗捕获，
/// 且结果像素尺寸要和窗口 bounds 等比，否则宁可不给图，也不能让模型按裁剪图算坐标。
enum WindowCaptureGeometry {
    static func isValid(_ bounds: CGRect) -> Bool {
        !bounds.isInfinite && !bounds.isNull
            && [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite)
            && bounds.size.width > 0 && bounds.size.height > 0
    }

    static func matchesFullWindow(pixelSize: CGSize, bounds: CGRect) -> Bool {
        guard
            isValid(bounds), pixelSize.width.isFinite, pixelSize.height.isFinite,
            pixelSize.width > 0, pixelSize.height > 0 else { return false }
        // 等比编码会产生整数像素舍入；不允许把裁剪图分别拉伸到完整窗口。
        let scale = min(pixelSize.width / bounds.width, pixelSize.height / bounds.height)
        return abs(pixelSize.width - bounds.width * scale) <= 2
            && abs(pixelSize.height - bounds.height * scale) <= 2
    }

    /// 单屏内优先硬件截图；出屏、跨屏或覆盖范围异常时使用整窗捕获。
    static func capture(
        bounds: CGRect, displayBounds: [CGRect],
        hardware: () -> CGImage?, fullWindow: () -> CGImage?
    ) -> CGImage? {
        guard isValid(bounds) else { return nil }
        if
            displayBounds.contains(where: { $0.contains(bounds) }),
            let image = hardware(), matchesFullWindow(pixelSize: size(of: image), bounds: bounds) {
            return image
        }
        guard
            let image = fullWindow(),
            matchesFullWindow(pixelSize: size(of: image), bounds: bounds) else { return nil }
        return image
    }

    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    static func size(of image: CGImage) -> CGSize {
        CGSize(width: image.width, height: image.height)
    }
}
