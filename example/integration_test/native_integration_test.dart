import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_media_compressor/native_media_compressor.dart';

import 'support/test_files.dart' as files;

/// Behaviour that only exists on the native platforms; the web runs
/// plugin_integration_test.dart alone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(files.setUpFiles);

  testWidgets('works from a background isolate', (_) async {
    final token = RootIsolateToken.instance!;
    final image = await files.fixture('photo_exif_rotated.jpg');
    final video = await files.fixture('h264_rotated_90.mp4');
    final imageDestination = files.outputPath('isolate.jpg');
    final videoDestination = files.outputPath('isolate.mp4');

    final (imageStatus, videoStatus, probe) = await Isolate.run(() async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      DartPluginRegistrant.ensureInitialized();
      final imageResult = await NativeMediaCompressor.compressImage(
        source: image,
        destination: imageDestination,
        options: const ImageOptions(maxLongSide: 800),
      );
      final videoResult =
          await NativeMediaCompressor.compressVideo(
            source: video,
            destination: videoDestination,
            options: const VideoOptions(maxShortSide: 240),
          ).result;
      final metadata = await NativeMediaCompressor.probeImage(image);

      return (
        imageResult.status,
        videoResult.status,
        (metadata?.width, metadata?.height),
      );
    });

    expect(imageStatus, CompressionStatus.compressed);
    expect(videoStatus, CompressionStatus.compressed);
    expect(probe, (1200, 1600));
    expect(files.exists(imageDestination), isTrue);
    expect(files.exists(videoDestination), isTrue);
  });

  testWidgets(
    'reads content:// URIs on Android',
    skip: defaultTargetPlatform != TargetPlatform.android,
    (_) async {
      Future<String> uriOf(String name) async {
        final path = await files.fixture(name);

        return files.contentUri(path);
      }

      final photo = await uriOf('photo_exif_rotated.jpg');
      final clip = await uriOf('h264_rotated_90.mp4');

      final imageProbe = await NativeMediaCompressor.probeImage(photo);
      final videoProbe = await NativeMediaCompressor.probeVideo(clip);
      final image = await NativeMediaCompressor.compressImage(
        source: photo,
        destination: files.outputPath('content.jpg'),
        options: const ImageOptions(maxLongSide: 800),
      );
      final video =
          await NativeMediaCompressor.compressVideo(
            source: clip,
            destination: files.outputPath('content.mp4'),
            options: const VideoOptions(maxShortSide: 240),
          ).result;

      expect((imageProbe!.width, imageProbe.height), (1200, 1600));
      expect(videoProbe!.width, lessThan(videoProbe.height));
      expect(image.status, CompressionStatus.compressed, reason: '$image');
      expect((image.width, image.height), (600, 800));
      expect(video.status, CompressionStatus.compressed, reason: '$video');
    },
  );
}
