import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../planning.dart';
import '../types.dart';
import 'browser.dart';
import 'media_plan.dart';
import 'mp4_demuxer.dart';
import 'mp4_muxer.dart';
import 'trim_range.dart';
import 'web_audio.dart';

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
      frameRate: video.frameRate,
    );
  }
}

/// Reading the video track of a source, shared by compression and
/// thumbnails.
abstract final class WebVideoSource {
  /// Matroska and WebM files start with the EBML magic number.
  static Future<bool> isMatroska(ByteSource file) async {
    if (file.length < 4) return false;
    final head = await file.read(0, 4);

    return head[0] == 0x1A &&
        head[1] == 0x45 &&
        head[2] == 0xDF &&
        head[3] == 0xA3;
  }

  /// Decoder configuration for [video], or null when the browser cannot
  /// decode it.
  static Future<web.VideoDecoderConfig?> decoderConfig(Mp4Track video) async {
    final codec = video.codecString;
    if (codec == null) return null;
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
    return null;
  }

  /// Decoder input for [sample] of [video], read from [file].
  static Future<web.EncodedVideoChunk> chunk(
    ByteSource file,
    Mp4Track video,
    Mp4Sample sample,
  ) async {
    final data = await file.read(sample.offset, sample.size);
    return web.EncodedVideoChunk(
      web.EncodedVideoChunkInit(
        type: sample.isSync ? 'key' : 'delta',
        timestamp: TrimRange.presentationUs(video, sample),
        duration: (sample.duration * 1e6 / video.timescale).round(),
        data: data.toJS,
      ),
    );
  }
}

final class _Stop implements Exception {
  const _Stop(this.status, [this.message]);

  final CompressionStatus status;
  final String? message;
}

