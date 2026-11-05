import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../types.dart';
import 'browser.dart';
import 'media_plan.dart';
import 'mp4_demuxer.dart';
import 'mp4_muxer.dart';

/// Video probing from the MP4 demuxer.
abstract final class WebVideoProbe {
  static Future<VideoMetadata?> probe(String source) async {
    final blob = await Browser.fetchBlob(source);
    if (blob == null) return null;
    final file = BlobByteSource(blob);
    final Mp4Movie? movie;
    try {
      movie = await Mp4Demuxer.parse(file);
    } on Object {
      return null;
    }
    final video = movie?.video;
    if (movie == null || video == null) return null;
    final quarterTurn = video.rotation % 180 != 0;
    final durationMs = movie.durationMs;
    final audio = movie.audio;
    return VideoMetadata(
      width: quarterTurn ? video.height : video.width,
      height: quarterTurn ? video.width : video.height,
      rotationDegrees: video.rotation,
      duration: Duration(milliseconds: durationMs),
      bitrate: durationMs > 0 ? file.length * 8000 ~/ durationMs : null,
      videoCodec: video.mimeType,
      hasAudio: audio.isNotEmpty,
      isHdr: video.isHdr,
      audioCodec: audio.isEmpty ? null : audio.first.mimeType,
    );
  }
}

final class _Stop implements Exception {
  const _Stop(this.status, [this.message]);

  final CompressionStatus status;
  final String? message;
}

/// One video compression: WebCodecs decode, scale on a canvas, H.264
/// encode, and copied AAC audio, written by [Mp4Muxer].
final class WebVideoJob {
  WebVideoJob({
    required this.source,
    required this.options,
    required void Function(double) onProgress,
  }) : _progress = ProgressThrottle(onProgress);

  static const _keyFrameIntervalUs = 2000000;
  static const _queueLimit = 8;

  final String source;
  final VideoOptions options;
  final ProgressThrottle _progress;

  _Stop? _stop;
  web.VideoDecoder? _decoder;
  web.VideoEncoder? _encoder;

  void cancel() => _halt(const _Stop(CompressionStatus.cancelled));

  void _halt(_Stop stop) {
    _stop ??= stop;
    _closeCodecs();
  }

  void _closeCodecs() {
    for (final close in [() => _decoder?.close(), () => _encoder?.close()]) {
      try {
        close();
      } on Object {
        // Already closed.
      }
    }
  }

  void _check() {
    final stop = _stop;
    if (stop != null) throw stop;
  }

  Future<CompressionResult> run() async {
    try {
      return await _run();
    } on _Stop catch (stop) {
      return CompressionResult(status: stop.status, message: stop.message);
    } on Object catch (error) {
      final stop = _stop;
      if (stop != null) {
        return CompressionResult(status: stop.status, message: stop.message);
      }
      return CompressionResult(
        status: CompressionStatus.failed,
        message: '$error',
      );
    } finally {
      _closeCodecs();
    }
  }

