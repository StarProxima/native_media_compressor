import Foundation

enum Scaling {
  /// Downscale factor that fits a displayed frame into both bounds. Never
  /// above 1; an absent or non-positive bound is ignored.
  static func factor(width: Double, height: Double, maxShortSide: Int64?, maxLongSide: Int64?)
    -> Double
  {
    let short = min(width, height)
    let long = max(width, height)
    guard short > 0 else { return 1 }
    var scale = 1.0
    if let bound = maxShortSide, bound > 0 { scale = min(scale, Double(bound) / short) }
    if let bound = maxLongSide, bound > 0 { scale = min(scale, Double(bound) / long) }
    return scale
  }
}

extension URL {
  var fileSize: Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
  }

  func removeFile() {
    try? FileManager.default.removeItem(at: self)
  }
}

extension CompressionReply {
  static func status(_ status: CompressionStatus, _ message: String? = nil) -> CompressionReply {
    CompressionReply(status: status, message: message)
  }
}
