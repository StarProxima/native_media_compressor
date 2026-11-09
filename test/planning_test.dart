import 'package:flutter_test/flutter_test.dart';
import 'package:native_media_compressor/native_media_compressor.dart';
import 'package:native_media_compressor/src/planning.dart';

/// A phone recording: 1080p, 10 Mbit/s overall, 20 seconds.
const _phone = VideoMetadata(
  width: 1080,
  height: 1920,
  rotationDegrees: 90,
  duration: Duration(seconds: 20),
  hasAudio: true,
  isHdr: false,
  bitrate: 10000000,
);

void main() {
  group('VideoPlanning.videoBitrate', () {
    test('presets scale with the output frame', () {
      int bitrate(VideoOptions options) =>
          VideoPlanning.videoBitrate(_phone, options);

      expect(bitrate(VideoOptions.light), (1080 * 1920 * 30 * 0.1).round());
      expect(bitrate(VideoOptions.balanced), (720 * 1280 * 30 * 0.07).round());
      expect(
        bitrate(VideoOptions.strong),
        lessThan(bitrate(VideoOptions.balanced)),
      );
      expect(
        bitrate(VideoOptions.balanced),
        lessThan(bitrate(VideoOptions.light)),
      );
    });

    test('never exceeds the source video bitrate', () {
      const quiet = VideoMetadata(
        width: 1920,
        height: 1080,
        rotationDegrees: 0,
        duration: Duration(seconds: 10),
        hasAudio: true,
        isHdr: false,
        bitrate: 900000,
      );
      final sourceVideo =
          ((900000 - VideoPlanning.audioBitrate) * VideoPlanning.maxSourceShare)
              .round();

      expect(
        VideoPlanning.videoBitrate(quiet, VideoOptions.light),
        sourceVideo,
      );
      expect(
        VideoPlanning.videoBitrate(
          quiet,
          const VideoOptions(videoBitrate: 8000000),
        ),
        sourceVideo,
      );
    });

    test('quality percent is a share of the source video bitrate', () {
      expect(
        VideoPlanning.videoBitrate(
          _phone,
          const VideoOptions(qualityPercent: 30),
        ),
        (10000000 - VideoPlanning.audioBitrate) * 30 ~/ 100,
      );
      expect(
        VideoPlanning.videoBitrate(
          _phone,
          const VideoOptions(qualityPercent: 100),
        ),
        ((10000000 - VideoPlanning.audioBitrate) * VideoPlanning.maxSourceShare)
            .round(),
      );
    });

    test('target size leaves room for audio and the container', () {
      final bitrate = VideoPlanning.videoBitrate(
        _phone,
        const VideoOptions(targetBytes: 10000000),
      );

      expect(bitrate, (10000000 * 8 * 0.95 / 20 - 128000).round());
      expect(
        VideoPlanning.videoBitrate(
          _phone,
          const VideoOptions(targetBytes: 10000000, includeAudio: false),
        ),
        greaterThan(bitrate),
      );
    });

    test('target size wins over every other setting', () {
      expect(
        VideoPlanning.videoBitrate(
          _phone,
          const VideoOptions(
            targetBytes: 5000000,
            videoBitrate: 9000000,
            qualityPercent: 90,
          ),
        ),
        (5000000 * 8 * 0.95 / 20 - 128000).round(),
      );
    });

    test('a tiny target still gets a usable bitrate', () {
      expect(
        VideoPlanning.videoBitrate(_phone, const VideoOptions(targetBytes: 1)),
        VideoPlanning.minVideoBitrate,
      );
    });

    test('an unreadable source keeps the explicit or fallback bitrate', () {
      expect(
        VideoPlanning.videoBitrate(null, const VideoOptions()),
        VideoPlanning.fallbackVideoBitrate,
      );
      expect(
        VideoPlanning.videoBitrate(
          null,
          const VideoOptions(videoBitrate: 1234567),
        ),
        1234567,
      );
    });
  });

  test('estimate adds copied audio and follows the frame bounds', () {
    final estimate = VideoPlanning.estimate(_phone, VideoOptions.balanced);
    final video = (720 * 1280 * 30 * 0.07).round();

    expect((estimate.width, estimate.height), (720, 1280));
    expect(estimate.videoBitrate, video);
    expect(estimate.sizeBytes, ((video + 128000) * 20 / 8).round());
  });

  group('ImagePlanning.nextAttempt', () {
    test('aims JPEG quality at the target first', () {
      final next = ImagePlanning.nextAttempt(
        const ImageOptions(quality: 90),
        sizeBytes: 400000,
        targetBytes: 200000,
        longSide: 2048,
      );

      expect(next!.quality, 45);
      expect(next.maxLongSide, 2048);
    });

    test('always lowers quality by at least a few points', () {
      final next = ImagePlanning.nextAttempt(
        const ImageOptions(quality: 80),
        sizeBytes: 210000,
        targetBytes: 200000,
        longSide: 2048,
      );

      expect(next!.quality, 75);
    });

    test('shrinks the image once quality is at the floor', () {
      final next = ImagePlanning.nextAttempt(
        const ImageOptions(quality: ImagePlanning.minQuality),
        sizeBytes: 400000,
        targetBytes: 200000,
        longSide: 2000,
      );

      expect(next!.maxLongSide, 1500);
      expect(next.quality, ImagePlanning.minQuality);
    });

    test('shrinks PNG straight away and stops at a tiny image', () {
      const png = ImageOptions(format: ImageFormat.png);

      expect(
        ImagePlanning.nextAttempt(
          png,
          sizeBytes: 400000,
          targetBytes: 200000,
          longSide: 1000,
        )!.maxLongSide,
        750,
      );
      expect(
        ImagePlanning.nextAttempt(
          png,
          sizeBytes: 400000,
          targetBytes: 200000,
          longSide: 20,
        ),
        isNull,
      );
    });

    test('stops once the output fits', () {
      expect(
        ImagePlanning.nextAttempt(
          const ImageOptions(),
          sizeBytes: 100,
          targetBytes: 100,
          longSide: 2048,
        ),
        isNull,
      );
    });
  });

  test('savings need a strictly smaller output', () {
    bool enough(int output, int percent) => Savings.enough(
      outputBytes: output,
      sourceBytes: 1000,
      minSavingsPercent: percent,
    );

    expect(enough(1000, 0), isFalse);
    expect(enough(999, 0), isTrue);
    expect(enough(800, 20), isTrue);
    expect(enough(801, 20), isFalse);
  });

  test('presets keep their place in the size order', () {
    expect(
      VideoOptions.strong.maxShortSide! < VideoOptions.balanced.maxShortSide!,
      isTrue,
    );
    expect(ImageOptions.strong.quality < ImageOptions.light.quality, isTrue);
    expect(
      VideoOptions.balanced.copyWith(maxBytes: 10).maxShortSide,
      VideoOptions.balanced.maxShortSide,
    );
  });
}