  Future<CompressionResult> _run() async {
    _check();
    if (!Browser.hasWebCodecs) {
      throw const _Stop(
        CompressionStatus.unsupported,
        'this browser has no WebCodecs',
      );
    }
    final blob = await Browser.fetchBlob(source);
    if (blob == null) {
      throw _Stop(CompressionStatus.failed, 'cannot read $source');
    }
    final file = BlobByteSource(blob);
    final movie = await Mp4Demuxer.parse(file);
    if (movie == null) {
      throw const _Stop(
        CompressionStatus.failed,
        'not an MP4 or QuickTime file',
      );
    }
    final video = movie.video;
    if (video == null) {
      throw const _Stop(CompressionStatus.unsupported, 'no video track');
    }
    if (video.samples.isEmpty || video.timescale <= 0) {
      throw const _Stop(
        CompressionStatus.unsupported,
        'fragmented or empty video track',
      );
    }
    final audio = options.includeAudio ? movie.audio : const <Mp4Track>[];
    for (final track in audio) {
      if (!track.isAac || track.esds == null || track.timescale <= 0) {
        throw _Stop(
          CompressionStatus.unsupported,
          'audio ${track.mimeType} cannot be copied without re-encoding',
        );
      }
    }
    _check();

    final decoderConfig = await _decoderConfig(video);
    final quarterTurn = video.rotation % 180 != 0;
    final (shownWidth, shownHeight) = MediaPlan.videoSize(
      quarterTurn ? video.height : video.width,
      quarterTurn ? video.width : video.height,
      options.maxShortSide,
      options.maxLongSide,
    );
    final width = quarterTurn ? shownHeight : shownWidth;
    final height = quarterTurn ? shownWidth : shownHeight;
    final durationUs = _us(video.duration, video.timescale);
    final sourceRate =
        durationUs > 0 ? video.samples.length * 1e6 / durationUs : 30.0;
    final maxRate = options.maxFrameRate;
    final frameRate =
        maxRate != null && maxRate > 0 && maxRate < sourceRate
            ? maxRate.toDouble()
            : sourceRate;
    final encoderConfig = await _encoderConfig(width, height, frameRate);
    _check();

    final muxer = Mp4Muxer();
    final audioBytes = audio.fold(
      0,
      (total, track) =>
          track.samples.fold(total, (sum, sample) => sum + sample.size),
    );
    final audioSamples = audio.fold(0, (n, track) => n + track.samples.length);
    final maxBytes = options.maxBytes;
    int estimatedSize() =>
        muxer.mediaBytes +
        audioBytes +
        2048 +
        32 * (video.samples.length + audioSamples);

    final canvas = web.OffscreenCanvas(width, height);
    final context =
        canvas.getContext('2d')! as web.OffscreenCanvasRenderingContext2D;
    final limiter = FrameRateLimiter(maxRate);
    var nextKeyFrameUs = 0;
    var keptFrames = 0;
    var lastFrameDurationUs =
        durationUs > 0 ? durationUs ~/ video.samples.length : 33333;

    void onFrame(web.VideoFrame frame) {
      final timestamp = frame.timestamp;
      if (_stop != null || timestamp < 0 || !limiter.keep(timestamp)) {
        frame.close();
        return;
      }
      context.drawImage(frame, 0, 0, width, height);
      final frameDuration = frame.duration;
      frame.close();
      if (frameDuration != null && frameDuration > 0) {
        lastFrameDurationUs = frameDuration;
      }
      final scaled = web.VideoFrame(
        canvas,
        web.VideoFrameInit(timestamp: timestamp),
      );
      final keyFrame = keptFrames == 0 || timestamp >= nextKeyFrameUs;
      if (keyFrame) nextKeyFrameUs = timestamp + _keyFrameIntervalUs;
      keptFrames++;
      try {
        _encoder!.encode(
          scaled,
          web.VideoEncoderEncodeOptions(keyFrame: keyFrame),
        );
      } finally {
        scaled.close();
      }
    }

    void onChunk(web.EncodedVideoChunk chunk, JSAny? metadata) {
      if (_stop != null) return;
      if (!muxer.hasVideo) {
        final avcC = Browser.decoderDescription(metadata);
        if (avcC == null) {
          _halt(
            const _Stop(
              CompressionStatus.failed,
              'the encoder gave no avcC configuration',
            ),
          );
          return;
        }
        muxer.setVideo(
          width: width,
          height: height,
          timescale: video.timescale,
          avcC: avcC,
          rotation: video.rotation,
        );
      }
      final data = JSUint8Array.withLength(chunk.byteLength);
      chunk.copyTo(data);
      muxer.addVideoSample(
        data.toDart,
        pts: _ticks(chunk.timestamp, video.timescale),
        duration: _ticks(
          chunk.duration ?? lastFrameDurationUs,
          video.timescale,
        ),
        isSync: chunk.type == 'key',
      );
      if (durationUs > 0) _progress.report(0.95 * chunk.timestamp / durationUs);
      if (maxBytes != null && estimatedSize() > maxBytes) {
        _halt(const _Stop(CompressionStatus.tooLarge));
      }
    }

    void onError(JSAny? error) =>
        _halt(_Stop(CompressionStatus.failed, 'codec error: $error'));

    _encoder = web.VideoEncoder(
      web.VideoEncoderInit(output: onChunk.toJS, error: onError.toJS),
    )..configure(encoderConfig);
    _decoder = web.VideoDecoder(
      web.VideoDecoderInit(output: onFrame.toJS, error: onError.toJS),
    )..configure(decoderConfig);

    var started = false;
    for (final sample in video.samples) {
      _check();
      if (!started && !sample.isSync) continue;
      started = true;
      final data = await file.read(sample.offset, sample.size);
      _check();
      _decoder!.decode(
        web.EncodedVideoChunk(
          web.EncodedVideoChunkInit(
            type: sample.isSync ? 'key' : 'delta',
            timestamp: _us(
              sample.presentationTime - video.editMediaTime,
              video.timescale,
            ),
            duration: _us(sample.duration, video.timescale),
            data: data.toJS,
          ),
        ),
      );
      while (_stop == null &&
          (_decoder!.decodeQueueSize > _queueLimit ||
              _encoder!.encodeQueueSize > _queueLimit)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    _check();
    await _decoder!.flush().toDart;
    _check();
    await _encoder!.flush().toDart;
    _check();
    if (!muxer.hasVideo) {
      throw const _Stop(CompressionStatus.failed, 'no frames were encoded');
    }

    for (final track in audio) {
      final index = muxer.addAudio(track);
      for (final sample in track.samples) {
        _check();
        final data = await file.read(sample.offset, sample.size);
        muxer.addAudioSample(index, Uint8List.fromList(data), sample.duration);
      }
    }

    final parts = muxer.finish();
    final size = parts.fold(0, (total, part) => total + part.length);
    if (maxBytes != null && size > maxBytes) {
      throw const _Stop(CompressionStatus.tooLarge);
    }
    _check();
    final output = web.Blob(
      [for (final part in parts) part.toJS].toJS,
      web.BlobPropertyBag(type: 'video/mp4'),
    );
    _progress.complete();
    return CompressionResult(
      status: CompressionStatus.compressed,
      path: web.URL.createObjectURL(output),
      width: shownWidth,
      height: shownHeight,
      sizeBytes: output.size,
    );
  }

  static int _us(int ticks, int timescale) => (ticks * 1e6 / timescale).round();

  static int _ticks(int us, int timescale) => (us * timescale / 1e6).round();

  static Future<web.VideoDecoderConfig> _decoderConfig(Mp4Track video) async {
    final codec = video.codecString;
    if (codec == null) {
      throw _Stop(
        CompressionStatus.unsupported,
        'cannot decode ${video.mimeType}',
      );
    }
    final config = web.VideoDecoderConfig(
      codec: codec,
      codedWidth: video.width,
      codedHeight: video.height,
    );
    final description = video.codecConfig;
    if (description != null && video.sampleEntryType != 'vp09') {
      config.description = description.toJS;
    }
    try {
      final support = await web.VideoDecoder.isConfigSupported(config).toDart;
      if (support.supported) return config;
    } on Object {
      // A config the browser cannot parse is as unsupported as a missing
      // decoder.
    }
    throw _Stop(
      CompressionStatus.unsupported,
      'the browser cannot decode $codec',
    );
  }

  Future<web.VideoEncoderConfig> _encoderConfig(
    int width,
    int height,
    double frameRate,
  ) async {
    for (final codec in MediaPlan.avcCodecs(width, height, frameRate)) {
      final config = web.VideoEncoderConfig(
        codec: codec,
        width: width,
        height: height,
        bitrate: options.videoBitrate,
        framerate: frameRate,
        avc: web.AvcEncoderConfig(format: 'avc'),
      );
      try {
        final support = await web.VideoEncoder.isConfigSupported(config).toDart;
        if (support.supported) return config;
      } on Object {
        // Try the next profile.
      }
    }
    throw _Stop(
      CompressionStatus.unsupported,
      'the browser cannot encode H.264 at ${width}x$height',
    );
  }
}
