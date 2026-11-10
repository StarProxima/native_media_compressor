## 1.0.0

* **Breaking:** `CompressionResult.videoCodec` is a `VideoCodec` instead of a
  MIME string, so a fallback is `result.videoCodec == VideoCodec.h264`.
  `VideoMetadata.videoCodec` stays a MIME type, as a probe can meet any codec.
* **Breaking:** `VideoOptions.qualityPercent` is now `sourceBitratePercent`:
  it is a share of the source bitrate, not an encoder quality.
* A cancel between the two passes of `targetBytes`, or during the second one,
  ends with `cancelled` instead of keeping the first pass as a finished
  compression.
* `CompressionResult.toString` leaves out what is not set.
* Android: HEVC is written only from Android 7, where the MP4 muxer takes it;
  earlier versions fall back to H.264 instead of failing on the first frame.
* Android: the foreground notification falls back to a system icon, not the
  app icon, which Android 8.0 cannot show as a small icon; `iconResource` is
  also looked up among mipmaps.
* Android: a codec that is busy or reclaimed answers `interrupted`, not
  `unsupported`, so the app knows to retry.
* iOS and macOS: box sizes and chunk offsets of a malformed MP4 can no longer
  overflow while audio is read from the container, and video settings the
  writer rejects answer `unsupported` instead of raising.
* Linux: the build takes the GStreamer headers only from 1.20 on, which the
  code needs; older headers now give the no-video build instead of a compile
  error. Replies and progress are always queued on the main loop.
* Documentation: `targetBytes` needs a readable duration, `minSavingsPercent`
  needs the source size (an Android `content://` source is always kept),
  which `ImageOptions` fields `videoThumbnail` uses, the Android service in
  the merged manifest and how to remove it, the macOS sandbox and output
  folders.

## 0.2.0

* Presets: `VideoOptions.light`, `balanced` and `strong`, and the same for
  `ImageOptions`.
* The video bitrate now follows the output frame size (`bitsPerPixel`) and
  never goes above 85% of the source video bitrate. **Breaking:** the
  default used to be a fixed 2.5 Mbit/s; set `videoBitrate` to keep it.
* `VideoOptions.targetBytes` and `qualityPercent`, and
  `ImageOptions.targetBytes`.
* `minSavingsPercent` drops an output that saves too little and returns the
  new `CompressionStatus.skipped`, leaving the destination as it was.
* `NativeMediaCompressor.estimateVideo` predicts the output size without
  encoding.
* `NativeMediaCompressor.compressImageBytes` compresses an image held in
  memory.
* `VideoOptions.codec`: HEVC output where the platform has an encoder, with
  a fallback to H.264; `CompressionResult.videoCodec` names the codec
  written.
* `VideoOptions.trimStart` and `trimEnd` keep part of a video, and
  `rotateQuarterTurns` rotates it.
* Audio that is not AAC is re-encoded to AAC at `VideoOptions.audioBitrate`
  instead of making the call `unsupported`.
* `NativeMediaCompressor.videoThumbnail` saves a frame as JPEG or PNG.
* `VideoMetadata.frameRate`; the automatic bitrate uses the source frame
  rate.
* A target size that the encoder misses by more than 8% gets a second pass.
* `ImageFormat.webp` and `ImageFormat.heic` where the platform has an
  encoder, for images and thumbnails.
* `ImageOptions.keepMetadata` copies EXIF, location included, with the
  orientation reset because it is already in the pixels.
* `NativeMediaCompressor.androidForegroundNotification` runs videos in an
  Android foreground service; iOS asks the system for background time while
  a video runs.
* Encoders keep to the requested bitrate more closely: CBR fallback on
  Android, peak-constrained VBR on Windows, Baseline H.264 in the iOS
  simulator.

## 0.1.0

* First release: compress video to H.264 in MP4 and images to JPEG or PNG with
  the platform's own codecs on Android, iOS, macOS, Windows, Linux and the web.
* Probe image and video parameters from the headers without decoding.
* Every call returns a status instead of throwing, and the destination changes
  only on success.
