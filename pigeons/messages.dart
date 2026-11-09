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

enum ImageFormat { jpeg, png, webp, heic }

/// Codec of the output video track.
enum VideoCodec { h264, hevc }

class VideoRequest {
  VideoRequest({
    required this.source,
    required this.destination,
    required this.videoBitrate,
    required this.includeAudio,
    required this.codec,
    required this.rotateQuarterTurns,
    required this.audioBitrate,
  });

  String source;
  String destination;
  int? maxShortSide;
  int? maxLongSide;
  int videoBitrate;
  int? maxFrameRate;
  int? maxBytes;
  bool includeAudio;

  /// Preferred output codec; HEVC falls back to H.264 where the platform has
  /// no HEVC encoder. The reply names the codec actually written.
  VideoCodec codec;

  /// Start of the kept range in the source timeline; null keeps from the
  /// start.
  int? startMs;

  /// End of the kept range in the source timeline; null keeps to the end.
  int? endMs;

  /// Clockwise quarter turns on top of the displayed orientation, 0 to 3.
  int rotateQuarterTurns;

  /// Bitrate for audio that has to be re-encoded to AAC. AAC audio is copied
  /// as is.
  int audioBitrate;
}

class ThumbnailRequest {
  ThumbnailRequest({
    required this.source,
    required this.destination,
    required this.positionMs,
    required this.format,
    required this.quality,
  });

  String source;
  String destination;

  /// Frame position in the source timeline; past the end means the last
  /// frame.
  int positionMs;
  int? maxShortSide;
  int? maxLongSide;
  ImageFormat format;
  int quality;
}

class ImageRequest {
  ImageRequest({
    required this.source,
    required this.destination,
    required this.format,
    required this.quality,
    required this.keepMetadata,
  });

  String source;
  String destination;
  int? maxShortSide;
  int? maxLongSide;
  ImageFormat format;
  int quality;

  /// Copy EXIF and other metadata of the source, location included, except
  /// the orientation, which is applied to the pixels.
  bool keepMetadata;
}

/// The notification an Android foreground service shows while videos are
/// compressed in it.
class ForegroundNotification {
  ForegroundNotification({
    required this.title,
    required this.channelName,
  });

  String title;
  String? text;

  /// Name of a drawable resource of the app for the small icon; null uses
  /// the app icon.
  String? iconResource;
  String channelName;
}

class CompressionReply {
  CompressionReply({required this.status});

  CompressionStatus status;
  int? width;
  int? height;
  int? sizeBytes;
  String? message;

  /// Codec of the written video track, as a MIME type such as `video/avc`.
  String? videoCodec;
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

  /// Average frames per second of the video track, when the container
  /// reports it.
  double? frameRate;
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

  @async
  CompressionReply videoThumbnail(ThumbnailRequest request);

  /// Runs later video compressions in an Android foreground service showing
  /// [notification], or stops doing so when it is null. Other platforms
  /// ignore it.
  void setForegroundNotification(ForegroundNotification? notification);
}

@FlutterApi()
abstract class MediaCompressorFlutterApi {
  void onProgress(int taskId, double progress);
}
