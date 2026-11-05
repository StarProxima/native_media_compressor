#ifndef NATIVE_MEDIA_COMPRESSOR_MEDIA_COMMON_H_
#define NATIVE_MEDIA_COMPRESSOR_MEDIA_COMMON_H_

#include <cstdint>
#include <optional>
#include <string>

#include "messages.g.h"

namespace native_media_compressor {

struct Outcome {
  NmcCompressionStatus status = NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED;
  int64_t width = 0;
  int64_t height = 0;
  int64_t size_bytes = 0;
  std::string message;

  static Outcome Of(NmcCompressionStatus status, std::string message = {});
};

struct SizeBounds {
  std::optional<int64_t> max_short_side;
  std::optional<int64_t> max_long_side;
};

// Factor that fits a displayed width x height into the bounds. Never above 1;
// absent or non-positive bounds are ignored.
double FitScale(int64_t width, int64_t height, const SizeBounds& bounds);

// round(side * scale), at least 1.
int64_t ScaledSide(int64_t side, double scale);

// floor(side * scale) rounded down to an even number, at least 2: H.264 with
// 4:2:0 chroma needs even frame sizes.
int64_t ScaledEvenSide(int64_t side, double scale);

// A temporary output file next to the destination, with the same extension.
// It replaces the destination only through Finish with a compressed outcome;
// otherwise it is deleted and the destination is left as it was, which also
// keeps the source intact when the source is the destination.
class PendingOutput {
 public:
  explicit PendingOutput(std::string destination);
  ~PendingOutput();
  PendingOutput(const PendingOutput&) = delete;
  PendingOutput& operator=(const PendingOutput&) = delete;

  const std::string& path() const { return path_; }
  bool destination_is_directory() const;

  // For a compressed outcome, moves the file over the destination and fills
  // size_bytes; a failed move turns it into failed. Any other outcome deletes
  // the temporary file.
  Outcome Finish(Outcome outcome);

 private:
  std::string destination_;
  std::string path_;
};

// File size in bytes, or -1 when the file does not exist.
int64_t FileSize(const std::string& path);

void RemoveFile(const std::string& path);

// EXIF orientation (1-8) of a JPEG file, 1 when absent or not a JPEG.
int ReadJpegOrientation(const std::string& path);

// Number of frames in a GIF, or -1 when the file is not a readable GIF.
int64_t CountGifFrames(const std::string& path);

// Number of frames in a WebP, or -1 when the file is not a readable WebP.
int64_t CountWebpFrames(const std::string& path);

// Number of frames in a PNG (more than 1 for APNG), or -1 when the file is not
// a readable PNG.
int64_t CountPngFrames(const std::string& path);

// The default image of an APNG as a plain PNG, with the animation chunks
// removed. False when the file is not a PNG or has no animation chunks.
bool ReadApngDefaultImage(const std::string& path, std::string* png);

// Width and height from a PNG header; false when the file is not a PNG.
bool ReadPngSize(const std::string& path, int* width, int* height);

// Image MIME type from the file signature, or empty when unknown.
std::string SniffImageMime(const std::string& path);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_MEDIA_COMMON_H_
