import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_media_compressor/native_media_compressor.dart';

import '../format.dart';
import '../media/media_files.dart';
import '../media/settings.dart';
import 'fact.dart';
import 'preview_pair.dart';
import 'section_card.dart';
import 'size_comparison.dart';

/// How a compression ended: sizes, facts, previews and where the output is.
class ResultCard extends StatelessWidget {
  const ResultCard({
    super.key,
    required this.outcome,
    this.sourcePreview,
    this.resultPreview,
    this.previewCaption,
  });

  final CompressionOutcome outcome;
  final Uint8List? sourcePreview;
  final Uint8List? resultPreview;
  final String? previewCaption;

  @override
  Widget build(BuildContext context) {
    final result = outcome.result;
    final outputBytes = result.sizeBytes;
    final path = result.path;
    final width = result.width;
    final height = result.height;
    final codec = result.videoCodec;
    final fellBack =
        outcome.requestedCodec == VideoCodec.hevc && codec == 'video/avc';

    return SectionCard(
      title: result.isCompressed ? 'Result' : _title(result.status),
      icon:
          result.isCompressed ? Icons.check_circle_outline : Icons.info_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!result.isCompressed) ...[
            _StatusMessage(outcome: outcome),
            const SizedBox(height: 20),
          ],
          if (outputBytes != null) ...[
            SizeComparison(
              sourceBytes: outcome.sourceBytes,
              outputBytes: outputBytes,
              outputLabel: result.isCompressed ? 'Compressed' : 'Would be',
            ),
            const SizedBox(height: 24),
          ],
          FactGrid(
            facts: [
              if (width != null && height != null)
                Fact(
                  label: 'Resolution',
                  value: Formats.resolution(width, height),
                ),
              if (codec != null)
                Fact(label: 'Codec written', value: Formats.codec(codec)),
              Fact(
                label: 'Time taken',
                value: Formats.elapsed(outcome.elapsed),
              ),
              if (!result.isCompressed)
                Fact(label: 'Status', value: result.status.name),
            ],
          ),
          if (fellBack) ...[
            const SizedBox(height: 12),
            const _Note(
              'There is no HEVC encoder here, so the video was written '
              'as H.264.',
            ),
          ],
          if (sourcePreview != null || resultPreview != null) ...[
            const SizedBox(height: 24),
            PreviewPair(
              source: sourcePreview,
              result: resultPreview,
              caption: previewCaption,
            ),
          ],
          if (path != null) ...[
            const SizedBox(height: 24),
            if (MediaFiles.canDownload)
              _DownloadRow(path: path, fileName: outcome.fileName)
            else
              _OutputPath(path: path),
          ],
        ],
      ),
    );
  }

  static String _title(CompressionStatus status) => switch (status) {
    CompressionStatus.compressed => 'Result',
    CompressionStatus.skipped => 'Kept the original',
    CompressionStatus.unsupported => 'Not supported here',
    CompressionStatus.tooLarge => 'Stopped at the size limit',
    CompressionStatus.cancelled => 'Cancelled',
    CompressionStatus.interrupted => 'Interrupted',
    CompressionStatus.failed => 'Failed',
  };
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({required this.outcome});

  final CompressionOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = outcome.result;
    final isError =
        result.status == CompressionStatus.failed ||
        result.status == CompressionStatus.unsupported;
    final message = result.message;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _explanation(),
            style: theme.textTheme.bodyMedium?.copyWith(
              color:
                  isError
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
            ),
          ),
          if (message != null && message.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    isError
                        ? scheme.onErrorContainer
                        : scheme.onSecondaryContainer,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _explanation() {
    const untouched = 'Nothing was written and the source is untouched.';

    return switch (outcome.result.status) {
      CompressionStatus.compressed => '',
      CompressionStatus.skipped => _skipped(),
      CompressionStatus.unsupported =>
        'This platform has no codec or system library for this file or '
            'these options. $untouched Try another preset, another file or '
            'another platform.',
      CompressionStatus.tooLarge =>
        'The output grew past the size limit, so compression stopped early. '
            '$untouched',
      CompressionStatus.cancelled => 'You stopped the compression. $untouched',
      CompressionStatus.interrupted =>
        'The system stopped the work, for example when the app went to the '
            'background. $untouched Running it again usually succeeds.',
      CompressionStatus.failed =>
        'The file could not be read, or a codec failed midway. $untouched',
    };
  }

  String _skipped() {
    final output = outcome.result.sizeBytes;
    final threshold = outcome.minSavingsPercent;
    final saved =
        output == null || outcome.sourceBytes == 0
            ? null
            : ((outcome.sourceBytes - output) * 100 / outcome.sourceBytes)
                .round();
    final how =
        saved == null
            ? 'The result saved too little'
            : saved <= 0
            ? 'The result was not smaller than the source'
            : 'The result was only $saved% smaller';
    final limit = threshold == null ? '' : ', under your $threshold% threshold';

    return '$how$limit, so it was dropped: the original is the better file to '
        'keep.';
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.path, required this.fileName});

  final String path;
  final String fileName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: () => MediaFiles.download(path, fileName),
          icon: const Icon(Icons.download),
          label: const Text('Download'),
        ),
        Text(
          fileName,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _OutputPath extends StatelessWidget {
  const _OutputPath({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(path, style: theme.textTheme.bodySmall),
          ),
          IconButton(
            tooltip: 'Copy path',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: path));
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Path copied')));
            },
          ),
        ],
      ),
    );
  }
}
