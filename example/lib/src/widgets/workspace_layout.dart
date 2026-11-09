import 'package:flutter/material.dart';

import 'section_card.dart';

/// Inputs and results side by side on wide screens, stacked on narrow ones.
class WorkspaceLayout extends StatelessWidget {
  const WorkspaceLayout({
    super.key,
    required this.inputs,
    required this.results,
    required this.placeholder,
  });

  static const wideWidth = 880.0;

  final List<Widget> inputs;

  /// Progress or the result; null before the first run.
  final Widget? results;

  /// Fills the results column on wide screens until there is a result.
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final results = this.results;
        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, input) in inputs.indexed) ...[
              if (index > 0) const SizedBox(height: 16),
              input,
            ],
          ],
        );
        if (constraints.maxWidth < wideWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              column,
              if (results != null) ...[const SizedBox(height: 16), results],
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: column),
            const SizedBox(width: 24),
            Expanded(flex: 6, child: results ?? placeholder),
          ],
        );
      },
    );
  }
}

/// What the results column shows before anything was compressed.
class ResultsPlaceholder extends StatelessWidget {
  const ResultsPlaceholder({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SectionCard(
      color: scheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.compare_outlined,
                size: 32,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Before and after',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
