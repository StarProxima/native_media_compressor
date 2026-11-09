/// Size, frame rate and encoder level decisions shared by the web video and
/// image paths. Free of browser APIs so it runs in VM tests.
abstract final class MediaPlan {
  static double fitScale(
    int width,
    int height,
    int? maxShortSide,
    int? maxLongSide,
  ) {
    if (width <= 0 || height <= 0) return 1;
    final short = width < height ? width : height;
    final long = width < height ? height : width;
    var scale = 1.0;
    if (maxShortSide != null && maxShortSide > 0) {
      scale = _min(scale, maxShortSide / short);
    }
    if (maxLongSide != null && maxLongSide > 0) {
      scale = _min(scale, maxLongSide / long);
    }
    return scale;
  }

  static double _min(double a, double b) => a < b ? a : b;

  /// Output size of an image: each side rounded, at least 1.
  static (int, int) imageSize(
    int width,
    int height,
    int? maxShortSide,
    int? maxLongSide,
  ) {
    final scale = fitScale(width, height, maxShortSide, maxLongSide);
    int side(int value) {
      final scaled = (value * scale).round();
      return scaled < 1 ? 1 : scaled;
    }

    return (side(width), side(height));
  }

  /// Output size of a video: each side rounded down to an even number, as
  /// 4:2:0 encoders need, and never above the bounds.
  static (int, int) videoSize(
    int width,
    int height,
    int? maxShortSide,
    int? maxLongSide,
  ) {
    final scale = fitScale(width, height, maxShortSide, maxLongSide);
    int side(int value) {
      final scaled = (value * scale + 1e-6).floor() & ~1;
      return scaled < 2 ? 2 : scaled;
    }

    return (side(width), side(height));
  }

  static const _avcLevels = [
    (30, 1620, 40500),
    (31, 3600, 108000),
    (32, 5120, 216000),
    (40, 8192, 245760),
    (42, 8704, 522240),
    (50, 22080, 589824),
    (51, 36864, 983040),
    (52, 36864, 2073600),
    (60, 139264, 4177920),
    (61, 139264, 8355840),
    (62, 139264, 16711680),
  ];

  /// Smallest H.264 `level_idc` whose frame size and macroblock rate limits
  /// fit the stream; browsers reject a level that is too low for the size.
  static int avcLevel(int width, int height, double frameRate) {
    final macroblocks = ((width + 15) ~/ 16) * ((height + 15) ~/ 16);
    final rate = macroblocks * (frameRate <= 0 ? 30 : frameRate);
    for (final (level, maxFrame, maxRate) in _avcLevels) {
      if (macroblocks <= maxFrame && rate <= maxRate) return level;
    }
    return _avcLevels.last.$1;
  }

  /// WebCodecs codec strings to try, best profile first.
  static List<String> avcCodecs(int width, int height, double frameRate) {
    final level = avcLevel(width, height, frameRate).toRadixString(16);
    return ['avc1.6400$level', 'avc1.4d00$level', 'avc1.4200$level'];
  }

  /// HEVC levels as `general_level_idc` (30 times the level number) with
  /// their luma picture size and luma sample rate limits.
  static const _hevcLevels = [
    (30, 36864, 552960),
    (60, 122880, 3686400),
    (63, 245760, 7372800),
    (90, 552960, 16588800),
    (93, 983040, 33177600),
    (120, 2228224, 66846720),
    (123, 2228224, 133693440),
    (150, 8912896, 267386880),
    (153, 8912896, 534773760),
    (156, 8912896, 1069547520),
    (180, 35651584, 1069547520),
    (183, 35651584, 2139095040),
    (186, 35651584, 4278190080),
  ];

  /// Smallest HEVC `general_level_idc` whose limits fit the stream.
  static int hevcLevel(int width, int height, double frameRate) {
    final samples = width * height;
    final rate = samples * (frameRate <= 0 ? 30 : frameRate);
    for (final (level, maxSize, maxRate) in _hevcLevels) {
      if (samples <= maxSize && rate <= maxRate) return level;
    }
    return _hevcLevels.last.$1;
  }

  /// WebCodecs codec strings for HEVC Main, `hvc1` first: players on Apple
  /// platforms only accept HEVC whose parameter sets sit in the sample entry.
  static List<String> hevcCodecs(int width, int height, double frameRate) {
    final level = hevcLevel(width, height, frameRate);
    return ['hvc1.1.6.L$level.B0', 'hev1.1.6.L$level.B0'];
  }

  /// Average frame rate of [sampleCount] frames over [duration] ticks of
  /// [timescale], or null when the track does not say how long it is.
  static double? frameRate(int sampleCount, int duration, int timescale) {
    if (sampleCount <= 0 || duration <= 0 || timescale <= 0) return null;
    return sampleCount * timescale / duration;
  }
}

/// Drops frames so that at most one falls into each `1 / maxFrameRate`
/// slot of the timeline.
final class FrameRateLimiter {
  FrameRateLimiter(int? maxFrameRate)
    : _slot =
          maxFrameRate == null || maxFrameRate <= 0
              ? 0
              : 1000000 / maxFrameRate;

  final double _slot;
  int? _lastSlot;

  /// Whether to keep the frame presented at [timestampUs].
  bool keep(int timestampUs) {
    if (_slot == 0) return true;
    // A tenth of a slot absorbs timestamp jitter in variable frame rate
    // recordings, so a frame that is only slightly early is not dropped.
    final slot = ((timestampUs + _slot / 10) / _slot).floor();
    if (_lastSlot != null && slot <= _lastSlot!) return false;
    _lastSlot = slot;
    return true;
  }
}

/// Turns a stream of progress values into monotonic, throttled updates.
final class ProgressThrottle {
  ProgressThrottle(this._emit, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final void Function(double) _emit;
  final DateTime Function() _clock;
  double _last = -1;
  DateTime? _lastAt;

  void report(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped <= _last) return;
    final now = _clock();
    final due =
        _lastAt == null ||
        clamped - _last >= 0.01 ||
        now.difference(_lastAt!).inMilliseconds >= 100;
    if (!due) return;
    _last = clamped;
    _lastAt = now;
    _emit(clamped);
  }

  void complete() {
    if (_last >= 1) return;
    _last = 1;
    _emit(1);
  }
}
