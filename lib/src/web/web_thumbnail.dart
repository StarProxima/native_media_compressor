import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import '../types.dart';
import 'browser.dart';
import 'media_plan.dart';
import 'mp4_demuxer.dart';
import 'trim_range.dart';
import 'web_video.dart';

/// Video frames as images on the web, decoded with WebCodecs.
abstract final class WebVideoThumbnail {
  /// Captures the frame at [position] of [source] as an image object URL.
  static Future<CompressionResult> capture(
    String source,
    Duration position,
    ImageOptions options,
  ) async {
    if (!Browser.hasWebCodecs) {
      return _result(
        CompressionStatus.unsupported,
        'this browser has no WebCodecs',
      );
    }
    final blob = await Browser.fetchBlob(source);
    if (blob == null) {
      return _result(CompressionStatus.failed, 'cannot read $source');
    }
    final file = BlobByteSource(blob);
    final movie = await Mp4Demuxer.parse(file);
    if (movie == null) {
      return await WebVideoSource.isMatroska(file)
          ? _result(
            CompressionStatus.unsupported,
            'Matroska and WebM are not read on the web',
          )
          : _result(CompressionStatus.failed, 'not an MP4 or QuickTime file');
    }
    final video = movie.video;
    if (video == null || video.samples.isEmpty || video.timescale <= 0) {
      return _result(CompressionStatus.unsupported, 'no video frames');
    }
    final config = await WebVideoSource.decoderConfig(video);
    if (config == null) {
      return _result(
        CompressionStatus.unsupported,
        'the browser cannot decode ${video.codecString ?? video.mimeType}',
      );
    }

    final frame = await _decode(file, video, config, position.inMicroseconds);
    if (frame == null) {
      return _result(CompressionStatus.failed, 'no frame was decoded');
    }
    try {
      return await _encode(frame, video.rotation, options);
    } finally {
      frame.close();
    }
  }

  /// Decodes from the sync sample before the frame shown at [positionUs] up
  /// to that frame, and returns it.
  static Future<web.VideoFrame?> _decode(
    ByteSource file,
    Mp4Track video,
    web.VideoDecoderConfig config,
    int positionUs,
  ) async {
    final target = TrimRange.frameAt(video, positionUs);
    final (first, end) = TrimRange(target, target + 1).videoSamples(video);
    web.VideoFrame? best;
    Object? failure;

    // The frame shown at the target time is the latest one not after it.
    bool closer(int time, int than) =>
        time <= target ? than > target || time > than : time < than;

    void onFrame(web.VideoFrame frame) {
      final current = best;
      if (current == null || closer(frame.timestamp, current.timestamp)) {
        current?.close();
        best = frame;
      } else {
        frame.close();
      }
    }

    void onError(JSAny? error) => failure ??= error;

    final decoder = web.VideoDecoder(
      web.VideoDecoderInit(output: onFrame.toJS, error: onError.toJS),
    )..configure(config);
    try {
      for (var i = first; i < end && failure == null; i++) {
        decoder.decode(
          await WebVideoSource.chunk(file, video, video.samples[i]),
        );
      }
      if (failure == null) await decoder.flush().toDart;
    } on Object catch (error) {
      failure ??= error;
    } finally {
      try {
        decoder.close();
      } on Object {
        // Already closed after an error.
      }
    }
    if (failure != null) {
      best?.close();
      return null;
    }
    return best;
  }

  static Future<CompressionResult> _encode(
    web.VideoFrame frame,
    int rotation,
    ImageOptions options,
  ) async {
    final quarterTurn = rotation % 180 != 0;
    final storedWidth = frame.displayWidth;
    final storedHeight = frame.displayHeight;
    final (width, height) = MediaPlan.imageSize(
      quarterTurn ? storedHeight : storedWidth,
      quarterTurn ? storedWidth : storedHeight,
      options.maxShortSide,
      options.maxLongSide,
    );
    final type = options.format == ImageFormat.png ? 'image/png' : 'image/jpeg';
    final web.Blob output;
    try {
      final canvas = web.OffscreenCanvas(width, height);
      final context =
          canvas.getContext('2d')! as web.OffscreenCanvasRenderingContext2D
            ..imageSmoothingQuality = 'high';
      if (type == 'image/jpeg') {
        context.fillStyle = 'white'.toJS;
        context.fillRect(0, 0, width, height);
      }
      switch (rotation) {
        case 90:
          context
            ..translate(width, 0)
            ..rotate(math.pi / 2);
        case 180:
          context
            ..translate(width, height)
            ..rotate(math.pi);
        case 270:
          context
            ..translate(0, height)
            ..rotate(-math.pi / 2);
      }
      context.drawImage(
        frame,
        0,
        0,
        quarterTurn ? height : width,
        quarterTurn ? width : height,
      );
      output =
          await canvas
              .convertToBlob(
                web.ImageEncodeOptions(
                  type: type,
                  quality: options.quality / 100,
                ),
              )
              .toDart;
    } on Object catch (error) {
      return _result(CompressionStatus.failed, 'encoding failed: $error');
    }
    // Browsers fall back to PNG for types they cannot encode.
    if (output.type != type) {
      return _result(
        CompressionStatus.unsupported,
        'the browser cannot encode $type',
      );
    }
    return CompressionResult(
      status: CompressionStatus.compressed,
      path: web.URL.createObjectURL(output),
      width: width,
      height: height,
      sizeBytes: output.size,
    );
  }

  static CompressionResult _result(CompressionStatus status, String message) =>
      CompressionResult(status: status, message: message);
}
