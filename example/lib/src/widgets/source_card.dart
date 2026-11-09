import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../format.dart';
import '../media/picked_media.dart';
import 'fact.dart';
import 'section_card.dart';

/// Where the user picks a file or the sample, and what was read from it.
class SourceCard extends StatelessWidget {
  const SourceCard({
    super.key,
    required this.kind,
    required this.source,
    required this.facts,
    required this.isLoading,
    required this.isBusy,
    required this.onPick,
    required this.onSample,
    this.note,
  });

  final MediaKind kind;
  final PickedMedia? source;

  /// What the probe read; empty while probing or when it failed.
  final List<Fact> facts;
  final bool isLoading;
  final bool isBusy;
  final VoidCallback onPick;
  final VoidCallback onSample;

  /// A remark under the facts, such as a probe that failed.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final source = this.source;

    return SectionCard(
      title: 'Source',
      icon: Icons.upload_file_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (source == null)
            _EmptySource(kind: kind)
          else
            _SourceSummary(source: source, kind: kind),
          if (isLoading) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
          if (source != null && facts.isNotEmpty) ...[
            const SizedBox(height: 20),
            FactGrid(facts: facts),
          ],
          if (note case final note?) ...[
            const SizedBox(height: 16),
            Text(
              note,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.tonalIcon(
                onPressed: isBusy ? null : onPick,
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(source == null ? 'Pick a file' : 'Pick another'),
              ),
              OutlinedButton.icon(
                onPressed: isBusy ? null : onSample,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Try a sample'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptySource extends StatelessWidget {
  const _EmptySource({required this.kind});

  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final what = switch (kind) {
      MediaKind.video => 'an MP4 or MOV video',
      MediaKind.image => 'a JPEG, PNG, HEIC or WebP image',
    };
    final where =
        kIsWeb
            ? 'It is compressed right in your browser and never uploaded.'
            : 'It is compressed on this device.';

    return Text(
      'Pick $what, or try the bundled sample. $where',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _SourceSummary extends StatelessWidget {
  const _SourceSummary({required this.source, required this.kind});

  final PickedMedia source;
  final MediaKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            kind == MediaKind.video
                ? Icons.movie_outlined
                : Icons.image_outlined,
            color: scheme.onSecondaryContainer,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                source.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                Formats.bytes(source.sizeBytes),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
