import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

final _fixtures = <String, String>{};

Future<void> setUpFiles() async {}

/// Loads the fixture from the asset bundle into a `blob:` URL.
Future<String> fixture(String name) async {
  final cached = _fixtures[name];
  if (cached != null) return cached;
  final data = await rootBundle.load('integration_test/fixtures/$name');
  final blob = web.Blob([data.buffer.asUint8List().toJS].toJS);

  return _fixtures[name] = web.URL.createObjectURL(blob);
}

/// The web ignores destinations; results point to object URLs instead.
String outputPath(String name) => 'out-$name';

Future<int> sizeOf(String location) async {
  final response = await web.window.fetch(location.toJS).toDart;
  final blob = await response.blob().toDart;

  return blob.size;
}

/// Nothing is ever written at a destination on the web.
bool exists(String path) => false;

void writeText(String path, String text) {}

String readText(String path) => throw UnsupportedError('no files on the web');

Future<String> copyFixture(String name, String path) =>
    throw UnsupportedError('no files on the web');

String createDirectory(String path) =>
    throw UnsupportedError('no files on the web');
