import 'dart:typed_data';

import 'package:flutter/material.dart';

/// The source and the result side by side; either may be missing.
class PreviewPair extends StatelessWidget {
  const PreviewPair({
    super.key,
    required this.source,
    required this.result,
    this.caption,
  });

  final Uint8List? source;
  final Uint8List? result;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      if (source case final bytes?) _Preview(label: 'Original', bytes: bytes),
      if (result case final bytes?) _Preview(label: 'Compressed', bytes: bytes),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    final caption = this.caption;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 360) {
              return Column(
                children: [
                  for (final (index, tile) in tiles.indexed) ...[
                    if (index > 0) const SizedBox(height: 12),
                    tile,
                  ],
                ],
              );
            }

            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, tile) in tiles.indexed) ...[
                  if (index > 0) const SizedBox(width: 12),
                  Expanded(child: tile),
                ],
                if (tiles.length == 1) const Spacer(),
              ],
            );
          },
        ),
        if (caption != null) ...[
          const SizedBox(height: 8),
          Text(
            caption,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.label, required this.bytes});

  final String label;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap:
                  () => showDialog<void>(
                    context: context,
                    builder: (_) => _FullPreview(label: label, bytes: bytes),
                  ),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                cacheWidth: 1200,
                gaplessPlayback: true,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FullPreview extends StatelessWidget {
  const _FullPreview({required this.label, required this.bytes});

  final String label;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          InteractiveViewer(
            maxScale: 8,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filledTonal(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
          Positioned(left: 16, top: 16, child: Chip(label: Text(label))),
        ],
      ),
    );
  }
}
