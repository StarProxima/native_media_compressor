import 'dart:async';
import 'dart:typed_data';

/// How a compression ended.
///
/// Every status except [compressed] leaves the destination as it was: the
/// output is written to a temporary file and moved into place only on success.
enum CompressionStatus {
  /// The output was written to the destination.
  compressed,

  /// The platform cannot handle this input or these options: a missing codec
  /// or system library, an audio track that cannot be copied without
  /// re-encoding, or a format the platform cannot encode.
  unsupported,

  /// The output grew past `maxBytes`, so compression stopped early.
  tooLarge,

  /// [CompressionTask.cancel] was called.
  cancelled,

  /// The system stopped the work, for example when the app was suspended in
  /// the background. Running the same request again usually succeeds.
  interrupted,

  /// The input could not be read or a codec failed midway.
  failed,

  /// The output was not smaller than the source by `minSavingsPercent`, so
  /// it was dropped and the source is the better file to keep.
  skipped,
}

/// Codec of the output video track, for [VideoOptions.codec].
enum VideoCodec {
  /// H.264: plays everywhere, the default.
  h264,

  /// HEVC (H.265): about a third smaller at the same quality, but not every
  /// player or browser decodes it. Where the platform has no HEVC encoder the
  /// output is H.264; [CompressionResult.videoCodec] tells which one it got.
  hevc,
}

/// Output format for [ImageOptions.format].
enum ImageFormat {
  /// Lossy JPEG; [ImageOptions.quality] applies.
  jpeg,

  /// Lossless PNG; [ImageOptions.quality] is ignored.
  png,

  /// Lossy WebP; [ImageOptions.quality] applies. Where the platform has no
  /// WebP encoder the result is [CompressionStatus.unsupported].
  webp,

  /// HEIC; [ImageOptions.quality] applies. Where the platform has no HEIC
  /// encoder the result is [CompressionStatus.unsupported].
  heic,
}

/// The notification an Android foreground service shows while videos are
/// compressed in it; see `NativeMediaCompressor.androidForegroundNotification`.
final class AndroidForegroundNotification {
  /// Creates the notification settings.
  const AndroidForegroundNotification({
    required this.title,
    this.text,
    this.iconResource,
    this.channelName = 'Video compression',
  });

  /// Notification title, such as "Compressing video".
  final String title;

  /// Notification text under the title.
  final String? text;

  /// Name of a drawable resource of the app for the small icon, such as
  /// `ic_notification`; null uses the app icon.
  final String? iconResource;

  /// Name of the notification channel shown in the system settings.
  final String channelName;
}

/// Video compression settings.
///
/// The frame is only ever scaled down, keeping its aspect ratio, until it fits
/// both [maxShortSide] and [maxLongSide]. The output is SDR video in an MP4
/// container, H.264 unless [codec] asks for HEVC. HDR input (HLG, PQ, Dolby
/// Vision) is tone-mapped to SDR on Android 7+ with a decoder for the source
/// profile, iOS 14+ and macOS 11+, and by the browser on the web where it
/// decodes the source; elsewhere it is [CompressionStatus.unsupported]. AAC
/// audio is copied without re-encoding; other audio is re-encoded to AAC at
/// [audioBitrate] where the platform has an AAC encoder.
///
/// The video bitrate comes from the first of [targetBytes], [videoBitrate]
/// and [sourceBitratePercent] that is set, and otherwise from
/// [bitsPerPixel]. It stays below the bitrate of the source video. Encoders
/// may still overshoot it on short clips; [minSavingsPercent] guarantees a
/// smaller output.
///
/// [light], [balanced] and [strong] are ready settings for the usual cases.
final class VideoOptions {
  /// Creates video compression settings.
  const VideoOptions({
    this.maxShortSide = 720,
    this.maxLongSide,
    this.videoBitrate,
    this.sourceBitratePercent,
    this.targetBytes,
    this.bitsPerPixel = 0.07,
    this.maxFrameRate = 30,
    this.maxBytes,
    this.minSavingsPercent,
    this.includeAudio = true,
    this.audioBitrate = 128000,
    this.codec = VideoCodec.h264,
    this.trimStart,
    this.trimEnd,
    this.rotateQuarterTurns = 0,
  }) : assert(maxShortSide == null || maxShortSide > 0),
       assert(audioBitrate > 0),
       assert(rotateQuarterTurns >= 0 && rotateQuarterTurns < 4),
       assert(maxLongSide == null || maxLongSide > 0),
       assert(videoBitrate == null || videoBitrate > 0),
       assert(
         sourceBitratePercent == null ||
             (sourceBitratePercent > 0 && sourceBitratePercent <= 100),
       ),
       assert(targetBytes == null || targetBytes > 0),
       assert(bitsPerPixel > 0),
       assert(maxFrameRate == null || maxFrameRate > 0),
       assert(maxBytes == null || maxBytes > 0),
       assert(
         minSavingsPercent == null ||
             (minSavingsPercent >= 0 && minSavingsPercent < 100),
       );

