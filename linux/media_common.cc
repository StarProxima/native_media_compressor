#include "media_common.h"

#include <glib.h>
#include <glib/gstdio.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <utility>
#include <vector>

namespace native_media_compressor {

namespace {

std::vector<uint8_t> ReadHead(const std::string& path, size_t limit) {
  std::vector<uint8_t> data;
  FILE* file = g_fopen(path.c_str(), "rb");
  if (file == nullptr) return data;
  data.resize(limit);
  data.resize(fread(data.data(), 1, limit, file));
  fclose(file);
  return data;
}

class ByteReader {
 public:
  ByteReader(const uint8_t* data, size_t size, bool little_endian)
      : data_(data), size_(size), little_endian_(little_endian) {}

  bool Has(size_t offset, size_t length) const {
    return offset <= size_ && length <= size_ - offset;
  }

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

 private:
  const uint8_t* data_;
  size_t size_;
  bool little_endian_;
};

int TiffOrientation(const uint8_t* tiff, size_t size) {
  if (size < 8) return 0;
  bool little_endian;
  if (tiff[0] == 'I' && tiff[1] == 'I') {
    little_endian = true;
  } else if (tiff[0] == 'M' && tiff[1] == 'M') {
    little_endian = false;
  } else {
    return 0;
  }
  const ByteReader reader(tiff, size, little_endian);
  if (reader.U16(2) != 42) return 0;
  const size_t ifd = reader.U32(4);
  if (!reader.Has(ifd, 2)) return 0;
  const uint32_t count = reader.U16(ifd);
  for (uint32_t i = 0; i < count; i++) {
    const size_t entry = ifd + 2 + size_t{i} * 12;
    if (!reader.Has(entry, 12)) break;
    if (reader.U16(entry) != 0x0112) continue;
    const uint32_t type = reader.U16(entry + 2);
    const uint32_t value = type == 4 ? reader.U32(entry + 8) : reader.U16(entry + 8);
    return value >= 1 && value <= 8 ? static_cast<int>(value) : 0;
  }
  return 0;
}

bool HasBrand(const uint8_t* brand, std::initializer_list<const char*> brands) {
  for (const char* candidate : brands) {
    if (memcmp(brand, candidate, 4) == 0) return true;
  }
  return false;
}

}  // namespace

Outcome Outcome::Of(NmcCompressionStatus status, std::string message) {
  Outcome outcome;
  outcome.status = status;
  outcome.message = std::move(message);
  return outcome;
}

double FitScale(int64_t width, int64_t height, const SizeBounds& bounds) {
  if (width <= 0 || height <= 0) return 1.0;
  const double short_side = static_cast<double>(std::min(width, height));
  const double long_side = static_cast<double>(std::max(width, height));
  double scale = 1.0;
  if (bounds.max_short_side && *bounds.max_short_side > 0) {
    scale = std::min(scale, static_cast<double>(*bounds.max_short_side) / short_side);
  }
  if (bounds.max_long_side && *bounds.max_long_side > 0) {
    scale = std::min(scale, static_cast<double>(*bounds.max_long_side) / long_side);
  }
  return scale;
}

int64_t ScaledSide(int64_t side, double scale) {
  return std::max<int64_t>(1, std::llround(static_cast<double>(side) * scale));
}

int64_t ScaledEvenSide(int64_t side, double scale) {
  // The epsilon keeps 1206 * (720 / 1206.0) at 720 instead of 719.
  const auto floored = static_cast<int64_t>(std::floor(static_cast<double>(side) * scale + 1e-6));
  return std::max<int64_t>(2, floored & ~int64_t{1});
}

PendingOutput::PendingOutput(std::string destination) : destination_(std::move(destination)) {
  g_autofree gchar* directory = g_path_get_dirname(destination_.c_str());
  g_autofree gchar* name = g_path_get_basename(destination_.c_str());
  g_autofree gchar* temp = g_strdup_printf("%s/.nmc-%08x%08x-%s", directory, g_random_int(),
                                           g_random_int(), name);
  path_ = temp;
}

PendingOutput::~PendingOutput() { RemoveFile(path_); }

bool PendingOutput::destination_is_directory() const {
  return g_file_test(destination_.c_str(), G_FILE_TEST_IS_DIR);
}

Outcome PendingOutput::Finish(Outcome outcome) {
  if (outcome.status != NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) {
    RemoveFile(path_);
    return outcome;
  }
  if (destination_is_directory() || g_rename(path_.c_str(), destination_.c_str()) != 0) {
    const std::string reason = g_strerror(errno);
    RemoveFile(path_);
    return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED,
                       "Could not move the output to the destination: " + reason);
  }
  outcome.size_bytes = FileSize(destination_);
  return outcome;
}

int64_t FileSize(const std::string& path) {
  GStatBuf info;
  if (g_stat(path.c_str(), &info) != 0) return -1;
  return static_cast<int64_t>(info.st_size);
}

void RemoveFile(const std::string& path) { g_unlink(path.c_str()); }

int ReadJpegOrientation(const std::string& path) {
  const std::vector<uint8_t> data = ReadHead(path, 256 * 1024);
  const size_t size = data.size();
  if (size < 4 || data[0] != 0xFF || data[1] != 0xD8) return 1;
  size_t pos = 2;
  while (pos + 4 <= size) {
    if (data[pos] != 0xFF) return 1;
    const uint8_t marker = data[pos + 1];
    if (marker == 0xFF) {
      pos++;
      continue;
    }
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      pos += 2;
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) return 1;
    const size_t length = (data[pos + 2] << 8) | data[pos + 3];
    if (length < 2) return 1;
    const size_t segment = pos + 4;
    const size_t available = std::min(length - 2, size - segment);
    if (marker == 0xE1 && available >= 14 && memcmp(&data[segment], "Exif\0\0", 6) == 0) {
      const int orientation = TiffOrientation(&data[segment + 6], available - 6);
      if (orientation != 0) return orientation;
    }
    pos += 2 + length;
  }
  return 1;
}

