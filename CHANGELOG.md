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
