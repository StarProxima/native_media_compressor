#ifndef NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_
#define NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_

#include <windows.h>

#include <propidl.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "media_common.h"

namespace native_media_compressor {

enum class ImageOutputFormat { kJpeg, kPng, kWebp, kHeic };

struct ImageJob {
  std::wstring source;
  std::wstring destination;
  SizeBounds bounds;
  ImageOutputFormat format = ImageOutputFormat::kJpeg;
  int quality = 85;
  // Copies the source's EXIF and other metadata into JPEG output, with the
  // orientation made normal. Other output formats are written without it.
  bool keep_metadata = false;
};

struct ImageInfo {
  int64_t width = 0;
  int64_t height = 0;
  int64_t frame_count = 1;
  std::optional<std::string> mime_type;
};

// Decodes the first frame with WIC, applies EXIF orientation, scales down and
// writes the job's format. WebP and HEIC are unsupported unless an encoder
// for them is installed. Blocks; call it from a worker thread.
// The destination is replaced only when the status is compressed and is
// otherwise left as it was; it may be the source itself.
Outcome CompressImageFile(const ImageJob& job);

// Reads the size, orientation and frame count from the headers. Null when no
// installed WIC decoder can read the file.
std::optional<ImageInfo> ProbeImageFile(const std::wstring& source);

// Scales opaque, upright BGRA pixels down to fit `job.bounds` and writes them
// to `output` in the job's format, without metadata; the job's source and
// destination are not used. COM must be initialized on the calling thread.
Outcome WriteFrameImage(const std::vector<uint8_t>& bgra, uint32_t width, uint32_t height,
                        const ImageJob& job, const std::wstring& output);

// An EXIF or XMP orientation (1 to 8) read as a number or a decimal string;
// null for anything else.
std::optional<UINT> OrientationValue(const PROPVARIANT& value);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_IMAGE_CODEC_H_
