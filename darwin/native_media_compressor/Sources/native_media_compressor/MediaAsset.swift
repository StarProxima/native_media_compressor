import AVFoundation
import Foundation

/// Container and track parameters of a video file, read without decoding.
struct MediaAsset {
  struct VideoTrack {
    let track: AVAssetTrack
    let naturalSize: CGSize
    let transform: CGAffineTransform
    let nominalFrameRate: Float
    let format: CMFormatDescription?
    let dataRate: Float
    let timeRange: CMTimeRange

    var displaySize: CGSize { MediaAsset.displaySize(naturalSize, transform) }

    var rotationDegrees: Int64 {
      let degrees = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
      let snapped = Int((degrees / 90).rounded()) * 90
      return Int64((snapped % 360 + 360) % 360)
    }

    var codec: String? { format.map { MediaAsset.videoMime(CMFormatDescriptionGetMediaSubType($0)) } }

    var isHDR: Bool {
      guard let format else { return false }
      let subtype = MediaAsset.fourCC(CMFormatDescriptionGetMediaSubType(format))
      if subtype == "dvh1" || subtype == "dvhe" { return true }
      let transfer =
        CMFormatDescriptionGetExtension(
          format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
      return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }
  }

  struct AudioTrack {
    let track: AVAssetTrack
    let format: CMFormatDescription?
    let dataRate: Float
    let isEnabled: Bool

    var id: Int { Int(track.trackID) }

    var codec: String? { format.map { MediaAsset.audioMime(CMFormatDescriptionGetMediaSubType($0)) } }

    var isAAC: Bool {
      guard let format else { return false }
      switch CMFormatDescriptionGetMediaSubType(format) {
      case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return true
      default: return false
      }
    }
  }

  let duration: CMTime
  let video: VideoTrack?
  let audio: [AudioTrack]
  /// Every sound track the container lists, including the ones AVFoundation
  /// cannot read.
  let containerAudio: [ContainerAudio.Track]
  /// Track ids of each alternate group, as AVFoundation reports them.
  let alternateGroups: [[Int]]

  /// Sound tracks in the container that AVFoundation cannot read.
  var unreadableAudio: [ContainerAudio.Track] {
    let readable = Set(audio.map(\.id))
    return containerAudio.filter { !readable.contains($0.id) }
  }

  static func load(_ asset: AVURLAsset) async throws -> MediaAsset {
    let (duration, video, audio, groups) = try await loadTracks(asset)
    return MediaAsset(
      duration: duration, video: video, audio: audio,
      containerAudio: ContainerAudio.soundTracks(at: asset.url),
      alternateGroups: groups.map { $0.trackIDs.map { Int(truncating: $0) } })
  }

  private static func loadTracks(_ asset: AVURLAsset) async throws -> (
    CMTime, VideoTrack?, [AudioTrack], [AVAssetTrackGroup]
  ) {
    if #available(iOS 15, macOS 12, *) {
      let (duration, groups) = try await asset.load(.duration, .trackGroups)
      var video: VideoTrack?
      if let track = try await asset.loadTracks(withMediaType: .video).first {
        let (size, transform, rate, formats, dataRate, timeRange) = try await track.load(
          .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions,
          .estimatedDataRate, .timeRange)
        video = VideoTrack(
          track: track, naturalSize: size, transform: transform, nominalFrameRate: rate,
          format: formats.first, dataRate: dataRate, timeRange: timeRange)
      }
      var audio: [AudioTrack] = []
      for track in try await asset.loadTracks(withMediaType: .audio) {
        let (formats, dataRate, isEnabled) = try await track.load(
          .formatDescriptions, .estimatedDataRate, .isEnabled)
        audio.append(
          AudioTrack(track: track, format: formats.first, dataRate: dataRate, isEnabled: isEnabled))
      }
      return (duration, video, audio, groups)
    }

