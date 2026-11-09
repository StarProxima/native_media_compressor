import AVFoundation
import Foundation
import VideoToolbox

/// Re-encodes a video to H.264 or HEVC in MP4 through AVAssetReader and
/// AVAssetWriter. AAC audio is copied without re-encoding; other audio is
/// re-encoded to AAC.
final class VideoTranscoder {
  private static let sizeCheckSamples = 30
  private static let watchdogInterval = DispatchTimeInterval.milliseconds(250)

  private let request: VideoRequest
  private let staged: StagedOutput
  private var output: URL { staged.file }
  private let stopRequest: () -> CompressionReply?
  private let onProgress: (Double) -> Void
  // Every writer input is fed on this queue, so the state below needs no lock.
  private let queue = DispatchQueue(label: "io.github.starproxima.native_media_compressor.video")
  private var stopReply: CompressionReply?
  private var pumps: [TrackPump] = []
  // MP3 that AVFoundation hides inside MP4 is read from a copy of its frames,
  // by a reader of its own.
  private var readers: [AVAssetReader] = []
  private var scratchFiles: [URL] = []
  private var writtenSamples = 0
  private var lastFrameSlot = -Double.infinity
  private var reportedPercent = -1

  init(
    request: VideoRequest, stopRequest: @escaping () -> CompressionReply?,
    onProgress: @escaping (Double) -> Void
  ) {
    self.request = request
    self.staged = StagedOutput(destination: URL(fileURLWithPath: request.destination))
    self.stopRequest = stopRequest
    self.onProgress = onProgress
  }

  /// Blocks the calling thread until the output is finished or abandoned.
  func run() -> CompressionReply {
    if let stopped = stopRequest() { return stopped }
    defer {
      for file in scratchFiles { try? FileManager.default.removeItem(at: file) }
    }
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
    let isTrimmed = request.startMs != nil || request.endMs != nil
    guard
      let range = Self.keptRange(
        startMs: request.startMs, endMs: request.endMs, duration: media.duration)
    else { return .status(.unsupported, "the trim range keeps nothing") }
    let audioPlan = request.includeAudio ? media.audioPlan : AudioPlan()
    if audioPlan.hasUnreadable {
      let codec = audioPlan.unreadableCodec ?? "of unknown format"
      return .status(.unsupported, "audio \(codec) cannot be decoded")
    }

    let reader = try AVAssetReader(asset: asset)
    if isTrimmed { reader.timeRange = range }
    readers = [reader]
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
    let frame = CGSize(width: width, height: height)
    // The turn goes into the track matrix next to the source orientation, so
    // no pixel has to move.
    let transform = MediaAsset.orientation(
      video.transform, turnedBy: Int(request.rotateQuarterTurns), size: frame)
    let (videoSettings, codec) = Self.videoSettings(
      width: width, height: height, frameRate: frameRate, request: request, writer: writer)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.transform = transform
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else { return .status(.unsupported, "cannot encode video") }
    writer.add(videoInput)

    // Screen recordings with a microphone keep system sound and voice in
    // separate tracks that play together, so every played group is kept.
    var audioPumps: [TrackPump] = []
    for source in audioPlan.sources {
      let output: AVAssetReaderTrackOutput
      let input: AVAssetWriterInput
      switch source {
      case .copy(let track):
        output = AVAssetReaderTrackOutput(track: track.track, outputSettings: nil)
        input = AVAssetWriterInput(
          mediaType: .audio, outputSettings: nil, sourceFormatHint: track.format)
        guard reader.canAdd(output) else { return .status(.unsupported, "cannot copy audio track") }
        reader.add(output)
      case .encode(let track):
        guard let pair = Self.encoder(for: track, reader: reader, writer: writer, request: request)
        else { return .status(.unsupported, "cannot re-encode audio \(track.codec ?? "")") }
        (output, input) = pair
      case .encodeHidden(let track):
        let file = FileManager.default.temporaryDirectory
          .appendingPathComponent(".nmc-\(UUID().uuidString).mp3")
        scratchFiles.append(file)
        let hidden = AVURLAsset(url: file)
        guard ContainerAudio.copySamples(ofTrack: track.id, from: asset.url, to: file),
          let decoded = try? await MediaAsset.load(hidden).audio.first
        else { return .status(.unsupported, "cannot decode audio \(track.codec ?? "")") }
        let hiddenReader = try AVAssetReader(asset: hidden)
        if isTrimmed { hiddenReader.timeRange = range }
        guard
          let pair = Self.encoder(
            for: decoded, reader: hiddenReader, writer: writer, request: request)
        else { return .status(.unsupported, "cannot re-encode audio \(track.codec ?? "")") }
        readers.append(hiddenReader)
        (output, input) = pair
      }
      input.expectsMediaDataInRealTime = false
      guard writer.canAdd(input) else { return .status(.unsupported, "cannot write audio track") }
      writer.add(input)
      audioPumps.append(TrackPump(output: output, input: input))
    }

    guard readers.allSatisfy({ $0.startReading() }), writer.startWriting() else {
      let error = readers.lazy.compactMap(\.error).first ?? writer.error
      for reader in readers { reader.cancelReading() }
      writer.cancelWriting()
      return Self.failure(error)
    }
    // Starting the session at the trim start puts that instant at 0 in the
    // output; the edit list the writer adds hides whatever part of the first
    // frame and audio packet lies before it.
    writer.startSession(atSourceTime: isTrimmed ? range.start : .zero)

    let start = isTrimmed ? range.start.seconds : 0
    let duration = isTrimmed ? range.duration.seconds : media.duration.seconds
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
        if stopReply == nil { stopReply = stopRequest() }
        if stopReply == nil, writer.status == .failed { stopReply = Self.failure(writer.error) }
        if stopReply != nil { stopAll() }
      }
      watchdog.resume()
      run(videoPump, writer: writer) { [self] sample in
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
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        reportProgress(at: time - start, duration: duration)
      }
      for pump in audioPumps {
        run(pump, writer: writer, shouldAppend: { _ in true }, onAppended: { _ in })
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
    if let failed = readers.first(where: { $0.status != .completed }) {
      let error = failed.error ?? writer.error
      writer.cancelWriting()
      return Self.failure(error)
    }
    // A reader limited to a range still hands over the whole frame or packet
    // that crosses its end.
    if isTrimmed, range.end.isNumeric { writer.endSession(atSourceTime: range.end) }
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
    let output = MediaAsset.displaySize(frame, transform)
    return CompressionReply(
      status: .compressed,
      width: Int64(output.width.rounded()),
      height: Int64(output.height.rounded()),
      sizeBytes: size,
      videoCodec: codec)
  }

