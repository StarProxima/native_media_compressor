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
  var knownFileSize: Int64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.int64Value
  }

  var fileSize: Int64 { knownFileSize ?? 0 }
}

/// A temporary file next to the destination that replaces it only on
/// success, so a failure leaves the destination as it was and the destination
/// may be the source itself.
struct StagedOutput {
  let destination: URL
  /// Where the encoder writes. Same directory as the destination, so the final
  /// rename is atomic; same extension, for encoders that look at it.
  let file: URL

  init(destination: URL) {
    self.destination = destination
    let suffix = destination.pathExtension.isEmpty ? "" : ".\(destination.pathExtension)"
    file = destination.deletingLastPathComponent()
      .appendingPathComponent(".nmc-\(UUID().uuidString)\(suffix)")
  }

  /// Runs `write`, which fills `file`, and moves the result over the
  /// destination when it is compressed. Any other outcome removes the
  /// temporary file only.
  func run(_ write: () -> CompressionReply) -> CompressionReply {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      return .status(.failed, "destination is a directory")
    }
    var reply = write()
    if reply.status == .compressed, rename(file.path, destination.path) != 0 {
      reply = .status(.failed, "cannot move output into place: \(String(cString: strerror(errno)))")
    }
    if reply.status != .compressed { try? FileManager.default.removeItem(at: file) }
    return reply
  }
}

extension CompressionReply {
  static func status(_ status: CompressionStatus, _ message: String? = nil) -> CompressionReply {
    CompressionReply(status: status, message: message)
  }
}
