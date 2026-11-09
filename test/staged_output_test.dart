import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_media_compressor/native_media_compressor.dart';
import 'package:native_media_compressor/src/planning.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Writes outputs of a chosen size to the destination it gets, like a real
/// platform, and records what it was asked.
class _FakePlatform extends NativeMediaCompressorPlatform
    with MockPlatformInterfaceMixin {
  /// Output size for an image request.
  int Function(ImageOptions options) imageSize = (_) => 100;

  /// Output size for a video request.
  int videoSize = 100;

  VideoMetadata? metadata;
  final imageRequests = <(String, ImageOptions)>[];
  final videoRequests = <(String, VideoOptions)>[];

  @override
  Future<CompressionResult> compressImage({
    required String source,
    required String destination,
    required ImageOptions options,
  }) async {
    imageRequests.add((destination, options));
    final size = imageSize(options);
    File(destination).writeAsBytesSync(Uint8List(size));

    return CompressionResult(
      status: CompressionStatus.compressed,
      path: destination,
      width: options.maxLongSide,
      height: options.maxLongSide,
      sizeBytes: size,
    );
  }

  @override
  CompressionTask compressVideo({
    required String source,
    required String destination,
    required VideoOptions options,
  }) {
    videoRequests.add((destination, options));
    File(destination).writeAsBytesSync(Uint8List(videoSize));

    return CompressionTask(
      result: Future.value(
        CompressionResult(
          status: CompressionStatus.compressed,
          path: destination,
          sizeBytes: videoSize,
        ),
      ),
      progress: const Stream.empty(),
      onCancel: () async {},
    );
  }

  @override
  Future<CompressionResult> videoThumbnail({
    required String source,
    required String destination,
    required Duration position,
    required ImageOptions options,
  }) async => const CompressionResult(status: CompressionStatus.unsupported);

  @override
  Future<ImageMetadata?> probeImage(String source) async => null;

  @override
  Future<VideoMetadata?> probeVideo(String source) async => metadata;
}