  /// The part of a `duration` long timeline between `startMs` and `endMs`.
  /// An end past the timeline keeps to its end; nil means nothing is kept.
  static func keptRange(startMs: Int64?, endMs: Int64?, duration: CMTime) -> CMTimeRange? {
    let start = CMTime(value: max(0, startMs ?? 0), timescale: 1000)
    var end = duration.isNumeric ? duration : .positiveInfinity
    if let endMs { end = CMTimeMinimum(end, CMTime(value: endMs, timescale: 1000)) }
    guard end > start else { return nil }
    return CMTimeRange(start: start, end: end)
  }

  /// Writer settings for the requested codec and the MIME type of the codec
  /// they select. HEVC falls back to H.264 where the system cannot encode it.
  private static func videoSettings(
    width: Int, height: Int, frameRate: Double, request: VideoRequest, writer: AVAssetWriter
  ) -> ([String: Any], String) {
    func settings(_ codec: AVVideoCodecType, profile: String, limitsRate: Bool) -> [String: Any] {
      var compression: [String: Any] = [
        AVVideoAverageBitRateKey: request.videoBitrate,
        AVVideoExpectedSourceFrameRateKey: frameRate,
        AVVideoMaxKeyFrameIntervalKey: max(1, Int((frameRate * 2).rounded())),
        AVVideoMaxKeyFrameIntervalDurationKey: 2,
        AVVideoProfileLevelKey: profile,
      ]
      // The average alone is a loose target that encoders may overshoot on
      // hard scenes; a cap of 1.5x over any second bounds that.
      if limitsRate {
        compression[kVTCompressionPropertyKey_DataRateLimits as String] =
          dataRateLimits(bitrate: request.videoBitrate)
      }
      return [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoScalingModeKey: AVVideoScalingModeResize,
        AVVideoColorPropertiesKey: bt709,
        AVVideoCompressionPropertiesKey: compression,
      ]
    }
    func firstApplicable(_ codec: AVVideoCodecType, profile: String) -> [String: Any]? {
      [true, false].lazy.map { settings(codec, profile: profile, limitsRate: $0) }
        .first { writer.canApply(outputSettings: $0, forMediaType: .video) }
    }
    // AVAssetWriter tags HEVC in MP4 as hvc1, the entry Apple players need.
    if request.codec == .hevc, hasHEVCEncoder,
      let hevc = firstApplicable(.hevc, profile: kVTProfileLevel_HEVC_Main_AutoLevel as String)
    {
      return (hevc, "video/hevc")
    }
    #if targetEnvironment(simulator)
      // The simulator's software H.264 encoder ignores the bitrate in the
      // Main and High profiles and writes several times the target; in
      // Baseline it follows it.
      let profile = AVVideoProfileLevelH264BaselineAutoLevel
    #else
      let profile = AVVideoProfileLevelH264HighAutoLevel
    #endif
    return (
      firstApplicable(.h264, profile: profile)
        ?? settings(.h264, profile: profile, limitsRate: false),
      "video/avc"
    )
  }

