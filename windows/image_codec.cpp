#include "image_codec.h"

#include <windows.h>

#include <wincodec.h>
#include <wincodecsdk.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cwchar>
#include <cwctype>
#include <initializer_list>
#include <string>
#include <vector>

namespace native_media_compressor {
namespace {

using Microsoft::WRL::ComPtr;

// Declared here rather than taken from wincodec.h, so that the build does not
// depend on the SDK version declaring and exporting them.
constexpr GUID kContainerFormatWebp = {
    0xe094b0e2, 0x67f2, 0x45b3, {0xb0, 0xea, 0x11, 0x53, 0x37, 0xca, 0x7c, 0xf3}};
constexpr GUID kContainerFormatHeif = {
    0xe1e62521, 0x6787, 0x405b, {0xa3, 0x39, 0x50, 0x07, 0x15, 0xb5, 0x76, 0x3f}};

GUID ContainerFormatOf(ImageOutputFormat format) {
  switch (format) {
    case ImageOutputFormat::kPng:
      return GUID_ContainerFormatPng;
    case ImageOutputFormat::kWebp:
      return kContainerFormatWebp;
    case ImageOutputFormat::kHeic:
      return kContainerFormatHeif;
    case ImageOutputFormat::kJpeg:
      break;
  }
  return GUID_ContainerFormatJpeg;
}

constexpr wchar_t kExifOrientation[] = L"/app1/ifd/{ushort=274}";
constexpr wchar_t kXmpOrientation[] = L"/xmp/tiff:Orientation";

struct OpenedImage {
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  UINT width = 0;
  UINT height = 0;
  UINT frame_count = 0;
  UINT orientation = 1;
  std::optional<std::string> mime_type;
};

UINT ReadOrientation(IWICBitmapFrameDecode* frame) {
  ComPtr<IWICMetadataQueryReader> reader;
  if (FAILED(frame->GetMetadataQueryReader(&reader))) return 1;
  // The photo policy name covers most containers; the raw EXIF paths are a
  // fallback for decoders that do not map it.
  for (const wchar_t* query :
       {L"System.Photo.Orientation", kExifOrientation, L"/ifd/{ushort=274}"}) {
    PROPVARIANT value;
    PropVariantInit(&value);
    std::optional<UINT> orientation;
    if (SUCCEEDED(reader->GetMetadataByName(query, &value))) orientation = OrientationValue(value);
    PropVariantClear(&value);
    if (orientation) return *orientation;
  }
  return 1;
}

bool HasMetadata(IWICMetadataQueryReader* reader, const wchar_t* query) {
  PROPVARIANT value;
  PropVariantInit(&value);
  const bool found = SUCCEEDED(reader->GetMetadataByName(query, &value));
  PropVariantClear(&value);
  return found;
}

// Decoders other than JPEG expose the EXIF directory under their own paths;
// it is re-created as the JPEG one. S_FALSE when the source has none.
HRESULT CopyExifDirectory(IWICImagingFactory* factory, IWICMetadataQueryReader* source,
                          IWICMetadataQueryWriter* target) {
  for (const wchar_t* query : {L"/ifd", L"/app1/ifd", L"/eXIf/ifd"}) {
    PROPVARIANT found;
    PropVariantInit(&found);
    ComPtr<IWICMetadataQueryReader> directory;
    if (SUCCEEDED(source->GetMetadataByName(query, &found)) && found.vt == VT_UNKNOWN &&
        found.punkVal != nullptr) {
      found.punkVal->QueryInterface(IID_PPV_ARGS(&directory));
    }
    PropVariantClear(&found);
    if (!directory) continue;
    ComPtr<IWICComponentFactory> components;
    NMC_RETURN_HR_IF_FAILED(factory->QueryInterface(IID_PPV_ARGS(&components)));
    ComPtr<IWICMetadataQueryWriter> copy;
    NMC_RETURN_HR_IF_FAILED(
        components->CreateQueryWriterFromReader(directory.Get(), nullptr, &copy));
    PROPVARIANT value;
    PropVariantInit(&value);
    value.vt = VT_UNKNOWN;
    value.punkVal = copy.Get();
    return target->SetMetadataByName(L"/app1/ifd", &value);
  }
  return S_FALSE;
}

// The pixels are already upright, so a copied orientation has to read as
// normal everywhere a reader may look, or the picture would turn twice.
HRESULT MakeOrientationNormal(IWICMetadataQueryWriter* writer) {
  if (HasMetadata(writer, kExifOrientation)) {
    PROPVARIANT normal;
    PropVariantInit(&normal);
    normal.vt = VT_UI2;
    normal.uiVal = 1;
    NMC_RETURN_HR_IF_FAILED(writer->SetMetadataByName(kExifOrientation, &normal));
  }
  if (HasMetadata(writer, kXmpOrientation)) {
    NMC_RETURN_HR_IF_FAILED(writer->RemoveMetadataByName(kXmpOrientation));
  }
  for (const wchar_t* query : {L"System.Photo.Orientation", kExifOrientation, kXmpOrientation}) {
    PROPVARIANT value;
    PropVariantInit(&value);
    std::optional<UINT> orientation;
    if (SUCCEEDED(writer->GetMetadataByName(query, &value))) orientation = OrientationValue(value);
    PropVariantClear(&value);
    if (orientation.value_or(1) != 1) return E_FAIL;
  }
  return S_OK;
}

HRESULT CopyMetadata(IWICImagingFactory* factory, IWICBitmapFrameDecode* source,
                     IWICBitmapFrameEncode* target) {
  ComPtr<IWICMetadataBlockReader> blocks;
  GUID container = GUID_NULL;
  if (SUCCEEDED(source->QueryInterface(IID_PPV_ARGS(&blocks))) &&
      SUCCEEDED(blocks->GetContainerFormat(&container)) &&
      container == GUID_ContainerFormatJpeg) {
    // Within one container every metadata block, XMP included, is copied as
    // it is.
    ComPtr<IWICMetadataBlockWriter> block_writer;
    NMC_RETURN_HR_IF_FAILED(target->QueryInterface(IID_PPV_ARGS(&block_writer)));
    NMC_RETURN_HR_IF_FAILED(block_writer->InitializeFromBlockReader(blocks.Get()));
  }
  ComPtr<IWICMetadataQueryWriter> writer;
  NMC_RETURN_HR_IF_FAILED(target->GetMetadataQueryWriter(&writer));
  if (container != GUID_ContainerFormatJpeg) {
    ComPtr<IWICMetadataQueryReader> reader;
    if (FAILED(source->GetMetadataQueryReader(&reader))) return S_OK;
    NMC_RETURN_HR_IF_FAILED(CopyExifDirectory(factory, reader.Get(), writer.Get()));
  }
  return MakeOrientationNormal(writer.Get());
}

std::string HeifBrand(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  char header[12] = {};
  DWORD bytes_read = 0;
  const BOOL ok = ReadFile(file, header, static_cast<DWORD>(sizeof(header)), &bytes_read, nullptr);
  CloseHandle(file);
  if (!ok || bytes_read != sizeof(header) || std::string(header + 4, 4) != "ftyp") return {};
  return std::string(header + 8, 4);
}

// HEIF decoders register one container for HEIC, AVIF and plain HEIF, so the
// file brand tells them apart.
std::string HeifFamilyMime(const std::wstring& path) {
  const std::string brand = HeifBrand(path);
  for (const char* heic : {"heic", "heix", "heim", "heis", "hevc", "hevx"}) {
    if (brand == heic) return "image/heic";
  }
  if (brand == "avif" || brand == "avis") return "image/avif";
  return "image/heif";
}

std::optional<std::string> MimeType(IWICBitmapDecoder* decoder, const std::wstring& path) {
  GUID container = GUID_NULL;
  if (SUCCEEDED(decoder->GetContainerFormat(&container))) {
    if (container == GUID_ContainerFormatJpeg) return "image/jpeg";
    if (container == GUID_ContainerFormatPng) return "image/png";
    if (container == GUID_ContainerFormatGif) return "image/gif";
    if (container == GUID_ContainerFormatBmp) return "image/bmp";
    if (container == GUID_ContainerFormatTiff) return "image/tiff";
  }
  // Store codec extensions (HEIF, WebP, AVIF) are matched by the MIME types
  // they register, which does not depend on the SDK declaring their GUIDs.
  ComPtr<IWICBitmapDecoderInfo> info;
  if (FAILED(decoder->GetDecoderInfo(&info))) return std::nullopt;
  UINT length = 0;
  if (FAILED(info->GetMimeTypes(0, nullptr, &length)) || length == 0) return std::nullopt;
  std::wstring mimes(length, L'\0');
  if (FAILED(info->GetMimeTypes(length, mimes.data(), &length))) return std::nullopt;
  mimes.resize(wcslen(mimes.c_str()));
  std::transform(mimes.begin(), mimes.end(), mimes.begin(),
                 [](wchar_t symbol) { return static_cast<wchar_t>(std::towlower(symbol)); });
  if (mimes.find(L"heic") != std::wstring::npos || mimes.find(L"heif") != std::wstring::npos ||
      mimes.find(L"avif") != std::wstring::npos) {
    return HeifFamilyMime(path);
  }
  if (mimes.find(L"webp") != std::wstring::npos) return "image/webp";
  const std::wstring first = mimes.substr(0, mimes.find(L','));
  if (first.empty()) return std::nullopt;
  return WideToUtf8(first);
}

bool IsWebp(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  char header[12] = {};
  DWORD bytes_read = 0;
  const BOOL ok = ReadFile(file, header, static_cast<DWORD>(sizeof(header)), &bytes_read, nullptr);
  CloseHandle(file);
  return ok && bytes_read == sizeof(header) && std::string(header, 4) == "RIFF" &&
         std::string(header + 8, 4) == "WEBP";
}

// WIC decodes an animated PNG as a single still frame, so the frame count is
// read from the `acTL` chunk, which must come before the first `IDAT`.
UINT ApngFrameCount(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return 0;
  const auto read32 = [](const unsigned char* bytes) {
    return (static_cast<uint32_t>(bytes[0]) << 24) | (static_cast<uint32_t>(bytes[1]) << 16) |
           (static_cast<uint32_t>(bytes[2]) << 8) | static_cast<uint32_t>(bytes[3]);
  };
  // Only chunk headers are read; the data of metadata chunks, which may be
  // large, is skipped by moving the file pointer.
  UINT frames = 0;
  LARGE_INTEGER position;
  position.QuadPart = 8;
  while (SetFilePointerEx(file, position, nullptr, FILE_BEGIN)) {
    unsigned char header[12] = {};
    DWORD bytes_read = 0;
    if (!ReadFile(file, header, static_cast<DWORD>(sizeof(header)), &bytes_read, nullptr) ||
        bytes_read < 8) {
      break;
    }
    const uint32_t length = read32(header);
    const std::string type(reinterpret_cast<const char*>(header + 4), 4);
    if (type == "acTL") {
      if (bytes_read == sizeof(header) && length >= 8) frames = read32(header + 8);
      break;
    }
    if (type == "IDAT" || type == "IEND") break;
    position.QuadPart += 12 + static_cast<LONGLONG>(length);
  }
  CloseHandle(file);
  return frames;
}

// Without the Store extension WIC has no decoder at all, so the decoder cannot
// name the format; the file signature can.
bool NeedsCodecExtension(const std::optional<std::string>& mime_type, const std::wstring& path) {
  if (mime_type) {
    return *mime_type == "image/heic" || *mime_type == "image/heif" ||
           *mime_type == "image/avif" || *mime_type == "image/webp";
  }
  return !HeifBrand(path).empty() || IsWebp(path);
}

HRESULT OpenImage(IWICImagingFactory* factory, const std::wstring& path, OpenedImage* image) {
  NMC_RETURN_HR_IF_FAILED(factory->CreateDecoderFromFilename(
      path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &image->decoder));
  image->mime_type = MimeType(image->decoder.Get(), path);
  NMC_RETURN_HR_IF_FAILED(image->decoder->GetFrameCount(&image->frame_count));
  if (image->frame_count == 0) return WINCODEC_ERR_FRAMEMISSING;
  if (image->mime_type == "image/png") {
    image->frame_count = std::max(image->frame_count, ApngFrameCount(path));
  }
  NMC_RETURN_HR_IF_FAILED(image->decoder->GetFrame(0, &image->frame));
  NMC_RETURN_HR_IF_FAILED(image->frame->GetSize(&image->width, &image->height));
  if (image->width == 0 || image->height == 0) return WINCODEC_ERR_BADIMAGE;
  image->orientation = ReadOrientation(image->frame.Get());
  return S_OK;
}

// Lets a decoder that can scale while decoding (the JPEG decoder does it in
// the DCT domain) skip the full-size bitmap. Falls back to the frame itself.
ComPtr<IWICBitmapSource> DownsampledSource(IWICImagingFactory* factory,
                                           IWICBitmapFrameDecode* frame, UINT width,
                                           UINT target_width, UINT target_height) {
  ComPtr<IWICBitmapSource> fallback(frame);
  ComPtr<IWICBitmapSourceTransform> transform;
  if (FAILED(frame->QueryInterface(IID_PPV_ARGS(&transform)))) return fallback;
  UINT scaled_width = target_width;
  UINT scaled_height = target_height;
  if (FAILED(transform->GetClosestSize(&scaled_width, &scaled_height)) ||
      scaled_width < target_width || scaled_height < target_height || scaled_width >= width) {
    return fallback;
  }
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  if (FAILED(transform->GetClosestPixelFormat(&format))) return fallback;
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmap(scaled_width, scaled_height, format, WICBitmapCacheOnLoad,
                                   &bitmap))) {
    return fallback;
  }
  {
    const WICRect area = {0, 0, static_cast<INT>(scaled_width), static_cast<INT>(scaled_height)};
    ComPtr<IWICBitmapLock> lock;
    if (FAILED(bitmap->Lock(&area, WICBitmapLockWrite, &lock))) return fallback;
    UINT stride = 0;
    UINT size = 0;
    BYTE* data = nullptr;
    if (FAILED(lock->GetStride(&stride)) || FAILED(lock->GetDataPointer(&size, &data)) ||
        FAILED(transform->CopyPixels(nullptr, scaled_width, scaled_height, &format,
                                     WICBitmapTransformRotate0, stride, size, data))) {
      return fallback;
    }
  }
  return bitmap;
}

