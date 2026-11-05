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
  std::wstring source;
  std::wstring destination;
  SizeBounds bounds;
  int64_t video_bitrate = 0;
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
  std::optional<std::string> video_codec;
  bool is_hdr = false;
  bool has_audio = false;
  std::optional<std::string> audio_codec;
};

// Re-encodes a video to H.264 with AAC audio in MP4 through Media Foundation.
// Blocks until done; call it from a worker thread. Reports progress from that
// thread. The destination is replaced only when the status is compressed and
// is otherwise left as it was; it may be the source itself.
Outcome TranscodeVideo(const VideoJob& job, const std::atomic<bool>& cancelled,
                       const std::function<void(double)>& on_progress);

// Reads the container and track headers without decoding. Null when the file
// has no video track, cannot be read, or Media Foundation is missing.
std::optional<VideoInfo> ProbeVideoFile(const std::wstring& source);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_