int64_t CountGifFrames(const std::string& path) {
  gchar* contents = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(path.c_str(), &contents, &length, nullptr)) return -1;
  const auto* data = reinterpret_cast<const uint8_t*>(contents);
  int64_t frames = -1;
  if (length >= 13 && memcmp(data, "GIF8", 4) == 0) {
    frames = 0;
    size_t pos = 13;
    if (data[10] & 0x80) pos += 3u << ((data[10] & 7) + 1);
    const auto skip_sub_blocks = [&] {
      while (pos < length) {
        const uint8_t block = data[pos++];
        if (block == 0) break;
        pos += block;
      }
    };
    while (pos < length) {
      const uint8_t introducer = data[pos++];
      if (introducer == 0x21) {
        pos++;
        skip_sub_blocks();
      } else if (introducer == 0x2C) {
        if (pos + 9 > length) break;
        const uint8_t flags = data[pos + 8];
        pos += 9;
        if (flags & 0x80) pos += 3u << ((flags & 7) + 1);
        pos++;
        skip_sub_blocks();
        frames++;
      } else {
        break;
      }
    }
    if (frames == 0) frames = -1;
  }
  g_free(contents);
  return frames;
}

int64_t CountWebpFrames(const std::string& path) {
  FILE* file = g_fopen(path.c_str(), "rb");
  if (file == nullptr) return -1;
  uint8_t header[12];
  int64_t result = -1;
  if (fread(header, 1, sizeof header, file) == sizeof header && memcmp(header, "RIFF", 4) == 0 &&
      memcmp(header + 8, "WEBP", 4) == 0) {
    bool animated = false;
    int64_t frames = 0;
    uint8_t chunk[8];
    while (fread(chunk, 1, sizeof chunk, file) == sizeof chunk) {
      const ByteReader reader(chunk, sizeof chunk, true);
      const uint32_t size = reader.U32(4);
      off_t skip = static_cast<off_t>(size) + (size & 1);
      if (memcmp(chunk, "VP8X", 4) == 0 && size >= 1) {
        uint8_t flags = 0;
        if (fread(&flags, 1, 1, file) != 1) break;
        animated = (flags & 0x02) != 0;
        skip -= 1;
      } else if (memcmp(chunk, "ANMF", 4) == 0) {
        frames++;
      }
      if (fseeko(file, skip, SEEK_CUR) != 0) break;
    }
    result = animated && frames > 0 ? frames : 1;
  }
  fclose(file);
  return result;
}

int64_t CountPngFrames(const std::string& path) {
  FILE* file = g_fopen(path.c_str(), "rb");
  if (file == nullptr) return -1;
  uint8_t signature[8];
  int64_t result = -1;
  if (fread(signature, 1, sizeof signature, file) == sizeof signature &&
      memcmp(signature, "\x89PNG\r\n\x1a\n", 8) == 0) {
    result = 1;
    uint8_t chunk[8];
    // acTL must come before the first IDAT; a later one is not an APNG.
    while (fread(chunk, 1, sizeof chunk, file) == sizeof chunk) {
      const uint32_t length = ByteReader(chunk, sizeof chunk, false).U32(0);
      if (memcmp(chunk + 4, "IDAT", 4) == 0) break;
      if (memcmp(chunk + 4, "acTL", 4) == 0 && length >= 8) {
        uint8_t frames[4];
        if (fread(frames, 1, sizeof frames, file) == sizeof frames) {
          const uint32_t count = ByteReader(frames, sizeof frames, false).U32(0);
          if (count > 0) result = count;
        }
        break;
      }
      // Chunk data plus its CRC.
      if (fseeko(file, static_cast<off_t>(length) + 4, SEEK_CUR) != 0) break;
    }
  }
  fclose(file);
  return result;
}

std::string SniffImageMime(const std::string& path) {
  const std::vector<uint8_t> data = ReadHead(path, 64);
  const size_t size = data.size();
  const uint8_t* d = data.data();
  if (size >= 3 && d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return "image/jpeg";
  if (size >= 8 && memcmp(d, "\x89PNG\r\n\x1a\n", 8) == 0) return "image/png";
  if (size >= 6 && memcmp(d, "GIF8", 4) == 0) return "image/gif";
  if (size >= 12 && memcmp(d, "RIFF", 4) == 0 && memcmp(d + 8, "WEBP", 4) == 0) return "image/webp";
  if (size >= 2 && d[0] == 'B' && d[1] == 'M') return "image/bmp";
  if (size >= 4 && (memcmp(d, "II*\0", 4) == 0 || memcmp(d, "MM\0*", 4) == 0)) return "image/tiff";
  if (size >= 16 && memcmp(d + 4, "ftyp", 4) == 0) {
    const ByteReader reader(d, size, false);
    const size_t box_end = std::min<size_t>(reader.U32(0), size);
    // The major brand is at 8, compatible brands from 16 on.
    for (size_t brand = 8; brand + 4 <= box_end; brand += brand == 8 ? 8 : 4) {
      if (HasBrand(d + brand, {"heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs"})) {
        return "image/heic";
      }
      if (HasBrand(d + brand, {"avif", "avis"})) return "image/avif";
    }
    for (size_t brand = 8; brand + 4 <= box_end; brand += brand == 8 ? 8 : 4) {
      if (HasBrand(d + brand, {"mif1", "msf1", "heif"})) return "image/heif";
    }
  }
  return {};
}

}  // namespace native_media_compressor