// Turns pixels stored as `width` x `height` into the displayed picture for an
// EXIF orientation. WIC's flip-rotator answers E_INVALIDARG for the sources
// this pipeline produces, so the eight cases are done by hand.
std::vector<BYTE> Reorient(const std::vector<BYTE>& stored, UINT width, UINT height,
                           UINT orientation) {
  const bool swaps_sides = orientation >= 5;
  const UINT shown_width = swaps_sides ? height : width;
  const UINT shown_height = swaps_sides ? width : height;
  std::vector<BYTE> shown(stored.size());
  for (UINT y = 0; y < shown_height; ++y) {
    for (UINT x = 0; x < shown_width; ++x) {
      UINT source_x = x;
      UINT source_y = y;
      switch (orientation) {
        case 2:
          source_x = width - 1 - x;
          break;
        case 3:
          source_x = width - 1 - x;
          source_y = height - 1 - y;
          break;
        case 4:
          source_y = height - 1 - y;
          break;
        case 5:
          source_x = y;
          source_y = x;
          break;
        case 6:
          source_x = y;
          source_y = height - 1 - x;
          break;
        case 7:
          source_x = width - 1 - y;
          source_y = height - 1 - x;
          break;
        case 8:
          source_x = width - 1 - y;
          source_y = x;
          break;
        default:
          break;
      }
      const BYTE* from = stored.data() + (static_cast<size_t>(source_y) * width + source_x) * 4;
      BYTE* to = shown.data() + (static_cast<size_t>(y) * shown_width + x) * 4;
      std::copy(from, from + 4, to);
    }
  }
  return shown;
}

