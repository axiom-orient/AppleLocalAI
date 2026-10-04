import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Deterministic, model-independent OCR fixture. No downloaded or generated media.
guard (2...3).contains(CommandLine.arguments.count) else {
  fatalError("usage: swift script/make_test_image.swift /absolute/output.png [text-file]")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let lines =
  CommandLine.arguments.count == 3
  ? try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8).components(
    separatedBy: "\n") : ["LOCAL 73"]
let height = max(240, lines.count * 64 + 100)
let context = CGContext(
  data: nil, width: 800, height: height, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 800, height: height))
for (index, line) in lines.enumerated() {
  let text = NSAttributedString(
    string: line,
    attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
        "Helvetica-Bold" as CFString, 36, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ])
  context.textPosition = CGPoint(x: 40, y: height - 70 - index * 64)
  CTLineDraw(CTLineCreateWithAttributedString(text), context)
}
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(
  output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write fixture") }
print(output.path)
