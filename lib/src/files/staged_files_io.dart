import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Local file operations of the Dart layer.
abstract final class StagedFiles {
  static final _random = Random();

  /// Size of [source] in bytes, or null when it is not a local file, such as
  /// an Android `content://` URI.
  static Future<int?> sizeOf(String source) async {
    if (source.contains('://')) return null;
    try {
      return await File(source).length();
    } on FileSystemException {
      return null;
    }
  }

  /// A free path next to [destination], with its extension, for an output
  /// that replaces [destination] only once it is kept.
  static String stagingFor(String destination) {
    final file = File(destination);
    final name = file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 ? name.substring(dot) : '';
    final id = _random.nextInt(1 << 32).toRadixString(36);

    return '${file.parent.path}${Platform.pathSeparator}.nmc-stage-$id$extension';
  }

  /// Moves the kept output at [staged] over [destination] and returns where
  /// it now is.
  static Future<String> commit(String staged, String destination) async {
    await File(staged).rename(destination);

    return destination;
  }

  /// Removes an output that is not kept. Missing files are fine.
  static Future<void> discard(String? path) async {
    if (path == null) return;
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Bytes of the file at [path].
  static Future<Uint8List> read(String path) => File(path).readAsBytes();
}

/// A scratch directory for compressing bytes held in memory.
final class TempSpace {
  TempSpace._(this._directory);

  final Directory _directory;

  /// Creates an empty scratch directory.
  static Future<TempSpace> create() async =>
      TempSpace._(await Directory.systemTemp.createTemp('nmc-'));

  /// Writes [bytes] to a new file and returns its path.
  Future<String> write(Uint8List bytes) async {
    final file = File('${_directory.path}${Platform.pathSeparator}input');
    await file.writeAsBytes(bytes, flush: true);

    return file.path;
  }

  /// A path for an output with [extension].
  String output(String extension) =>
      '${_directory.path}${Platform.pathSeparator}output.$extension';

  /// Removes the directory and everything in it.
  Future<void> dispose() async {
    try {
      await _directory.delete(recursive: true);
    } on FileSystemException {
      // Already gone.
    }
  }
}
