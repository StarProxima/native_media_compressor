import 'dart:math' as math;

import 'types.dart';
import 'web/media_plan.dart';

/// Turns [VideoOptions] into the concrete numbers the encoders get.
abstract final class VideoPlanning {
  /// Bitrate the copied audio is assumed to take; the probe reports only the
  /// overall bitrate of the file.
  static const audioBitrate = 128000;

  /// Below this the encoders produce mush whatever the frame size.
  static const minVideoBitrate = 100000;

  /// Used when the source cannot be probed; the compression itself then
  /// decides whether the file is readable.
  static const fallbackVideoBitrate = 2500000;

  /// Share of the source video bitrate the output may use at most:
  /// re-encoding at the source's own bitrate loses quality without saving
  /// space, and encoders overshoot their target by a few percent.
  static const maxSourceShare = 0.85;

  /// Frame rate assumed when the container does not report one.
  static const _assumedFrameRate = 30.0;

  /// HEVC reaches the quality of H.264 at about this share of its bitrate.
  static const hevcShare = 0.7;

  /// Displayed output size for a [source] frame.
  static (int, int) outputSize(VideoMetadata source, VideoOptions options) {
    final (width, height) = MediaPlan.videoSize(
      source.width,
      source.height,
      options.maxShortSide,
      options.maxLongSide,
    );

    return options.rotateQuarterTurns.isOdd ? (height, width) : (width, height);
  }

  /// Video bitrate for [source] under [options], never above
  /// [maxSourceShare] of the source's own video bitrate.
  static int videoBitrate(VideoMetadata? source, VideoOptions options) {
    if (source == null) {
      return options.videoBitrate ?? fallbackVideoBitrate;
    }
    final sourceVideo = _sourceVideoBitrate(source);
    final wanted = _wantedBitrate(source, options, sourceVideo);
    final capped =
        sourceVideo == null
            ? wanted
            : math.min(wanted, (sourceVideo * maxSourceShare).round());

    return math.max(capped, minVideoBitrate);
  }

  /// What [options] would produce for [source], without encoding.
  static VideoEstimate estimate(VideoMetadata source, VideoOptions options) {
    final (width, height) = outputSize(source, options);
    final bitrate = videoBitrate(source, options);
    final audio = _keepsAudio(source, options) ? audioBitrate : 0;
    final seconds = keptDuration(source, options).inMilliseconds / 1000;

    return VideoEstimate(
      width: width,
      height: height,
      videoBitrate: bitrate,
      sizeBytes: ((bitrate + audio) * seconds / 8).round(),
    );
  }

  static int _wantedBitrate(
    VideoMetadata source,
    VideoOptions options,
    int? sourceVideo,
  ) {
    final targetBytes = options.targetBytes;
    final seconds = keptDuration(source, options).inMilliseconds / 1000;
    if (targetBytes != null && seconds > 0) {
      final audio = _keepsAudio(source, options) ? audioBitrate : 0;
      // The container and the first keyframe take a few percent on top.
      return (targetBytes * 8 * 0.95 / seconds - audio).round();
    }
    final explicit = options.videoBitrate;
    if (explicit != null) return explicit;
    final percent = options.sourceBitratePercent;
    if (percent != null && sourceVideo != null) {
      return sourceVideo * percent ~/ 100;
    }
    final (width, height) = outputSize(source, options);
    final sourceRate = source.frameRate ?? _assumedFrameRate;
    final cap = options.maxFrameRate?.toDouble();
    final frameRate = cap == null ? sourceRate : math.min(sourceRate, cap);
    final efficiency = options.codec == VideoCodec.hevc ? hevcShare : 1.0;

    return (width * height * frameRate * options.bitsPerPixel * efficiency)
        .round();
  }

  /// How far over the target an output may land before a second pass.
  static const targetTolerance = 0.08;

  /// Whether [outputBytes] lands too far above [targetBytes].
  static bool missesTarget(int outputBytes, int targetBytes) =>
      outputBytes > targetBytes * (1 + targetTolerance);

