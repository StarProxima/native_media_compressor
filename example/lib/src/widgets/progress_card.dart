import 'package:flutter/material.dart';

import '../format.dart';
import 'section_card.dart';

/// A running compression: percent, time left and a way to stop it.
class ProgressCard extends StatelessWidget {
  const ProgressCard({
    super.key,
    required this.progress,
    required this.startedAt,
    this.onCancel,
  });

  /// Fraction done; null when the operation reports no progress.
  final double? progress;
  final DateTime startedAt;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = this.progress;
    final onCancel = this.onCancel;
    final eta = _timeLeft(progress);

    return SectionCard(
      title: 'Compressing',
      icon: Icons.hourglass_top_outlined,
      trailing:
          onCancel == null
              ? null
              : TextButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.close),
                label: const Text('Cancel'),
              ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                progress == null ? 'Working…' : '${(progress * 100).round()}%',
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (eta != null)
                Text(
                  eta,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: progress, minHeight: 10),
          ),
        ],
      ),
    );
  }

  /// Time left at the average rate so far; null until a few percent are done,
  /// when the rate still swings too much to be useful.
  String? _timeLeft(double? progress) {
    if (progress == null || progress < 0.03 || progress >= 1) return null;
    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed < const Duration(milliseconds: 700)) return null;
    final left = elapsed * ((1 - progress) / progress);

    return left < const Duration(seconds: 1)
        ? 'Almost done'
        : 'About ${Formats.elapsed(left)} left';
  }
}