  /// Near the source quality: up to 1080p at 60 frames per second.
  static const light = VideoOptions(
    maxShortSide: 1080,
    maxFrameRate: 60,
    bitsPerPixel: 0.1,
  );

  /// The default: up to 720p at 30 frames per second.
  static const balanced = VideoOptions();

  /// The smallest files that stay watchable: up to 480p at 30 frames per
  /// second.
  static const strong = VideoOptions(maxShortSide: 480, bitsPerPixel: 0.05);

  /// Upper bound for the shorter side of the frame, in pixels.
  final int? maxShortSide;

  /// Upper bound for the longer side of the frame, in pixels.
  final int? maxLongSide;

  /// Video bitrate, in bits per second. When null, the bitrate is derived
  /// from the other settings.
  final int? videoBitrate;

  /// Video bitrate as a percentage of the source video bitrate, from 1 to
  /// 100. Not an encoder quality: 50 asks for half the bitrate the source
  /// has, whatever that is.
  final int? sourceBitratePercent;

  /// Desired output size in bytes. The video bitrate is derived from the
  /// duration so that video and copied audio add up to about this size;
  /// encoders land within a few percent, so set [maxBytes] as well when the
  /// size is a hard limit. Needs the duration from `probeVideo`; a source the
  /// probe cannot read is compressed at [videoBitrate] or the default
  /// bitrate instead.
  final int? targetBytes;

  /// Bits of video per pixel per frame for the automatic bitrate: 0.07 keeps
  /// screen text and faces sharp, 0.05 is visibly softer, 0.1 is close to the
  /// source.
  final double bitsPerPixel;

  /// Frames above this rate are dropped. Values above 240 are treated as
  /// 240.
  final int? maxFrameRate;

  /// Compression stops with [CompressionStatus.tooLarge] as soon as the output
  /// exceeds this many bytes.
  final int? maxBytes;

  /// When set, an output that is not at least this many percent smaller
  /// than the source is dropped with [CompressionStatus.skipped]; 0 drops
  /// only outputs that are not smaller at all. Needs the source size, so
  /// an Android `content://` source is always kept.
  final int? minSavingsPercent;

  /// Whether to keep the audio tracks.
  final bool includeAudio;

  /// Bitrate for audio that is not AAC and so has to be re-encoded, in bits
  /// per second. AAC audio is copied and keeps its own bitrate.
  final int audioBitrate;

  /// Codec of the output video track.
  final VideoCodec codec;

  /// Start of the part to keep; null keeps from the beginning.
  final Duration? trimStart;

  /// End of the part to keep; null keeps to the end.
  final Duration? trimEnd;

  /// Clockwise quarter turns added to the displayed orientation, 0 to 3.
  final int rotateQuarterTurns;

  /// A copy with the given fields replaced. Nullable fields cannot be cleared
  /// this way; create new options for that.
  VideoOptions copyWith({
    int? maxShortSide,
    int? maxLongSide,
    int? videoBitrate,
    int? sourceBitratePercent,
    int? targetBytes,
    double? bitsPerPixel,
    int? maxFrameRate,
    int? maxBytes,
    int? minSavingsPercent,
    bool? includeAudio,
    int? audioBitrate,
    VideoCodec? codec,
    Duration? trimStart,
    Duration? trimEnd,
    int? rotateQuarterTurns,
  }) => VideoOptions(
    maxShortSide: maxShortSide ?? this.maxShortSide,
    maxLongSide: maxLongSide ?? this.maxLongSide,
    videoBitrate: videoBitrate ?? this.videoBitrate,
    sourceBitratePercent: sourceBitratePercent ?? this.sourceBitratePercent,
    targetBytes: targetBytes ?? this.targetBytes,
    bitsPerPixel: bitsPerPixel ?? this.bitsPerPixel,
    maxFrameRate: maxFrameRate ?? this.maxFrameRate,
    maxBytes: maxBytes ?? this.maxBytes,
    minSavingsPercent: minSavingsPercent ?? this.minSavingsPercent,
    includeAudio: includeAudio ?? this.includeAudio,
    audioBitrate: audioBitrate ?? this.audioBitrate,
    codec: codec ?? this.codec,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
    rotateQuarterTurns: rotateQuarterTurns ?? this.rotateQuarterTurns,
  );
}

