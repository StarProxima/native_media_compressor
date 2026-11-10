import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_media_compressor/native_media_compressor.dart';

import 'support/background.dart';
import 'support/test_files.dart' as files;

final _isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

final _isApple =
    !kIsWeb &&
    const [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ].contains(defaultTargetPlatform);

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

enum _Host { android, apple, windows, linux, web }

final _host =
    kIsWeb
        ? _Host.web
        : switch (defaultTargetPlatform) {
          TargetPlatform.android => _Host.android,
          TargetPlatform.iOS || TargetPlatform.macOS => _Host.apple,
          TargetPlatform.windows => _Host.windows,
          _ => _Host.linux,
        };

/// A fixture and where the readme's format tables promise it: [compresses]
/// must succeed, [rejects] must be unsupported, anywhere else either works.
typedef _Format = ({String name, Set<_Host> compresses, Set<_Host> rejects});

const _all = {..._Host.values};

const List<_Format> _videoFormats = [
  (name: 'format_h264.m4v', compresses: _all, rejects: {}),
  (name: 'format_h264.3gp', compresses: _all, rejects: {}),
  // Mono AAC at 22.05 kHz: copied where AAC is copied, resampled where it is
  // re-encoded, since the AAC encoders take only 44.1 and 48 kHz.
  (name: 'format_aac_22k.mp4', compresses: _all, rejects: {}),
  (
    name: 'format_h264.mkv',
    compresses: {_Host.android, _Host.windows, _Host.linux},
    rejects: {_Host.apple, _Host.web},
  ),
  (
    name: 'format_hevc.mp4',
    compresses: {_Host.android, _Host.apple, _Host.linux},
    rejects: {},
  ),
  (
    name: 'format_vp8.webm',
    compresses: {_Host.android, _Host.linux},
    rejects: {_Host.apple, _Host.web},
  ),
  (
    name: 'format_vp9.webm',
    compresses: {_Host.android, _Host.linux},
    rejects: {_Host.apple, _Host.web},
  ),
  (
    name: 'format_vp9.mp4',
    compresses: {_Host.android, _Host.linux, _Host.web},
    rejects: {_Host.apple},
  ),
  (
    name: 'format_av1.mp4',
    compresses: {_Host.android, _Host.linux, _Host.web},
    rejects: {},
  ),
];

const List<_Format> _imageFormats = [
  (name: 'format.bmp', compresses: _all, rejects: {}),
  (
    name: 'format.tiff',
    compresses: {_Host.apple, _Host.windows, _Host.linux},
    rejects: {_Host.android, _Host.web},
  ),
  (
    name: 'format.avif',
    compresses: {_Host.android, _Host.apple, _Host.web},
    rejects: {},
  ),
];

