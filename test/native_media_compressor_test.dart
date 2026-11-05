import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_media_compressor/native_media_compressor.dart';
import 'package:native_media_compressor/src/messages.g.dart' as pigeon;
import 'package:native_media_compressor/src/platform.dart';

const _prefix = 'dev.flutter.pigeon.native_media_compressor';
const _codec = pigeon.MediaCompressorHostApi.pigeonChannelCodec;

/// Answers host API calls the way the native side would.
class _FakeHost {
  _FakeHost() {
    for (final method in [
      'compressVideo',
      'compressImage',
      'cancel',
      'probeImage',
      'probeVideo',
    ]) {
      _messenger.setMockMessageHandler(
        '$_prefix.MediaCompressorHostApi.$method',
        (message) async {
          final args = _codec.decodeMessage(message)! as List<Object?>;
          calls.add((method, args));
          final reply = await handlers[method]!(args);

          return _codec.encodeMessage(reply);
        },
      );
    }
  }

  final calls = <(String, List<Object?>)>[];
  final handlers = <String, Future<List<Object?>> Function(List<Object?>)>{};

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> sendProgress(int taskId, double value) =>
      _messenger.handlePlatformMessage(
        '$_prefix.MediaCompressorFlutterApi.onProgress',
        _codec.encodeMessage([taskId, value]),
        (_) {},
      );
}

List<Object?> _ok(Object? value) => [value];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeHost host;

  setUp(() {
    host = _FakeHost();
    NativeMediaCompressorPlatform.instance = PigeonMediaCompressor();
  });

  test('compressVideo passes options and reports the destination', () async {
    host.handlers['compressVideo'] =
        (_) async => _ok(
          pigeon.CompressionReply(
            status: pigeon.CompressionStatus.compressed,
            width: 720,
            height: 1280,
            sizeBytes: 1000,
          ),
        );

    final result =
        await NativeMediaCompressor.compressVideo(
          source: '/in.mov',
          destination: '/out.mp4',
          options: const VideoOptions(maxBytes: 5000, includeAudio: false),
        ).result;

    expect(result.status, CompressionStatus.compressed);
    expect(result.path, '/out.mp4');
    expect((result.width, result.height, result.sizeBytes), (720, 1280, 1000));
    final request = host.calls.single.$2[1]! as pigeon.VideoRequest;
    expect(request.source, '/in.mov');
    expect(request.maxShortSide, 720);
    expect(request.maxBytes, 5000);
    expect(request.includeAudio, isFalse);
  });

  test('a status other than compressed has no path', () async {
    host.handlers['compressImage'] =
        (_) async => _ok(
          pigeon.CompressionReply(status: pigeon.CompressionStatus.tooLarge),
        );

    final result = await NativeMediaCompressor.compressImage(
      source: '/in.heic',
      destination: '/out.jpg',
    );

    expect(result.status, CompressionStatus.tooLarge);
    expect(result.path, isNull);
  });

  test('progress goes to its own task and closes with the result', () async {
    final finish = Completer<List<Object?>>();
    host.handlers['compressVideo'] = (_) => finish.future;

    final first = NativeMediaCompressor.compressVideo(
      source: '/a.mp4',
      destination: '/a-out.mp4',
    );
    final second = NativeMediaCompressor.compressVideo(
      source: '/b.mp4',
      destination: '/b-out.mp4',
    );
    final firstValues = first.progress.toList();
    final secondValues = second.progress.toList();
    await pumpEventQueue();
    final firstId = host.calls[0].$2[0]! as int;
    final secondId = host.calls[1].$2[0]! as int;

    await host.sendProgress(firstId, 0.25);
    await host.sendProgress(secondId, 1.5);
    finish.complete(
      _ok(pigeon.CompressionReply(status: pigeon.CompressionStatus.compressed)),
    );

    expect(await firstValues, [0.25]);
    expect(await secondValues, [1.0]);
  });

  test('cancel reaches the host only while the task runs', () async {
    final finish = Completer<List<Object?>>();
    host.handlers['compressVideo'] = (_) => finish.future;
    host.handlers['cancel'] = (_) async => _ok(null);

    final task = NativeMediaCompressor.compressVideo(
      source: '/a.mp4',
      destination: '/a-out.mp4',
    );
    await pumpEventQueue();
    await task.cancel();
    finish.complete(
      _ok(pigeon.CompressionReply(status: pigeon.CompressionStatus.cancelled)),
    );
    expect((await task.result).status, CompressionStatus.cancelled);
    await task.cancel();

    expect(host.calls.map((call) => call.$1), ['compressVideo', 'cancel']);
  });

  test('a host error becomes failed instead of throwing', () async {
    host.handlers['compressImage'] =
        (_) async => ['codec', 'decoder died', null];

    final result = await NativeMediaCompressor.compressImage(
      source: '/in.png',
      destination: '/out.png',
      options: const ImageOptions(format: ImageFormat.png),
    );

    expect(result.status, CompressionStatus.failed);
    expect(result.message, contains('decoder died'));
    final request = host.calls.single.$2[0]! as pigeon.ImageRequest;
    expect(request.format, pigeon.ImageFormat.png);
  });

  test('a missing host implementation is unsupported', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          '$_prefix.MediaCompressorHostApi.compressVideo',
          null,
        );

    final result =
        await NativeMediaCompressor.compressVideo(
          source: '/a.mp4',
          destination: '/a-out.mp4',
        ).result;

    expect(result.status, CompressionStatus.unsupported);
  });

  test('probes map host replies and errors', () async {
    host.handlers['probeImage'] =
        (_) async => _ok(
          pigeon.ImageProbe(
            width: 3000,
            height: 4000,
            frameCount: 12,
            mimeType: 'image/webp',
          ),
        );
    host.handlers['probeVideo'] = (_) async => ['io', 'unreadable', null];

    final image = await NativeMediaCompressor.probeImage('/a.webp');
    final video = await NativeMediaCompressor.probeVideo('/a.mp4');

    expect((image!.width, image.height, image.isAnimated), (3000, 4000, true));
    expect(video, isNull);
  });
}
