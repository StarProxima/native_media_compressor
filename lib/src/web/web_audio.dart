import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'browser.dart';
import 'codec_config.dart';
import 'mp4_demuxer.dart';
import 'trim_range.dart';

/// Re-encodes one audio track to AAC-LC with WebCodecs `AudioDecoder` and
/// `AudioEncoder`.
final class AacTranscoder {
  AacTranscoder._(this.track, this._decoderConfig, this._encoderConfig);

  /// AAC-LC frames always hold this many samples per channel.
  static const _frameSamples = 1024;
  static const _queueLimit = 8;

  final Mp4Track track;
  final _AudioConfig _decoderConfig;
  final _AudioConfig _encoderConfig;

  _AudioDecoder? _decoder;
  _AudioEncoder? _encoder;
  Object? _error;
  Uint8List? _asc;
  final _chunks = <Uint8List>[];

  /// Number of channels and sample rate of the AAC output.
  int get channelCount => _encoderConfig.numberOfChannels;

  int get sampleRate => _encoderConfig.sampleRate;

  int get bitrate => _encoderConfig.bitrate;

  /// The encoded AAC frames, each [frameDuration] ticks of [sampleRate].
  List<Uint8List> get chunks => _chunks;

  int get frameDuration => _frameSamples;

  /// The `esds` box for the output, once [run] has finished.
  Uint8List get esds => AudioConfig.esds(_asc!, bitrate: bitrate);

  /// A transcoder for [track], or null when the browser cannot decode it or
  /// has no AAC encoder for its sample rate and channels.
  static Future<AacTranscoder?> create(Mp4Track track, int bitrate) async {
    if (!Browser.has('AudioDecoder') || !Browser.has('AudioEncoder')) {
      return null;
    }
    final codec = AudioConfig.decoder(track.mimeType, track.audioConfig);
    if (codec == null || track.sampleRate <= 0 || track.channelCount <= 0) {
      return null;
    }
    final decoderConfig = _AudioConfig(
      codec: codec.$1,
      sampleRate: track.sampleRate,
      numberOfChannels: track.channelCount,
    );
    final description = codec.$2;
    if (description != null) decoderConfig.description = description.toJS;
    final encoderConfig = _AudioConfig(
      codec: 'mp4a.40.2',
      sampleRate: track.sampleRate,
      numberOfChannels: track.channelCount,
    )..bitrate = bitrate;
    try {
      final decodable =
          await _AudioDecoder.isConfigSupported(decoderConfig).toDart;
      if (!decodable.supported) return null;
      final encodable =
          await _AudioEncoder.isConfigSupported(encoderConfig).toDart;
      if (!encodable.supported) return null;
    } on Object {
      return null;
    }
    return AacTranscoder._(track, decoderConfig, encoderConfig);
  }

