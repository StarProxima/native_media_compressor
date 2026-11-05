import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_media_compressor/native_media_compressor.dart';
import 'package:path_provider/path_provider.dart';

/// Platforms whose system codecs must handle every common format. Elsewhere
/// HEIC, WebP and some audio may legitimately be unsupported.
final _fullCodecs = Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

late Directory _work;

Future<String> _fixture(String name) async {
  final file = File('${_work.path}/in-$name');
  if (!file.existsSync()) {
    final data = await rootBundle.load('integration_test/fixtures/$name');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }

  return file.path;
}

String _out(String name) => '${_work.path}/out-$name';

/// Short and long sides of a frame.
(int, int) _sides(int? width, int? height) {
  final w = width!, h = height!;

  return w < h ? (w, h) : (h, w);
}

void _expectAbsent(String path) =>
    expect(File(path).existsSync(), isFalse, reason: '$path must not exist');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final temp = await getTemporaryDirectory();
    _work = await Directory('${temp.path}/nmc_test').create(recursive: true);
  });

  group('probeVideo', () {
    testWidgets('reads size, duration and codecs', (_) async {
      final probe = await NativeMediaCompressor.probeVideo(
        await _fixture('h264_aac_1080p.mp4'),
      );

      expect(probe, isNotNull);
      expect((probe!.width, probe.height), (1920, 1080));
      expect(probe.rotationDegrees, 0);
      expect(probe.duration.inMilliseconds, closeTo(2000, 150));
      expect(probe.videoCodec, 'video/avc');
      expect(probe.hasAudio, isTrue);
      expect(probe.audioCodec, 'audio/mp4a-latm');
    });

    testWidgets('reports displayed size of a rotated video', (_) async {
      final probe = await NativeMediaCompressor.probeVideo(
        await _fixture('h264_rotated_90.mp4'),
      );

      expect((probe!.width, probe.height), (1080, 1920));
      expect(probe.rotationDegrees, anyOf(90, 270));
    });

    testWidgets('reads HEVC', (_) async {
      final probe = await NativeMediaCompressor.probeVideo(
        await _fixture('hevc_aac_720p.mov'),
      );

      expect(probe!.videoCodec, 'video/hevc');
    });

    testWidgets('returns null for a file without video', (_) async {
      expect(
        await NativeMediaCompressor.probeVideo(await _fixture('broken.jpg')),
        isNull,
      );
      expect(
        await NativeMediaCompressor.probeVideo(
          await _fixture('audio_only.m4a'),
        ),
        isNull,
      );
    });
  });

  group('compressVideo', () {
    testWidgets('scales down, keeps audio and reports progress', (_) async {
      final source = await _fixture('h264_aac_1080p.mp4');
      final destination = _out('h264.mp4');
      final task = NativeMediaCompressor.compressVideo(
        source: source,
        destination: destination,
        options: const VideoOptions(maxShortSide: 360, videoBitrate: 500000),
      );
      final progress = task.progress.toList();

      final result = await task.result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect(result.path, destination);
      expect(result.sizeBytes, File(destination).lengthSync());
      expect(result.sizeBytes, lessThan(File(source).lengthSync()));
      final (short, long) = _sides(result.width, result.height);
      expect(short, inInclusiveRange(336, 360));
      expect(long / short, closeTo(16 / 9, 0.05));
      final values = await progress;
      expect(values, isNotEmpty);
      expect(values, orderedEquals([...values]..sort()));
      expect(values.last, greaterThan(0.9));

      final probe = await NativeMediaCompressor.probeVideo(destination);
      expect(probe!.videoCodec, 'video/avc');
      expect(probe.hasAudio, isTrue);
      expect(probe.duration.inMilliseconds, closeTo(2000, 200));
    });

    testWidgets('keeps the displayed orientation', (_) async {
      final destination = _out('rotated.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_rotated_90.mp4'),
            destination: destination,
            options: const VideoOptions(maxShortSide: 360),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect(result.width!, lessThan(result.height!));
      final probe = await NativeMediaCompressor.probeVideo(destination);
      expect(probe!.width, lessThan(probe.height));
    });

    testWidgets('re-encodes HEVC to H.264', (_) async {
      final destination = _out('hevc.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('hevc_aac_720p.mov'),
            destination: destination,
            options: const VideoOptions(maxShortSide: 360),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      final probe = await NativeMediaCompressor.probeVideo(destination);
      expect(probe!.videoCodec, 'video/avc');
    });

    testWidgets('copies or rejects several audio tracks', (_) async {
      final destination = _out('two-audio.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('two_audio_tracks.mp4'),
            destination: destination,
            options: const VideoOptions(maxShortSide: 360),
          ).result;

      if (_fullCodecs) {
        expect(result.status, CompressionStatus.compressed, reason: '$result');
        final probe = await NativeMediaCompressor.probeVideo(destination);
        expect(probe!.hasAudio, isTrue);
      } else {
        expect(
          result.status,
          anyOf(CompressionStatus.compressed, CompressionStatus.unsupported),
        );
      }
    });

    testWidgets('drops audio it cannot copy only when allowed', (_) async {
      final source = await _fixture('mp3_audio.mp4');
      final kept = _out('mp3-kept.mp4');
      final dropped = _out('mp3-dropped.mp4');

      final withAudio =
          await NativeMediaCompressor.compressVideo(
            source: source,
            destination: kept,
            options: const VideoOptions(maxShortSide: 360),
          ).result;
      final withoutAudio =
          await NativeMediaCompressor.compressVideo(
            source: source,
            destination: dropped,
            options: const VideoOptions(maxShortSide: 360, includeAudio: false),
          ).result;

      if (_fullCodecs) {
        expect(withAudio.status, CompressionStatus.unsupported);
        _expectAbsent(kept);
      }
      expect(withoutAudio.status, CompressionStatus.compressed);
      final probe = await NativeMediaCompressor.probeVideo(dropped);
      expect(probe!.hasAudio, isFalse);
    });

    testWidgets('HDR is either converted or unsupported', (_) async {
      final destination = _out('hdr.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('hdr10_hevc.mp4'),
            destination: destination,
            options: const VideoOptions(maxShortSide: 360),
          ).result;

      expect(
        result.status,
        anyOf(CompressionStatus.compressed, CompressionStatus.unsupported),
      );
      if (!result.isCompressed) _expectAbsent(destination);
    });

    testWidgets('stops when the output outgrows maxBytes', (_) async {
      final destination = _out('too-large.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_aac_1080p.mp4'),
            destination: destination,
            options: const VideoOptions(
              maxShortSide: 1080,
              videoBitrate: 8000000,
              maxBytes: 20000,
            ),
          ).result;

      expect(result.status, CompressionStatus.tooLarge);
      _expectAbsent(destination);
    });

    testWidgets('cancel stops the work and leaves no file', (_) async {
      final destination = _out('cancelled.mp4');
      final task = NativeMediaCompressor.compressVideo(
        source: await _fixture('h264_aac_1080p.mp4'),
        destination: destination,
        options: const VideoOptions(maxShortSide: 1080),
      );
      await task.cancel();

      expect((await task.result).status, CompressionStatus.cancelled);
      _expectAbsent(destination);
    });

    testWidgets('a file without video is unsupported or failed', (_) async {
      for (final name in ['audio_only.m4a', 'broken.jpg']) {
        final destination = _out('$name.mp4');
        final result =
            await NativeMediaCompressor.compressVideo(
              source: await _fixture(name),
              destination: destination,
            ).result;

        expect(
          result.status,
          anyOf(CompressionStatus.unsupported, CompressionStatus.failed),
          reason: name,
        );
        _expectAbsent(destination);
      }
    });

    testWidgets('runs queued compressions one after another', (_) async {
      final source = await _fixture('hevc_aac_720p.mov');
      final tasks = [
        for (var i = 0; i < 2; i++)
          NativeMediaCompressor.compressVideo(
            source: source,
            destination: _out('queued-$i.mp4'),
            options: const VideoOptions(maxShortSide: 240),
          ),
      ];

      final results = await Future.wait(tasks.map((task) => task.result));

      expect(
        results.map((result) => result.status),
        everyElement(CompressionStatus.compressed),
      );
    });

    testWidgets('replaces an existing destination', (_) async {
      final destination = _out('existing.mp4');
      File(destination).writeAsStringSync('stale');

      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('hevc_aac_720p.mov'),
            destination: destination,
            options: const VideoOptions(maxShortSide: 240),
          ).result;

      expect(result.status, CompressionStatus.compressed);
      expect(File(destination).lengthSync(), greaterThan(1000));
    });
  });

  group('probeImage', () {
    testWidgets('applies EXIF orientation', (_) async {
      final probe = await NativeMediaCompressor.probeImage(
        await _fixture('photo_exif_rotated.jpg'),
      );

      expect((probe!.width, probe.height), (1200, 1600));
      expect(probe.frameCount, 1);
      expect(probe.mimeType, 'image/jpeg');
    });

    testWidgets('counts animation frames', (_) async {
      final gif = await NativeMediaCompressor.probeImage(
        await _fixture('animated.gif'),
      );

      expect((gif!.width, gif.height), (320, 240));
      expect(gif.frameCount, 3);
      expect(gif.isAnimated, isTrue);
    });

    testWidgets('reads HEIC and WebP where the platform can', (_) async {
      final heic = await NativeMediaCompressor.probeImage(
        await _fixture('photo.heic'),
      );
      final webp = await NativeMediaCompressor.probeImage(
        await _fixture('animated.webp'),
      );

      if (_fullCodecs) {
        expect((heic!.width, heic.height), (1600, 1200));
        expect(heic.mimeType, 'image/heic');
        expect(webp!.frameCount, 3);
        expect(webp.mimeType, 'image/webp');
      }
    });

    testWidgets('returns null for a broken file', (_) async {
      expect(
        await NativeMediaCompressor.probeImage(await _fixture('broken.jpg')),
        isNull,
      );
    });
  });

  group('compressImage', () {
    testWidgets('bakes in orientation and fits the long side', (_) async {
      final destination = _out('photo.jpg');
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('photo_exif_rotated.jpg'),
        destination: destination,
        options: const ImageOptions(maxLongSide: 800, quality: 80),
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect((result.width, result.height), (600, 800));
      expect(result.sizeBytes, File(destination).lengthSync());
      final probe = await NativeMediaCompressor.probeImage(destination);
      expect((probe!.width, probe.height), (600, 800));
      expect(probe.mimeType, 'image/jpeg');
    });

    testWidgets('uses the tighter of both bounds', (_) async {
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('photo_exif_rotated.jpg'),
        destination: _out('bounded.jpg'),
        options: const ImageOptions(maxShortSide: 300, maxLongSide: 1000),
      );

      expect((result.width, result.height), (300, 400));
    });

    testWidgets('never scales up', (_) async {
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('alpha.png'),
        destination: _out('not-upscaled.png'),
        options: const ImageOptions(maxLongSide: 4000, format: ImageFormat.png),
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect((result.width, result.height), (1200, 800));
    });

    testWidgets('writes PNG', (_) async {
      final destination = _out('alpha.png');
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('alpha.png'),
        destination: destination,
        options: const ImageOptions(maxLongSide: 600, format: ImageFormat.png),
      );

      expect((result.width, result.height), (600, 400));
      final probe = await NativeMediaCompressor.probeImage(destination);
      expect(probe!.mimeType, 'image/png');
    });

    testWidgets('keeps the first frame of an animation', (_) async {
      final destination = _out('animated.jpg');
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('animated.gif'),
        destination: destination,
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      final probe = await NativeMediaCompressor.probeImage(destination);
      expect((probe!.width, probe.height, probe.frameCount), (320, 240, 1));
    });

    testWidgets('decodes HEIC and WebP where the platform can', (_) async {
      for (final name in ['photo.heic', 'photo.webp']) {
        final destination = _out('$name.jpg');
        final result = await NativeMediaCompressor.compressImage(
          source: await _fixture(name),
          destination: destination,
          options: const ImageOptions(maxLongSide: 800),
        );

        if (_fullCodecs) {
          expect(result.status, CompressionStatus.compressed, reason: name);
          expect((result.width, result.height), (800, 600), reason: name);
        } else {
          expect(
            result.status,
            anyOf(CompressionStatus.compressed, CompressionStatus.unsupported),
            reason: name,
          );
        }
      }
    });

    testWidgets('a broken file leaves no output', (_) async {
      final destination = _out('broken.jpg');
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('broken.jpg'),
        destination: destination,
      );

      expect(
        result.status,
        anyOf(CompressionStatus.failed, CompressionStatus.unsupported),
      );
      _expectAbsent(destination);
    });
  });
}
