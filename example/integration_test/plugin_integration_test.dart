import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_media_compressor/native_media_compressor.dart';

import 'support/test_files.dart' as files;

final _isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Platforms whose system codecs must handle every common format. Elsewhere
/// HEIC, WebP and some audio may legitimately be unsupported.
final _fullCodecs =
    !kIsWeb &&
    const [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ].contains(defaultTargetPlatform);

Future<String> _fixture(String name) => files.fixture(name);

String _out(String name) => files.outputPath(name);

/// Where a compressed result is: the destination, or an object URL on the
/// web.
String _at(CompressionResult result, String destination) =>
    kIsWeb ? result.path! : destination;

/// Short and long sides of a frame.
(int, int) _sides(int? width, int? height) {
  final w = width!, h = height!;

  return w < h ? (w, h) : (h, w);
}

void _expectAbsent(CompressionResult result, String destination) {
  expect(result.path, isNull);
  expect(
    files.exists(destination),
    isFalse,
    reason: '$destination must not exist',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(files.setUpFiles);

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
      expect(probe.isHdr, isFalse);
    });

    testWidgets('detects HDR transfer functions', (_) async {
      for (final name in [
        'hdr10_hevc.mp4',
        'hlg_hevc.mov',
        'hlg_hevc_8bit.mp4',
      ]) {
        final probe = await NativeMediaCompressor.probeVideo(
          await _fixture(name),
        );

        expect(probe!.isHdr, isTrue, reason: name);
      }
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
      expect(result.path, kIsWeb ? startsWith('blob:') : destination);
      final output = _at(result, destination);
      expect(result.sizeBytes, await files.sizeOf(output));
      expect(result.sizeBytes, lessThan(await files.sizeOf(source)));
      final (short, long) = _sides(result.width, result.height);
      expect(short, inInclusiveRange(336, 360));
      expect(long / short, closeTo(16 / 9, 0.05));
      final values = await progress;
      expect(values, isNotEmpty);
      expect(values, orderedEquals([...values]..sort()));
      expect(values.last, greaterThan(0.9));

      final probe = await NativeMediaCompressor.probeVideo(output);
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
      final probe = await NativeMediaCompressor.probeVideo(
        _at(result, destination),
      );
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

      // Windows decodes HEVC only with the HEVC Video Extensions installed.
      if (!_fullCodecs && result.status == CompressionStatus.unsupported) {
        return;
      }
      expect(result.status, CompressionStatus.compressed, reason: '$result');
      final probe = await NativeMediaCompressor.probeVideo(
        _at(result, destination),
      );
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
        final probe = await NativeMediaCompressor.probeVideo(
          _at(result, destination),
        );
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

      // The web copies AAC only, like the platforms with full codecs.
      if (_fullCodecs || kIsWeb) {
        expect(withAudio.status, CompressionStatus.unsupported);
        _expectAbsent(withAudio, kept);
      }
      expect(withoutAudio.status, CompressionStatus.compressed);
      final probe = await NativeMediaCompressor.probeVideo(
        _at(withoutAudio, dropped),
      );
      expect(probe!.hasAudio, isFalse);
    });

    testWidgets('converts HDR to SDR', (_) async {
      // The 10-bit HEVC files need a Main 10 decoder, which phones have and
      // Android emulators do not. The 8-bit HLG file runs the same tone
      // mapping everywhere.
      for (final (name, needsMain10) in [
        ('hlg_hevc_8bit.mp4', false),
        ('hdr10_hevc.mp4', true),
        ('hlg_hevc.mov', true),
      ]) {
        final destination = _out('$name.mp4');
        final result =
            await NativeMediaCompressor.compressVideo(
              source: await _fixture(name),
              destination: destination,
              options: const VideoOptions(maxShortSide: 360),
            ).result;

        if (_fullCodecs && !(needsMain10 && _isAndroid)) {
          expect(
            result.status,
            CompressionStatus.compressed,
            reason: '$name $result',
          );
        } else {
          expect(
            result.status,
            anyOf(CompressionStatus.compressed, CompressionStatus.unsupported),
            reason: name,
          );
        }
        if (result.isCompressed) {
          final probe = await NativeMediaCompressor.probeVideo(
            _at(result, destination),
          );
          expect(probe!.isHdr, isFalse, reason: name);
          expect(probe.videoCodec, 'video/avc', reason: name);
        } else {
          _expectAbsent(result, destination);
        }
      }
    });

    testWidgets('compresses real screen recordings', (_) async {
      for (final (name, short, long) in [
        ('screen_ios.mov', 1206, 2622),
        ('screen_android.mp4', 1080, 2400),
      ]) {
        final destination = _out('$name.mp4');
        final result =
            await NativeMediaCompressor.compressVideo(
              source: await _fixture(name),
              destination: destination,
              options: const VideoOptions(maxShortSide: 720),
            ).result;

        if (!_fullCodecs && result.status == CompressionStatus.unsupported) {
          continue;
        }
        expect(
          result.status,
          CompressionStatus.compressed,
          reason: '$name $result',
        );
        final (outShort, outLong) = _sides(result.width, result.height);
        expect(outShort, inInclusiveRange(700, 720), reason: name);
        expect(outLong / outShort, closeTo(long / short, 0.03), reason: name);
        final probe = await NativeMediaCompressor.probeVideo(
          _at(result, destination),
        );
        expect(probe!.width, lessThan(probe.height), reason: name);
      }
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
      _expectAbsent(result, destination);
    });

    testWidgets('cancel stops the work and leaves no file', (_) async {
      final destination = _out('cancelled.mp4');
      final task = NativeMediaCompressor.compressVideo(
        source: await _fixture('h264_aac_1080p.mp4'),
        destination: destination,
        options: const VideoOptions(maxShortSide: 1080),
      );
      await task.cancel();
      final result = await task.result;

      expect(result.status, CompressionStatus.cancelled);
      _expectAbsent(result, destination);
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
        _expectAbsent(result, destination);
      }
    });

    testWidgets('runs queued compressions one after another', (_) async {
      final source = await _fixture('h264_rotated_90.mp4');
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
      files.writeStale(destination);

      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_rotated_90.mp4'),
            destination: destination,
            options: const VideoOptions(maxShortSide: 240),
          ).result;

      expect(result.status, CompressionStatus.compressed);
      expect(await files.sizeOf(_at(result, destination)), greaterThan(1000));
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
      final output = _at(result, destination);
      expect(result.sizeBytes, await files.sizeOf(output));
      final probe = await NativeMediaCompressor.probeImage(output);
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
      final probe = await NativeMediaCompressor.probeImage(
        _at(result, destination),
      );
      expect(probe!.mimeType, 'image/png');
    });

    testWidgets('keeps the first frame of an animation', (_) async {
      final destination = _out('animated.jpg');
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('animated.gif'),
        destination: destination,
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      final probe = await NativeMediaCompressor.probeImage(
        _at(result, destination),
      );
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
          expect(
            result.status,
            CompressionStatus.compressed,
            reason: '$name $result',
          );
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
      _expectAbsent(result, destination);
    });
  });
}
