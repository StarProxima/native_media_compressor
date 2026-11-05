import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

late Directory _work;

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

bool exists(String path) => File(path).existsSync();

void writeStale(String path) => File(path).writeAsStringSync('stale');