  /// Bytes the copied or re-encoded audio of [source] is expected to take.
  static int audioBytes(VideoMetadata source, VideoOptions options) {
    if (!_keepsAudio(source, options)) return 0;
    final seconds = keptDuration(source, options).inMilliseconds / 1000;

    return (audioBitrate * seconds / 8).round();
  }

  /// Video bitrate for a second pass after [bitrate] produced [outputBytes]
  /// for [targetBytes]: the encoder's miss is assumed to be proportional, and
  /// only the video part of the file scales with the bitrate.
  static int correctedBitrate(
    int bitrate, {
    required int outputBytes,
    required int targetBytes,
    required int audioBytes,
  }) {
    final videoOut = outputBytes - audioBytes;
    final videoTarget = targetBytes - audioBytes;
    if (videoOut <= 0 || videoTarget <= 0) return minVideoBitrate;
    final corrected = (bitrate * videoTarget / videoOut * 0.95).round();

    return math.max(corrected, minVideoBitrate);
  }

  /// Length of the part of [source] that [options] keeps.
  static Duration keptDuration(VideoMetadata source, VideoOptions options) {
    final end =
        options.trimEnd == null || options.trimEnd! > source.duration
            ? source.duration
            : options.trimEnd!;
    final start = options.trimStart ?? Duration.zero;

    return end > start ? end - start : Duration.zero;
  }

  static int? _sourceVideoBitrate(VideoMetadata source) {
    final overall = source.bitrate;
    if (overall == null || overall <= 0) return null;
    final audio = source.hasAudio ? math.min(audioBitrate, overall ~/ 2) : 0;

    return overall - audio;
  }

  static bool _keepsAudio(VideoMetadata source, VideoOptions options) =>
      options.includeAudio && source.hasAudio;
}

/// Quality and size steps for [ImageOptions.targetBytes].
abstract final class ImagePlanning {
  /// JPEG quality is not worth going below this; shrinking the image keeps
  /// more detail from there on.
  static const minQuality = 40;

  /// How much each shrinking step takes off the long side.
  static const shrinkStep = 0.75;

  /// At most this many encodes per image.
  static const maxAttempts = 8;

  /// The next settings to try after [tried] produced [sizeBytes] for
  /// [targetBytes], or null when nothing is left to try.
  ///
  /// [longSide] is the long side [tried] produced.
  static ImageOptions? nextAttempt(
    ImageOptions tried, {
    required int sizeBytes,
    required int targetBytes,
    required int longSide,
  }) {
    if (sizeBytes <= targetBytes) return null;
    if (tried.format != ImageFormat.png && tried.quality > minQuality) {
      // JPEG size grows roughly with quality, so aim straight at the target
      // instead of stepping down a few points at a time.
      final ratio = targetBytes / sizeBytes;
      final quality =
          (tried.quality * ratio)
              .floor()
              .clamp(minQuality, math.max(minQuality, tried.quality - 5))
              .toInt();

      return tried.copyWith(quality: quality);
    }
    final shorter = (longSide * shrinkStep).floor();
    if (shorter < 16) return null;

    return ImageOptions(
      maxShortSide:
          tried.maxShortSide == null
              ? null
              : (tried.maxShortSide! * shrinkStep).floor(),
      maxLongSide: shorter,
      format: tried.format,
      quality: tried.quality,
      targetBytes: tried.targetBytes,
      minSavingsPercent: tried.minSavingsPercent,
      keepMetadata: tried.keepMetadata,
    );
  }
}

/// The `minSavingsPercent` rule of [VideoOptions] and [ImageOptions].
abstract final class Savings {
  /// Whether [outputBytes] is smaller than [sourceBytes] by at least
  /// [minSavingsPercent] percent.
  static bool enough({
    required int outputBytes,
    required int sourceBytes,
    required int minSavingsPercent,
  }) =>
      outputBytes < sourceBytes &&
      outputBytes * 100 <= sourceBytes * (100 - minSavingsPercent);
}
