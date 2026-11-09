import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Files the compressor reads and writes, as paths in the temporary
/// directory.
abstract final class MediaFiles {
  /// Whether results can be saved through the browser.
  static const canDownload = false;

  /// Writes [bytes] to a file named [name] and returns its path.
  static Future<String> materialize(Uint8List bytes, String name) async {
    final file = File('${(await _directory()).path}/$name');
    await file.writeAsBytes(bytes, flush: true);

    return file.path;
  }

  static Future<Uint8List> read(String location) =>
      File(location).readAsBytes();

  /// A fresh path for an output named [name].
  static Future<String> output(String name) async =>
      '${(await _directory()).path}/$name';

  static void download(String location, String name) =>
      throw UnsupportedError('downloads are web only');

  static Future<Directory> _directory() async {
    final temp = await getTemporaryDirectory();

    return Directory(
      '${temp.path}/native_media_compressor_example',
    ).create(recursive: true);
  }
}
