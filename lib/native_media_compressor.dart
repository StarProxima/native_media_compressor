/// Compresses images and videos with the platform's own codecs.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'src/files/staged_files.dart';
import 'src/planning.dart';
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
  static NativeMediaCompressorPlatform get _platform =>
      NativeMediaCompressorPlatform.instance;

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
    VideoOptions options = VideoOptions.balanced,
  }) {
    final job = _VideoJob(source, destination, options);

    return CompressionTask(
      result: job.run(),
      progress: job.progress.stream,
      onCancel: job.cancel,
    );
  }

  /// Compresses the image at [source] into [destination].
  ///
  /// [source] and [destination] follow the same rules as in [compressVideo].
  static Future<CompressionResult> compressImage({
    required String source,
    required String destination,
    ImageOptions options = ImageOptions.balanced,
  }) async {
    try {
      return await _compressImage(source, destination, options);
    } on Object catch (error) {
      return CompressionResult(
        status: CompressionStatus.failed,
        message: '$error',
      );
    }
  }

  /// Compresses an image held in memory, such as a camera frame or a
  /// download, without writing files of the caller's own.
  static Future<ImageBytesResult> compressImageBytes(
    Uint8List bytes, {
    ImageOptions options = ImageOptions.balanced,
  }) async {
    TempSpace? space;
    try {
      space = await TempSpace.create();
      final source = await space.write(bytes);
      final extension = options.format == ImageFormat.png ? 'png' : 'jpg';
      final result = await _compressImage(
        source,
        space.output(extension),
        options,
        sourceBytes: bytes.length,
      );
      if (!result.isCompressed) {
        return ImageBytesResult(status: result.status, message: result.message);
      }
      final output = await StagedFiles.read(result.path!);
      await StagedFiles.discard(result.path);

      return ImageBytesResult(
        status: result.status,
        bytes: output,
        width: result.width,
        height: result.height,
      );
    } on Object catch (error) {
      return ImageBytesResult(
        status: CompressionStatus.failed,
        message: '$error',
      );
    } finally {
      await space?.dispose();
    }
  }

  /// Saves the frame at [position] of the video at [source] as an image at
  /// [destination], scaled down to fit [options] like [compressImage].
  ///
  /// A [position] past the end gives the last frame. On the web the result
  /// points to an object URL.
  static Future<CompressionResult> videoThumbnail({
    required String source,
    required String destination,
    Duration position = Duration.zero,
    ImageOptions options = const ImageOptions(maxLongSide: 512),
  }) async {
    try {
      return await _platform.videoThumbnail(
        source: source,
        destination: destination,
        position: position,
        options: options,
      );
    } on Object catch (error) {
      return CompressionResult(
        status: CompressionStatus.failed,
        message: '$error',
      );
    }
  }

  /// Reads the image size and frame count without decoding the pixels.
  ///
  /// Returns null when the platform cannot read the image.
  static Future<ImageMetadata?> probeImage(String source) =>
      _platform.probeImage(source);

  /// Reads the video size, rotation, duration and codecs without decoding.
  ///
  /// Returns null when the platform cannot read the video.
  static Future<VideoMetadata?> probeVideo(String source) =>
      _platform.probeVideo(source);

  /// Predicts the output size, frame and bitrate [options] give for the
  /// video at [source], from its headers and without encoding.
  ///
  /// Returns null when the platform cannot read the video.
  static Future<VideoEstimate?> estimateVideo(
    String source, {
    VideoOptions options = VideoOptions.balanced,
  }) async {
    final metadata = await _platform.probeVideo(source);

    return metadata == null ? null : VideoPlanning.estimate(metadata, options);
  }

  static Future<CompressionResult> _compressImage(
    String source,
    String destination,
    ImageOptions options, {
    int? sourceBytes,
  }) async {
    final targetBytes = options.targetBytes;
    final minSavings = options.minSavingsPercent;
    if (targetBytes == null && minSavings == null) {
      return _platform.compressImage(
        source: source,
        destination: destination,
        options: options,
      );
    }
    final sourceSize =
        minSavings == null
            ? null
            : sourceBytes ?? await StagedFiles.sizeOf(source);

    CompressionResult? best;
    var attempt = options;
    for (var i = 0; i < ImagePlanning.maxAttempts; i++) {
      final result = await _platform.compressImage(
        source: source,
        destination: StagedFiles.stagingFor(destination),
        options: attempt,
      );
      if (!result.isCompressed) {
        if (best == null) return result;
        break;
      }
      if (best == null || _size(result) < _size(best)) {
        await StagedFiles.discard(best?.path);
        best = result;
      } else {
        await StagedFiles.discard(result.path);
      }
      if (targetBytes == null) break;
      final next = ImagePlanning.nextAttempt(
        attempt,
        sizeBytes: _size(result),
        targetBytes: targetBytes,
        longSide: math.max(result.width ?? 0, result.height ?? 0),
      );
      if (next == null) break;
      attempt = next;
    }

    return _keep(
      best!,
      destination: destination,
      sourceBytes: sourceSize,
      minSavingsPercent: minSavings,
    );
  }

  /// Moves the staged output of [result] into place, or drops it when it
  /// does not save [minSavingsPercent] of [sourceBytes].
  static Future<CompressionResult> _keep(
    CompressionResult result, {
    required String destination,
    required int? sourceBytes,
    required int? minSavingsPercent,
  }) async {
    if (minSavingsPercent != null &&
        sourceBytes != null &&
        !Savings.enough(
          outputBytes: _size(result),
          sourceBytes: sourceBytes,
          minSavingsPercent: minSavingsPercent,
        )) {
      await StagedFiles.discard(result.path);

      return CompressionResult(
        status: CompressionStatus.skipped,
        width: result.width,
        height: result.height,
        sizeBytes: result.sizeBytes,
        message:
            'the output is ${_size(result)} bytes, the source $sourceBytes',
      );
    }
    try {
      return CompressionResult(
        status: result.status,
        path: await StagedFiles.commit(result.path!, destination),
        width: result.width,
        height: result.height,
        sizeBytes: result.sizeBytes,
        message: result.message,
        videoCodec: result.videoCodec,
      );
    } on Object catch (error) {
      await StagedFiles.discard(result.path);

      return CompressionResult(
        status: CompressionStatus.failed,
        message: 'cannot move the output into place: $error',
      );
    }
  }

  static int _size(CompressionResult result) => result.sizeBytes ?? 0;
}