bool NeedsEncoderExtension(ImageOutputFormat format) {
  return format == ImageOutputFormat::kWebp || format == ImageOutputFormat::kHeic;
}

const char* FormatName(ImageOutputFormat format) {
  switch (format) {
    case ImageOutputFormat::kPng:
      return "PNG";
    case ImageOutputFormat::kWebp:
      return "WebP";
    case ImageOutputFormat::kHeic:
      return "HEIC";
    case ImageOutputFormat::kJpeg:
      break;
  }
  return "JPEG";
}

// Sets `*metadata_failed` and fails when copying the metadata fails, so that
// the caller can write the image again without it.
Outcome WriteImage(IWICImagingFactory* factory, const ImageJob& job, IWICStream* stream,
                   std::vector<BYTE>& pixels, const WICPixelFormatGUID& pixel_format, UINT stride,
                   UINT width, UINT height, IWICBitmapFrameDecode* metadata_source,
                   bool* metadata_failed) {
  ComPtr<IWICBitmapEncoder> encoder;
  if (const HRESULT result =
          factory->CreateEncoder(ContainerFormatOf(job.format), nullptr, &encoder);
      FAILED(result)) {
    const std::string step = std::string("Finding a ") + FormatName(job.format) + " encoder";
    return Outcome::Of(Status::kUnsupported, DescribeHresult(step.c_str(), result));
  }
  NMC_RETURN_IF_FAILED(encoder->Initialize(stream, WICBitmapEncoderNoCache),
                       "Starting the encoder");
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> options;
  NMC_RETURN_IF_FAILED(encoder->CreateNewFrame(&frame, &options), "Creating the output frame");
  if (job.format != ImageOutputFormat::kPng) {
    PROPBAG2 option = {};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value = {};
    value.vt = VT_R4;
    value.fltVal = static_cast<FLOAT>(std::clamp(job.quality, 0, 100)) / 100.0f;
    const HRESULT quality_result = options ? options->Write(1, &option, &value) : E_NOINTERFACE;
    // Codec extensions need not take this option; their default quality is
    // better than no image.
    if (FAILED(quality_result) && job.format == ImageOutputFormat::kJpeg) {
      return Outcome::Failed("Setting the JPEG quality", quality_result);
    }
  }
  NMC_RETURN_IF_FAILED(frame->Initialize(options.Get()), "Initializing the output frame");
  NMC_RETURN_IF_FAILED(frame->SetSize(width, height), "Setting the output size");
  WICPixelFormatGUID encoder_format = pixel_format;
  NMC_RETURN_IF_FAILED(frame->SetPixelFormat(&encoder_format), "Setting the pixel format");
  if (metadata_source != nullptr) {
    if (const HRESULT result = CopyMetadata(factory, metadata_source, frame.Get());
        FAILED(result)) {
      if (metadata_failed != nullptr) *metadata_failed = true;
      return Outcome::Failed("Copying the metadata", result);
    }
  }
  if (encoder_format == pixel_format) {
    NMC_RETURN_IF_FAILED(frame->WritePixels(height, stride, static_cast<UINT>(pixels.size()),
                                            pixels.data()),
                         "Encoding the pixels");
  } else {
    // Codec extensions may take only pixel layouts of their own.
    ComPtr<IWICBitmap> bitmap;
    NMC_RETURN_IF_FAILED(
        factory->CreateBitmapFromMemory(width, height, pixel_format, stride,
                                        static_cast<UINT>(pixels.size()), pixels.data(), &bitmap),
        "Copying the pixels");
    ComPtr<IWICFormatConverter> converter;
    NMC_RETURN_IF_FAILED(factory->CreateFormatConverter(&converter), "Creating a pixel converter");
    NMC_RETURN_IF_FAILED(converter->Initialize(bitmap.Get(), encoder_format,
                                               WICBitmapDitherTypeNone, nullptr, 0.0,
                                               WICBitmapPaletteTypeCustom),
                         "Converting the pixels for the encoder");
    NMC_RETURN_IF_FAILED(frame->WriteSource(converter.Get(), nullptr), "Encoding the pixels");
  }
  NMC_RETURN_IF_FAILED(frame->Commit(), "Finishing the frame");
  NMC_RETURN_IF_FAILED(encoder->Commit(), "Finishing the file");
  return Outcome::Compressed(width, height);
}

