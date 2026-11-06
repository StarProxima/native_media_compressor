import AVFoundation
import Foundation

/// Re-encodes a video to H.264 in MP4 through AVAssetReader and AVAssetWriter.
/// AAC audio is copied without re-encoding.
final class VideoTranscoder {
  private static let sizeCheckSamples = 30
  private static let watchdogInterval = DispatchTimeInterval.milliseconds(250)

  private let request: VideoRequest
  private let staged: StagedOutput
  private var output: URL { staged.file }
  private let isCancelled: () -> Bool
  private let onProgress: (Double) -> Void
  // Every writer input is fed on this queue, so the state below needs no lock.
  private let queue = DispatchQueue(label: "io.github.starproxima.native_media_compressor.video")
  private var stopReply: CompressionReply?
  private var pumps: [TrackPump] = []
  private var writtenSamples = 0
  private var lastFrameSlot = -Double.infinity
  private var reportedPercent = -1

  init(
    request: VideoRequest, isCancelled: @escaping () -> Bool,
    onProgress: @escaping (Double) -> Void
  ) {
    self.request = request
    self.staged = StagedOutput(destination: URL(fileURLWithPath: request.destination))
    self.isCancelled = isCancelled
    self.onProgress = onProgress
  }

  /// Blocks the calling thread until the output is finished or abandoned.
  func run() -> CompressionReply {
    if isCancelled() { return .status(.cancelled) }
    return staged.run {
      let box = ReplyBox()
      let done = DispatchSemaphore(value: 0)
      Task {
        do {
          box.reply = try await transcode()
        } catch {
          box.reply = Self.failure(error)
        }
        done.signal()
      }
      done.wait()
      return box.reply
    }
  }

  private func transcode() async throws -> CompressionReply {
    let asset = AVURLAsset(url: URL(fileURLWithPath: request.source))
    let media = try await MediaAsset.load(asset)
    guard let video = media.video, video.naturalSize.width > 0, video.naturalSize.height > 0
    else { return .status(.unsupported, "no video track") }
    if video.isHDR, !Self.canToneMap {
      return .status(.unsupported, "HDR to SDR conversion needs iOS 14 or macOS 11")
    }
    let audioPlan = request.includeAudio ? media.audioPlan : AudioPlan()
    if audioPlan.hasUncopyable {
      let codec = audioPlan.uncopyableCodec ?? "of unknown format"
      return .status(.unsupported, "audio \(codec) has no AAC alternative to copy")
    }
    let audioTracks = audioPlan.tracks

    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)