/// Image compression settings.
///
/// The image is only ever scaled down, keeping its aspect ratio, until it fits
/// both [maxShortSide] and [maxLongSide]. EXIF orientation is applied to the
/// pixels, and metadata is not copied. Animated images keep only the first
/// frame.
///
/// [light], [balanced] and [strong] are ready settings for the usual cases.
final class ImageOptions {
  /// Creates image compression settings.
  const ImageOptions({
    this.maxShortSide,
    this.maxLongSide = 2048,
    this.format = ImageFormat.jpeg,
    this.quality = 85,
    this.targetBytes,
    this.minSavingsPercent,
    this.keepMetadata = false,
  }) : assert(quality >= 0 && quality <= 100),
       assert(targetBytes == null || targetBytes > 0),
       assert(
         minSavingsPercent == null ||
             (minSavingsPercent >= 0 && minSavingsPercent < 100),
       );

  /// Near the source quality: long side up to 2560, JPEG quality 90.
  static const light = ImageOptions(maxLongSide: 2560, quality: 90);

  /// The default: long side up to 2048, JPEG quality 85.
  static const balanced = ImageOptions();

  /// Small files for previews and chats: long side up to 1280, JPEG quality
  /// 75.
  static const strong = ImageOptions(maxLongSide: 1280, quality: 75);

  /// Upper bound for the shorter side, in pixels.
  final int? maxShortSide;

  /// Upper bound for the longer side, in pixels.
  final int? maxLongSide;

  /// Output format.
  final ImageFormat format;

  /// Encoder quality from 0 to 100 for lossy formats.
  final int quality;

  /// Desired output size in bytes. JPEG quality goes down from [quality],
  /// then the image shrinks, until the output fits; if nothing fits, the
  /// smallest attempt is the result.
  final int? targetBytes;

  /// When set, an output that is not at least this many percent smaller
  /// than the source is dropped with [CompressionStatus.skipped]; 0 drops
  /// only outputs that are not smaller at all. Needs the source size, so
  /// an Android `content://` source is always kept.
  final int? minSavingsPercent;

  /// Copy the source's EXIF metadata, such as the camera, the capture time
  /// and the location, except the orientation, which is applied to the
  /// pixels. Off by default, so photos do not leak where they were taken.
  /// Platforms that cannot write metadata into the output format ignore it.
  final bool keepMetadata;

  /// A copy with the given fields replaced. Nullable fields cannot be cleared
  /// this way; create new options for that.
  ImageOptions copyWith({
    int? maxShortSide,
    int? maxLongSide,
    ImageFormat? format,
    int? quality,
    int? targetBytes,
    int? minSavingsPercent,
    bool? keepMetadata,
  }) => ImageOptions(
    maxShortSide: maxShortSide ?? this.maxShortSide,
    maxLongSide: maxLongSide ?? this.maxLongSide,
    format: format ?? this.format,
    quality: quality ?? this.quality,
    targetBytes: targetBytes ?? this.targetBytes,
    minSavingsPercent: minSavingsPercent ?? this.minSavingsPercent,
    keepMetadata: keepMetadata ?? this.keepMetadata,
  );
}

/// Result of a compression.
final class CompressionResult {
  /// Creates a compression result.
  const CompressionResult({
    required this.status,
    this.path,
    this.width,
    this.height,
    this.sizeBytes,
    this.message,
    this.videoCodec,
  });

  /// How the compression ended.
  final CompressionStatus status;

  /// Where the output is: the destination path, or an object URL on the web.
  /// Set only when [status] is [CompressionStatus.compressed].
  final String? path;

  /// Output width in pixels, as displayed.
  final int? width;

  /// Output height in pixels, as displayed.
  final int? height;

  /// Output size in bytes.
  final int? sizeBytes;

  /// Platform details about a failure, for logs.
  final String? message;

  /// Codec of the written video track: [VideoCodec.h264] when HEVC was asked
  /// for but the platform has no encoder for it. Null for images and when
  /// nothing was written.
  final VideoCodec? videoCodec;

  /// Whether the output was written.
  bool get isCompressed => status == CompressionStatus.compressed;

  @override
  String toString() {
    final buffer = StringBuffer('CompressionResult(${status.name}');
    if (path != null) buffer.write(', path: $path');
    if (width != null || height != null) buffer.write(', ${width}x$height');
    if (sizeBytes != null) buffer.write(', sizeBytes: $sizeBytes');
    if (videoCodec != null) buffer.write(', videoCodec: ${videoCodec!.name}');
    if (message != null) buffer.write(', message: $message');
    buffer.write(')');

    return buffer.toString();
  }
}

