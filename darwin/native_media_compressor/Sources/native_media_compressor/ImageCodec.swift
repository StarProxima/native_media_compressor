import CoreGraphics
import Foundation
import ImageIO

/// Image probing and re-encoding through ImageIO.
enum ImageCodec {
  static func probe(_ path: String) -> ImageProbe? {
    guard let source = openSource(path), let header = Header(source) else { return nil }
    return ImageProbe(
      width: Int64(header.width),
      height: Int64(header.height),
      frameCount: Int64(CGImageSourceGetCount(source)),
      mimeType: CGImageSourceGetType(source).flatMap { mimeTypes[$0 as String] })
  }

  static func compress(_ request: ImageRequest) -> CompressionReply {
    let staged = StagedOutput(destination: URL(fileURLWithPath: request.destination))
    return staged.run { encode(request, to: staged.file) }
  }

  private static func encode(_ request: ImageRequest, to output: URL) -> CompressionReply {
    guard let source = openSource(request.source), let header = Header(source) else {
      return .status(.failed, "cannot read image")
    }
    let scale = Scaling.factor(
      width: Double(header.width), height: Double(header.height),
      maxShortSide: request.maxShortSide, maxLongSide: request.maxLongSide)
    let width = max(1, Int((Double(header.width) * scale).rounded()))
    let height = max(1, Int((Double(header.height) * scale).rounded()))
    // Decodes straight to the target size, so a large photo never needs a
    // full-resolution bitmap, and bakes the EXIF orientation into the pixels.
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return .status(.failed, "cannot decode image")
    }
    let isJpeg = request.format == .jpeg
    let flatten = isJpeg && hasAlpha(image)
    if image.width != width || image.height != height || flatten {
      guard let redrawn = redraw(image, width: width, height: height, opaque: flatten) else {
        return .status(.failed, "cannot draw image")
      }
      image = redrawn
    }

    let type = (isJpeg ? "public.jpeg" : "public.png") as CFString
    guard let encoder = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
      return .status(.failed, "cannot create \(output.path)")
    }
    var properties: [CFString: Any] = [:]
    if isJpeg {
      properties[kCGImageDestinationLossyCompressionQuality] =
        Double(min(100, max(0, request.quality))) / 100
    }
    CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(encoder) else { return .status(.failed, "cannot encode image") }
    return CompressionReply(
      status: .compressed, width: Int64(width), height: Int64(height),
      sizeBytes: output.fileSize)
  }

  private static func openSource(_ path: String) -> CGImageSource? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    return CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options)
  }

  private static func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: return true
    }
  }

  private static func redraw(_ image: CGImage, width: Int, height: Int, opaque: Bool) -> CGImage? {
    let space =
      image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
      ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: alpha.rawValue)
    else { return nil }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    if opaque {
      context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
      context.fill(rect)
    }
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    return context.makeImage()
  }

  /// Size of the first frame as displayed, after EXIF orientation.
  private struct Header {
    let width: Int
    let height: Int

    init?(_ source: CGImageSource) {
      guard CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
        width > 0, height > 0
      else { return nil }
      let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
      let swaps = (5...8).contains(orientation)
      self.width = swaps ? height : width
      self.height = swaps ? width : height
    }
  }

  private static let mimeTypes: [String: String] = [
    "public.jpeg": "image/jpeg",
    "public.png": "image/png",
    "public.heic": "image/heic",
    "public.heics": "image/heic",
    "public.heif": "image/heif",
    "org.webmproject.webp": "image/webp",
    "com.compuserve.gif": "image/gif",
    "com.microsoft.bmp": "image/bmp",
    "public.tiff": "image/tiff",
    "public.avif": "image/avif",
    "public.avis": "image/avif",
  ]
}