  /// `kVTCompressionPropertyKey_DataRateLimits`: at most 1.5 times the
  /// average bitrate, in bytes, over any one second.
  static func dataRateLimits(bitrate: Int64) -> [Double] {
    [Double(bitrate) / 8 * 1.5, 1]
  }

  /// Reader output that decodes `track` and writer input that encodes it to
  /// AAC, or nil when this system has no AAC encoder for it.
  private static func encoder(
    for track: MediaAsset.AudioTrack, reader: AVAssetReader, writer: AVAssetWriter,
    request: VideoRequest
  ) -> (AVAssetReaderTrackOutput, AVAssetWriterInput)? {
    let settings = AudioEncoding.settings(for: track.format, bitrate: request.audioBitrate)
    // An input made from settings the writer rejects raises an Objective-C
    // exception, which Swift cannot catch.
    guard writer.canApply(outputSettings: settings.encoded, forMediaType: .audio) else {
      return nil
    }
    let output = AVAssetReaderTrackOutput(track: track.track, outputSettings: settings.decoded)
    guard reader.canAdd(output) else { return nil }
    reader.add(output)
    return (output, AVAssetWriterInput(mediaType: .audio, outputSettings: settings.encoded))
  }

  private func run(
    _ pump: TrackPump,
    writer: AVAssetWriter,
    shouldAppend: @escaping (CMSampleBuffer) -> Bool,
    onAppended: @escaping (CMSampleBuffer) -> Void
  ) {
    pump.input.requestMediaDataWhenReady(on: queue) { [self] in
      while pump.input.isReadyForMoreMediaData, !pump.isFinished {
        if stopReply == nil { stopReply = stopRequest() }
        if stopReply != nil {
          stopAll()
          return
        }
        guard let sample = pump.output.copyNextSampleBuffer() else {
          pump.finish()
          return
        }
        guard shouldAppend(sample) else { continue }
        guard pump.input.append(sample) else {
          stopReply = Self.failure(writer.error)
          stopAll()
          return
        }
        onAppended(sample)
        writtenSamples += 1
        if let maxBytes = request.maxBytes, writtenSamples % Self.sizeCheckSamples == 0,
          output.fileSize > maxBytes
        {
          stopReply = .status(.tooLarge)
          stopAll()
          return
        }
      }
    }
  }

  private func stopAll() {
    for reader in readers { reader.cancelReading() }
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

  /// Devices without an HEVC encoder, such as iPhones before the A10, leave
  /// it out of this list.
  private static let hasHEVCEncoder: Bool = {
    var list: CFArray?
    guard VTCopyVideoEncoderList(nil, &list) == noErr,
      let encoders = list as? [[String: Any]]
    else { return false }
    return encoders.contains {
      ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
        == kCMVideoCodecType_HEVC
    }
  }()

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

/// Moves one track from a reader to the writer. Touched only on the
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