    try await loadValues(of: asset, keys: ["duration", "tracks", "trackGroups"])
    let trackKeys = [
      "naturalSize", "preferredTransform", "nominalFrameRate", "formatDescriptions",
      "estimatedDataRate", "enabled", "timeRange",
    ]
    var video: VideoTrack?
    if let track = asset.tracks(withMediaType: .video).first {
      try await loadValues(of: track, keys: trackKeys)
      video = VideoTrack(
        track: track, naturalSize: track.naturalSize, transform: track.preferredTransform,
        nominalFrameRate: track.nominalFrameRate, format: firstFormat(of: track),
        dataRate: track.estimatedDataRate, timeRange: track.timeRange)
    }
    var audio: [AudioTrack] = []
    for track in asset.tracks(withMediaType: .audio) {
      try await loadValues(of: track, keys: trackKeys)
      audio.append(
        AudioTrack(
          track: track, format: firstFormat(of: track), dataRate: track.estimatedDataRate,
          isEnabled: track.isEnabled))
    }
    return (asset.duration, video, audio, asset.trackGroups)
  }

  static func probe(_ path: String) async -> VideoProbe? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let media = try? await load(asset), let video = media.video else { return nil }
    let size = video.displaySize
    guard size.width > 0, size.height > 0 else { return nil }
    let dataRate = video.dataRate + media.audio.reduce(0) { $0 + $1.dataRate }
    let seconds = media.duration.seconds
    return VideoProbe(
      width: Int64(size.width.rounded()),
      height: Int64(size.height.rounded()),
      rotationDegrees: video.rotationDegrees,
      durationMs: seconds.isFinite ? Int64((seconds * 1000).rounded()) : 0,
      bitrate: dataRate > 0 ? Int64(dataRate.rounded()) : nil,
      videoCodec: video.codec,
      isHdr: video.isHDR,
      hasAudio: !media.audio.isEmpty || !media.unreadableAudio.isEmpty,
      audioCodec: media.audioPlan.firstCodec ?? media.audio.first?.codec
        ?? media.unreadableAudio.first?.codec,
      frameRate: video.nominalFrameRate > 0 ? Double(video.nominalFrameRate) : nil)
  }

  static func displaySize(_ size: CGSize, _ transform: CGAffineTransform) -> CGSize {
    let rect = CGRect(origin: .zero, size: size).applying(transform)
    return CGSize(width: abs(rect.width), height: abs(rect.height))
  }

  /// `transform` followed by `quarterTurns` clockwise quarter turns, with the
  /// translation redone so a `size` frame lands at the origin.
  ///
  /// Only the rotation and mirroring of `transform` are kept: its translation
  /// is in the units of the source frame, not of the scaled output.
  static func orientation(_ transform: CGAffineTransform, turnedBy quarterTurns: Int, size: CGSize)
    -> CGAffineTransform
  {
    // Exact matrices: a rotation built from an angle leaves 6e-17 where 0
    // belongs. In the y-down frame of video, (0, 1, -1, 0) turns clockwise.
    let turns: [CGAffineTransform] = [
      .identity,
      CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0),
      CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0),
      CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0),
    ]
    let linear = CGAffineTransform(
      a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
    let turned = linear.concatenating(turns[(quarterTurns % 4 + 4) % 4])
    let bounds = CGRect(origin: .zero, size: size).applying(turned)
    return turned.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
  }

  private static func loadValues(of object: AVAsynchronousKeyValueLoading, keys: [String])
    async throws
  {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      object.loadValuesAsynchronously(forKeys: keys) { continuation.resume() }
    }
    for key in keys {
      var error: NSError?
      if object.statusOfValue(forKey: key, error: &error) != .loaded {
        throw error ?? CocoaError(.fileReadCorruptFile)
      }
    }
  }

  private static func firstFormat(of track: AVAssetTrack) -> CMFormatDescription? {
    guard let first = track.formatDescriptions.first else { return nil }
    return (first as! CMFormatDescription)
  }

  private static func videoMime(_ subtype: FourCharCode) -> String {
    switch fourCC(subtype) {
    case "avc1", "avc3": return "video/avc"
    case "hvc1", "hev1": return "video/hevc"
    case "vp08": return "video/x-vnd.on2.vp8"
    case "vp09": return "video/x-vnd.on2.vp9"
    case "av01": return "video/av01"
    case let other: return other.trimmingCharacters(in: .whitespaces)
    }
  }

  private static func audioMime(_ subtype: FourCharCode) -> String {
    switch fourCC(subtype) {
    case "aac ", "aach", "aacp": return "audio/mp4a-latm"
    case ".mp3": return "audio/mpeg"
    case "opus": return "audio/opus"
    case "ac-3": return "audio/ac3"
    case "ec-3": return "audio/eac3"
    case "flac": return "audio/flac"
    case let other: return other.trimmingCharacters(in: .whitespaces)
    }
  }

  private static func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
  }
}
