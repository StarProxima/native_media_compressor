#ifndef NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_
#define NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_

#include <cstdint>
#include <optional>
#include <string>

#include "media_common.h"

namespace native_media_compressor {

struct ImageJob {
  std::string source;
  std::string destination;
  SizeBounds bounds;
  NmcImageFormat format = NATIVE_MEDIA_COMPRESSOR_IMAGE_FORMAT_JPEG;
  int64_t quality = 85;
  // Copies the EXIF of a JPEG source into a JPEG output; ignored otherwise.
  bool keep_metadata = false;
};

struct ImageInfo {
  int64_t width = 0;
  int64_t height = 0;
  int64_t frame_count = 1;
  std::string mime_type;
};

// Reads the displayed size, frame count and MIME type from the file header.
std::optional<ImageInfo> ProbeImageFile(const std::string& path);

// Decodes downsampled, applies EXIF orientation and writes the requested
// format. Blocks; call off the platform thread.
Outcome CompressImageFile(const ImageJob& job);

// Packed 8-bit RGB pixels, `stride` bytes per row.
struct RgbFrame {
  const uint8_t* pixels = nullptr;
  int width = 0;
  int height = 0;
  int stride = 0;
};

// Scales `frame` down to fit `bounds` and writes it to `output` in `format`,
// the way CompressImageFile writes a decoded image. Does not stage the
// output; the caller owns the temporary file.
Outcome WriteRgbFrame(const RgbFrame& frame, const SizeBounds& bounds, NmcImageFormat format,
                      int64_t quality, const std::string& output);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_
