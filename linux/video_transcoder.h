#ifndef NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_
#define NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

#include "media_common.h"

namespace native_media_compressor {

struct VideoJob {
  std::string source;
  std::string destination;
  SizeBounds bounds;
  int64_t video_bitrate = 2500000;
  std::optional<int64_t> max_frame_rate;
  std::optional<int64_t> max_bytes;
  bool include_audio = true;
};

struct VideoInfo {
  int64_t width = 0;
  int64_t height = 0;
  int64_t rotation_degrees = 0;
  int64_t duration_ms = 0;
  std::optional<int64_t> bitrate;
  std::string video_codec;
  bool is_hdr = false;
  bool has_audio = false;
  std::string audio_codec;
};

// Displayed size, rotation, duration and codecs. Null when the file is
// unreadable, has no video track, or GStreamer is not installed.
std::optional<VideoInfo> ProbeVideoFile(const std::string& path);

// Re-encodes to H.264 in MP4. Blocks until done; `on_progress` is called on
// the calling thread with throttled, increasing values below 1, then 1.0
// right before a compressed outcome.
Outcome TranscodeVideo(const VideoJob& job, const std::atomic<bool>& cancelled,
                       const std::function<void(double)>& on_progress);

// MIME spellings shared by all platforms for GStreamer caps names.
std::string NormalizeVideoCodec(const std::string& caps_name);
std::string NormalizeAudioCodec(const std::string& caps_name, int mpeg_version);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_
