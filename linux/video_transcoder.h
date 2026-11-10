#ifndef NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_
#define NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

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
  bool hevc = false;
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
  std::string video_codec;
  bool is_hdr = false;
  bool has_audio = false;
  std::string audio_codec;
  std::optional<double> frame_rate;
  int64_t audio_track_count = 0;
  std::optional<int64_t> size_bytes;
};

struct ThumbnailJob {
  std::string source;
  std::string destination;
  int64_t position_ms = 0;
  SizeBounds bounds;
  NmcImageFormat format = NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_JPEG;
  int64_t quality = 85;
};

// Displayed size, rotation, duration and codecs. Null when the file is
// unreadable, has no video track, or GStreamer is not installed.
std::optional<VideoInfo> ProbeVideoFile(const std::string& path);

// Re-encodes to H.264 or HEVC in MP4. Blocks until done; `on_progress` is
// called on the calling thread with throttled, increasing values below 1,
// then 1.0 right before a compressed outcome.
Outcome TranscodeVideo(const VideoJob& job, const std::atomic<bool>& cancelled,
                       const std::function<void(double)>& on_progress);

// Writes the displayed frame at `position_ms` as an image. Blocks.
Outcome VideoThumbnail(const ThumbnailJob& job);

// MIME spellings shared by all platforms for GStreamer caps names.
std::string NormalizeVideoCodec(const std::string& caps_name);
std::string NormalizeAudioCodec(const std::string& caps_name, int mpeg_version);

struct VideoEncoderChoice {
  const char* encoder;
  const char* parser;
  // Without the parser the branch is not usable; otherwise it is optional.
  bool parser_required;
  // Forced on the parser output, or null.
  const char* output_caps;
  const char* mime;
};

// Encoders to try, in order. HEVC falls back to the H.264 encoders.
std::vector<VideoEncoderChoice> VideoEncoderCandidates(bool hevc);

// GStreamer AAC encoders to try, in order.
std::vector<const char*> AacEncoderCandidates();

// Values of GstVideoOrientationMethod, so the math is testable without
// GStreamer headers.
enum VideoOrientation {
  kOrientationIdentity = 0,
  kOrientation90R = 1,
  kOrientation180 = 2,
  kOrientation90L = 3,
  kOrientationHoriz = 4,
  kOrientationVert = 5,
  kOrientationUlLr = 6,
  kOrientationUrLl = 7,
};

// The videoflip method that applies `method` and then `quarter_turns`
// clockwise quarter turns.
int CombineVideoOrientation(int method, int64_t quarter_turns);

// The part of the source timeline a job keeps, in milliseconds.
struct KeptRange {
  int64_t start_ms = 0;
  // Absent only when neither an end nor the source duration is known.
  std::optional<int64_t> end_ms;
  // False when the range is the whole source, so nothing has to be cut.
  bool partial = false;
};

// Null when the requested range keeps nothing. An end past the source
// duration keeps to the end.
std::optional<KeptRange> ResolveKeptRange(std::optional<int64_t> start_ms,
                                          std::optional<int64_t> end_ms, int64_t duration_ms);

enum class TrimStep { kDrop, kKeep, kEnd };

// What happens to a sample at `time_ns` of the source timeline when keeping
// [start_ns, end_ns); a negative `end_ns` keeps to the end and a negative
// `time_ns` is a sample outside the decoded segment.
TrimStep TrimSample(int64_t time_ns, int64_t start_ns, int64_t end_ns);

enum class FramePick { kTake, kTakeAndStop, kStop };

// Keeps the last frame at or before `position_ns`; the first frame when the
// position is before it. `time_ns` is negative when unknown.
FramePick PickThumbnailFrame(int64_t time_ns, int64_t position_ns, bool have_frame);

// Seek target for a thumbnail, or -1 to decode from the start. Positions past
// the end land just before it, so the last frame is decoded.
int64_t ThumbnailSeekMs(int64_t position_ms, int64_t duration_ms);

// Bytes per row of a packed RGB frame of `size` bytes, or 0 when the buffer
// is too small for the frame.
int RgbRowStride(int width, int height, size_t size);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_VIDEO_TRANSCODER_H_
