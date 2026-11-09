#ifndef NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_
#define NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "media_common.h"

namespace native_media_compressor {

struct ImageJob {
  std::wstring source;
  std::wstring destination;
  SizeBounds bounds;
  bool png = false;
  int quality = 85;
};

struct ImageInfo {
  int64_t width = 0;
  int64_t height = 0;
  int64_t frame_count = 1;
  std::optional<std::string> mime_type;
};

// Decodes the first frame with WIC, applies EXIF orientation, scales down and
// writes JPEG or PNG without metadata. Blocks; call it from a worker thread.
// The destination is replaced only when the status is compressed and is
// otherwise left as it was; it may be the source itself.
Outcome CompressImageFile(const ImageJob& job);

// Reads the size, orientation and frame count from the headers. Null when no
// installed WIC decoder can read the file.
std::optional<ImageInfo> ProbeImageFile(const std::wstring& source);

// Scales opaque, upright BGRA pixels down to fit `job.bounds` and writes them
// to `output` as JPEG or PNG; the job's source and destination are not used.
// COM must be initialized on the calling thread.
Outcome WriteFrameImage(const std::vector<uint8_t>& bgra, uint32_t width, uint32_t height,
                        const ImageJob& job, const std::wstring& output);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_
