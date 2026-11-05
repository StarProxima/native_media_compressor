import 'dart:async';

/// How a compression ended.
///
/// Every status except [compressed] leaves no file at the destination.
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
}

/// Output format for [ImageOptions.format].
enum ImageFormat {
  /// Lossy JPEG; [ImageOptions.quality] applies.
  jpeg,

  /// Lossless PNG; [ImageOptions.quality] is ignored.
  png,
}

/// Video compression settings.
///
/// The frame is only ever scaled down, keeping its aspect ratio, until it fits
/// both [maxShortSide] and [maxLongSide]. The output is SDR H.264 video in an
/// MP4 container: HDR input is tone-mapped. AAC audio is copied without
/// re-encoding.
final class VideoOptions {
  /// Creates video compression settings.
  const VideoOptions({
    this.maxShortSide = 720,
    this.maxLongSide,
    this.videoBitrate = 2500000,
    this.maxFrameRate = 30,
    this.maxBytes,
    this.includeAudio = true,
  });

  /// Upper bound for the shorter side of the frame, in pixels.
  final int? maxShortSide;

  /// Upper bound for the longer side of the frame, in pixels.
  final int? maxLongSide;

  /// Target video bitrate, in bits per second.
  final int videoBitrate;

  /// Frames above this rate are dropped where the platform supports it.
  final int? maxFrameRate;

  /// Compression stops with [CompressionStatus.tooLarge] as soon as the output
  /// exceeds this many bytes.
  final int? maxBytes;

  /// Whether to keep the audio tracks. Inputs with non-AAC audio are
  /// [CompressionStatus.unsupported] unless this is false.
  final bool includeAudio;
}

/// Image compression settings.
///
/// The image is only ever scaled down, keeping its aspect ratio, until it fits
/// both [maxShortSide] and [maxLongSide]. EXIF orientation is applied to the
/// pixels, and metadata is not copied. Animated images keep only the first
/// frame.
final class ImageOptions {
  /// Creates image compression settings.
  const ImageOptions({
    this.maxShortSide,
    this.maxLongSide = 2048,
    this.format = ImageFormat.jpeg,
    this.quality = 85,
  }) : assert(quality >= 0 && quality <= 100);

  /// Upper bound for the shorter side, in pixels.
  final int? maxShortSide;

  /// Upper bound for the longer side, in pixels.
  final int? maxLongSide;

  /// Output format.
  final ImageFormat format;

  /// Encoder quality from 0 to 100 for lossy formats.
  final int quality;
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

  /// Whether the output was written.
  bool get isCompressed => status == CompressionStatus.compressed;

  @override
  String toString() =>
      'CompressionResult($status, path: $path, ${width}x$height, '
      'sizeBytes: $sizeBytes${message == null ? '' : ', message: $message'})';
}

/// Image parameters read from the file header without decoding the pixels.
final class ImageMetadata {
  /// Creates image metadata.
  const ImageMetadata({
    required this.width,
    required this.height,
    required this.frameCount,
    this.mimeType,
  });

  /// Width in pixels after EXIF orientation is applied.
  final int width;

  /// Height in pixels after EXIF orientation is applied.
  final int height;

  /// Number of frames; above 1 for animated images.
  final int frameCount;

  /// MIME type the platform detected, such as `image/heic`.
  final String? mimeType;

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
  /// camera recordings do by default. Compression converts it to SDR.
  final bool isHdr;

  /// Whether there is at least one audio track.
  final bool hasAudio;

  /// Codec MIME type of the first audio track, such as `audio/mp4a-latm`.
  final String? audioCodec;
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

  /// Fraction done, from 0 to 1. Closes when [result] completes.
  final Stream<double> progress;

  final Future<void> Function() _onCancel;

  /// Stops the compression; [result] then completes with
  /// [CompressionStatus.cancelled] unless it has already finished.
  Future<void> cancel() => _onCancel();
}
