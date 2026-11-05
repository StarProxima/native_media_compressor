/// Compresses images and videos with the platform's own codecs.
library;

import 'src/platform.dart';
import 'src/types.dart';

export 'src/platform.dart' show NativeMediaCompressorPlatform;
export 'src/types.dart';

/// Compresses images and videos with the codecs the platform already ships:
/// MediaCodec on Android, AVFoundation and ImageIO on iOS and macOS, Media
/// Foundation and WIC on Windows, GStreamer and gdk-pixbuf on Linux, WebCodecs
/// and canvas on the web.
///
/// Nothing here throws on bad input or a missing codec: the result carries a
/// [CompressionStatus] instead, and the destination is not touched unless the
/// status is [CompressionStatus.compressed].
abstract final class NativeMediaCompressor {
  /// Compresses the video at [source] into an MP4 file at [destination].
  ///
  /// [source] is a file path, a `content://` URI on Android, or a `blob:`
  /// URL on the web. [destination] is a file path; on the web it is ignored
  /// and the result points to an object URL. An existing file at
  /// [destination] is replaced on success; [destination] may equal [source]
  /// to compress in place.
  ///
  /// Videos are compressed one at a time; a second call waits for the first
  /// to finish.
  static CompressionTask compressVideo({
    required String source,
    required String destination,
    VideoOptions options = const VideoOptions(),
  }) => NativeMediaCompressorPlatform.instance.compressVideo(
    source: source,
    destination: destination,
    options: options,
  );

  /// Compresses the image at [source] into [destination].
  ///
  /// [source] and [destination] follow the same rules as in [compressVideo].
  static Future<CompressionResult> compressImage({
    required String source,
    required String destination,
    ImageOptions options = const ImageOptions(),
  }) => NativeMediaCompressorPlatform.instance.compressImage(
    source: source,
    destination: destination,
    options: options,
  );

  /// Reads the image size and frame count without decoding the pixels.
  ///
  /// Returns null when the platform cannot read the image.
  static Future<ImageMetadata?> probeImage(String source) =>
      NativeMediaCompressorPlatform.instance.probeImage(source);

  /// Reads the video size, rotation, duration and codecs without decoding.
  ///
  /// Returns null when the platform cannot read the video.
  static Future<VideoMetadata?> probeVideo(String source) =>
      NativeMediaCompressorPlatform.instance.probeVideo(source);
}