/// One video compression: WebCodecs decode, scale on a canvas, H.264 or
/// HEVC encode, and AAC audio copied or re-encoded, written by [Mp4Muxer].
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
  final _transcoders = <AacTranscoder>[];

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
    for (final transcoder in _transcoders) {
      transcoder.close();
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
      throw await WebVideoSource.isMatroska(file)
          ? const _Stop(
            CompressionStatus.unsupported,
            'Matroska and WebM are not read on the web',
          )
          : const _Stop(
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
    final range = TrimRange.of(
      options.trimStart,
      options.trimEnd,
      TrimRange.videoEndUs(video),
    );
    final (firstSample, endSample) = range?.videoSamples(video) ?? (0, 0);
    if (range == null || endSample <= firstSample) {
      throw const _Stop(
        CompressionStatus.unsupported,
        'the trim range keeps no part of the video',
      );
    }

    final audio = <(Mp4Track, AacTranscoder?)>[];
    for (final track in options.includeAudio ? movie.audio : <Mp4Track>[]) {
      if (track.timescale <= 0) {
        throw _Stop(
          CompressionStatus.unsupported,
          'audio ${track.mimeType} has no timescale',
        );
      }
      if (track.isAac && track.esds != null) {
        audio.add((track, null));
        continue;
      }
      final transcoder = await AacTranscoder.create(
        track,
        options.audioBitrate,
      );
      if (transcoder == null) {
        throw _Stop(
          CompressionStatus.unsupported,
          'audio ${track.mimeType} cannot be re-encoded to AAC in this '
          'browser',
        );
      }
      _transcoders.add(transcoder);
      audio.add((track, transcoder));
    }
    _check();

    final decoderConfig = await WebVideoSource.decoderConfig(video);
    if (decoderConfig == null) {
      throw _Stop(
        CompressionStatus.unsupported,
        'the browser cannot decode ${video.codecString ?? video.mimeType}',
      );
    }
    final (width, height) = MediaPlan.videoSize(
      video.width,
      video.height,
      options.maxShortSide,
      options.maxLongSide,
    );
    // The turn is written to the track matrix like the source rotation, so
    // frames are encoded as stored.
    final rotation = (video.rotation + 90 * options.rotateQuarterTurns) % 360;
    final (shownWidth, shownHeight) =
        rotation % 180 != 0 ? (height, width) : (width, height);
    final sourceRate = video.frameRate ?? 30.0;
    final maxRate = options.maxFrameRate?.clamp(1, 240);
    final frameRate =
        maxRate != null && maxRate > 0 && maxRate < sourceRate
            ? maxRate.toDouble()
            : sourceRate;
    final (encoderConfig, hevc) = await _encoderConfig(
      width,
      height,
      frameRate,
    );
    _check();

    final muxer = Mp4Muxer();
    var audioBytes = 0;
    var audioSamples = 0;
    for (final (track, transcoder) in audio) {
      final (first, end, _) = range.audioSamples(track);
      audioSamples += end - first;
      if (transcoder != null) {
        audioBytes += transcoder.bitrate * range.durationUs ~/ 8000000;
        continue;
      }
      for (var i = first; i < end; i++) {
        audioBytes += track.samples[i].size;
      }
    }
    final maxBytes = options.maxBytes;
    int estimatedSize() =>
        muxer.mediaBytes +
        audioBytes +
        2048 +
        32 * (endSample - firstSample + audioSamples);

    final canvas = web.OffscreenCanvas(width, height);
    final context =
        canvas.getContext('2d')! as web.OffscreenCanvasRenderingContext2D;
    final limiter = FrameRateLimiter(maxRate);
    var nextKeyFrameUs = 0;
    var keptFrames = 0;
    var lastFrameDurationUs = (1e6 / sourceRate).round();

    void onFrame(web.VideoFrame frame) {
      final sourceTime = frame.timestamp;
      final timestamp = sourceTime - range.startUs;
      if (_stop != null ||
          !range.keeps(sourceTime) ||
          !limiter.keep(timestamp)) {
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
        final config = Browser.decoderDescription(metadata);
        if (config == null) {
          _halt(
            _Stop(
              CompressionStatus.failed,
              'the encoder gave no ${hevc ? 'hvcC' : 'avcC'} configuration',
            ),
          );
          return;
        }
        muxer.setVideo(
          width: width,
          height: height,
          timescale: video.timescale,
          config: config,
          hevc: hevc,
          rotation: rotation,
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
      _progress.report(0.95 * chunk.timestamp / range.durationUs);
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

    for (var i = firstSample; i < endSample; i++) {
      _check();
      final chunk = await WebVideoSource.chunk(file, video, video.samples[i]);
      _check();
      _decoder!.decode(chunk);
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

    for (final (track, transcoder) in audio) {
      final (first, end, skip) = range.audioSamples(track);
      if (end <= first) continue;
      if (transcoder == null) {
        final index = muxer.addAudio(track, editMediaTime: skip);
        for (var i = first; i < end; i++) {
          _check();
          final sample = track.samples[i];
          final data = await file.read(sample.offset, sample.size);
          muxer.addAudioSample(
            index,
            Uint8List.fromList(data),
            sample.duration,
          );
        }
        continue;
      }
      await transcoder.run(
        file: file,
        range: range,
        first: first,
        end: end,
        check: _check,
      );
      final index = muxer.addAacAudio(
        timescale: transcoder.sampleRate,
        esds: transcoder.esds,
        channelCount: transcoder.channelCount,
        sampleRate: transcoder.sampleRate,
      );
      for (final chunk in transcoder.chunks) {
        muxer.addAudioSample(index, chunk, transcoder.frameDuration);
      }
      transcoder.close();
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
      videoCodec: hevc ? VideoCodec.hevc : VideoCodec.h264,
    );
  }

  static int _ticks(int us, int timescale) => (us * timescale / 1e6).round();

  /// The encoder configuration and whether it is HEVC: HEVC when asked for
  /// and the browser has an encoder for it, H.264 otherwise.
  Future<(web.VideoEncoderConfig, bool)> _encoderConfig(
    int width,
    int height,
    double frameRate,
  ) async {
    final bitrate = VideoPlanning.videoBitrate(null, options);
    web.VideoEncoderConfig config(String codec) => web.VideoEncoderConfig(
      codec: codec,
      width: width,
      height: height,
      bitrate: bitrate,
      framerate: frameRate,
      bitrateMode: 'variable',
      latencyMode: 'quality',
    );
    final candidates = [
      if (options.codec == VideoCodec.hevc)
        for (final codec in MediaPlan.hevcCodecs(width, height, frameRate))
          (config(codec)..hevc = web.HevcEncoderConfig(format: 'hevc'), true),
      for (final codec in MediaPlan.avcCodecs(width, height, frameRate))
        (config(codec)..avc = web.AvcEncoderConfig(format: 'avc'), false),
    ];
    for (final candidate in candidates) {
      try {
        final support =
            await web.VideoEncoder.isConfigSupported(candidate.$1).toDart;
        if (support.supported) return candidate;
      } on Object {
        // Try the next codec.
      }
    }
    throw _Stop(
      CompressionStatus.unsupported,
      'the browser cannot encode H.264 at ${width}x$height',
    );
  }
}
