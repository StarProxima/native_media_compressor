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

  /// The automatic bitrate assumes at most this many frames per second: the
  /// probe does not report the source rate, and a 60 fps budget would double
  /// the bitrate of the far more common 30 fps recordings.
  static const _assumedFrameRate = 30;

  /// Displayed output size for a [source] frame.
  static (int, int) outputSize(VideoMetadata source, VideoOptions options) =>
      MediaPlan.videoSize(
        source.width,
        source.height,
        options.maxShortSide,
        options.maxLongSide,
      );

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
    final seconds = source.duration.inMilliseconds / 1000;

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
    final seconds = source.duration.inMilliseconds / 1000;
    if (targetBytes != null && seconds > 0) {
      final audio = _keepsAudio(source, options) ? audioBitrate : 0;
      // The container and the first keyframe take a few percent on top.
      return (targetBytes * 8 * 0.95 / seconds - audio).round();
    }
    final explicit = options.videoBitrate;
    if (explicit != null) return explicit;
    final percent = options.qualityPercent;
    if (percent != null && sourceVideo != null) {
      return sourceVideo * percent ~/ 100;
    }
    final (width, height) = outputSize(source, options);
    final frameRate = math.min(
      options.maxFrameRate ?? _assumedFrameRate,
      _assumedFrameRate,
    );

    return (width * height * frameRate * options.bitsPerPixel).round();
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
    if (tried.format == ImageFormat.jpeg && tried.quality > minQuality) {
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
