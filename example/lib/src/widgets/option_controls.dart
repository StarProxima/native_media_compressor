import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';

/// A labelled row: a title with a value on the right, and a control below.
class OptionTile extends StatelessWidget {
  const OptionTile({
    super.key,
    required this.title,
    required this.child,
    this.value,
    this.leading,
  });

  final String title;
  final String? value;
  final Widget? leading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = this.value;
    final leading = this.leading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 8)],
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (value != null)
              Text(
                value,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
        child,
      ],
    );
  }
}

/// A switch for aiming at an output size, with a slider for the size.
class TargetSizeControl extends StatelessWidget {
  const TargetSizeControl({
    super.key,
    required this.enabled,
    required this.targetBytes,
    required this.sourceBytes,
    required this.onEnabledChanged,
    required this.onTargetChanged,
  });

  final bool enabled;
  final int targetBytes;
  final int sourceBytes;
  final ValueChanged<bool>? onEnabledChanged;
  final ValueChanged<int>? onTargetChanged;

  @override
  Widget build(BuildContext context) {
    final min = math.max(20 * 1024, sourceBytes * 0.03).toDouble();
    final max = math.max(min + 1024, sourceBytes * 0.95);
    final value = targetBytes.toDouble().clamp(min, max);
    final onTargetChanged = this.onTargetChanged;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SwitchRow(
          title: 'Aim for a file size',
          value: enabled,
          onChanged: onEnabledChanged,
          trailingText: enabled ? Formats.bytes(value.round()) : null,
        ),
        if (enabled)
          Slider(
            min: min,
            max: max,
            value: value,
            label: Formats.bytes(value.round()),
            onChanged:
                onTargetChanged == null
                    ? null
                    : (bytes) => onTargetChanged(bytes.round()),
          ),
      ],
    );
  }
}

/// A switch for dropping outputs that save too little, with the threshold.
class KeepOriginalControl extends StatelessWidget {
  const KeepOriginalControl({
    super.key,
    required this.enabled,
    required this.percent,
    required this.onEnabledChanged,
    required this.onPercentChanged,
  });

  final bool enabled;
  final int percent;
  final ValueChanged<bool>? onEnabledChanged;
  final ValueChanged<int>? onPercentChanged;

  @override
  Widget build(BuildContext context) {
    final onPercentChanged = this.onPercentChanged;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SwitchRow(
          title: 'Keep the original if it saves less than $percent%',
          value: enabled,
          onChanged: onEnabledChanged,
        ),
        if (enabled)
          Slider(
            min: 1,
            max: 90,
            divisions: 89,
            value: percent.toDouble(),
            label: '$percent%',
            onChanged:
                onPercentChanged == null
                    ? null
                    : (value) => onPercentChanged(value.round()),
          ),
      ],
    );
  }
}

/// A switch with a title, and an optional value beside the switch.
class SwitchOption extends StatelessWidget {
  const SwitchOption({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) =>
      _SwitchRow(title: title, value: value, onChanged: onChanged);
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.trailingText,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? trailingText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trailingText = this.trailingText;

    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (trailingText != null) ...[
          Text(
            trailingText,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
        ],
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