// `metadata_source` is the decoded frame whose metadata goes into the output,
// or null to write none.
Outcome Encode(IWICImagingFactory* factory, const ImageJob& job, const std::wstring& output,
               const std::vector<BYTE>& premultiplied, UINT width, UINT height,
               IWICBitmapFrameDecode* metadata_source) {
  const bool png = job.format == ImageOutputFormat::kPng;
  bool has_alpha = false;
  if (png) {
    for (size_t index = 3; index < premultiplied.size(); index += 4) {
      if (premultiplied[index] != 255) {
        has_alpha = true;
        break;
      }
    }
  }
  const bool keep_alpha = png && has_alpha;
  const WICPixelFormatGUID pixel_format =
      keep_alpha ? GUID_WICPixelFormat32bppBGRA : GUID_WICPixelFormat24bppBGR;
  const UINT pixel_bytes = keep_alpha ? 4 : 3;
  const UINT stride = (width * pixel_bytes + 3) / 4 * 4;
  std::vector<BYTE> pixels(static_cast<size_t>(stride) * height);
  for (UINT y = 0; y < height; ++y) {
    const BYTE* in = premultiplied.data() + static_cast<size_t>(y) * width * 4;
    BYTE* out = pixels.data() + static_cast<size_t>(y) * stride;
    for (UINT x = 0; x < width; ++x, in += 4, out += pixel_bytes) {
      const UINT alpha = in[3];
      if (keep_alpha) {
        for (int channel = 0; channel < 3; ++channel) {
          out[channel] = static_cast<BYTE>(
              alpha == 0 ? 0u : std::min<UINT>(255, (in[channel] * 255u + alpha / 2) / alpha));
        }
        out[3] = static_cast<BYTE>(alpha);
      } else {
        // Premultiplied colour over white: c + (1 - a) * 255.
        for (int channel = 0; channel < 3; ++channel) {
          out[channel] = static_cast<BYTE>(std::min<UINT>(255, in[channel] + 255u - alpha));
        }
      }
    }
  }

  const auto write = [&](IWICBitmapFrameDecode* source_frame, bool* metadata_failed) -> Outcome {
    ComPtr<IWICStream> stream;
    NMC_RETURN_IF_FAILED(factory->CreateStream(&stream), "Creating the output stream");
    NMC_RETURN_IF_FAILED(stream->InitializeFromFilename(output.c_str(), GENERIC_WRITE),
                         "Creating the output file");
    Outcome outcome = WriteImage(factory, job, stream.Get(), pixels, pixel_format, stride, width,
                                 height, source_frame, metadata_failed);
    // A Store codec extension can be partly installed (HEIF without HEVC)
    // and then fail midway; that is a missing codec, not a broken image.
    if (outcome.status == Status::kFailed && NeedsEncoderExtension(job.format)) {
      outcome.status = Status::kUnsupported;
    }
    return outcome;
  };
  bool metadata_failed = false;
  Outcome outcome = write(metadata_source, &metadata_failed);
  if (!metadata_failed) return outcome;
  // Metadata is kept on a best effort basis: the image is written again
  // without it, into a fresh file so that nothing of the first try remains.
  RemoveFile(output);
  return write(nullptr, nullptr);
}

