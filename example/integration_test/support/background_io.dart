import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/services.dart';

/// Runs [computation] in a new isolate that can call plugins.
Future<R> runInBackground<R>(Future<R> Function() computation) {
  final token = RootIsolateToken.instance!;

  return Isolate.run(() {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    DartPluginRegistrant.ensureInitialized();

    return computation();
  });
}
