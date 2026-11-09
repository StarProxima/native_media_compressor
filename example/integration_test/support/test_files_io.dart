import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

late Directory _work;

/// Whether this runs in the iOS simulator, whose software H.264 encoder does
/// not go below about 1.5 Mbit/s at 1080p, so sizes there do not follow the
/// requested bitrate.
bool get isIosSimulator =>
    Platform.isIOS && Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');

Future<void> setUpFiles() async {
  final temp = await getTemporaryDirectory();
  _work = await Directory('${temp.path}/nmc_test').create(recursive: true);
}

/// Copies the fixture out of the asset bundle and returns its path.
Future<String> fixture(String name) async {
  final file = File('${_work.path}/in-$name');
  if (!file.existsSync()) {
    final data = await rootBundle.load('integration_test/fixtures/$name');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }

  return file.path;
}

String outputPath(String name) => '${_work.path}/out-$name';

Future<int> sizeOf(String location) async => File(location).lengthSync();

Future<Uint8List> bytesOf(String location) => File(location).readAsBytes();

bool exists(String path) => File(path).existsSync();

void writeText(String path, String text) => File(path).writeAsStringSync(text);

String readText(String path) => File(path).readAsStringSync();

/// Copies the fixture to [path] and returns [path].
Future<String> copyFixture(String name, String path) async {
  await File(await fixture(name)).copy(path);

  return path;
}

/// The `content://` URI under which the example app's CacheFileProvider serves
/// [path] on Android. [path] must be inside the temporary directory.
String contentUri(String path) =>
    Uri(
      scheme: 'content',
      host: 'io.github.starproxima.native_media_compressor_example.files',
      path: path.substring(_work.parent.path.length),
    ).toString();

/// Names of the entries in [path], without the directory.
List<String> list(String path) => [
  for (final entry in Directory(path).listSync())
    entry.path.substring(path.length + 1),
];

/// Creates an empty directory at [path], dropping what an earlier run left.
String createDirectory(String path) {
  final directory = Directory(path);
  if (directory.existsSync()) directory.deleteSync(recursive: true);
  directory.createSync(recursive: true);

  return path;
}