/// What is wrong with [result] for [format] on this platform, or null.
String? _formatProblem(_Format format, CompressionResult result) {
  // The CI log then shows what each platform does with the formats the
  // readme leaves open.
  debugPrint('format ${_host.name} ${format.name}: ${result.status.name}');
  final expected =
      format.compresses.contains(_host)
          ? CompressionStatus.compressed
          : format.rejects.contains(_host)
          ? CompressionStatus.unsupported
          : null;
  final allowed = {CompressionStatus.compressed, CompressionStatus.unsupported};
  if (expected != null && result.status != expected ||
      !allowed.contains(result.status)) {
    return '${format.name}: expected ${expected?.name ?? 'compressed or '
            'unsupported'}, got $result';
  }
  if (result.isCompressed && (result.width, result.height) != (320, 240)) {
    return '${format.name}: ${result.width}x${result.height}, not 320x240';
  }

  return null;
}

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

    testWidgets('re-encodes audio it cannot copy to AAC', (_) async {
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

      // Browsers encode AAC only where the system offers an encoder.
      if (kIsWeb) {
        expect(
          withAudio.status,
          anyOf(CompressionStatus.compressed, CompressionStatus.unsupported),
        );
      } else {
        expect(
          withAudio.status,
          CompressionStatus.compressed,
          reason: '$withAudio',
        );
      }
      if (withAudio.isCompressed) {
        final probe = await NativeMediaCompressor.probeVideo(
          _at(withAudio, kept),
        );
        expect(probe!.audioCodec, 'audio/mp4a-latm');
      } else {
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

    testWidgets('cancel stops a compression that is already running', (
      _,
    ) async {
      final destination = _out('cancelled-midway.mp4');
      final task = NativeMediaCompressor.compressVideo(
        source: await _fixture('long_1080p.mp4'),
        destination: destination,
        options: const VideoOptions(maxShortSide: 1080),
      );
      await task.progress.firstWhere((value) => value > 0);
      await task.cancel();
      final result = await task.result;

      expect(result.status, CompressionStatus.cancelled, reason: '$result');
      _expectAbsent(result, destination);
    });

    testWidgets('cancels a queued video without running it', (_) async {
      final running = NativeMediaCompressor.compressVideo(
        source: await _fixture('long_1080p.mp4'),
        destination: _out('queue-first.mp4'),
        options: const VideoOptions(maxShortSide: 360),
      );
      final queuedDestination = _out('queue-second.mp4');
      final queued = NativeMediaCompressor.compressVideo(
        source: await _fixture('h264_rotated_90.mp4'),
        destination: queuedDestination,
        options: const VideoOptions(maxShortSide: 240),
      );
      final queuedProgress = queued.progress.toList();
      await queued.cancel();

      final queuedResult = await queued.result;
      final runningResult = await running.result;

      expect(queuedResult.status, CompressionStatus.cancelled);
      _expectAbsent(queuedResult, queuedDestination);
      expect(await queuedProgress, isEmpty);
      expect(
        runningResult.status,
        CompressionStatus.compressed,
        reason: '$runningResult',
      );
    });

    testWidgets('never scales a video up', (_) async {
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_aac_1080p.mp4'),
            destination: _out('not-upscaled.mp4'),
            options: const VideoOptions(maxShortSide: 2160),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      final (short, long) = _sides(result.width, result.height);
      expect(short, inInclusiveRange(1072, 1080));
      expect(long, inInclusiveRange(1904, 1920));
    });

    testWidgets('fits the long side when only maxLongSide is set', (_) async {
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_aac_1080p.mp4'),
            destination: _out('long-side.mp4'),
            options: const VideoOptions(maxShortSide: null, maxLongSide: 640),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      final (short, long) = _sides(result.width, result.height);
      expect(long, inInclusiveRange(624, 640));
      expect(long / short, closeTo(16 / 9, 0.05));
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
      files.writeText(destination, 'stale');

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
      final apng = await NativeMediaCompressor.probeImage(
        await _fixture('animated.png'),
      );
      expect(apng!.frameCount, 3);
      expect(apng.mimeType, 'image/png');
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

    testWidgets('compresses and probes many images at once', (_) async {
      final sources = {
        'photo_exif_rotated.jpg': (450, 600),
        'alpha.png': (600, 400),
        'animated.gif': (320, 240),
        'animated.png': (320, 240),
      };
      final paths = {
        for (final name in sources.keys) name: await _fixture(name),
      };

      final work = [
        for (var copy = 0; copy < 3; copy++)
          for (final MapEntry(key: name, value: path) in paths.entries)
            NativeMediaCompressor.compressImage(
              source: path,
              destination: _out('parallel-$copy-$name.jpg'),
              options: const ImageOptions(maxLongSide: 600),
            ).then((result) => (name, result)),
      ];
      final probes = [
        for (final path in paths.values) NativeMediaCompressor.probeImage(path),
      ];
      final results = await Future.wait(work);

      for (final (name, result) in results) {
        expect(result.status, CompressionStatus.compressed, reason: name);
        expect((result.width, result.height), sources[name], reason: name);
      }
      expect(await Future.wait(probes), everyElement(isNotNull));
    });
  });

  group('image output', () {
    final latin1 = const Latin1Codec();

    Future<String> textOf(CompressionResult result, String destination) async =>
        latin1.decode(await files.bytesOf(_at(result, destination)));

    testWidgets('writes WebP where the platform can', (_) async {
      final destination = _out('photo.webp');
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('photo_exif_rotated.jpg'),
        destination: destination,
        options: const ImageOptions(maxLongSide: 800, format: ImageFormat.webp),
      );

      if (_isAndroid || kIsWeb) {
        expect(result.status, CompressionStatus.compressed, reason: '$result');
      } else {
        expect(
          result.status,
          anyOf(CompressionStatus.compressed, CompressionStatus.unsupported),
          reason: '$result',
        );
      }
      if (result.isCompressed) {
        expect((result.width, result.height), (600, 800));
        final text = await textOf(result, destination);
        expect(text.substring(0, 4), 'RIFF');
        expect(text.substring(8, 12), 'WEBP');
      } else {
        _expectAbsent(result, destination);
      }
    });

    testWidgets('writes HEIC where the platform can', (_) async {
      final destination = _out('photo.heic');
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('photo_exif_rotated.jpg'),
        destination: destination,
        options: const ImageOptions(maxLongSide: 800, format: ImageFormat.heic),
      );

      if (_isApple) {
        expect(result.status, CompressionStatus.compressed, reason: '$result');
      } else {
        expect(
          result.status,
          anyOf(CompressionStatus.compressed, CompressionStatus.unsupported),
          reason: '$result',
        );
      }
      if (result.isCompressed) {
        expect((result.width, result.height), (600, 800));
        expect(
          (await textOf(result, destination)).substring(4, 12),
          'ftypheic',
        );
      } else {
        _expectAbsent(result, destination);
      }
    });

    testWidgets('drops metadata unless asked to keep it', (_) async {
      final source = await _fixture('photo_exif_full.jpg');
      final plain = _out('metadata-dropped.jpg');
      final kept = _out('metadata-kept.jpg');

      final dropped = await NativeMediaCompressor.compressImage(
        source: source,
        destination: plain,
        options: const ImageOptions(maxLongSide: 800),
      );
      final keeping = await NativeMediaCompressor.compressImage(
        source: source,
        destination: kept,
        options: const ImageOptions(maxLongSide: 800, keepMetadata: true),
      );

      expect(dropped.status, CompressionStatus.compressed, reason: '$dropped');
      expect(keeping.status, CompressionStatus.compressed, reason: '$keeping');
      expect(await textOf(dropped, plain), isNot(contains('NMCTestCamera')));
      final keptText = await textOf(keeping, kept);
      // Linux and Windows may not write metadata; everywhere else they must.
      if (_isAndroid || _isApple || kIsWeb) {
        expect(keptText, contains('NMCTestCamera'));
      }
      // The orientation is in the pixels now, so a kept tag must not turn
      // the picture a second time.
      final probe = await NativeMediaCompressor.probeImage(_at(keeping, kept));
      expect((probe!.width, probe.height), (600, 800));
    });

    testWidgets('a foreground notification keeps videos working', (_) async {
      NativeMediaCompressor.androidForegroundNotification =
          const AndroidForegroundNotification(title: 'Compressing video');
      try {
        final destination = _out('foreground.mp4');
        final result =
            await NativeMediaCompressor.compressVideo(
              source: await _fixture('h264_rotated_90.mp4'),
              destination: destination,
              options: const VideoOptions(maxShortSide: 240),
            ).result;

        expect(result.status, CompressionStatus.compressed, reason: '$result');
      } finally {
        NativeMediaCompressor.androidForegroundNotification = null;
      }
    });
  });

  group('video tools', () {
    testWidgets('probe reports the frame rate', (_) async {
      final probe = await NativeMediaCompressor.probeVideo(
        await _fixture('h264_aac_1080p.mp4'),
      );

      expect(probe!.frameRate, closeTo(30, 0.5));
    });

    testWidgets('writes HEVC where the platform can, else H.264', (_) async {
      final source = await _fixture('h264_aac_1080p.mp4');
      final hevcPath = _out('codec-hevc.mp4');
      final avcPath = _out('codec-avc.mp4');
      final hevc =
          await NativeMediaCompressor.compressVideo(
            source: source,
            destination: hevcPath,
            options: const VideoOptions(codec: VideoCodec.hevc),
          ).result;
      final avc =
          await NativeMediaCompressor.compressVideo(
            source: source,
            destination: avcPath,
          ).result;

      expect(hevc.status, CompressionStatus.compressed, reason: '$hevc');
      expect(avc.videoCodec, VideoCodec.h264);
      if (_isAndroid || _isApple) expect(hevc.videoCodec, VideoCodec.hevc);
      expect(hevc.videoCodec, isNotNull);
      final probe = await NativeMediaCompressor.probeVideo(_at(hevc, hevcPath));
      expect(
        probe!.videoCodec,
        hevc.videoCodec == VideoCodec.hevc ? 'video/hevc' : 'video/avc',
      );
      if (hevc.videoCodec == VideoCodec.hevc) {
        expect(hevc.sizeBytes, lessThan(avc.sizeBytes!));
      }
    });

    testWidgets('keeps only the trimmed range', (_) async {
      final destination = _out('trimmed.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('long_1080p.mp4'),
            destination: destination,
            options: const VideoOptions(
              maxShortSide: 360,
              trimStart: Duration(seconds: 2),
              trimEnd: Duration(seconds: 5),
            ),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      final probe = await NativeMediaCompressor.probeVideo(
        _at(result, destination),
      );
      expect(probe!.duration.inMilliseconds, closeTo(3000, 200));
      expect(probe.hasAudio, isTrue);
    });

    testWidgets('a trim past the end keeps up to the end', (_) async {
      final destination = _out('trimmed-tail.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_aac_1080p.mp4'),
            destination: destination,
            options: const VideoOptions(
              maxShortSide: 360,
              trimStart: Duration(milliseconds: 1000),
              trimEnd: Duration(seconds: 30),
            ),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      final probe = await NativeMediaCompressor.probeVideo(
        _at(result, destination),
      );
      expect(probe!.duration.inMilliseconds, closeTo(1000, 200));
    });

    testWidgets('rotates by quarter turns', (_) async {
      final destination = _out('rotated-turn.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_aac_1080p.mp4'),
            destination: destination,
            options: const VideoOptions(
              maxShortSide: 360,
              rotateQuarterTurns: 1,
            ),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect((result.width, result.height), (360, 640));
      final probe = await NativeMediaCompressor.probeVideo(
        _at(result, destination),
      );
      expect((probe!.width, probe.height), (360, 640));
    });

    testWidgets('saves a frame as an image', (_) async {
      final destination = _out('thumbnail.jpg');
      final result = await NativeMediaCompressor.videoThumbnail(
        source: await _fixture('h264_aac_1080p.mp4'),
        destination: destination,
        position: const Duration(seconds: 1),
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect((result.width, result.height), (512, 288));
      final probe = await NativeMediaCompressor.probeImage(
        _at(result, destination),
      );
      expect((probe!.width, probe.height), (512, 288));
      expect(probe.mimeType, 'image/jpeg');
    });

    testWidgets('a thumbnail keeps the displayed orientation', (_) async {
      final destination = _out('thumbnail-rotated.png');
      final result = await NativeMediaCompressor.videoThumbnail(
        source: await _fixture('h264_rotated_90.mp4'),
        destination: destination,
        position: const Duration(seconds: 30),
        options: const ImageOptions(maxLongSide: 320, format: ImageFormat.png),
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect((result.width, result.height), (180, 320));
    });

    testWidgets('a thumbnail of a broken file leaves no output', (_) async {
      final destination = _out('thumbnail-broken.jpg');
      final result = await NativeMediaCompressor.videoThumbnail(
        source: await _fixture('broken.jpg'),
        destination: destination,
      );

      expect(
        result.status,
        anyOf(CompressionStatus.unsupported, CompressionStatus.failed),
      );
      _expectAbsent(result, destination);
    });
  });

  group('presets and targets', () {
    Future<int> outputSize(CompressionResult result, String destination) =>
        files.sizeOf(_at(result, destination));

    testWidgets('stronger presets give smaller files', (_) async {
      final source = await _fixture('h264_aac_1080p.mp4');
      final sizes = <int>[];
      for (final (name, options) in [
        ('strong', VideoOptions.strong),
        ('balanced', VideoOptions.balanced),
        ('light', VideoOptions.light),
      ]) {
        final destination = _out('preset-$name.mp4');
        final result =
            await NativeMediaCompressor.compressVideo(
              source: source,
              destination: destination,
              options: options,
            ).result;
        expect(result.status, CompressionStatus.compressed, reason: name);
        sizes.add(await outputSize(result, destination));
      }

      if (files.isIosSimulator) {
        markTestSkipped('the simulator encoder ignores low bitrates');
        return;
      }
      expect(sizes[0], lessThan(sizes[1]));
      expect(sizes[1], lessThan(sizes[2]));
    });

    testWidgets('the estimate is close to the real output', (_) async {
      final source = await _fixture('h264_aac_1080p.mp4');
      final estimate = await NativeMediaCompressor.estimateVideo(source);
      final destination = _out('estimated.mp4');
      final result =
          await NativeMediaCompressor.compressVideo(
            source: source,
            destination: destination,
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect((estimate!.width, estimate.height), (result.width, result.height));
      if (files.isIosSimulator) {
        markTestSkipped('the simulator encoder ignores low bitrates');
        return;
      }
      final ratio = await outputSize(result, destination) / estimate.sizeBytes;
      expect(ratio, inInclusiveRange(0.6, 1.5));
    });

    testWidgets('a video that cannot shrink enough is skipped', (_) async {
      final destination = _out('not-worth-it.mp4');
      files.writeText(destination, 'keep');

      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('long_1080p.mp4'),
            destination: destination,
            options: VideoOptions.light.copyWith(minSavingsPercent: 50),
          ).result;

      expect(result.status, CompressionStatus.skipped, reason: '$result');
      expect(result.path, isNull);
      if (!kIsWeb) expect(files.readText(destination), 'keep');
    });

    testWidgets('video lands near the target size', (_) async {
      final destination = _out('target.mp4');
      const target = 300000;
      final result =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_aac_1080p.mp4'),
            destination: destination,
            options: const VideoOptions(targetBytes: target),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      if (files.isIosSimulator) {
        markTestSkipped('the simulator encoder ignores low bitrates');
        return;
      }
      expect(
        await outputSize(result, destination),
        inInclusiveRange(target * 0.5, target * 1.3),
      );
    });

    testWidgets('an image fits the target size', (_) async {
      final destination = _out('target.jpg');
      const target = 40000;
      final result = await NativeMediaCompressor.compressImage(
        source: await _fixture('photo_exif_rotated.jpg'),
        destination: destination,
        options: const ImageOptions(targetBytes: target),
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect(result.sizeBytes, lessThanOrEqualTo(target));
      expect(await outputSize(result, destination), result.sizeBytes);
    });

    testWidgets('compresses an image held in memory', (_) async {
      final bytes = await files.bytesOf(
        await _fixture('photo_exif_rotated.jpg'),
      );

      final result = await NativeMediaCompressor.compressImageBytes(
        bytes,
        options: const ImageOptions(maxLongSide: 800),
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect((result.width, result.height), (600, 800));
      expect(result.bytes!.length, lessThan(bytes.length));
      expect(result.bytes!.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    });
  });

  group('formats', () {
    testWidgets('compresses the video formats the readme lists', (_) async {
      final problems = <String>[];
      for (final format in _videoFormats) {
        final destination = _out('${format.name}.mp4');
        final result =
            await NativeMediaCompressor.compressVideo(
              source: await _fixture(format.name),
              destination: destination,
            ).result;
        problems.add(_formatProblem(format, result) ?? '');
        if (result.isCompressed) {
          final probe = await NativeMediaCompressor.probeVideo(
            _at(result, destination),
          );
          if (probe?.videoCodec != 'video/avc') {
            problems.add('${format.name}: output is ${probe?.videoCodec}');
          }
        }
      }

      expect(problems.where((problem) => problem.isNotEmpty), isEmpty);
    });

    testWidgets('compresses the image formats the readme lists', (_) async {
      final problems = <String>[];
      for (final format in _imageFormats) {
        final result = await NativeMediaCompressor.compressImage(
          source: await _fixture(format.name),
          destination: _out('${format.name}.jpg'),
        );
        problems.add(_formatProblem(format, result) ?? '');
      }

      expect(problems.where((problem) => problem.isNotEmpty), isEmpty);
    });
  });

  // The web ignores destinations: results are always new object URLs.
  group('destination', skip: kIsWeb, () {
    Future<String> copyOf(String name) =>
        files.copyFixture(name, _out('own-$name'));

    testWidgets('compresses an image in place', (_) async {
      final path = await copyOf('photo_exif_rotated.jpg');
      final before = await files.sizeOf(path);

      final result = await NativeMediaCompressor.compressImage(
        source: path,
        destination: path,
        options: const ImageOptions(maxLongSide: 800),
      );

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect(await files.sizeOf(path), lessThan(before));
      final probe = await NativeMediaCompressor.probeImage(path);
      expect((probe!.width, probe.height), (600, 800));
    });

    testWidgets('compresses a video in place', (_) async {
      final path = await copyOf('h264_rotated_90.mp4');
      final before = await files.sizeOf(path);

      final result =
          await NativeMediaCompressor.compressVideo(
            source: path,
            destination: path,
            options: const VideoOptions(maxShortSide: 240),
          ).result;

      expect(result.status, CompressionStatus.compressed, reason: '$result');
      expect(await files.sizeOf(path), lessThan(before));
      final probe = await NativeMediaCompressor.probeVideo(path);
      expect(probe!.width, lessThan(probe.height));
    });

    testWidgets('a failure leaves an existing destination as it was', (
      _,
    ) async {
      final image = _out('kept.jpg');
      final video = _out('kept.mp4');
      files.writeText(image, 'keep');
      files.writeText(video, 'keep');

      final imageResult = await NativeMediaCompressor.compressImage(
        source: await _fixture('broken.jpg'),
        destination: image,
      );
      final videoResult =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_aac_1080p.mp4'),
            destination: video,
            options: const VideoOptions(
              maxShortSide: 1080,
              videoBitrate: 8000000,
              maxBytes: 20000,
            ),
          ).result;

      expect(imageResult.isCompressed, isFalse);
      expect(videoResult.status, CompressionStatus.tooLarge);
      expect(files.readText(image), 'keep');
      expect(files.readText(video), 'keep');
    });

    testWidgets('a directory destination is not touched', (_) async {
      final directory = files.createDirectory(_out('folder'));
      final inside = '$directory/inside.txt';
      files.writeText(inside, 'keep');
      final source = await _fixture('photo_exif_rotated.jpg');

      final result = await NativeMediaCompressor.compressImage(
        source: source,
        destination: directory,
      );

      expect(result.isCompressed, isFalse);
      expect(files.readText(inside), 'keep');
      expect(files.exists(source), isTrue);
    });

    testWidgets('no temporary file is left behind', (_) async {
      final directory = files.createDirectory(_out('leftovers'));

      final outcomes = [
        (await NativeMediaCompressor.compressImage(
          source: await _fixture('broken.jpg'),
          destination: '$directory/broken.jpg',
        )).status,
        (await NativeMediaCompressor.compressVideo(
              source: await _fixture('audio_only.m4a'),
              destination: '$directory/audio.mp4',
            ).result)
            .status,
        (await NativeMediaCompressor.compressVideo(
              source: await _fixture('h264_aac_1080p.mp4'),
              destination: '$directory/too-large.mp4',
              options: const VideoOptions(
                maxShortSide: 1080,
                videoBitrate: 8000000,
                maxBytes: 20000,
              ),
            ).result)
            .status,
      ];
      final running = NativeMediaCompressor.compressVideo(
        source: await _fixture('long_1080p.mp4'),
        destination: '$directory/cancelled.mp4',
        options: const VideoOptions(maxShortSide: 1080),
      );
      await running.progress.firstWhere((value) => value > 0);
      await running.cancel();
      outcomes.add((await running.result).status);

      expect(outcomes, everyElement(isNot(CompressionStatus.compressed)));
      expect(files.list(directory), isEmpty);

      final image = await NativeMediaCompressor.compressImage(
        source: await _fixture('photo_exif_rotated.jpg'),
        destination: '$directory/photo.jpg',
      );
      final video =
          await NativeMediaCompressor.compressVideo(
            source: await _fixture('h264_rotated_90.mp4'),
            destination: '$directory/video.mp4',
            options: const VideoOptions(maxShortSide: 240),
          ).result;

      expect(
        [image.status, video.status],
        [CompressionStatus.compressed, CompressionStatus.compressed],
      );
      expect(
        files.list(directory),
        unorderedEquals(['photo.jpg', 'video.mp4']),
      );
    });

    testWidgets('paths may contain spaces and non-Latin letters', (_) async {
      final directory = files.createDirectory(_out('папка с пробелами 📷'));
      final photo = await files.copyFixture(
        'photo_exif_rotated.jpg',
        '$directory/фото 1.jpg',
      );
      final clip = await files.copyFixture(
        'h264_rotated_90.mp4',
        '$directory/видео 1.mp4',
      );

      expect(await NativeMediaCompressor.probeImage(photo), isNotNull);
      expect(await NativeMediaCompressor.probeVideo(clip), isNotNull);
      final image = await NativeMediaCompressor.compressImage(
        source: photo,
        destination: '$directory/сжатое фото.jpg',
        options: const ImageOptions(maxLongSide: 800),
      );
      final video =
          await NativeMediaCompressor.compressVideo(
            source: clip,
            destination: '$directory/сжатое видео.mp4',
            options: const VideoOptions(maxShortSide: 240),
          ).result;

      expect(image.status, CompressionStatus.compressed, reason: '$image');
      expect(video.status, CompressionStatus.compressed, reason: '$video');
      expect(files.exists('$directory/сжатое фото.jpg'), isTrue);
      expect(files.exists('$directory/сжатое видео.mp4'), isTrue);
    });
  });
  group('native', skip: kIsWeb, () {
    testWidgets('works from a background isolate', (_) async {
      final image = await _fixture('photo_exif_rotated.jpg');
      final video = await _fixture('h264_rotated_90.mp4');
      final imageDestination = _out('isolate.jpg');
      final videoDestination = _out('isolate.mp4');

      final (imageStatus, videoStatus, probe) = await runInBackground(() async {
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

    testWidgets('reads content:// URIs on Android', skip: !_isAndroid, (
      _,
    ) async {
      final photo = files.contentUri(await _fixture('photo_exif_rotated.jpg'));
      final clip = files.contentUri(await _fixture('h264_rotated_90.mp4'));

      final imageProbe = await NativeMediaCompressor.probeImage(photo);
      final videoProbe = await NativeMediaCompressor.probeVideo(clip);
      final image = await NativeMediaCompressor.compressImage(
        source: photo,
        destination: _out('content.jpg'),
        options: const ImageOptions(maxLongSide: 800),
      );
      final video =
          await NativeMediaCompressor.compressVideo(
            source: clip,
            destination: _out('content.mp4'),
            options: const VideoOptions(maxShortSide: 240),
          ).result;

      expect((imageProbe!.width, imageProbe.height), (1200, 1600));
      expect(videoProbe!.width, lessThan(videoProbe.height));
      expect(image.status, CompressionStatus.compressed, reason: '$image');
      expect((image.width, image.height), (600, 800));
      expect(video.status, CompressionStatus.compressed, reason: '$video');
    });
  });
}