Outcome Run(const ImageJob& job, const std::wstring& output, bool* needs_codec_extension) {
  ComPtr<IWICImagingFactory> factory;
  NMC_RETURN_IF_FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                        IID_PPV_ARGS(&factory)),
                       "Creating the WIC factory");
  OpenedImage image;
  const HRESULT open_result = OpenImage(factory.Get(), job.source, &image);
  *needs_codec_extension = NeedsCodecExtension(image.mime_type, job.source);
  if (open_result == WINCODEC_ERR_COMPONENTNOTFOUND) {
    return Outcome::Of(Status::kUnsupported, "No installed WIC decoder reads this file");
  }
  NMC_RETURN_IF_FAILED(open_result, "Opening the image");

  const bool swaps_sides = image.orientation >= 5;
  const UINT shown_width = swaps_sides ? image.height : image.width;
  const UINT shown_height = swaps_sides ? image.width : image.height;
  const double scale = FitScale(shown_width, shown_height, job.bounds);
  const UINT out_width = std::max<UINT>(1, static_cast<UINT>(std::lround(shown_width * scale)));
  const UINT out_height = std::max<UINT>(1, static_cast<UINT>(std::lround(shown_height * scale)));
  const UINT stored_width = swaps_sides ? out_height : out_width;
  const UINT stored_height = swaps_sides ? out_width : out_height;

  const uint64_t buffer_size = static_cast<uint64_t>(out_width) * out_height * 4;
  if (buffer_size > 0x7FFFFFFFu) {
    return Outcome::Of(Status::kFailed, "The output image is too large to hold in memory");
  }

  ComPtr<IWICBitmapSource> source =
      scale < 1.0
          ? DownsampledSource(factory.Get(), image.frame.Get(), image.width, stored_width,
                              stored_height)
          : ComPtr<IWICBitmapSource>(image.frame);
  ComPtr<IWICFormatConverter> converter;
  NMC_RETURN_IF_FAILED(factory->CreateFormatConverter(&converter), "Creating a pixel converter");
  // Scaling premultiplied pixels keeps transparent edges from bleeding colour.
  NMC_RETURN_IF_FAILED(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPBGRA,
                                             WICBitmapDitherTypeNone, nullptr, 0.0,
                                             WICBitmapPaletteTypeCustom),
                       "Converting the pixels");
  source = converter;
  UINT current_width = 0;
  UINT current_height = 0;
  NMC_RETURN_IF_FAILED(source->GetSize(&current_width, &current_height), "Reading the size");
  if (current_width != stored_width || current_height != stored_height) {
    ComPtr<IWICBitmapScaler> scaler;
    NMC_RETURN_IF_FAILED(factory->CreateBitmapScaler(&scaler), "Creating a scaler");
    NMC_RETURN_IF_FAILED(scaler->Initialize(source.Get(), stored_width, stored_height,
                                            WICBitmapInterpolationModeFant),
                         "Scaling the image");
    source = scaler;
  }
  NMC_RETURN_IF_FAILED(source->GetSize(&current_width, &current_height), "Reading the size");
  if (current_width != stored_width || current_height != stored_height) {
    return Outcome::Of(Status::kFailed, "The image pipeline produced an unexpected size");
  }

  std::vector<BYTE> pixels(static_cast<size_t>(buffer_size));
  NMC_RETURN_IF_FAILED(source->CopyPixels(nullptr, stored_width * 4,
                                          static_cast<UINT>(buffer_size), pixels.data()),
                       "Decoding the image");
  if (image.orientation > 1) {
    pixels = Reorient(pixels, stored_width, stored_height, image.orientation);
  }
  IWICBitmapFrameDecode* metadata_source =
      job.keep_metadata && job.format == ImageOutputFormat::kJpeg ? image.frame.Get() : nullptr;
  return Encode(factory.Get(), job, output, pixels, out_width, out_height, metadata_source);
}

}  // namespace

