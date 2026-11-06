import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartPackageName: 'native_media_compressor',
    kotlinOut:
        'android/src/main/kotlin/io/github/starproxima/native_media_compressor/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'io.github.starproxima.native_media_compressor',
    ),
    swiftOut:
        'darwin/native_media_compressor/Sources/native_media_compressor/Messages.g.swift',
    cppHeaderOut: 'windows/messages.g.h',
    cppSourceOut: 'windows/messages.g.cpp',
    cppOptions: CppOptions(namespace: 'native_media_compressor'),
    gobjectHeaderOut: 'linux/messages.g.h',
    gobjectSourceOut: 'linux/messages.g.cc',
    gobjectOptions: GObjectOptions(module: 'Nmc'),
  ),
)
enum CompressionStatus {
  compressed,
  unsupported,
  tooLarge,
  cancelled,
  interrupted,
  failed,
}

enum ImageFormat { jpeg, png }

class VideoRequest {
  VideoRequest({
    required this.source,
    required this.destination,
    required this.videoBitrate,
    required this.includeAudio,
  });

  String source;
  String destination;
  int? maxShortSide;
  int? maxLongSide;
  int videoBitrate;
  int? maxFrameRate;
  int? maxBytes;
  bool includeAudio;
}

class ImageRequest {
  ImageRequest({
    required this.source,
    required this.destination,
    required this.format,
    required this.quality,
  });

  String source;
  String destination;
  int? maxShortSide;
  int? maxLongSide;
  ImageFormat format;
  int quality;
}

class CompressionReply {
  CompressionReply({required this.status});

  CompressionStatus status;
  int? width;
  int? height;
  int? sizeBytes;
  String? message;
}

class ImageProbe {
  ImageProbe({
    required this.width,
    required this.height,
    required this.frameCount,
  });

  int width;
  int height;
  int frameCount;
  String? mimeType;
}

class VideoProbe {
  VideoProbe({
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.durationMs,
    required this.hasAudio,
    required this.isHdr,
  });

  int width;
  int height;
  int rotationDegrees;
  int durationMs;
  int? bitrate;
  String? videoCodec;
  bool isHdr;
  bool hasAudio;
  String? audioCodec;
}

@HostApi()
abstract class MediaCompressorHostApi {
  @async
  CompressionReply compressVideo(int taskId, VideoRequest request);

  @async
  CompressionReply compressImage(ImageRequest request);

  void cancel(int taskId);

  @async
  ImageProbe? probeImage(String source);

  @async
  VideoProbe? probeVideo(String source);
}

@FlutterApi()
abstract class MediaCompressorFlutterApi {
  void onProgress(int taskId, double progress);
}
