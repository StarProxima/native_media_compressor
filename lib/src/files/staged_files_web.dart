import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Object URL operations of the Dart layer. The web ignores destinations,
/// so every output is its own object URL from the start.
abstract final class StagedFiles {
  /// Size of what [source] points to, or null when it cannot be fetched.
  static Future<int?> sizeOf(String source) async {
    try {
      final response = await web.window.fetch(source.toJS).toDart;
      if (!response.ok) return null;

      return (await response.blob().toDart).size;
    } on Object {
      return null;
    }
  }

  /// The web writes no files, so there is nothing to stage.
  static String stagingFor(String destination) => destination;

  /// The output already is its own object URL.
  static Future<String> commit(String staged, String destination) async =>
      staged;

  /// Releases an object URL that is not kept.
  static Future<void> discard(String? path) async {
    if (path != null && path.startsWith('blob:')) {
      web.URL.revokeObjectURL(path);
    }
  }

  /// Bytes behind the object URL [path].
  static Future<Uint8List> read(String path) async {
    final response = await web.window.fetch(path.toJS).toDart;
    final buffer = await response.arrayBuffer().toDart;

    return buffer.toDart.asUint8List();
  }
}

/// Object URLs for compressing bytes held in memory.
final class TempSpace {
  TempSpace._();

  final _urls = <String>[];

  /// Nothing to create on the web.
  static Future<TempSpace> create() async => TempSpace._();

  /// Wraps [bytes] in an object URL.
  Future<String> write(Uint8List bytes) async {
    final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS));
    _urls.add(url);

    return url;
  }

  /// The web ignores destinations.
  String output(String extension) => '';

  /// Releases the object URLs.
  Future<void> dispose() async {
    for (final url in _urls) {
      web.URL.revokeObjectURL(url);
    }
    _urls.clear();
  }
}
