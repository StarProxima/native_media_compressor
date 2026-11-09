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

## 0.1.0

* First release: compress video to H.264 in MP4 and images to JPEG or PNG with
  the platform's own codecs on Android, iOS, macOS, Windows, Linux and the web.
* Probe image and video parameters from the headers without decoding.
* Every call returns a status instead of throwing, and the destination changes
  only on success.
