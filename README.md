<p align="center">
  <img src="https://raw.githubusercontent.com/StarProxima/native_media_compressor/main/.github/assets/banner.png" alt="native_media_compressor: compress images and video with the codecs the platform already ships" width="100%">
</p>

<p align="center">
  <a href="https://pub.dev/packages/native_media_compressor"><img src="https://img.shields.io/pub/v/native_media_compressor.svg" alt="pub version"></a>
  <a href="https://github.com/StarProxima/native_media_compressor/actions/workflows/ci.yml"><img src="https://github.com/StarProxima/native_media_compressor/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
</p>

Compress images and videos in Flutter with the codecs the platform already ships. No ffmpeg, no bundled encoders: the package adds only its own code to your app, and the encoding runs on the system's codecs, hardware-accelerated where the device has them.

- **Presets instead of knobs:** pick `light`, `balanced` or `strong`, and the bitrate follows the frame size and stays below the source's, so the output never grows past the original.
- **Video** to H.264 or HEVC in MP4: scale down, cap the frame rate, trim, rotate, aim at a target size, stop early at a size limit, report progress, cancel. AAC audio is copied, any other audio is re-encoded to AAC.
- **Thumbnails:** save any frame of a video as JPEG or PNG.
- **Images** to JPEG or PNG: scale down, apply EXIF orientation, strip metadata. HEIC, WebP and animated inputs are read where the platform can decode them.
- **Probe** size, rotation, duration, codecs, HDR and frame count from the headers, without decoding, to decide whether compression is worth it.
- **Results instead of exceptions.** Every call ends with a status, and a failed call never touches the destination file. An output that saves too little can be dropped in favour of the original.

## Why the platform's codecs

Every phone and computer already has an H.264 encoder and image codecs: the camera, the gallery and the browser use them, and on most devices the video encoder runs in hardware. Packages built on ffmpeg bring a second copy of all that into your app, which costs several to tens of megabytes depending on the build and the number of CPU architectures, and their software encoders are slower and use more battery than the system's hardware ones.

This package calls the system codecs directly, so your app grows only by the package's own code:

| Platform | Added to a release app |
|---|---|
| Android, arm64 APK | about 160 KB |
| iOS, app bundle | about 520 KB |
| macOS, app bundle | about 1 MB, one universal binary for Intel and Apple silicon |
| Web, `main.dart.js` | about 75 KB, 23 KB gzipped |

Measured with Flutter 3.47.8 as the difference between an empty app and the same app calling every method of the package. Windows and Linux are not measured yet.

