import 'package:flutter/material.dart';
import 'package:native_media_compressor/native_media_compressor.dart';

import '../format.dart';
import '../media/settings.dart';
import '../widgets/option_controls.dart';
import '../widgets/preset_selector.dart';
import '../widgets/section_card.dart';

/// Preset, custom options and the live size estimate for a video.
class VideoSettingsCard extends StatelessWidget {
  const VideoSettingsCard({
    super.key,
    required this.settings,
    required this.sourceBytes,
    required this.estimate,
    required this.isEstimating,
    required this.onChanged,
  });

  static const _descriptions = {
    Preset.light: 'Up to 1080p at 60 fps, close to the source quality.',
    Preset.balanced: 'Up to 720p at 30 fps. The default for sharing.',
    Preset.strong:
        'Up to 480p at 30 fps: the smallest files that stay watchable.',
    Preset.custom: 'Your own target size, codec, trim, rotation and audio.',
  };

  final VideoSettings settings;

  /// Size of the picked source; null before a file is picked.
  final int? sourceBytes;
  final VideoEstimate? estimate;
  final bool isEstimating;

  /// Null while compressing, which locks the controls.
  final ValueChanged<VideoSettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final sourceBytes = this.sourceBytes;

    return SectionCard(
      title: 'Settings',
      icon: Icons.tune,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PresetSelector(
            value: settings.preset,
            descriptions: _descriptions,
            onChanged:
                onChanged == null
                    ? null
                    : (preset) => onChanged(settings.copyWith(preset: preset)),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child:
                settings.preset == Preset.custom
                    ? Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: _CustomVideoControls(
                        settings: settings,
                        sourceBytes: sourceBytes,
                        onChanged: onChanged,
                      ),
                    )
                    : const SizedBox(width: double.infinity),
          ),
          if (sourceBytes != null) ...[
            const SizedBox(height: 20),
            _EstimateLine(
              estimate: estimate,
              sourceBytes: sourceBytes,
              isEstimating: isEstimating,
            ),
          ],
        ],
      ),
    );
  }
}

class _CustomVideoControls extends StatelessWidget {
  const _CustomVideoControls({
    required this.settings,
    required this.sourceBytes,
    required this.onChanged,
  });

  final VideoSettings settings;
  final int? sourceBytes;
  final ValueChanged<VideoSettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final sourceBytes = this.sourceBytes;
    final duration = settings.duration;
    void update(VideoSettings next) => onChanged?.call(next);
    final enabled = onChanged != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sourceBytes != null) ...[
          TargetSizeControl(
            enabled: settings.useTarget,
            targetBytes: settings.targetBytes,
            sourceBytes: sourceBytes,
            onEnabledChanged:
                enabled
                    ? (on) => update(settings.copyWith(useTarget: on))
                    : null,
            onTargetChanged:
                enabled
                    ? (bytes) => update(settings.copyWith(targetBytes: bytes))
                    : null,
          ),
          const SizedBox(height: 12),
        ],
        OptionTile(
          title: 'Codec',
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<VideoCodec>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: VideoCodec.h264, label: Text('H.264')),
                ButtonSegment(value: VideoCodec.hevc, label: Text('HEVC')),
              ],
              selected: {settings.codec},
              onSelectionChanged:
                  enabled
                      ? (selection) =>
                          update(settings.copyWith(codec: selection.single))
                      : null,
            ),
          ),
        ),
        if (duration > Duration.zero) ...[
          const SizedBox(height: 16),
          OptionTile(
            title: 'Trim',
            value:
                '${Formats.position(settings.trimStart)} – '
                '${Formats.position(settings.trimEnd)}',
            child: RangeSlider(
              min: 0,
              max: duration.inMilliseconds.toDouble(),
              values: RangeValues(
                settings.trimStart.inMilliseconds.toDouble(),
                settings.trimEnd.inMilliseconds.toDouble(),
              ),
              labels: RangeLabels(
                Formats.position(settings.trimStart),
                Formats.position(settings.trimEnd),
              ),
              onChanged:
                  enabled
                      ? (values) => update(
                        settings.copyWith(
                          trimStart: Duration(
                            milliseconds: values.start.round(),
                          ),
                          trimEnd: Duration(milliseconds: values.end.round()),
                        ),
                      )
                      : null,
            ),
          ),
        ],
        const SizedBox(height: 8),
        _RotationRow(
          quarterTurns: settings.quarterTurns,
          onRotate:
              enabled
                  ? () => update(
                    settings.copyWith(
                      quarterTurns: (settings.quarterTurns + 1) % 4,
                    ),
                  )
                  : null,
        ),
        const SizedBox(height: 8),
        SwitchOption(
          title: 'Keep audio',
          value: settings.includeAudio,
          onChanged:
              enabled
                  ? (on) => update(settings.copyWith(includeAudio: on))
                  : null,
        ),
        const SizedBox(height: 8),
        KeepOriginalControl(
          enabled: settings.keepOriginal,
          percent: settings.minSavingsPercent,
          onEnabledChanged:
              enabled
                  ? (on) => update(settings.copyWith(keepOriginal: on))
                  : null,
          onPercentChanged:
              enabled
                  ? (percent) =>
                      update(settings.copyWith(minSavingsPercent: percent))
                  : null,
        ),
      ],
    );
  }
}

class _RotationRow extends StatelessWidget {
  const _RotationRow({required this.quarterTurns, required this.onRotate});

  final int quarterTurns;
  final VoidCallback? onRotate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Text(
            'Rotate',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          '${quarterTurns * 90}°',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 12),
        IconButton.filledTonal(
          tooltip: 'Rotate 90° clockwise',
          onPressed: onRotate,
          icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
        ),
      ],
    );
  }
}

/// "≈ 4.1 MB · 1280×720 · 1.9 Mbit/s" for the current options.
class _EstimateLine extends StatelessWidget {
  const _EstimateLine({
    required this.estimate,
    required this.sourceBytes,
    required this.isEstimating,
  });

  final VideoEstimate? estimate;
  final int sourceBytes;
  final bool isEstimating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final estimate = this.estimate;
    final style = theme.textTheme.bodyLarge;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.insights_outlined, color: scheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child:
                estimate == null
                    ? Text(
                      isEstimating
                          ? 'Estimating…'
                          : 'No estimate: the video headers could not be read',
                      style: style,
                    )
                    : Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '≈ ${Formats.bytes(estimate.sizeBytes)}',
                          style: style?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                        Text(
                          '· ${Formats.resolution(estimate.width, estimate.height)}'
                          ' · ${Formats.bitrate(estimate.videoBitrate)}',
                          style: style?.copyWith(
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
          ),
          if (estimate != null)
            Text(
              Formats.change(sourceBytes, estimate.sizeBytes),
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      ),
    );
  }
}
