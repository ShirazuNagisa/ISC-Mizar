// 从 PNG 的**顶部**裁一条出来。
//
//	swift Scripts/crop-top.swift <输入.png> <输出.png> <高度>
//
// # 为什么需要它（而不是用 sips）
//
// `sips -c` 只从**中心**裁，而 `--cropOffset` 并不是"从左上角偏移"：
// 实测 `sips -c 247 1640 --cropOffset 0 0 in.png` 裁出来的是屏幕中间那一条，
// 而给一个能把它顶到最上面的负偏移（-1056）会得到一张全黑的图（越界）。
// 而演示横幅恰好在最上面 —— 状态栏之下那一条。
//
// # 为什么用 Swift 而不是 Python + Pillow
//
// 这台机器上的 python3 没有 Pillow。为了让一张截图去要求一个图像库，
// 换来的是一条"跑不通就跳过"的静默降级 —— 而那张横幅是验收要求的证据
// 之一。Swift 工具链是这个仓库本来就依赖的东西（Package.swift 的
// tools-version 是 6.4），因此这个脚本没有任何额外前提。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("crop-top: \(message)\n".utf8))
    exit(1)
}

guard arguments.count == 4 else {
    fail("用法：swift Scripts/crop-top.swift <输入.png> <输出.png> <高度>")
}
guard let height = Int(arguments[3]), height > 0 else {
    fail("高度必须是一个正整数：\(arguments[3])")
}
guard let source = CGImageSourceCreateWithURL(
    URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("读不出输入图：\(arguments[1])")
}
guard height <= image.height else {
    fail("要裁的 \(height) 行比图还高（图高 \(image.height)）")
}

// CGImage 的坐标原点在**左上角**，(0,0) 就是我们要的那一条的起点。
guard let cropped = image.cropping(
    to: CGRect(x: 0, y: 0, width: image.width, height: height)) else {
    fail("裁切失败")
}
guard let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: arguments[2]) as CFURL,
    UTType.png.identifier as CFString, 1, nil) else {
    fail("写不出输出图：\(arguments[2])")
}
CGImageDestinationAddImage(destination, cropped, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("写盘失败：\(arguments[2])")
}
