import 'dart:async';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'native_media_compressor.dart';
import 'src/web/web_image.dart';
import 'src/web/web_video.dart';

/// Web implementation of `native_media_compressor`, on WebCodecs for video
/// and `createImageBitmap` with `OffscreenCanvas` for images.
///
/// Sources are `blob:`, `data:` or same-origin (or CORS-enabled) `http(s):`
/// URLs. Destinations are ignored: a compressed result's `path` is a new
/// object URL of the output, which the caller revokes when done with it.
class NativeMediaCompressorWeb extends NativeMediaCompressorPlatform {
  /// Registers the web implementation with the plugin registrar.
  static void registerWith(Registrar registrar) {
    NativeMediaCompressorPlatform.instance = NativeMediaCompressorWeb();
  }

  Future<void> _videoQueue = Future.value();

  @override
  CompressionTask compressVideo({
    required String source,
    required String destination,
    required VideoOptions options,
  }) {
    final progress = StreamController<double>();
    final job = WebVideoJob(
      source: source,
      options: options,
      onProgress: progress.add,
    );
    final result = Completer<CompressionResult>();
    _videoQueue = _videoQueue.then((_) async {
      result.complete(await job.run());
      // ignore: unawaited_futures
      progress.close();
    });

    return CompressionTask(
      result: result.future,
      progress: progress.stream,
      onCancel: () async => job.cancel(),
    );
  }

  @override
  Future<CompressionResult> compressImage({
    required String source,
    required String destination,
    required ImageOptions options,
  }) async {
    try {
      return await WebImage.compress(source, options);
    } on Object catch (error) {
      return CompressionResult(
        status: CompressionStatus.failed,
        message: '$error',
      );
    }
  }

  @override
  Future<ImageMetadata?> probeImage(String source) async {
    try {
      return await WebImage.probe(source);
    } on Object {
      return null;
    }
  }

  @override
  Future<VideoMetadata?> probeVideo(String source) =>
      WebVideoProbe.probe(source);
}