  /// Decodes the samples [first] to [end] of [track] read from [file],
  /// keeps what falls into [range] and encodes it. [check] throws when the
  /// job has stopped.
  Future<void> run({
    required ByteSource file,
    required TrimRange range,
    required int first,
    required int end,
    required void Function() check,
  }) async {
    final limitUs = range.toEnd ? null : range.durationUs;

    void onData(_AudioData data) {
      try {
        if (_error != null) return;
        final kept = _slice(data, limitUs);
        if (kept == null) return;
        _encoder!.encode(kept);
        if (!identical(kept, data)) kept.close();
      } finally {
        data.close();
      }
    }

    void onChunk(_EncodedAudioChunk chunk, JSAny? metadata) {
      _asc ??= Browser.decoderDescription(metadata);
      final data = JSUint8Array.withLength(chunk.byteLength);
      chunk.copyTo(data);
      _chunks.add(data.toDart);
    }

    void onError(JSAny? error) {
      _error ??= error;
    }

    _encoder = _AudioEncoder(
      _AudioCodecInit(output: onChunk.toJS, error: onError.toJS),
    )..configure(_encoderConfig);
    _decoder = _AudioDecoder(
      _AudioCodecInit(output: onData.toJS, error: onError.toJS),
    )..configure(_decoderConfig);

    for (var i = first; i < end; i++) {
      check();
      _throwIfFailed();
      final sample = track.samples[i];
      final data = await file.read(sample.offset, sample.size);
      _decoder!.decode(
        _EncodedAudioChunk(
          _EncodedAudioChunkInit(
            type: 'key',
            timestamp: TrimRange.presentationUs(track, sample) - range.startUs,
            duration: (sample.duration * 1e6 / track.timescale).round(),
            data: data.toJS,
          ),
        ),
      );
      while (_error == null &&
          (_decoder!.decodeQueueSize > _queueLimit ||
              _encoder!.encodeQueueSize > _queueLimit)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    check();
    _throwIfFailed();
    await _decoder!.flush().toDart;
    _throwIfFailed();
    await _encoder!.flush().toDart;
    _throwIfFailed();
    if (_asc == null) {
      throw StateError('the AAC encoder gave no AudioSpecificConfig');
    }
  }

  void _throwIfFailed() {
    final error = _error;
    if (error != null) throw StateError('audio codec error: $error');
  }

  /// The part of [data] from timestamp zero up to [limitUs], [data] itself
  /// when it lies inside, or null when nothing of it does.
  static _AudioData? _slice(_AudioData data, int? limitUs) {
    final rate = data.sampleRate;
    final frames = data.numberOfFrames;
    final start = data.timestamp;
    var from = start >= 0 ? 0 : (-start * rate / 1e6).ceil();
    var to = frames;
    if (limitUs != null) {
      final limit = ((limitUs - start) * rate / 1e6).round();
      if (limit < to) to = limit;
    }
    if (from < 0) from = 0;
    if (to <= from) return null;
    if (from == 0 && to == frames) return data;
    final count = to - from;
    final channels = data.numberOfChannels;
    final planes = Float32List(count * channels);
    for (var channel = 0; channel < channels; channel++) {
      // Copied through a JS array: under Wasm a Dart list's `toJS` is a copy
      // the browser would write into instead.
      final plane = JSFloat32Array.withLength(count);
      data.copyTo(
        plane,
        _AudioDataCopyToOptions(
          planeIndex: channel,
          frameOffset: from,
          frameCount: count,
          format: 'f32-planar',
        ),
      );
      planes.setAll(channel * count, plane.toDart);
    }
    return _AudioData(
      _AudioDataInit(
        format: 'f32-planar',
        sampleRate: rate,
        numberOfFrames: count,
        numberOfChannels: channels,
        timestamp: start + (from * 1e6 / rate).round(),
        data: planes.toJS,
      ),
    );
  }

  void close() {
    for (final close in [() => _decoder?.close(), () => _encoder?.close()]) {
      try {
        close();
      } on Object {
        // Already closed.
      }
    }
  }
}

@JS('AudioDecoder')
extension type _AudioDecoder._(JSObject _) implements JSObject {
  external factory _AudioDecoder(_AudioCodecInit init);

  external static JSPromise<_AudioSupport> isConfigSupported(
    _AudioConfig config,
  );

  external int get decodeQueueSize;

  external void configure(_AudioConfig config);

  external void decode(_EncodedAudioChunk chunk);

  external JSPromise<JSAny?> flush();

  external void close();
}

@JS('AudioEncoder')
extension type _AudioEncoder._(JSObject _) implements JSObject {
  external factory _AudioEncoder(_AudioCodecInit init);

  external static JSPromise<_AudioSupport> isConfigSupported(
    _AudioConfig config,
  );

  external int get encodeQueueSize;

  external void configure(_AudioConfig config);

  external void encode(_AudioData data);

  external JSPromise<JSAny?> flush();

  external void close();
}

extension type _AudioCodecInit._(JSObject _) implements JSObject {
  external factory _AudioCodecInit({
    required JSFunction output,
    required JSFunction error,
  });
}

extension type _AudioSupport._(JSObject _) implements JSObject {
  external bool get supported;
}

extension type _AudioConfig._(JSObject _) implements JSObject {
  external factory _AudioConfig({
    required String codec,
    required int sampleRate,
    required int numberOfChannels,
  });

  external int get sampleRate;

  external int get numberOfChannels;

  external int get bitrate;

  external set bitrate(int value);

  external set description(JSAny value);
}

@JS('EncodedAudioChunk')
extension type _EncodedAudioChunk._(JSObject _) implements JSObject {
  external factory _EncodedAudioChunk(_EncodedAudioChunkInit init);

  external int get byteLength;

  external void copyTo(JSObject destination);
}

extension type _EncodedAudioChunkInit._(JSObject _) implements JSObject {
  external factory _EncodedAudioChunkInit({
    required String type,
    required int timestamp,
    required int duration,
    required JSAny data,
  });
}

@JS('AudioData')
extension type _AudioData._(JSObject _) implements JSObject {
  external factory _AudioData(_AudioDataInit init);

  external double get sampleRate;

  external int get numberOfFrames;

  external int get numberOfChannels;

  external int get timestamp;

  external void copyTo(JSObject destination, _AudioDataCopyToOptions options);

  external void close();
}

extension type _AudioDataInit._(JSObject _) implements JSObject {
  external factory _AudioDataInit({
    required String format,
    required num sampleRate,
    required int numberOfFrames,
    required int numberOfChannels,
    required int timestamp,
    required JSAny data,
  });
}

extension type _AudioDataCopyToOptions._(JSObject _) implements JSObject {
  external factory _AudioDataCopyToOptions({
    required int planeIndex,
    required int frameOffset,
    required int frameCount,
    required String format,
  });
}
