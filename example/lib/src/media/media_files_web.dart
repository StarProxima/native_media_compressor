import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Files the compressor reads and writes, as `blob:` object URLs.
abstract final class MediaFiles {
  /// Whether results can be saved through the browser.
  static const canDownload = true;

  /// Wraps [bytes] in a blob and returns its object URL.
  static Future<String> materialize(Uint8List bytes, String name) async {
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: _mimeType(name)),
    );

    return web.URL.createObjectURL(blob);
  }

  static Future<Uint8List> read(String location) async {
    final response = await web.window.fetch(location.toJS).toDart;
    final buffer = await response.arrayBuffer().toDart;

    return buffer.toDart.asUint8List();
  }

  /// The web ignores destinations: results come back as object URLs.
  static Future<String> output(String name) async => name;

  static void download(String location, String name) {
    final anchor =
        web.HTMLAnchorElement()
          ..href = location
          ..download = name;
    web.document.body?.append(anchor);
    anchor
      ..click()
      ..remove();
  }

  static String _mimeType(String name) => switch (name.split('.').last) {
    'mp4' => 'video/mp4',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    _ => '',
  };
}
