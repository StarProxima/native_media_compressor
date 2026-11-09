#ifndef NATIVE_MEDIA_COMPRESSOR_JPEG_EXIF_H_
#define NATIVE_MEDIA_COMPRESSOR_JPEG_EXIF_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace native_media_compressor {

// The first APP1 "Exif" segment of a JPEG, marker and length included, or
// empty when the data is not a JPEG, has no EXIF or ends inside the segment.
std::vector<uint8_t> FindJpegExifSegment(const uint8_t* data, size_t size);

// Sets the IFD0 orientation tag of an APP1 EXIF segment to 1 (normal) in
// place. False when the TIFF header or IFD0 cannot be read to the end, so an
// unpatched orientation may remain; true also when there is no orientation tag.
bool ResetExifOrientation(std::vector<uint8_t>* segment);

// `jpeg` with `segment` inserted right after SOI, or empty when `jpeg` does not
// start with SOI.
std::vector<uint8_t> InsertAfterSoi(const std::vector<uint8_t>& jpeg,
                                    const std::vector<uint8_t>& segment);

// Copies the EXIF of the JPEG at `source` into the JPEG at `output` with the
// orientation reset to normal. Leaves `output` alone when the source has no
// usable EXIF; false only when rewriting `output` failed.
bool CopyJpegExif(const std::string& source, const std::string& output, std::string* error);

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_JPEG_EXIF_H_