void main() {
  late Directory dir;
  late _FakePlatform platform;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nmc-staged-');
    platform = _FakePlatform();
    NativeMediaCompressorPlatform.instance = platform;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  String file(String name, [int size = 0]) {
    final path = '${dir.path}/$name';
    if (size > 0) File(path).writeAsBytesSync(Uint8List(size));

    return path;
  }

  List<String> entries() =>
      dir.listSync().map((entry) => entry.uri.pathSegments.last).toList()
        ..sort();

  test(
    'an output that saves too little is skipped and leaves no file',
    () async {
      final source = file('in.jpg', 1000);
      final destination = file('out.jpg');
      File(destination).writeAsStringSync('old');
      platform.imageSize = (_) => 900;

      final result = await NativeMediaCompressor.compressImage(
        source: source,
        destination: destination,
        options: const ImageOptions(minSavingsPercent: 20),
      );

      expect(result.status, CompressionStatus.skipped);
      expect(result.path, isNull);
      expect(File(destination).readAsStringSync(), 'old');
      expect(entries(), ['in.jpg', 'out.jpg']);
    },
  );

  test('an output that saves enough replaces the destination', () async {
    final source = file('in.jpg', 1000);
    final destination = file('out.jpg');
    platform.imageSize = (_) => 700;

    final result = await NativeMediaCompressor.compressImage(
      source: source,
      destination: destination,
      options: const ImageOptions(minSavingsPercent: 20),
    );

    expect(result.status, CompressionStatus.compressed);
    expect(result.path, destination);
    expect(File(destination).lengthSync(), 700);
    expect(entries(), ['in.jpg', 'out.jpg']);
    expect(platform.imageRequests.single.$1, isNot(destination));
  });

  test('in place, a skipped output keeps the source as it was', () async {
    final source = file('clip.mp4', 1000);
    platform.videoSize = 990;

    final result =
        await NativeMediaCompressor.compressVideo(
          source: source,
          destination: source,
          options: VideoOptions.balanced.copyWith(minSavingsPercent: 5),
        ).result;

    expect(result.status, CompressionStatus.skipped);
    expect(File(source).lengthSync(), 1000);
    expect(entries(), ['clip.mp4']);
  });

  test('in place, a kept output replaces the source', () async {
    final source = file('clip.mp4', 1000);
    platform.videoSize = 400;

    final result =
        await NativeMediaCompressor.compressVideo(
          source: source,
          destination: source,
          options: VideoOptions.balanced.copyWith(minSavingsPercent: 5),
        ).result;

    expect(result.status, CompressionStatus.compressed);
    expect(File(source).lengthSync(), 400);
    expect(entries(), ['clip.mp4']);
  });

  test('without a savings rule the platform writes the destination', () async {
    final destination = file('out.mp4');
    platform.metadata = const VideoMetadata(
      width: 1920,
      height: 1080,
      rotationDegrees: 0,
      duration: Duration(seconds: 4),
      hasAudio: false,
      isHdr: false,
      bitrate: 600000,
    );

    await NativeMediaCompressor.compressVideo(
      source: file('in.mp4', 10),
      destination: destination,
    ).result;

    final (written, options) = platform.videoRequests.single;
    expect(written, destination);
    expect(options.videoBitrate, 510000);
  });

  test('target size lowers quality until the image fits', () async {
    final destination = file('out.jpg');
    platform.imageSize = (options) => options.quality * 1000;

    final result = await NativeMediaCompressor.compressImage(
      source: file('in.jpg', 100000),
      destination: destination,
      options: const ImageOptions(quality: 90, targetBytes: 45000),
    );

    expect(result.sizeBytes, lessThanOrEqualTo(45000));
    expect(File(destination).lengthSync(), result.sizeBytes);
    expect(platform.imageRequests.map((request) => request.$2.quality), [
      90,
      45,
    ]);
    expect(entries(), ['in.jpg', 'out.jpg']);
  });

  test(
    'target size shrinks the image when quality alone is not enough',
    () async {
      platform.imageSize = (options) => options.maxLongSide! * 100;

      final result = await NativeMediaCompressor.compressImage(
        source: file('in.jpg', 1000000),
        destination: file('out.jpg'),
        options: const ImageOptions(
          quality: ImagePlanning.minQuality,
          maxLongSide: 2000,
          targetBytes: 120000,
        ),
      );

      expect(platform.imageRequests.map((request) => request.$2.maxLongSide), [
        2000,
        1500,
        1125,
      ]);
      expect(result.sizeBytes, 112500);
      expect(entries(), ['in.jpg', 'out.jpg']);
    },
  );

  test('bytes in memory come back compressed without leftovers', () async {
    platform.imageSize = (_) => 321;
    final before =
        Directory.systemTemp
            .listSync()
            .where((entry) => entry.path.contains('nmc-'))
            .length;

    final result = await NativeMediaCompressor.compressImageBytes(
      Uint8List(5000),
    );

    expect(result.status, CompressionStatus.compressed);
    expect(result.bytes, hasLength(321));
    expect(
      Directory.systemTemp
          .listSync()
          .where((entry) => entry.path.contains('nmc-'))
          .length,
      before,
    );
  });

  test('estimate follows the probe', () async {
    platform.metadata = const VideoMetadata(
      width: 1920,
      height: 1080,
      rotationDegrees: 0,
      duration: Duration(seconds: 8),
      hasAudio: false,
      isHdr: false,
      bitrate: 8000000,
    );

    final estimate = await NativeMediaCompressor.estimateVideo('/in.mp4');

    expect((estimate!.width, estimate.height), (1280, 720));
    // Eight seconds of video without audio.
    expect(estimate.sizeBytes, (estimate.videoBitrate * 8 / 8).round());
  });
}
