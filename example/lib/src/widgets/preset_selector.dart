import 'package:flutter/material.dart';

import '../media/settings.dart';

/// Light, Balanced, Strong or Custom, with a line on what the choice does.
class PresetSelector extends StatelessWidget {
  const PresetSelector({
    super.key,
    required this.value,
    required this.descriptions,
    required this.onChanged,
  });

  final Preset value;
  final Map<Preset, String> descriptions;
  final ValueChanged<Preset>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onChanged = this.onChanged;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<Preset>(
          showSelectedIcon: false,
          segments: [
            for (final (preset, label) in const [
              (Preset.light, 'Light'),
              (Preset.balanced, 'Balanced'),
              (Preset.strong, 'Strong'),
              (Preset.custom, 'Custom'),
            ])
              ButtonSegment(
                value: preset,
                label: Text(label, maxLines: 1, softWrap: false),
              ),
          ],
          selected: {value},
          onSelectionChanged:
              onChanged == null
                  ? null
                  : (selection) => onChanged(selection.single),
        ),
        const SizedBox(height: 10),
        Text(
          descriptions[value] ?? '',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
