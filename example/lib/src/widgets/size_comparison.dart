import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format.dart';

/// The source and output sizes as bars, with the change in percent.
class SizeComparison extends StatelessWidget {
  const SizeComparison({
    super.key,
    required this.sourceBytes,
    required this.outputBytes,
    this.outputLabel = 'Compressed',
  });

  final int sourceBytes;
  final int outputBytes;
  final String outputLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final larger = math.max(math.max(outputBytes, sourceBytes), 1);
    final saved = outputBytes < sourceBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text(
              '${Formats.bytes(sourceBytes)} → ${Formats.bytes(outputBytes)}',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: saved ? scheme.primaryContainer : scheme.errorContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(
                  Formats.change(sourceBytes, outputBytes),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color:
                        saved
                            ? scheme.onPrimaryContainer
                            : scheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _SizeBar(
          label: 'Original',
          bytes: sourceBytes,
          fraction: sourceBytes / larger,
          color: scheme.outline,
        ),
        const SizedBox(height: 10),
        _SizeBar(
          label: outputLabel,
          bytes: outputBytes,
          fraction: outputBytes / larger,
          color: saved ? scheme.primary : scheme.error,
        ),
      ],
    );
  }
}

class _SizeBar extends StatelessWidget {
  const _SizeBar({
    required this.label,
    required this.bytes,
    required this.fraction,
    required this.color,
  });

  final String label;
  final int bytes;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 14,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(7),
            ),
            alignment: Alignment.centerLeft,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction.clamp(0.01, 1)),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder:
                  (context, value, _) => FractionallySizedBox(
                    widthFactor: value,
                    child: Container(
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
            ),
          ),
        ),
        SizedBox(
          width: 84,
          child: Text(
            Formats.bytes(bytes),
            textAlign: TextAlign.right,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
