# native_media_compressor

Compress images and videos in Flutter with the codecs the platform already ships. No ffmpeg, no bundled encoders: the package adds only its own code to your app.

| Platform | Video | Images | Probe |
|---|---|---|---|
| Android 5.0+ | MediaCodec, H.264 | ImageDecoder / BitmapFactory | MediaExtractor, image headers |
| iOS 13+, macOS 10.15+ | AVFoundation, H.264 | ImageIO | AVFoundation, ImageIO |
| Windows 10+ | Media Foundation, H.264 | WIC | Media Foundation, WIC |

Linux and web support are in progress.

## Usage

```dart
import 'package:native_media_compressor/native_media_compressor.dart';

final task = NativeMediaCompressor.compressVideo(
  source: '/path/to/input.mov',
  destination: '/path/to/output.mp4',
  options: const VideoOptions(maxShortSide: 720, videoBitrate: 2500000),
);
task.progress.listen((fraction) => print('${(fraction * 100).round()}%'));
final result = await task.result;

if (result.isCompressed) {
  print('${result.width}x${result.height}, ${result.sizeBytes} bytes');
}
```

```dart
final result = await NativeMediaCompressor.compressImage(
  source: '/path/to/photo.heic',
  destination: '/path/to/photo.jpg',
  options: const ImageOptions(maxLongSide: 2048, quality: 85),
);
```

Read the size and codecs without decoding, for example to decide whether compression is worth it:

```dart
final video = await NativeMediaCompressor.probeVideo('/path/to/input.mov');
final image = await NativeMediaCompressor.probeImage('/path/to/photo.heic');
```

## Results instead of exceptions

Compression never throws on bad input or a missing codec. Check `CompressionResult.status`:

| Status | Meaning |
|---|---|
| `compressed` | The output is at `destination`. |
| `unsupported` | The platform cannot do it: no codec, non-AAC audio while `includeAudio` is true, a format it cannot encode. Use the original file. |
| `tooLarge` | The output passed `VideoOptions.maxBytes`; compression stopped early. |
| `cancelled` | `CompressionTask.cancel()` was called. |
| `interrupted` | The system stopped the work, for example in the background. Retrying usually works. |
| `failed` | The input is unreadable or a codec failed; `message` has details. |

Every status except `compressed` leaves nothing at `destination`.

## What the output looks like

- Video: SDR H.264 in MP4. HDR input (HLG, PQ, Dolby Vision, as iPhone cameras record by default) is tone-mapped to SDR on Android and Apple platforms. The frame is scaled down to fit `maxShortSide` and `maxLongSide`, never up. AAC audio is copied without re-encoding; on Windows audio is re-encoded to AAC. Frames above `maxFrameRate` are dropped. The displayed orientation is kept.
- Images: JPEG or PNG, scaled down to fit both bounds, with EXIF orientation applied to the pixels and no metadata copied. Animated images keep the first frame. JPEG output of an image with transparency is flattened onto white.
- Videos are compressed one at a time; images and probes run in parallel.

## Platform notes

- **iOS and macOS:** works with both Swift Package Manager and CocoaPods. HDR conversion needs iOS 14 or macOS 11.
- **Android:** `source` may be a `content://` URI. HEIC decoding needs Android 9 or newer.
- **Windows:** HDR video is `unsupported` for now. Video needs Media Foundation, which Windows N editions only have with the Media Feature Pack; without it video calls return `unsupported` and the app still starts. HEIC and WebP decoding need the matching codec extensions from the Microsoft Store.

## License

MIT