The trade-off: the output is H.264 or HEVC, JPEG or PNG, and which inputs decode depends on the device and the system version, see [Supported formats](#supported-formats).

## Platform support

| Platform | Video | Images | Probe |
|---|---|---|---|
| Android 5.0+ | MediaCodec | ImageDecoder, BitmapFactory | MediaExtractor, image headers |
| iOS 13+, macOS 10.15+ | AVFoundation | ImageIO | AVFoundation, ImageIO |
| Windows 10+ | Media Foundation | WIC | Media Foundation, WIC |
| Linux | GStreamer | gdk-pixbuf | GStreamer, image headers |
| Web: Chrome and Edge 94+, Safari 16.4+, Firefox 130+ | WebCodecs | `createImageBitmap`, `OffscreenCanvas` | MP4 and image headers |

What each platform needs and where it says `unsupported` is listed under [Platform notes](#platform-notes).

## Supported formats

Video becomes H.264, or HEVC where the platform has an encoder and you ask for it, in MP4 with AAC audio; images become JPEG or PNG. What can be read depends on the decoders the system has. The tables below are what CI checks on every platform with one sample file per container, codec and image format: an Android 15 emulator, the current iOS simulator and macOS, Windows Server 2025 without Store extensions, Ubuntu with the GStreamer packages from [Platform notes](#platform-notes), and Chrome. A format the platform cannot read returns `unsupported`, never `failed`.

### Video input

| Platform | Containers | Video codecs | Audio |
|---|---|---|---|
| Android | MP4, MOV, M4V, 3GP, MKV, WebM | H.264, HEVC, VP8, VP9, AV1, as far as the device has decoders; AV1 is on most Android 10+ devices | AAC copied, other codecs re-encoded to AAC |
| iOS, macOS | MP4, MOV, M4V, 3GP; not MKV or WebM | H.264, HEVC; AV1 only with a hardware decoder (A17 Pro, M3 and newer); not VP8 or VP9 | AAC copied, other codecs re-encoded to AAC |
| Windows | MP4, MOV, M4V, 3GP, MKV | H.264 built in; HEVC, VP8, VP9 and AV1 with the matching Microsoft Store extensions | Re-encoded to AAC, one audio track |
| Linux | Whatever the installed GStreamer plugins open; with the packages from Platform notes MP4, MOV, M4V, 3GP, MKV, WebM | Whatever the installed decoders handle; with those packages H.264, HEVC, VP8, VP9, AV1 | AAC copied, other codecs re-encoded to AAC |
| Web | MP4, MOV, M4V, 3GP, not fragmented; not MKV or WebM | Whatever the browser's WebCodecs decodes: H.264 everywhere; VP9 and AV1 in current Chrome, Edge and Firefox; HEVC where the device decodes it in hardware | AAC copied; other codecs re-encoded where the browser has an AAC encoder |

Audio that has to be re-encoded becomes AAC at `VideoOptions.audioBitrate`. Only where the platform has no AAC encoder, as in some browsers, is such a file `unsupported`; `includeAudio: false` then drops the audio instead.

### Video output

| Platform | H.264 | HEVC with `VideoCodec.hevc` |
|---|---|---|
| Android | always | where the device has an HEVC encoder, almost every phone since 2016 |
| iOS, macOS | always | where the device has an HEVC encoder (A10, 6th-generation Intel and newer) |
| Windows | always | with the HEVC Video Extensions from the Microsoft Store |
| Linux | `x264enc`, `openh264enc` or `vah264enc` | with `x265enc` or `vah265enc` |
| Web | always | where WebCodecs encodes HEVC, mostly Safari and Chrome with hardware support |

Where HEVC is not available the output is H.264; `CompressionResult.videoCodec` says which one was written.

### Image input

| Platform | Formats |
|---|---|
| Android | JPEG, PNG, WebP, GIF, BMP; HEIC and HEIF on Android 9+; AVIF on Android 12+; not TIFF |
| iOS, macOS | JPEG, PNG, HEIC, GIF, TIFF, BMP; WebP on iOS 14+ and macOS 11+; AVIF on iOS 16+ and macOS 13+ |
| Windows | JPEG, PNG, GIF, BMP, TIFF built in; WebP, HEIC and AVIF with the matching Microsoft Store extensions |
| Linux | JPEG, PNG, GIF, BMP, TIFF through gdk-pixbuf; WebP, HEIC and AVIF with the matching gdk-pixbuf loaders, such as `webp-pixbuf-loader` and `heif-gdk-pixbuf` |
| Web | JPEG, PNG, GIF, WebP, BMP, AVIF; HEIC in Safari only; not TIFF |

Animated GIF, WebP and PNG keep their first frame.

## Installation

```sh
flutter pub add native_media_compressor
```

The package asks for no permissions and needs no manifest changes: it reads and writes only the paths you pass, so your app needs access to them. On Linux, install the GStreamer development headers before building, see [Platform notes](#platform-notes).

## Usage

### Compress a video

```dart
import 'package:native_media_compressor/native_media_compressor.dart';

final task = NativeMediaCompressor.compressVideo(
  source: '/path/to/input.mov',
  destination: '/path/to/output.mp4',
  options: VideoOptions.balanced,
);

task.progress.listen((fraction) => print('${(fraction * 100).round()}%'));

final result = await task.result;
if (result.isCompressed) {
  print('${result.width}x${result.height}, ${result.sizeBytes} bytes');
} else {
  print('kept the original: ${result.status} ${result.message ?? ''}');
}
```

`task.cancel()` stops the work; `result` then completes with `CompressionStatus.cancelled`. Videos are compressed one at a time, so a second call waits for the first.

### Compress an image

```dart
final result = await NativeMediaCompressor.compressImage(
  source: '/path/to/photo.heic',
  destination: '/path/to/photo.jpg',
  options: ImageOptions.strong,
);
```

Images and probes run in parallel. An image already in memory, such as a camera frame or a download, goes through `compressImageBytes` and comes back as bytes, with no files of your own to manage:

```dart
final result = await NativeMediaCompressor.compressImageBytes(bytes);
final jpeg = result.bytes;
```

### Pick a preset

| Preset | Video | Images |
|---|---|---|
| `light` | up to 1080p, 60 fps, 0.1 bits per pixel | long side up to 2560, JPEG 90 |
| `balanced`, the default | up to 720p, 30 fps, 0.07 bits per pixel | long side up to 2048, JPEG 85 |
| `strong` | up to 480p, 30 fps, 0.05 bits per pixel | long side up to 1280, JPEG 75 |

The video bitrate is the frame size times the frame rate times the bits per pixel, so a 720p output gets about 1.9 Mbit/s and a 480p one about 0.6 Mbit/s. It never goes above 85% of the source's own video bitrate: re-encoding at the source bitrate would lose quality without saving space. Any field can be changed on top of a preset:

```dart
final options = VideoOptions.strong.copyWith(maxBytes: 25 * 1024 * 1024);
```

### Hit a target size

Ask for a size, and the video bitrate is derived from the duration, leaving room for the copied audio:

```dart
NativeMediaCompressor.compressVideo(
  source: source,
  destination: destination,
  options: const VideoOptions(targetBytes: 10 * 1024 * 1024),
);
```

Encoders do not always keep to the requested bitrate, so when the output misses the target by more than 8% the video is encoded once more at a corrected bitrate, and the closer of the two results is kept. Add `maxBytes` when the size is a hard limit, such as an upload cap. For images, `ImageOptions.targetBytes` lowers JPEG quality and then the image size until the output fits, in at most eight encodes.

### Keep the original when compression does not pay off

```dart
const options = VideoOptions(minSavingsPercent: 20);
```

An output that is not at least 20% smaller than the source is dropped and the call returns `CompressionStatus.skipped`; `destination` stays as it was. `0` drops only outputs that are not smaller at all.

### Trim, rotate and pick the codec

```dart
const options = VideoOptions(
  trimStart: Duration(seconds: 5),
  trimEnd: Duration(seconds: 35),
  rotateQuarterTurns: 1, // a quarter turn clockwise
  codec: VideoCodec.hevc, // about a third smaller; falls back to H.264
);
```

The bitrate, the estimate and a target size all take the trimmed length into account. HEVC gets about 70% of the H.264 bitrate for the same quality.

### Save a frame

```dart
final thumbnail = await NativeMediaCompressor.videoThumbnail(
  source: '/path/to/input.mov',
  destination: '/path/to/frame.jpg',
  position: const Duration(seconds: 3),
  options: const ImageOptions(maxLongSide: 512),
);
```

The frame keeps the displayed orientation; a position past the end gives the last frame.

### Estimate before compressing

`estimateVideo` tells the output size, frame and bitrate from the headers alone, for a "this will be about 12 MB" hint before the user commits:

```dart
final estimate = await NativeMediaCompressor.estimateVideo(
  source,
  options: VideoOptions.strong,
);
print('about ${estimate?.sizeBytes} bytes at ${estimate?.width}x${estimate?.height}');
```

### Probe before compressing

Probing reads the headers only, so it is cheap enough to run for every picked file:

```dart
final video = await NativeMediaCompressor.probeVideo('/path/to/input.mov');
if (video != null && video.width * video.height > 1280 * 720) {
  // Worth compressing.
}

final image = await NativeMediaCompressor.probeImage('/path/to/photo.heic');
print('${image?.width}x${image?.height}, animated: ${image?.isAnimated}');
```

Both return `null` when the platform cannot read the file.

### Compress in place

`destination` may equal `source`. The output goes to a temporary file next to it and replaces the original only when compression succeeds:

```dart
await NativeMediaCompressor.compressImage(source: path, destination: path);
```

## Options

### `VideoOptions`

| Option | Default | Meaning |
|---|---|---|
| `maxShortSide` | `720` | Upper bound for the shorter side, in pixels. |
| `maxLongSide` | `null` | Upper bound for the longer side, in pixels. |
| `targetBytes` | `null` | Desired output size; the video bitrate is derived from it. |
| `videoBitrate` | `null` | Video bitrate, in bits per second. |
| `qualityPercent` | `null` | Video bitrate as a percentage of the source's. |
| `bitsPerPixel` | `0.07` | Bitrate per pixel per frame when none of the three above is set. |
| `maxFrameRate` | `30` | Frames above this rate are dropped. Capped at 240. |
| `maxBytes` | `null` | Stop with `tooLarge` as soon as the output exceeds this size. |
| `minSavingsPercent` | `null` | Drop an output that is not this much smaller than the source, with `skipped`. |
| `includeAudio` | `true` | Keep the audio tracks. |
| `audioBitrate` | `128000` | Bitrate for audio re-encoded to AAC; AAC audio is copied as is. |
| `codec` | `VideoCodec.h264` | `h264`, or `hevc` with a fallback to H.264. |
| `trimStart`, `trimEnd` | `null` | Keep only this part of the video. |
| `rotateQuarterTurns` | `0` | Clockwise quarter turns on top of the displayed orientation. |

The frame is scaled down to fit both bounds, keeping its aspect ratio, and never scaled up. The bitrate comes from the first of `targetBytes`, `videoBitrate` and `qualityPercent` that is set, then from `bitsPerPixel`, and stays below 85% of the source video bitrate.

### `ImageOptions`

| Option | Default | Meaning |
|---|---|---|
| `maxShortSide` | `null` | Upper bound for the shorter side, in pixels. |
| `maxLongSide` | `2048` | Upper bound for the longer side, in pixels. |
| `format` | `ImageFormat.jpeg` | `jpeg` or `png`. |
| `quality` | `85` | JPEG quality from 0 to 100; ignored for PNG. |
| `targetBytes` | `null` | Desired output size; quality, then size, go down until it fits. |
| `minSavingsPercent` | `null` | Drop an output that is not this much smaller than the source, with `skipped`. |

## Results instead of exceptions

Compression never throws on bad input or a missing codec. Check `CompressionResult.status`:

| Status | Meaning |
|---|---|
| `compressed` | The output is at `destination`. |
| `unsupported` | The platform cannot do it: no decoder for the input, no AAC encoder for audio that needs one, a container it cannot read. Use the original file. |
| `tooLarge` | The output passed `VideoOptions.maxBytes`; compression stopped early. |
| `cancelled` | `CompressionTask.cancel()` was called. |
| `interrupted` | The system stopped the work, for example in the background. Retrying usually works. |
| `failed` | The input is unreadable or a codec failed; `message` has details. |
| `skipped` | The output did not save `minSavingsPercent`; keep the original. |

Every status except `compressed` leaves `destination` as it was.

## What the output looks like

- **Video:** SDR H.264 or HEVC in MP4, scaled down to fit `maxShortSide` and `maxLongSide`. The displayed orientation is kept, plus `rotateQuarterTurns`. AAC audio is copied without re-encoding, other audio is re-encoded to AAC; on Windows all audio is re-encoded to AAC. Frames above `maxFrameRate` are dropped.
- **HDR video** (HLG, PQ, Dolby Vision, as phone cameras record by default) is tone-mapped to SDR on Android 7+ when the device decodes the source profile, on iOS 14+, macOS 11+ and in the browser. On Windows and Linux it is `unsupported` for now.
- **Images:** JPEG or PNG, scaled down to fit both bounds, with EXIF orientation applied to the pixels and no metadata copied. Animated images keep the first frame. JPEG output of an image with transparency is flattened onto white.

## Platform notes

**Android.** `source` may be a `content://` URI. HEIC decoding needs Android 9 or newer.

**iOS and macOS.** Works with both Swift Package Manager and CocoaPods. HDR conversion needs iOS 14 or macOS 11.

**Windows.** Video needs Media Foundation, which Windows N editions only have with the Media Feature Pack; without it video calls return `unsupported` and the app still starts. HEVC video, HEIC and WebP need the matching codec extensions from the Microsoft Store; without them those inputs are `unsupported`.

**Linux.** GStreamer is loaded at runtime, so the app starts and images work without it. Video needs:

- the development headers at build time: `libgstreamer1.0-dev` and `libgstreamer-plugins-base1.0-dev` on Debian and Ubuntu. Without them the plugin still builds, and video calls return `unsupported`;
- at run time, a decoder for the input, an H.264 encoder (`x264enc`, `openh264enc` or `vah264enc`), for HEVC `x265enc` or `vah265enc`, and for re-encoded audio an AAC encoder (`avenc_aac`, `voaacenc` or `fdkaacenc`), for example from `gstreamer1.0-plugins-good`, `-bad`, `-ugly` and `gstreamer1.0-libav`.

HEIC and WebP images need the matching gdk-pixbuf loaders, such as `heif-gdk-pixbuf` and `webp-pixbuf-loader`.

**Web.** `source` is a `blob:`, `data:` or same-origin (or CORS-enabled) `http(s):` URL. `destination` is ignored: `result.path` is a new object URL of the output, which you release with `URL.revokeObjectURL` when done. Video input must be MP4 or QuickTime (fragmented MP4 is `unsupported`), and which input codecs decode depends on the browser; without WebCodecs video calls return `unsupported`. HEIC images are `unsupported` outside Safari.

**Background isolates.** Compression works from any isolate, but `CompressionTask.progress` only reports in the root isolate.

## Example

The [example app](example/lib/main.dart) picks a file, probes it and compresses it with progress and cancel. Its [integration tests](example/integration_test/plugin_integration_test.dart) run on real media on every platform in CI.

## License

MIT, see [LICENSE](LICENSE).
