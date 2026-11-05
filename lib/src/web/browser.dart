import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'mp4_demuxer.dart';

/// Browser entry points that `package:web` does not bind, and small helpers
/// over the ones it does.
abstract final class Browser {
  static bool has(String name) => web.window.has(name);

  static bool get hasWebCodecs =>
      has('VideoDecoder') && has('VideoEncoder') && has('EncodedVideoChunk');

  /// Reads a `blob:`, `data:` or `http(s):` URL, or returns null.
  static Future<web.Blob?> fetchBlob(String url) async {
    try {
      final response = await web.window.fetch(url.toJS).toDart;
      if (!response.ok) return null;
      return await response.blob().toDart;
    } on Object {
      return null;
    }
  }

  static Future<Uint8List> bytesOf(web.Blob blob) async =>
      (await blob.arrayBuffer().toDart).toDart.asUint8List();

  /// Number of frames the browser reports for an image, or null without
  /// `ImageDecoder`.
  static Future<int?> frameCount(web.Blob blob, String mimeType) async {
    if (!has('ImageDecoder')) return null;
    _ImageDecoder? decoder;
    try {
      if (!(await _ImageDecoder.isTypeSupported(mimeType).toDart).toDart) {
        return null;
      }
      decoder = _ImageDecoder(
        _ImageDecoderInit(
          data: await blob.arrayBuffer().toDart,
          type: mimeType,
        ),
      );
      await decoder.tracks.ready.toDart;
      return decoder.tracks.selectedTrack?.frameCount;
    } on Object {
      return null;
    } finally {
      decoder?.close();
    }
  }

  /// Whether `ImageDecoder` rules out [mimeType]; false when unknown.
  static Future<bool> cannotDecodeImage(String mimeType) async {
    if (!has('ImageDecoder')) return false;
    try {
      return !(await _ImageDecoder.isTypeSupported(mimeType).toDart).toDart;
    } on Object {
      return false;
    }
  }

  /// The `description` of an encoder output's decoder config, copied.
  static Uint8List? decoderDescription(JSAny? metadata) {
    if (metadata == null || !metadata.isA<JSObject>()) return null;
    final config = (metadata as JSObject).getProperty<JSAny?>(
      'decoderConfig'.toJS,
    );
    if (config == null || !config.isA<JSObject>()) return null;
    final description = (config as JSObject).getProperty<JSAny?>(
      'description'.toJS,
    );
    if (description == null) return null;
    if (description.isA<JSArrayBuffer>()) {
      return Uint8List.fromList(
        (description as JSArrayBuffer).toDart.asUint8List(),
      );
    }
    if (!description.isA<JSObject>()) return null;
    final view = description as JSObject;
    final buffer = view.getProperty<JSArrayBuffer>('buffer'.toJS);
    final offset = view.getProperty<JSNumber>('byteOffset'.toJS).toDartInt;
    final length = view.getProperty<JSNumber>('byteLength'.toJS).toDartInt;
    return Uint8List.fromList(buffer.toDart.asUint8List(offset, length));
  }
}

/// Reads a [web.Blob] through a window of a few megabytes, so walking the
/// samples of a large video does not load it whole.
final class BlobByteSource implements ByteSource {
  BlobByteSource(this.blob) : length = blob.size;

  static const _window = 4 << 20;

  final web.Blob blob;

  @override
  final int length;

  var _start = 0;
  var _cache = Uint8List(0);

  @override
  Future<Uint8List> read(int offset, int count) async {
    if (offset < 0 || offset + count > length) {
      throw RangeError('read of $count bytes at $offset is past $length');
    }
    if (offset >= _start && offset + count <= _start + _cache.length) {
      return Uint8List.sublistView(
        _cache,
        offset - _start,
        offset - _start + count,
      );
    }
    if (count > _window) return _slice(offset, count);
    final windowEnd = offset + _window > length ? length : offset + _window;
    _cache = await _slice(offset, windowEnd - offset);
    _start = offset;
    return Uint8List.sublistView(_cache, 0, count);
  }

  Future<Uint8List> _slice(int start, int count) async =>
      Browser.bytesOf(blob.slice(start, start + count));
}

@JS('ImageDecoder')
extension type _ImageDecoder._(JSObject _) implements JSObject {
  external factory _ImageDecoder(_ImageDecoderInit init);

  external static JSPromise<JSBoolean> isTypeSupported(String type);

  external _ImageTrackList get tracks;

  external void close();
}

extension type _ImageDecoderInit._(JSObject _) implements JSObject {
  external factory _ImageDecoderInit({
    required JSAny data,
    required String type,
  });
}

extension type _ImageTrackList._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get ready;

  external _ImageTrack? get selectedTrack;
}

extension type _ImageTrack._(JSObject _) implements JSObject {
  external int get frameCount;
}
