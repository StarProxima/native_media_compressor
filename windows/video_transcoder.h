#ifndef NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_
#define NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

#include "image_codec.h"
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
  bool prefer_hevc = false;
  std::optional<int64_t> start_ms;
  std::optional<int64_t> end_ms;
  int64_t rotate_quarter_turns = 0;
  int64_t audio_bitrate = 128000;
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
  std::optional<double> frame_rate;
  int64_t audio_track_count = 0;
  std::optional<int64_t> size_bytes;
};

struct ThumbnailJob {
  std::wstring source;
  std::wstring destination;
  int64_t position_ms = 0;
  SizeBounds bounds;
  ImageOutputFormat format = ImageOutputFormat::kJpeg;
  int quality = 85;
};

// Part of the source timeline to keep, in 100 ns ticks.
struct TrimRange {
  static constexpr int64_t kOpenEnd = INT64_MAX;
  int64_t start = 0;
  int64_t end = kOpenEnd;
};

// Frames of a PCM buffer to drop from its start and then to keep.
struct PcmCrop {
  uint64_t skip_frames = 0;
  uint64_t keep_frames = 0;
};

// Re-encodes a video to H.264 or HEVC with AAC audio in MP4 through Media
// Foundation. Blocks until done; call it from a worker thread. Reports
// progress from that thread. The destination is replaced only when the status
// is compressed and is otherwise left as it was; it may be the source itself.
Outcome TranscodeVideo(const VideoJob& job, const std::atomic<bool>& cancelled,
                       const std::function<void(double)>& on_progress);

// Reads the container and track headers without decoding. Null when the file
// has no video track, cannot be read, or Media Foundation is missing.
std::optional<VideoInfo> ProbeVideoFile(const std::wstring& source);

// Decodes one frame, turns it upright and writes it in the job's format.
// Blocks; call it from a worker thread. The destination is replaced only when
// the status is compressed.
Outcome SaveVideoFrame(const ThumbnailJob& job);

// The kept range for the requested milliseconds, or null when it keeps
// nothing. `duration` is in ticks and is 0 when unknown; an end at or past it
// keeps to the end of the source.
std::optional<TrimRange> ResolveTrim(std::optional<int64_t> start_ms,
                                     std::optional<int64_t> end_ms, int64_t duration);

// Which of `frames` PCM frames starting at `time` (ticks) fall inside `range`.
PcmCrop CropPcm(int64_t time, uint64_t frames, uint32_t sample_rate, const TrimRange& range);

// Clockwise degrees (0, 90, 180 or 270) after adding quarter turns to the
// source rotation.
uint32_t TotalRotation(uint32_t source_degrees, int64_t quarter_turns);

// The Media Foundation AAC encoder takes only a few byte rates; this picks the
// one closest to `bitrate` bits per second.
uint32_t AacBytesPerSecond(int64_t bitrate);

// Time in ticks to show for a thumbnail at `position_ms`. A position past the
// end becomes the start of the last frame, so that a frame is still decoded.
int64_t ThumbnailTime(int64_t position_ms, int64_t duration, int64_t frame_duration);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_
