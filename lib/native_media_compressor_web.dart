import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'native_media_compressor.dart';

/// Web implementation of `native_media_compressor`.
class NativeMediaCompressorWeb extends NativeMediaCompressorPlatform {
  /// Registers the web implementation with the plugin registrar.
  static void registerWith(Registrar registrar) {
    NativeMediaCompressorPlatform.instance = NativeMediaCompressorWeb();
  }

  @override
  CompressionTask compressVideo({
    required String source,
    required String destination,
    required VideoOptions options,
  }) => CompressionTask(
    result: Future.value(
      const CompressionResult(status: CompressionStatus.unsupported),
    ),
    progress: const Stream.empty(),
    onCancel: () async {},
  );

  @override
  Future<CompressionResult> compressImage({
    required String source,
    required String destination,
    required ImageOptions options,
  }) async => const CompressionResult(status: CompressionStatus.unsupported);

  @override
  Future<ImageMetadata?> probeImage(String source) async => null;

  @override
  Future<VideoMetadata?> probeVideo(String source) async => null;
}