/// What [VideoOptions] would produce for a source, computed from its
/// headers without encoding anything.
final class VideoEstimate {
  /// Creates a video estimate.
  const VideoEstimate({
    required this.width,
    required this.height,
    required this.videoBitrate,
    required this.sizeBytes,
  });

  /// Output width in pixels, as displayed.
  final int width;

  /// Output height in pixels, as displayed.
  final int height;

  /// Video bitrate the encoder would get, in bits per second.
  final int videoBitrate;

  /// Expected output size in bytes; encoders usually land within 10% of it.
  final int sizeBytes;
}

/// Result of compressing an image held in memory.
final class ImageBytesResult {
  /// Creates an image bytes result.
  const ImageBytesResult({
    required this.status,
    this.bytes,
    this.width,
    this.height,
    this.message,
  });

  /// How the compression ended.
  final CompressionStatus status;

  /// The compressed image; set only when [status] is
  /// [CompressionStatus.compressed].
  final Uint8List? bytes;

  /// Output width in pixels.
  final int? width;

  /// Output height in pixels.
  final int? height;

  /// Platform details about a failure, for logs.
  final String? message;

  /// Whether the image was compressed.
  bool get isCompressed => status == CompressionStatus.compressed;
}

/// Image parameters read from the file header without decoding the pixels.
final class ImageMetadata {
  /// Creates image metadata.
  const ImageMetadata({
    required this.width,
    required this.height,
    required this.frameCount,
    this.mimeType,
    this.sizeBytes,
  });

  /// Width in pixels after EXIF orientation is applied.
  final int width;

  /// Height in pixels after EXIF orientation is applied.
  final int height;

  /// Number of frames; above 1 for animated images.
  final int frameCount;

  /// MIME type the platform detected, such as `image/heic`.
  final String? mimeType;

  /// Size of the source in bytes, when the platform can tell.
  final int? sizeBytes;

  /// Whether the image has more than one frame.
  bool get isAnimated => frameCount > 1;
}

/// Video parameters read from the container without decoding.
final class VideoMetadata {
  /// Creates video metadata.
  const VideoMetadata({
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.duration,
    required this.hasAudio,
    required this.isHdr,
    this.bitrate,
    this.videoCodec,
    this.audioCodec,
    this.frameRate,
    this.audioTrackCount,
    this.sizeBytes,
  });

  /// Width in pixels as displayed, after rotation.
  final int width;

  /// Height in pixels as displayed, after rotation.
  final int height;

  /// Rotation the player applies to the stored frames: 0, 90, 180 or 270.
  final int rotationDegrees;

  /// Duration of the longest track.
  final Duration duration;

  /// Overall bitrate in bits per second, when the container reports it.
  final int? bitrate;

  /// Video codec MIME type, such as `video/avc` or `video/hevc`.
  final String? videoCodec;

  /// Whether the video uses an HDR transfer function (PQ or HLG), as iPhone
  /// camera recordings do by default. See [VideoOptions] for where it can be
  /// converted to SDR.
  final bool isHdr;

  /// Whether there is at least one audio track.
  final bool hasAudio;

  /// Codec MIME type of the first audio track, such as `audio/mp4a-latm`.
  final String? audioCodec;

  /// Average frames per second, when the container reports it.
  final double? frameRate;

  /// Number of audio tracks, when the platform can tell.
  final int? audioTrackCount;

  /// Size of the source in bytes, when the platform can tell. Lets
  /// `minSavingsPercent` work for sources that are not plain files, such as
  /// Android `content://` URIs.
  final int? sizeBytes;
}

/// A running video compression.
final class CompressionTask {
  /// Creates a task. Platform implementations call this.
  CompressionTask({
    required this.result,
    required Stream<double> progress,
    required Future<void> Function() onCancel,
  }) : progress = progress.asBroadcastStream(),
       _onCancel = onCancel;

  /// Completes when compression ends. Never completes with an error.
  final Future<CompressionResult> result;

  /// Fraction done, from 0 to 1. Closes when [result] completes. Only the root
  /// isolate receives progress; in a background isolate the stream stays
  /// empty.
  final Stream<double> progress;

  final Future<void> Function() _onCancel;

  /// Stops the compression; [result] then completes with
  /// [CompressionStatus.cancelled] unless it has already finished.
  Future<void> cancel() => _onCancel();
}
