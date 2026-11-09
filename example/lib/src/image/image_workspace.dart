import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:native_media_compressor/native_media_compressor.dart';

import '../format.dart';
import '../media/media_files.dart';
import '../media/picked_media.dart';
import '../media/settings.dart';
import '../widgets/compress_button.dart';
import '../widgets/fact.dart';
import '../widgets/progress_card.dart';
import '../widgets/result_card.dart';
import '../widgets/source_card.dart';
import '../widgets/workspace_layout.dart';
import 'image_settings_card.dart';

class ImageWorkspace extends StatefulWidget {
  const ImageWorkspace({super.key});

  @override
  State<ImageWorkspace> createState() => _ImageWorkspaceState();
}

class _ImageWorkspaceState extends State<ImageWorkspace> {
  PickedMedia? _source;
  ImageMetadata? _metadata;
  Uint8List? _sourceBytes;
  var _isProbing = false;
  var _settings = const ImageSettings();

  /// Bumped on every new source, so late answers about an old one are
  /// dropped.
  var _sourceRun = 0;

  var _isCompressing = false;
  DateTime? _startedAt;
  CompressionOutcome? _outcome;
  Uint8List? _resultBytes;

  Future<void> _open(Future<PickedMedia?> Function() pick) async {
    final source = await _pickOrReport(pick);
    if (source == null || !mounted) return;

    final run = ++_sourceRun;
    setState(() {
      _source = source;
      _metadata = null;
      _sourceBytes = null;
      _isProbing = true;
      _outcome = null;
      _resultBytes = null;
      _settings = ImageSettings.forSource(
        source.sizeBytes,
      ).copyWith(preset: _settings.preset, format: _settings.format);
    });
    final metadata = await NativeMediaCompressor.probeImage(source.location);
    final bytes = await _read(source.location);
    if (!mounted || run != _sourceRun) return;
    setState(() {
      _metadata = metadata;
      _sourceBytes = bytes;
      _isProbing = false;
    });
  }

  Future<void> _compress() async {
    final source = _source;
    if (source == null || _isCompressing) return;
    final settings = _settings;
    final options = settings.toOptions();
    final fileName = '${source.baseName}-compressed.${settings.extension}';
    final stopwatch = Stopwatch()..start();
    setState(() {
      _isCompressing = true;
      _startedAt = DateTime.now();
      _outcome = null;
      _resultBytes = null;
    });

    final result = await NativeMediaCompressor.compressImage(
      source: source.location,
      destination: await MediaFiles.output(
        '${DateTime.now().millisecondsSinceEpoch}-$fileName',
      ),
      options: options,
    );
    stopwatch.stop();
    final path = result.path;
    final bytes =
        result.isCompressed && path != null ? await _read(path) : null;
    if (!mounted) return;
    setState(() {
      _isCompressing = false;
      _outcome = CompressionOutcome(
        result: result,
        sourceBytes: source.sizeBytes,
        elapsed: stopwatch.elapsed,
        fileName: fileName,
        minSavingsPercent: options.minSavingsPercent,
      );
      _resultBytes = bytes;
    });
  }

  static Future<Uint8List?> _read(String location) async {
    try {
      return await MediaFiles.read(location);
    } on Object {
      return null;
    }
  }

  Future<PickedMedia?> _pickOrReport(
    Future<PickedMedia?> Function() pick,
  ) async {
    try {
      return await pick();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the file: $error')),
        );
      }

      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final metadata = _metadata;
    final outcome = _outcome;
    final startedAt = _startedAt;

    return WorkspaceLayout(
      inputs: [
        SourceCard(
          kind: MediaKind.image,
          source: source,
          facts: metadata == null ? const [] : _facts(metadata),
          isLoading: _isProbing,
          isBusy: _isCompressing,
          onPick: () => _open(() => PickedMedia.pick(MediaKind.image)),
          onSample: () => _open(() => PickedMedia.sample(MediaKind.image)),
          note:
              source != null && metadata == null && !_isProbing
                  ? 'Could not read this image\'s header. The platform may '
                      'not decode this format.'
                  : null,
        ),
        ImageSettingsCard(
          settings: _settings,
          sourceBytes: source?.sizeBytes,
          onChanged:
              _isCompressing
                  ? null
                  : (settings) => setState(() => _settings = settings),
        ),
        CompressButton(
          label: 'Compress image',
          onPressed:
              source == null || _isCompressing || _isProbing ? null : _compress,
        ),
      ],
      results:
          _isCompressing && startedAt != null
              ? ProgressCard(progress: null, startedAt: startedAt)
              : outcome == null
              ? null
              : ResultCard(
                outcome: outcome,
                sourcePreview: _sourceBytes,
                resultPreview: _resultBytes,
                previewCaption: 'Tap a picture to zoom in.',
              ),
      placeholder: const ResultsPlaceholder(
        text:
            'Pick an image or try the sample, choose a preset and press '
            'Compress. The size comparison and both pictures side by side '
            'appear here.',
      ),
    );
  }

  static List<Fact> _facts(ImageMetadata metadata) => [
    Fact(
      label: 'Resolution',
      value: Formats.resolution(metadata.width, metadata.height),
    ),
    Fact(label: 'Format', value: Formats.codec(metadata.mimeType)),
    Fact(
      label: 'Frames',
      value:
          metadata.isAnimated ? '${metadata.frameCount}, animated' : '1, still',
    ),
    Fact(
      label: 'Megapixels',
      value: (metadata.width * metadata.height / 1e6).toStringAsFixed(1),
    ),
  ];
}
