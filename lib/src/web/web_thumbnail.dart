import '../types.dart';

/// Video frames as images on the web.
abstract final class WebVideoThumbnail {
  /// Captures the frame at [position] of [source] as an image object URL.
  static Future<CompressionResult> capture(
    String source,
    Duration position,
    ImageOptions options,
  ) async => const CompressionResult(
    status: CompressionStatus.unsupported,
    message: 'video thumbnails are not implemented on the web yet',
  );
}
