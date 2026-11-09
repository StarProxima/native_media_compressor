#include "jpeg_exif.h"

#include <glib.h>
#include <glib/gstdio.h>

#include <cstdio>
#include <cstring>

namespace native_media_compressor {

namespace {

// APP segments come before the image data and are at most 64 KiB each, so
// the EXIF block sits well inside the first megabyte.
constexpr size_t kExifSearchLimit = 1024 * 1024;

// Marker, length and the "Exif\0\0" identifier precede the TIFF header.
constexpr size_t kTiffOffset = 10;

constexpr uint16_t kOrientationTag = 0x0112;
constexpr uint16_t kLongType = 4;

std::vector<uint8_t> ReadHead(const std::string& path, size_t limit) {
  std::vector<uint8_t> data;
  FILE* file = g_fopen(path.c_str(), "rb");
  if (file == nullptr) return data;
  data.resize(limit);
  data.resize(fread(data.data(), 1, limit, file));
  fclose(file);
  return data;
}

class TiffBytes {
 public:
  TiffBytes(uint8_t* data, bool little_endian) : data_(data), little_endian_(little_endian) {}

  uint32_t U16(size_t offset) const {
    const uint8_t* p = data_ + offset;
    return little_endian_ ? (p[0] | (p[1] << 8)) : ((p[0] << 8) | p[1]);
  }

  uint32_t U32(size_t offset) const {
    const uint8_t* p = data_ + offset;
    return little_endian_
               ? (uint32_t{p[0]} | uint32_t{p[1]} << 8 | uint32_t{p[2]} << 16 | uint32_t{p[3]} << 24)
               : (uint32_t{p[0]} << 24 | uint32_t{p[1]} << 16 | uint32_t{p[2]} << 8 | uint32_t{p[3]});
  }

  void Put(size_t offset, uint32_t value, size_t width) {
    for (size_t i = 0; i < width; i++) {
      const size_t shift = little_endian_ ? i : width - 1 - i;
      data_[offset + i] = static_cast<uint8_t>(value >> (8 * shift));
    }
  }

 private:
  uint8_t* data_;
  bool little_endian_;
};

}  // namespace

std::vector<uint8_t> FindJpegExifSegment(const uint8_t* data, size_t size) {
  if (data == nullptr || size < 4 || data[0] != 0xFF || data[1] != 0xD8) return {};
  size_t pos = 2;
  while (pos + 4 <= size) {
    if (data[pos] != 0xFF) return {};
    const uint8_t marker = data[pos + 1];
    if (marker == 0xFF) {
      pos++;
      continue;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      pos += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return {};
    const size_t length = (data[pos + 2] << 8) | data[pos + 3];
    if (length < 2 || length > size - pos - 2) return {};
    if (marker == 0xE1 && length >= 8 && memcmp(data + pos + 4, "Exif\0\0", 6) == 0) {
      return std::vector<uint8_t>(data + pos, data + pos + 2 + length);
    }
    pos += 2 + length;
  }
  return {};
}

bool ResetExifOrientation(std::vector<uint8_t>* segment) {
  if (segment->size() < kTiffOffset + 8 || memcmp(segment->data() + 4, "Exif\0\0", 6) != 0) {
    return false;
  }
  uint8_t* tiff = segment->data() + kTiffOffset;
  const size_t size = segment->size() - kTiffOffset;
  bool little_endian;
  if (tiff[0] == 'I' && tiff[1] == 'I') {
    little_endian = true;
  } else if (tiff[0] == 'M' && tiff[1] == 'M') {
    little_endian = false;
  } else {
    return false;
  }
  TiffBytes bytes(tiff, little_endian);
  if (bytes.U16(2) != 42) return false;
  const size_t ifd = bytes.U32(4);
  if (ifd > size || size - ifd < 2) return false;
  const size_t count = bytes.U16(ifd);
  if ((size - ifd - 2) / 12 < count) return false;
  for (size_t i = 0; i < count; i++) {
    const size_t entry = ifd + 2 + i * 12;
    if (bytes.U16(entry) != kOrientationTag) continue;
    // The value is stored in the entry itself, left-aligned in four bytes.
    const bool is_long = bytes.U16(entry + 2) == kLongType;
    bytes.Put(entry + 8, 1, is_long ? 4 : 2);
  }
  return true;
}

std::vector<uint8_t> InsertAfterSoi(const std::vector<uint8_t>& jpeg,
                                    const std::vector<uint8_t>& segment) {
  if (jpeg.size() < 2 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return {};
  std::vector<uint8_t> result;
  result.reserve(jpeg.size() + segment.size());
  result.insert(result.end(), jpeg.begin(), jpeg.begin() + 2);
  result.insert(result.end(), segment.begin(), segment.end());
  result.insert(result.end(), jpeg.begin() + 2, jpeg.end());
  return result;
}

bool CopyJpegExif(const std::string& source, const std::string& output, std::string* error) {
  const std::vector<uint8_t> head = ReadHead(source, kExifSearchLimit);
  std::vector<uint8_t> segment = FindJpegExifSegment(head.data(), head.size());
  // An orientation that cannot be reset would turn the already rotated pixels
  // again, so such metadata is dropped.
  if (segment.empty() || !ResetExifOrientation(&segment)) return true;

  gchar* contents = nullptr;
  gsize length = 0;
  GError* failure = nullptr;
  if (!g_file_get_contents(output.c_str(), &contents, &length, &failure)) {
    *error = failure != nullptr ? failure->message : "Could not read the output";
    g_clear_error(&failure);
    return false;
  }
  const std::vector<uint8_t> jpeg(contents, contents + length);
  g_free(contents);
  const std::vector<uint8_t> combined = InsertAfterSoi(jpeg, segment);
  if (combined.empty()) return true;
  if (!g_file_set_contents(output.c_str(), reinterpret_cast<const gchar*>(combined.data()),
                           static_cast<gssize>(combined.size()), &failure)) {
    *error = failure != nullptr ? failure->message : "Could not write the metadata";
    g_clear_error(&failure);
    return false;
  }
  return true;
}

}  // namespace native_media_compressor