    // Asking the decoder for 8-bit BT.709 makes VideoToolbox convert the
    // colours, which tone-maps PQ and HLG input. The writer gets the same tags
    // so players do not treat the result as wide gamut or HDR.
    let videoOutput = AVAssetReaderTrackOutput(
      track: video.track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        AVVideoColorPropertiesKey: Self.bt709,
      ])
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else { return .status(.unsupported, "cannot decode video") }
    reader.add(videoOutput)

    let sourceRate = video.nominalFrameRate > 0 ? Double(video.nominalFrameRate) : nil
    let maxRate = request.maxFrameRate.flatMap { $0 > 0 ? Double($0) : nil }
    let frameRate = [sourceRate, maxRate].compactMap { $0 }.min() ?? 30
    let display = video.displaySize
    let scale = Scaling.factor(
      width: Double(display.width), height: Double(display.height),
      maxShortSide: request.maxShortSide, maxLongSide: request.maxLongSide)
    let width = Self.evenSide(Double(video.naturalSize.width) * scale)
    let height = Self.evenSide(Double(video.naturalSize.height) * scale)
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoScalingModeKey: AVVideoScalingModeResize,
        AVVideoColorPropertiesKey: Self.bt709,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: request.videoBitrate,
          AVVideoExpectedSourceFrameRateKey: frameRate,
          AVVideoMaxKeyFrameIntervalDurationKey: 2,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
      ])
    videoInput.transform = video.transform
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else { return .status(.unsupported, "cannot encode H.264") }
    writer.add(videoInput)

    // Screen recordings with a microphone keep system sound and voice in
    // separate tracks that play together, so every played group is copied.
    var audioPumps: [TrackPump] = []
    for track in audioTracks {
      let output = AVAssetReaderTrackOutput(track: track.track, outputSettings: nil)
      let input = AVAssetWriterInput(
        mediaType: .audio, outputSettings: nil, sourceFormatHint: track.format)
      input.expectsMediaDataInRealTime = false
      guard reader.canAdd(output), writer.canAdd(input) else {
        return .status(.unsupported, "cannot copy audio track")
      }
      reader.add(output)
      writer.add(input)
      audioPumps.append(TrackPump(output: output, input: input))
    }

    guard reader.startReading(), writer.startWriting() else {
      let error = reader.error ?? writer.error
      reader.cancelReading()
      writer.cancelWriting()
      return Self.failure(error)
    }
    writer.startSession(atSourceTime: .zero)

    let duration = media.duration.seconds
    let videoPump = TrackPump(output: videoOutput, input: videoInput)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let group = DispatchGroup()
      pumps = [videoPump] + audioPumps
      for pump in pumps { pump.start(group: group) }
      // A failed writer stops asking its inputs for data, so no pump would
      // notice the failure or a cancel on its own.
      let watchdog = DispatchSource.makeTimerSource(queue: queue)
      watchdog.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
      watchdog.setEventHandler { [self] in
        if stopReply == nil, isCancelled() { stopReply = .status(.cancelled) }
        if stopReply == nil, writer.status == .failed { stopReply = Self.failure(writer.error) }
        if stopReply != nil { stopAll(reader: reader) }
      }
      watchdog.resume()
      run(videoPump, reader: reader, writer: writer) { [self] sample in
        guard let maxRate else { return true }
        // One frame per slot of a fixed grid at the target rate. Measuring
        // from the last kept frame instead would keep only every second frame
        // of a screen recording whose frames come slightly faster than the
        // limit, halving its rate.
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let slot = (time * maxRate).rounded()
        // Kept in Double: an Int conversion of a huge or invalid time would trap.
        guard slot.isFinite else { return true }
        guard slot > lastFrameSlot else { return false }
        lastFrameSlot = slot
        return true
      } onAppended: { [self] sample in
        reportProgress(at: CMSampleBufferGetPresentationTimeStamp(sample).seconds, duration: duration)
      }
      for pump in audioPumps {
        run(pump, reader: reader, writer: writer, shouldAppend: { _ in true }, onAppended: { _ in })
      }
      group.notify(queue: queue) {
        watchdog.cancel()
        continuation.resume()
      }
    }

    if let stopReply = queue.sync(execute: { stopReply }) {
      writer.cancelWriting()
      return stopReply
    }
    // On iOS a backgrounded app loses the hardware codec and reading or
    // writing ends with an error.
    guard reader.status == .completed else {
      let error = reader.error ?? writer.error
      writer.cancelWriting()
      return Self.failure(error)
    }
    await writer.finishWriting()
    guard writer.status == .completed else { return Self.failure(writer.error) }

    let size = output.fileSize
    if let maxBytes = request.maxBytes, size > maxBytes { return .status(.tooLarge) }
    queue.sync {
      if reportedPercent < 100 {
        reportedPercent = 100
        onProgress(1)
      }
    }
    let output = MediaAsset.displaySize(CGSize(width: width, height: height), video.transform)
    return CompressionReply(
      status: .compressed,
      width: Int64(output.width.rounded()),
      height: Int64(output.height.rounded()),
      sizeBytes: size)
  }

  private func run(
    _ pump: TrackPump,
    reader: AVAssetReader,
    writer: AVAssetWriter,
    shouldAppend: @escaping (CMSampleBuffer) -> Bool,
    onAppended: @escaping (CMSampleBuffer) -> Void
  ) {
    pump.input.requestMediaDataWhenReady(on: queue) { [self] in
      while pump.input.isReadyForMoreMediaData, !pump.isFinished {
        if stopReply == nil, isCancelled() { stopReply = .status(.cancelled) }
        if stopReply != nil {
          stopAll(reader: reader)
          return
        }
        guard let sample = pump.output.copyNextSampleBuffer() else {
          pump.finish()
          return
        }
        guard shouldAppend(sample) else { continue }
        guard pump.input.append(sample) else {
          stopReply = Self.failure(writer.error)
          stopAll(reader: reader)
          return
        }
        onAppended(sample)
        writtenSamples += 1
        if let maxBytes = request.maxBytes, writtenSamples % Self.sizeCheckSamples == 0,
          output.fileSize > maxBytes
        {
          stopReply = .status(.tooLarge)
          stopAll(reader: reader)
          return
        }
      }
    }
  }

  private func stopAll(reader: AVAssetReader) {
    reader.cancelReading()
    for pump in pumps { pump.finish() }
  }

  private func reportProgress(at time: Double, duration: Double) {
    guard duration > 0, time.isFinite else { return }
    let percent = Int(max(0, min(100, time / duration * 100)))
    guard percent > reportedPercent else { return }
    reportedPercent = percent
    onProgress(Double(percent) / 100)
  }

  private static func failure(_ error: Error?) -> CompressionReply {
    guard let error else { return .status(.failed, "unknown AVFoundation error") }
    let status: CompressionStatus =
      isInterruption(error) ? .interrupted : isUnsupported(error) ? .unsupported : .failed
    return .status(status, String(describing: error))
  }

  /// The system cannot open the container (Matroska, WebM) or has no decoder
  /// for the codec (VP9 on most Apple devices).
  private static let unsupportedCodes = [
    AVError.Code.fileFormatNotRecognized.rawValue, AVError.Code.decoderNotFound.rawValue,
  ]

  private static func isUnsupported(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == AVFoundationErrorDomain && unsupportedCodes.contains(error.code)
  }

  // AVErrorOperationInterrupted and AVErrorMediaServicesWereReset, which the
  // macOS SDK does not declare.
  private static let interruptionCodes = [-11847, -11819]

  private static func isInterruption(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == AVFoundationErrorDomain, interruptionCodes.contains(error.code) {
      return true
    }
    // VideoToolbox drops its session when the app moves to the background.
    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
    return underlying?.domain == NSOSStatusErrorDomain && underlying?.code == -12903
  }

  private static let bt709: [String: Any] = [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
  ]

  /// VideoToolbox tone-maps PQ and HLG to SDR from iOS 14 and macOS 11 on.
  private static var canToneMap: Bool {
    if #available(iOS 14, macOS 11, *) { return true }
    return false
  }

  // 4:2:0 chroma needs even sides; anything coarser, such as multiples of 16,
  // visibly stretches odd sizes like 1206x2622. Rounding to the nearest pixel
  // first keeps 1206 * (720 / 1206) at 720 instead of 718.
  private static func evenSide(_ value: Double) -> Int {
    let side = Int(value.rounded())
    return max(2, side - side % 2)
  }
}

private final class ReplyBox {
  var reply = CompressionReply.status(.failed)
}

/// Moves one track from the reader to the writer. Touched only on the
/// transcoder queue.
private final class TrackPump {
  let output: AVAssetReaderTrackOutput
  let input: AVAssetWriterInput
  private(set) var isFinished = false
  private var group: DispatchGroup?

  init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
    self.output = output
    self.input = input
  }

  func start(group: DispatchGroup) {
    self.group = group
    group.enter()
  }

  /// Safe to call again: the group waits for each track exactly once.
  func finish() {
    guard !isFinished else { return }
    isFinished = true
    input.markAsFinished()
    group?.leave()
  }
}
