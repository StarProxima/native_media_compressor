import AVFoundation
import Foundation

/// Saves one frame of a video as an image through AVAssetImageGenerator.
enum VideoThumbnail {
  /// Blocks the calling thread until the image is written or abandoned.
  static func capture(_ request: ThumbnailRequest) -> CompressionReply {
    let staged = StagedOutput(destination: URL(fileURLWithPath: request.destination))
    return staged.run {
      let box = ThumbnailBox()
      let done = DispatchSemaphore(value: 0)
      Task {
        box.reply = await capture(request, to: staged.file)
        done.signal()
      }
      done.wait()
      return box.reply
    }
  }

  /// Time of the frame shown at `positionMs`. A position at or past the end
  /// of the track asks for the instant just before the end, which the last
  /// frame covers; the end itself has no frame.
  static func frameTime(positionMs: Int64, track: CMTimeRange) -> CMTime {
    let position = CMTime(value: max(0, positionMs), timescale: 1000)
    guard track.duration.isNumeric, track.duration > .zero else { return position }
    let start = track.start.isNumeric ? track.start : .zero
    let last = CMTimeSubtract(
      CMTimeRangeGetEnd(track), CMTimeMinimum(CMTime(value: 1, timescale: 1000), track.duration))
    return CMTimeMaximum(start, CMTimeMinimum(position, last))
  }

  private static func capture(_ request: ThumbnailRequest, to output: URL) async -> CompressionReply {
    guard FileManager.default.isReadableFile(atPath: request.source) else {
      return .status(.failed, "cannot read \(request.source)")
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: request.source))
    guard let media = try? await MediaAsset.load(asset), let video = media.video else {
      return .status(.unsupported, "no video track")
    }
    let display = video.displaySize
    guard display.width > 0, display.height > 0 else {
      return .status(.unsupported, "no video track")
    }
    let scale = Scaling.factor(
      width: Double(display.width), height: Double(display.height),
      maxShortSide: request.maxShortSide, maxLongSide: request.maxLongSide)
    let width = max(1, Int((Double(display.width) * scale).rounded()))
    let height = max(1, Int((Double(display.height) * scale).rounded()))

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    // Zero tolerance decodes the frame shown at that time instead of the
    // nearest keyframe, which may be seconds away.
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    // A square box bounds the long side whichever way the frame is turned,
    // so a 4K frame is never decoded to a full-size bitmap.
    let side = max(width, height)
    generator.maximumSize = CGSize(width: side, height: side)
    let time = frameTime(positionMs: request.positionMs, track: video.timeRange)
    let image: CGImage
    do {
      image = try await frame(of: generator, at: time)
    } catch {
      return .status(.failed, String(describing: error))
    }
    return ImageCodec.write(
      image, width: width, height: height, format: request.format, quality: request.quality,
      to: output)
  }

  private static func frame(of generator: AVAssetImageGenerator, at time: CMTime) async throws
    -> CGImage
  {
    if #available(iOS 16, macOS 13, *) {
      return try await generator.image(at: time).image
    }
    return try generator.copyCGImage(at: time, actualTime: nil)
  }
}

private final class ThumbnailBox {
  var reply = CompressionReply.status(.failed)
}
