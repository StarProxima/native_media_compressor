import 'package:flutter_test/flutter_test.dart';
import 'package:native_media_compressor/src/web/media_plan.dart';

void main() {
  test('image sizes fit the tighter bound and never grow', () {
    expect(MediaPlan.imageSize(1200, 1600, null, 800), (600, 800));
    expect(MediaPlan.imageSize(1200, 1600, 300, 1000), (300, 400));
    expect(MediaPlan.imageSize(1200, 800, null, 4000), (1200, 800));
    expect(MediaPlan.imageSize(1000, 1, null, 10), (10, 1));
  });

  test('video sizes are even and stay within the bounds', () {
    expect(MediaPlan.videoSize(1920, 1080, 360, null), (640, 360));
    expect(MediaPlan.videoSize(1080, 1920, 360, null), (360, 640));
    expect(MediaPlan.videoSize(1206, 2622, 720, null), (720, 1564));
    expect(MediaPlan.videoSize(1081, 721, null, null), (1080, 720));
  });

  test('picks an H.264 level that fits the frame', () {
    expect(MediaPlan.avcLevel(640, 360, 30), 30);
    expect(MediaPlan.avcLevel(1280, 720, 30), 31);
    expect(MediaPlan.avcLevel(1920, 1080, 30), 40);
    expect(MediaPlan.avcLevel(1920, 1080, 60), 42);
    expect(MediaPlan.avcCodecs(1920, 1080, 30).first, 'avc1.640028');
  });

  test('frame limiter keeps one frame per slot', () {
    final limiter = FrameRateLimiter(30);
    final kept = [
      for (var i = 0; i < 60; i++)
        if (limiter.keep((i * 1000000 / 60).round())) i,
    ];

    expect(kept, hasLength(30));
    expect(FrameRateLimiter(null).keep(0), isTrue);
    final jittery = FrameRateLimiter(30);
    expect(
      [0, 33000, 66900, 99800].where(jittery.keep),
      hasLength(4),
      reason: 'a frame a little early for its slot is kept',
    );
  });

  test('progress is monotonic, throttled and ends at 1', () {
    var now = DateTime(2024);
    final values = <double>[];
    final progress = ProgressThrottle(values.add, clock: () => now);

    progress
      ..report(0.1)
      ..report(0.105)
      ..report(0.05)
      ..report(0.2);
    now = now.add(const Duration(milliseconds: 150));
    progress
      ..report(0.201)
      ..complete();

    expect(values, [0.1, 0.2, 0.201, 1.0]);
  });
}