/// A video compression that first resolves [VideoOptions] against the
/// source, then runs on the platform.
final class _VideoJob {
  _VideoJob(this.source, this.destination, this.options);

  final String source;
  final String destination;
  final VideoOptions options;
  final progress = StreamController<double>();

  CompressionTask? _task;
  var _isCancelled = false;

  Future<CompressionResult> run() async {
    try {
      return await _run();
    } on Object catch (error) {
      return CompressionResult(
        status: CompressionStatus.failed,
        message: '$error',
      );
    } finally {
      // ignore: unawaited_futures
      progress.close();
    }
  }

  Future<void> cancel() async {
    _isCancelled = true;
    await _task?.cancel();
  }

  Future<CompressionResult> _run() async {
    final platform = NativeMediaCompressorPlatform.instance;
    VideoMetadata? metadata;
    try {
      metadata = await platform.probeVideo(source);
    } on Object {
      // Without the source's numbers the options keep their own bitrate.
    }
    final minSavings = options.minSavingsPercent;
    final sourceBytes =
        minSavings == null ? null : await StagedFiles.sizeOf(source);
    final isStaged = sourceBytes != null;
    if (_isCancelled) {
      return const CompressionResult(status: CompressionStatus.cancelled);
    }

    final task = platform.compressVideo(
      source: source,
      destination: isStaged ? StagedFiles.stagingFor(destination) : destination,
      options: options.copyWith(
        videoBitrate: VideoPlanning.videoBitrate(metadata, options),
      ),
    );
    _task = task;
    final forwarding = task.progress.listen(progress.add);
    // A cancel that arrived while the task was being created.
    if (_isCancelled) await task.cancel();
    final result = await task.result;
    await forwarding.cancel();
    if (!isStaged || !result.isCompressed) return result;

    return NativeMediaCompressor._keep(
      result,
      destination: destination,
      sourceBytes: sourceBytes,
      minSavingsPercent: minSavings,
    );
  }
}
