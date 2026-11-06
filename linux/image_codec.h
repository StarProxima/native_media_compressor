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
};

struct ImageInfo {
  int64_t width = 0;
  int64_t height = 0;
  int64_t frame_count = 1;
  std::string mime_type;
};

// Reads the displayed size, frame count and MIME type from the file header.
std::optional<ImageInfo> ProbeImageFile(const std::string& path);

// Decodes downsampled, applies EXIF orientation and writes JPEG or PNG. Blocks;
// call off the platform thread.
Outcome CompressImageFile(const ImageJob& job);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_
