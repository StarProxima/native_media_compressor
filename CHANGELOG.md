## 0.1.0

* First release: compress video to H.264 in MP4 and images to JPEG or PNG with
  the platform's own codecs on Android, iOS, macOS, Windows, Linux and the web.
* Probe image and video parameters from the headers without decoding.
* Every call returns a status instead of throwing, and the destination changes
  only on success.