Outcome CompressImageFile(const ImageJob& job) {
  if (IsDirectory(job.destination)) {
    return Outcome::Of(Status::kFailed, "The destination is a directory");
  }
  // Pixel buffers of a huge image can fail to allocate. Unwinding releases WIC
  // and deletes the temporary file, so that ends only this operation.
  try {
    PendingOutput output(job.destination);
    if (!output.reserved()) {
      return Outcome::Of(Status::kFailed, "Cannot create a file next to the destination");
    }
    Outcome outcome;
    {
      ComScope com;
      bool needs_codec_extension = false;
      outcome = Run(job, output.path(), &needs_codec_extension);
      // A Store codec extension can be partly installed (HEIF without HEVC)
      // and then fail midway; that is a missing codec, not a broken file.
      if (outcome.status == Status::kFailed && needs_codec_extension) {
        outcome.status = Status::kUnsupported;
      }
    }
    if (outcome.status != Status::kCompressed) return outcome;
    outcome.size_bytes = FileSize(output.path());
    if (outcome.size_bytes <= 0) return Outcome::Of(Status::kFailed, "The encoder wrote no output");
    if (!output.Commit()) {
      return Outcome::Of(Status::kFailed,
                         DescribeHresult("Replacing the destination",
                                         HRESULT_FROM_WIN32(GetLastError())));
    }
    return outcome;
  } catch (...) {
    return Outcome::Of(Status::kFailed, kUnexpectedError);
  }
}

