import 'dart:async';
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
import 'video_settings_card.dart';

class VideoWorkspace extends StatefulWidget {
  const VideoWorkspace({super.key});

  @override
  State<VideoWorkspace> createState() => _VideoWorkspaceState();
}

class _VideoWorkspaceState extends State<VideoWorkspace> {
  PickedMedia? _source;
  VideoMetadata? _metadata;
  var _isProbing = false;
  var _settings = const VideoSettings();

  VideoEstimate? _estimate;
  var _isEstimating = false;
  Timer? _estimateDelay;
  var _estimateRun = 0;

  /// Bumped on every new source, so late answers about an old one are
  /// dropped.
  var _sourceRun = 0;
  Uint8List? _sourceFrame;

  CompressionTask? _task;
  var _isCompressing = false;
  double? _progress;
  DateTime? _startedAt;
  CompressionOutcome? _outcome;
  Uint8List? _resultFrame;

  @override
  void dispose() {
    _estimateDelay?.cancel();
    // ignore: unawaited_futures
    _task?.cancel();
    super.dispose();
  }

  Future<void> _open(Future<PickedMedia?> Function() pick) async {
    final source = await _pickOrReport(pick);
    if (source == null || !mounted) return;

    final run = ++_sourceRun;
    setState(() {
      _source = source;
      _metadata = null;
      _isProbing = true;
      _estimate = null;
      _outcome = null;
      _sourceFrame = null;
      _resultFrame = null;
    });
    final metadata = await NativeMediaCompressor.probeVideo(source.location);
    if (!mounted || run != _sourceRun) return;
    setState(() {
      _metadata = metadata;
      _isProbing = false;
      _settings = VideoSettings.forSource(
        sizeBytes: source.sizeBytes,
        duration: metadata?.duration ?? Duration.zero,
      ).copyWith(preset: _settings.preset);
    });
    _scheduleEstimate();

    final frame = await _frame(
      source.location,
      (metadata?.duration ?? Duration.zero) ~/ 2,
    );
    if (mounted && run == _sourceRun) setState(() => _sourceFrame = frame);
  }

  void _changeSettings(VideoSettings settings) {
    setState(() => _settings = settings);
    _scheduleEstimate();
  }

  /// Waits for sliders to settle before asking for a new estimate.
  void _scheduleEstimate() {
    final source = _source;
    if (source == null) return;
    _estimateDelay?.cancel();
    setState(() => _isEstimating = true);
    _estimateDelay = Timer(const Duration(milliseconds: 120), () async {
      final run = ++_estimateRun;
      final estimate = await NativeMediaCompressor.estimateVideo(
        source.location,
        options: _settings.toOptions(),
      );
      if (!mounted || run != _estimateRun || source != _source) return;
      setState(() {
        _estimate = estimate;
        _isEstimating = false;
      });
    });
  }

  Future<void> _compress() async {
    final source = _source;
    if (source == null || _isCompressing) return;
    final options = _settings.toOptions();
    final fileName = '${source.baseName}-compressed.mp4';
    final stopwatch = Stopwatch()..start();
    setState(() {
      _isCompressing = true;
      _progress = 0;
      _startedAt = DateTime.now();
      _outcome = null;
      _resultFrame = null;
    });

    final destination = await MediaFiles.output(
      '${DateTime.now().millisecondsSinceEpoch}-$fileName',
    );
    final task = NativeMediaCompressor.compressVideo(
      source: source.location,
      destination: destination,
      options: options,
    );
    _task = task;
    final progress = task.progress.listen((value) {
      if (mounted) setState(() => _progress = value);
    });
    final result = await task.result;
    stopwatch.stop();
    await progress.cancel();
    _task = null;

    final path = result.path;
    final kept = _keptDuration(options);
    final frame =
        result.isCompressed && path != null
            ? await _frame(path, kept ~/ 2)
            : null;
    if (!mounted) return;
    setState(() {
      _isCompressing = false;
      _progress = null;
      _outcome = CompressionOutcome(
        result: result,
        sourceBytes: source.sizeBytes,
        elapsed: stopwatch.elapsed,
        fileName: fileName,
        minSavingsPercent: options.minSavingsPercent,
        requestedCodec: options.codec,
      );
      _resultFrame = frame;
    });
  }

  Duration _keptDuration(VideoOptions options) {
    final duration = _metadata?.duration ?? Duration.zero;
    final end = options.trimEnd ?? duration;
    final start = options.trimStart ?? Duration.zero;

    return end > start ? end - start : Duration.zero;
  }

  /// A frame of the video at [location] as image bytes, or null where the
  /// platform cannot take thumbnails.
  Future<Uint8List?> _frame(String location, Duration position) async {
    final result = await NativeMediaCompressor.videoThumbnail(
      source: location,
      destination: await MediaFiles.output(
        'frame-${DateTime.now().microsecondsSinceEpoch}.jpg',
      ),
      position: position,
      options: const ImageOptions(maxLongSide: 800),
    );
    final path = result.path;
    if (!result.isCompressed || path == null) return null;
    try {
      return await MediaFiles.read(path);
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
          kind: MediaKind.video,
          source: source,
          facts: metadata == null ? const [] : _facts(metadata),
          isLoading: _isProbing,
          isBusy: _isCompressing,
          onPick: () => _open(() => PickedMedia.pick(MediaKind.video)),
          onSample: () => _open(() => PickedMedia.sample(MediaKind.video)),
          note:
              source != null && metadata == null && !_isProbing
                  ? 'Could not read this video\'s headers. It may still '
                      'compress where the platform can decode it.'
                  : null,
        ),
        VideoSettingsCard(
          settings: _settings,
          sourceBytes: source?.sizeBytes,
          estimate: _estimate,
          isEstimating: _isEstimating || _isProbing,
          onChanged: _isCompressing ? null : _changeSettings,
        ),
        CompressButton(
          label: 'Compress video',
          onPressed:
              source == null || _isCompressing || _isProbing ? null : _compress,
        ),
      ],
      results:
          _isCompressing && startedAt != null
              ? ProgressCard(
                progress: _progress,
                startedAt: startedAt,
                onCancel: () => _task?.cancel(),
              )
              : outcome == null
              ? null
              : ResultCard(
                outcome: outcome,
                sourcePreview: _sourceFrame,
                resultPreview: _resultFrame,
                previewCaption: 'Middle frame, taken with videoThumbnail.',
              ),
      placeholder: const ResultsPlaceholder(
        text:
            'Pick a video or try the sample, choose a preset and press '
            'Compress. The size comparison and the frames before and after '
            'appear here.',
      ),
    );
  }

  static List<Fact> _facts(VideoMetadata metadata) {
    final frameRate = metadata.frameRate;
    final bitrate = metadata.bitrate;

    return [
      Fact(
        label: 'Resolution',
        value: Formats.resolution(metadata.width, metadata.height),
      ),
      Fact(label: 'Duration', value: Formats.duration(metadata.duration)),
      if (frameRate != null)
        Fact(label: 'Frame rate', value: '${frameRate.round()} fps'),
      if (bitrate != null)
        Fact(label: 'Bitrate', value: Formats.bitrate(bitrate)),
      Fact(label: 'Video', value: Formats.codec(metadata.videoCodec)),
      Fact(
        label: 'Audio',
        value: metadata.hasAudio ? Formats.codec(metadata.audioCodec) : 'None',
      ),
      Fact(label: 'Dynamic range', value: metadata.isHdr ? 'HDR' : 'SDR'),
      if (metadata.rotationDegrees != 0)
        Fact(label: 'Rotation', value: '${metadata.rotationDegrees}°'),
    ];
  }
}
