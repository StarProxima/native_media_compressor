import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'media_files.dart';

/// What the user compresses: videos or images.
enum MediaKind {
  video(
    label: 'Video',
    sampleAsset: 'assets/samples/mandelbrot_1080p.mp4',
    types: XTypeGroup(
      label: 'Videos',
      extensions: ['mp4', 'mov', 'm4v', '3gp', 'mkv', 'webm'],
      mimeTypes: ['video/*'],
      uniformTypeIdentifiers: ['public.movie'],
    ),
  ),
  image(
    label: 'Image',
    sampleAsset: 'assets/samples/mandelbrot_photo.jpg',
    types: XTypeGroup(
      label: 'Images',
      extensions: ['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif'],
      mimeTypes: ['image/*'],
      uniformTypeIdentifiers: ['public.image'],
    ),
  );

  const MediaKind({
    required this.label,
    required this.sampleAsset,
    required this.types,
  });

  final String label;
  final String sampleAsset;
  final XTypeGroup types;
}

/// A file ready for the compressor: a path on native platforms, a `blob:`
/// URL on the web.
class PickedMedia {
  const PickedMedia({
    required this.name,
    required this.location,
    required this.sizeBytes,
  });

  final String name;
  final String location;
  final int sizeBytes;

  /// [name] without its extension, for naming outputs.
  String get baseName {
    final dot = name.lastIndexOf('.');

    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Asks the user for a file; null when they close the dialog.
  static Future<PickedMedia?> pick(MediaKind kind) async {
    final file = await openFile(acceptedTypeGroups: [kind.types]);
    if (file == null) return null;

    return PickedMedia(
      name: file.name,
      location: file.path,
      sizeBytes: await file.length(),
    );
  }

  /// The bundled sample for [kind], copied out of the asset bundle.
  static Future<PickedMedia> sample(MediaKind kind) async {
    final data = await rootBundle.load(kind.sampleAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final name = kind.sampleAsset.split('/').last;

    return PickedMedia(
      name: name,
      location: await MediaFiles.materialize(bytes, name),
      sizeBytes: bytes.length,
    );
  }
}
