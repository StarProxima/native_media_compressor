import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'messages.g.dart' as pigeon;
import 'planning.dart';
import 'types.dart';

/// Platform implementation of `native_media_compressor`.
///
/// Platform packages extend this class and set [instance] when they register.
abstract class NativeMediaCompressorPlatform extends PlatformInterface {
  /// Creates a platform implementation.
  NativeMediaCompressorPlatform() : super(token: _token);

  static final Object _token = Object();

  static NativeMediaCompressorPlatform _instance = PigeonMediaCompressor();

  /// The implementation in use.
  static NativeMediaCompressorPlatform get instance => _instance;

  static set instance(NativeMediaCompressorPlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// See `NativeMediaCompressor.compressVideo`.
  CompressionTask compressVideo({
    required String source,
    required String destination,
    required VideoOptions options,
  });

  /// See `NativeMediaCompressor.compressImage`.
  Future<CompressionResult> compressImage({
    required String source,
    required String destination,
    required ImageOptions options,
  });

  /// See `NativeMediaCompressor.probeImage`.
  Future<ImageMetadata?> probeImage(String source);

  /// See `NativeMediaCompressor.probeVideo`.
  Future<VideoMetadata?> probeVideo(String source);

  /// See `NativeMediaCompressor.androidForegroundNotification`. Only the
  /// Android implementation does something with it.
  Future<void> setForegroundNotification(
    AndroidForegroundNotification? notification,
  ) async {}

  /// See `NativeMediaCompressor.videoThumbnail`.
  Future<CompressionResult> videoThumbnail({
    required String source,
    required String destination,
    required Duration position,
    required ImageOptions options,
  });
}

/// Implementation over the host platform channel, used on every platform
/// except the web.
class PigeonMediaCompressor extends NativeMediaCompressorPlatform
    implements pigeon.MediaCompressorFlutterApi {
  static const _maxFrameRate = 240;

  /// Creates an implementation that talks to the host through
  /// [binaryMessenger], or through the default messenger when it is null.
  PigeonMediaCompressor({BinaryMessenger? binaryMessenger})
    : _binaryMessenger = binaryMessenger,
      _host = pigeon.MediaCompressorHostApi(binaryMessenger: binaryMessenger);

  final BinaryMessenger? _binaryMessenger;
  final pigeon.MediaCompressorHostApi _host;
  final _progress = <int, void Function(double)>{};

  // A hot restart starts a new isolate while the host may still run tasks of
  // the old one, so ids must not start from the same number every time.
  var _nextTaskId = Random().nextInt(1 << 30);
  var _isListening = false;

  @override
  CompressionTask compressVideo({
    required String source,
    required String destination,
    required VideoOptions options,
  }) {
    _listen();
    final taskId = _nextTaskId++;
    final progress = StreamController<double>();
    _progress[taskId] = progress.add;
    final request = pigeon.VideoRequest(
      source: source,
      destination: destination,
      maxShortSide: options.maxShortSide,
      maxLongSide: options.maxLongSide,
      videoBitrate: VideoPlanning.videoBitrate(null, options),
      maxFrameRate: options.maxFrameRate?.clamp(1, _maxFrameRate),
      maxBytes: options.maxBytes,
      includeAudio: options.includeAudio,
      codec: pigeon.VideoCodec.values[options.codec.index],
      startMs: options.trimStart?.inMilliseconds,
      endMs: options.trimEnd?.inMilliseconds,
      rotateQuarterTurns: options.rotateQuarterTurns,
      audioBitrate: options.audioBitrate,
    );
    final result = _guard(
      () => _host.compressVideo(taskId, request),
      path: destination,
    ).whenComplete(() {
      _progress.remove(taskId);
      // ignore: unawaited_futures
      progress.close();
    });

    return CompressionTask(
      result: result,
      progress: progress.stream,
      onCancel: () async {
        if (!_progress.containsKey(taskId)) return;
        try {
          await _host.cancel(taskId);
        } on PlatformException {
          // The task finished on the host before the cancel arrived.
        } on MissingPluginException {
          // Nothing to cancel.
        }
      },
    );
  }

  @override
  Future<CompressionResult> compressImage({
    required String source,
    required String destination,
    required ImageOptions options,
  }) {
    final request = pigeon.ImageRequest(
      source: source,
      destination: destination,
      maxShortSide: options.maxShortSide,
      maxLongSide: options.maxLongSide,
      format: pigeon.ImageFormat.values[options.format.index],
      quality: options.quality,
      keepMetadata: options.keepMetadata,
    );

    return _guard(() => _host.compressImage(request), path: destination);
  }

  @override
  Future<ImageMetadata?> probeImage(String source) async {
    try {
      final probe = await _host.probeImage(source);
      if (probe == null) return null;

      return ImageMetadata(
        width: probe.width,
        height: probe.height,
        frameCount: probe.frameCount,
        mimeType: probe.mimeType,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<VideoMetadata?> probeVideo(String source) async {
    try {
      final probe = await _host.probeVideo(source);
      if (probe == null) return null;

      return VideoMetadata(
        width: probe.width,
        height: probe.height,
        rotationDegrees: probe.rotationDegrees,
        duration: Duration(milliseconds: probe.durationMs),
        bitrate: probe.bitrate,
        videoCodec: probe.videoCodec,
        hasAudio: probe.hasAudio,
        isHdr: probe.isHdr,
        audioCodec: probe.audioCodec,
        frameRate: probe.frameRate,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<CompressionResult> videoThumbnail({
    required String source,
    required String destination,
    required Duration position,
    required ImageOptions options,
  }) {
    final request = pigeon.ThumbnailRequest(
      source: source,
      destination: destination,
      positionMs: position.inMilliseconds,
      maxShortSide: options.maxShortSide,
      maxLongSide: options.maxLongSide,
      format: pigeon.ImageFormat.values[options.format.index],
      quality: options.quality,
    );

    return _guard(() => _host.videoThumbnail(request), path: destination);
  }

  @override
  Future<void> setForegroundNotification(
    AndroidForegroundNotification? notification,
  ) async {
    try {
      await _host.setForegroundNotification(
        notification == null
            ? null
            : pigeon.ForegroundNotification(
              title: notification.title,
              text: notification.text,
              iconResource: notification.iconResource,
              channelName: notification.channelName,
            ),
      );
    } on PlatformException {
      // Not supported on this platform.
    } on MissingPluginException {
      // Not supported on this platform.
    }
  }

  @override
  void onProgress(int taskId, double progress) {
    _progress[taskId]?.call(progress.clamp(0, 1).toDouble());
  }

  void _listen() {
    if (_isListening) return;
    try {
      pigeon.MediaCompressorFlutterApi.setUp(
        this,
        binaryMessenger: _binaryMessenger,
      );
      _isListening = true;
    } on UnsupportedError {
      // Background isolates cannot receive platform messages, so progress is
      // only reported to the root isolate; compression itself still works.
    }
  }

  static Future<CompressionResult> _guard(
    Future<pigeon.CompressionReply> Function() call, {
    required String path,
  }) async {
    try {
      final reply = await call();
      final status = CompressionStatus.values[reply.status.index];

      return CompressionResult(
        status: status,
        path: status == CompressionStatus.compressed ? path : null,
        width: reply.width,
        height: reply.height,
        sizeBytes: reply.sizeBytes,
        message: reply.message,
        videoCodec: switch (reply.videoCodec) {
          'video/avc' => VideoCodec.h264,
          'video/hevc' => VideoCodec.hevc,
          _ => null,
        },
      );
    } on PlatformException catch (error) {
      return CompressionResult(
        // Pigeon reports a channel nobody listens to on this platform as
        // channel-error.
        status:
            error.code == 'channel-error'
                ? CompressionStatus.unsupported
                : CompressionStatus.failed,
        message: '${error.code}: ${error.message}',
      );
    } on MissingPluginException {
      return const CompressionResult(status: CompressionStatus.unsupported);
    }
  }
}