std::optional<ImageInfo> ProbeImageFile(const std::wstring& source) {
  ComScope com;
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory)))) {
    return std::nullopt;
  }
  OpenedImage image;
  if (FAILED(OpenImage(factory.Get(), source, &image))) return std::nullopt;
  const bool swaps_sides = image.orientation >= 5;
  ImageInfo info;
  info.width = swaps_sides ? image.height : image.width;
  info.height = swaps_sides ? image.width : image.height;
  info.frame_count = image.frame_count;
  info.mime_type = image.mime_type;
  if (const int64_t size = FileSize(source); size >= 0) info.size_bytes = size;
  return info;
}

Outcome WriteFrameImage(const std::vector<uint8_t>& bgra, uint32_t width, uint32_t height,
                        const ImageJob& job, const std::wstring& output) {
  if (width == 0 || height == 0 || bgra.size() != static_cast<size_t>(width) * height * 4) {
    return Outcome::Of(Status::kFailed, "The frame has no pixels");
  }
  ComPtr<IWICImagingFactory> factory;
  NMC_RETURN_IF_FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                        IID_PPV_ARGS(&factory)),
                       "Creating the WIC factory");
  const double scale = FitScale(width, height, job.bounds);
  const UINT out_width = std::max<UINT>(1, static_cast<UINT>(std::lround(width * scale)));
  const UINT out_height = std::max<UINT>(1, static_cast<UINT>(std::lround(height * scale)));
  if (out_width == width && out_height == height) {
    return Encode(factory.Get(), job, output, bgra, width, height, nullptr);
  }

  ComPtr<IWICBitmap> bitmap;
  NMC_RETURN_IF_FAILED(
      factory->CreateBitmapFromMemory(width, height, GUID_WICPixelFormat32bppPBGRA, width * 4,
                                      static_cast<UINT>(bgra.size()),
                                      const_cast<BYTE*>(bgra.data()), &bitmap),
      "Copying the frame");
  ComPtr<IWICBitmapScaler> scaler;
  NMC_RETURN_IF_FAILED(factory->CreateBitmapScaler(&scaler), "Creating a scaler");
  NMC_RETURN_IF_FAILED(
      scaler->Initialize(bitmap.Get(), out_width, out_height, WICBitmapInterpolationModeFant),
      "Scaling the frame");
  std::vector<BYTE> pixels(static_cast<size_t>(out_width) * out_height * 4);
  NMC_RETURN_IF_FAILED(scaler->CopyPixels(nullptr, out_width * 4, static_cast<UINT>(pixels.size()),
                                          pixels.data()),
                       "Scaling the frame");
  return Encode(factory.Get(), job, output, pixels, out_width, out_height, nullptr);
}

std::optional<UINT> OrientationValue(const PROPVARIANT& value) {
  int64_t number = 0;
  switch (value.vt) {
    case VT_UI1:
      number = value.bVal;
      break;
    case VT_UI2:
      number = value.uiVal;
      break;
    case VT_UI4:
      number = value.ulVal;
      break;
    case VT_I2:
      number = value.iVal;
      break;
    case VT_I4:
      number = value.lVal;
      break;
    case VT_LPSTR: {
      // XMP stores the orientation as text.
      if (value.pszVal == nullptr || *value.pszVal == '\0') return std::nullopt;
      char* end = nullptr;
      number = std::strtol(value.pszVal, &end, 10);
      if (*end != '\0') return std::nullopt;
      break;
    }
    case VT_LPWSTR: {
      if (value.pwszVal == nullptr || *value.pwszVal == L'\0') return std::nullopt;
      wchar_t* end = nullptr;
      number = std::wcstol(value.pwszVal, &end, 10);
      if (*end != L'\0') return std::nullopt;
      break;
    }
    default:
      return std::nullopt;
  }
  if (number < 1 || number > 8) return std::nullopt;
  return static_cast<UINT>(number);
}

}  // namespace native_media_compressor
