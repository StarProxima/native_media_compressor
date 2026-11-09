import 'package:native_media_compressor/native_media_compressor.dart';

/// The ready presets, plus hand-picked options.
enum Preset { light, balanced, strong, custom }

/// What the video controls are set to.
class VideoSettings {
  const VideoSettings({
    this.preset = Preset.balanced,
    this.useTarget = true,
    this.targetBytes = 1,
    this.codec = VideoCodec.h264,
    this.duration = Duration.zero,
    this.trimStart = Duration.zero,
    this.trimEnd = Duration.zero,
    this.quarterTurns = 0,
    this.includeAudio = true,
    this.keepOriginal = false,
    this.minSavingsPercent = 20,
  });

  /// Settings for a freshly picked source of [sizeBytes] and [duration].
  factory VideoSettings.forSource({
    required int sizeBytes,
    required Duration duration,
  }) => VideoSettings(
    targetBytes: (sizeBytes * 0.4).round(),
    duration: duration,
    trimEnd: duration,
  );

  final Preset preset;
  final bool useTarget;
  final int targetBytes;
  final VideoCodec codec;

  /// Length of the source; zero when it could not be read, which hides
  /// trimming.
  final Duration duration;
  final Duration trimStart;
  final Duration trimEnd;
  final int quarterTurns;
  final bool includeAudio;
  final bool keepOriginal;
  final int minSavingsPercent;

  VideoOptions toOptions() => switch (preset) {
    Preset.light => VideoOptions.light,
    Preset.balanced => VideoOptions.balanced,
    Preset.strong => VideoOptions.strong,
    Preset.custom => VideoOptions(
      targetBytes: useTarget ? targetBytes : null,
      codec: codec,
      trimStart: trimStart > Duration.zero ? trimStart : null,
      trimEnd: trimEnd < duration ? trimEnd : null,
      rotateQuarterTurns: quarterTurns,
      includeAudio: includeAudio,
      minSavingsPercent: keepOriginal ? minSavingsPercent : null,
    ),
  };

  VideoSettings copyWith({
    Preset? preset,
    bool? useTarget,
    int? targetBytes,
    VideoCodec? codec,
    Duration? trimStart,
    Duration? trimEnd,
    int? quarterTurns,
    bool? includeAudio,
    bool? keepOriginal,
    int? minSavingsPercent,
  }) => VideoSettings(
    preset: preset ?? this.preset,
    useTarget: useTarget ?? this.useTarget,
    targetBytes: targetBytes ?? this.targetBytes,
    codec: codec ?? this.codec,
    duration: duration,
    trimStart: trimStart ?? this.trimStart,
    trimEnd: trimEnd ?? this.trimEnd,
    quarterTurns: quarterTurns ?? this.quarterTurns,
    includeAudio: includeAudio ?? this.includeAudio,
    keepOriginal: keepOriginal ?? this.keepOriginal,
    minSavingsPercent: minSavingsPercent ?? this.minSavingsPercent,
  );
}

/// What the image controls are set to.
class ImageSettings {
  const ImageSettings({
    this.preset = Preset.balanced,
    this.useTarget = true,
    this.targetBytes = 1,
    this.format = ImageFormat.jpeg,
    this.keepOriginal = false,
    this.minSavingsPercent = 20,
  });

  factory ImageSettings.forSource(int sizeBytes) =>
      ImageSettings(targetBytes: (sizeBytes * 0.3).round());

  final Preset preset;
  final bool useTarget;
  final int targetBytes;
  final ImageFormat format;
  final bool keepOriginal;
  final int minSavingsPercent;

  ImageOptions toOptions() => switch (preset) {
    Preset.light => ImageOptions.light,
    Preset.balanced => ImageOptions.balanced,
    Preset.strong => ImageOptions.strong,
    Preset.custom => ImageOptions(
      format: format,
      targetBytes: useTarget ? targetBytes : null,
      minSavingsPercent: keepOriginal ? minSavingsPercent : null,
    ),
  };

  String get extension =>
      preset == Preset.custom && format == ImageFormat.png ? 'png' : 'jpg';

  ImageSettings copyWith({
    Preset? preset,
    bool? useTarget,
    int? targetBytes,
    ImageFormat? format,
    bool? keepOriginal,
    int? minSavingsPercent,
  }) => ImageSettings(
    preset: preset ?? this.preset,
    useTarget: useTarget ?? this.useTarget,
    targetBytes: targetBytes ?? this.targetBytes,
    format: format ?? this.format,
    keepOriginal: keepOriginal ?? this.keepOriginal,
    minSavingsPercent: minSavingsPercent ?? this.minSavingsPercent,
  );
}

/// A finished compression with what the result card needs to explain it.
class CompressionOutcome {
  const CompressionOutcome({
    required this.result,
    required this.sourceBytes,
    required this.elapsed,
    required this.fileName,
    this.minSavingsPercent,
    this.requestedCodec,
  });

  final CompressionResult result;
  final int sourceBytes;
  final Duration elapsed;

  /// Name to save the output under.
  final String fileName;

  /// The threshold that was set, to explain [CompressionStatus.skipped].
  final int? minSavingsPercent;

  /// The codec that was asked for, to notice a fallback to H.264.
  final VideoCodec? requestedCodec;
}
