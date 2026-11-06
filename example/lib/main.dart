import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:native_media_compressor/native_media_compressor.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'native_media_compressor',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const CompressorPage(),
    );
  }
}

const _videos = XTypeGroup(
  label: 'Videos',
  extensions: ['mp4', 'mov', 'm4v'],
  mimeTypes: ['video/*'],
  uniformTypeIdentifiers: ['public.movie'],
);

const _images = XTypeGroup(
  label: 'Images',
  extensions: ['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif'],
  mimeTypes: ['image/*'],
  uniformTypeIdentifiers: ['public.image'],
);

class CompressorPage extends StatefulWidget {
  const CompressorPage({super.key});

  @override
  State<CompressorPage> createState() => _CompressorPageState();
}

class _CompressorPageState extends State<CompressorPage> {
  CompressionTask? _task;
  double? _progress;
  final _log = <String>[];

  bool get _busy => _progress != null;

  Future<void> _pick({required bool video}) async {
    final file = await openFile(
      acceptedTypeGroups: [video ? _videos : _images],
    );
    if (file == null) return;

    final originalBytes = await file.length();
    setState(() {
      _log
        ..clear()
        ..add('${file.name}: ${_formatBytes(originalBytes)}');
      _progress = video ? 0 : -1;
    });

    // The web ignores the destination and returns an object URL instead.
    final destination =
        kIsWeb
            ? ''
            : '${(await getTemporaryDirectory()).path}/compressed.${video ? 'mp4' : 'jpg'}';

    final CompressionResult result;
    if (video) {
      final metadata = await NativeMediaCompressor.probeVideo(file.path);
      if (metadata != null) {
        _show(
          '${metadata.width}x${metadata.height}, ${metadata.duration.inSeconds} s, '
          '${metadata.videoCodec}${metadata.isHdr ? ', HDR' : ''}',
        );
      }
      final task = NativeMediaCompressor.compressVideo(
        source: file.path,
        destination: destination,
      );
      _task = task;
      task.progress.listen((value) => setState(() => _progress = value));
      result = await task.result;
    } else {
      final metadata = await NativeMediaCompressor.probeImage(file.path);
      if (metadata != null) {
        _show(
          '${metadata.width}x${metadata.height}, ${metadata.mimeType}'
          '${metadata.isAnimated ? ', ${metadata.frameCount} frames' : ''}',
        );
      }
      result = await NativeMediaCompressor.compressImage(
        source: file.path,
        destination: destination,
      );
    }

    _task = null;
    _progress = null;
    _show(switch (result.status) {
      CompressionStatus.compressed =>
        'Compressed to ${result.width}x${result.height}, '
            '${_formatBytes(result.sizeBytes ?? 0)}',
      _ =>
        '${result.status.name}${result.message == null ? '' : ': ${result.message}'}',
    });
  }

  void _show(String line) {
    if (mounted) setState(() => _log.add(line));
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    return Scaffold(
      appBar: AppBar(title: const Text('native_media_compressor')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => _pick(video: true),
                icon: const Icon(Icons.movie_outlined),
                label: const Text('Compress a video'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _pick(video: false),
                icon: const Icon(Icons.image_outlined),
                label: const Text('Compress an image'),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 24),
            LinearProgressIndicator(value: progress < 0 ? null : progress),
            if (_task != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _task?.cancel(),
                  child: const Text('Cancel'),
                ),
              ),
          ],
          const SizedBox(height: 24),
          for (final line in _log)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(line),
            ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) => switch (bytes) {
  < 1024 => '$bytes B',
  < 1024 * 1024 => '${(bytes / 1024).toStringAsFixed(0)} KB',
  _ => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB',
};
