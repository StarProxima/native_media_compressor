import 'package:flutter/material.dart';
import 'package:native_media_compressor/native_media_compressor.dart';

import '../media/settings.dart';
import '../widgets/option_controls.dart';
import '../widgets/preset_selector.dart';
import '../widgets/section_card.dart';

/// Preset and custom options for an image.
class ImageSettingsCard extends StatelessWidget {
  const ImageSettingsCard({
    super.key,
    required this.settings,
    required this.sourceBytes,
    required this.onChanged,
  });

  static const _descriptions = {
    Preset.light: 'Long side up to 2560 px at JPEG quality 90.',
    Preset.balanced: 'Long side up to 2048 px at JPEG quality 85. The default.',
    Preset.strong:
        'Long side up to 1280 px at JPEG quality 75: small files for chats '
        'and previews.',
    Preset.custom: 'Your own target size and output format.',
  };

  final ImageSettings settings;
  final int? sourceBytes;

  /// Null while compressing, which locks the controls.
  final ValueChanged<ImageSettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;

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
                      child: _CustomImageControls(
                        settings: settings,
                        sourceBytes: sourceBytes,
                        onChanged: onChanged,
                      ),
                    )
                    : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _CustomImageControls extends StatelessWidget {
  const _CustomImageControls({
    required this.settings,
    required this.sourceBytes,
    required this.onChanged,
  });

  final ImageSettings settings;
  final int? sourceBytes;
  final ValueChanged<ImageSettings>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final sourceBytes = this.sourceBytes;
    final enabled = onChanged != null;
    void update(ImageSettings next) => onChanged?.call(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OptionTile(
          title: 'Format',
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<ImageFormat>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ImageFormat.jpeg, label: Text('JPEG')),
                ButtonSegment(value: ImageFormat.png, label: Text('PNG')),
              ],
              selected: {settings.format},
              onSelectionChanged:
                  enabled
                      ? (selection) =>
                          update(settings.copyWith(format: selection.single))
                      : null,
            ),
          ),
        ),
        if (sourceBytes != null) ...[
          const SizedBox(height: 16),
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
        ],
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
