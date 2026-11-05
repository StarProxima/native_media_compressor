#include "image_codec.h"

#include <windows.h>

#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cwchar>
#include <cwctype>
#include <initializer_list>
#include <vector>

namespace native_media_compressor {
namespace {

using Microsoft::WRL::ComPtr;

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
       {L"System.Photo.Orientation", L"/app1/ifd/{ushort=274}", L"/ifd/{ushort=274}"}) {
    PROPVARIANT value;
    PropVariantInit(&value);
    UINT orientation = 0;
    if (SUCCEEDED(reader->GetMetadataByName(query, &value))) {
      switch (value.vt) {
        case VT_UI1:
          orientation = value.bVal;
          break;
        case VT_UI2:
          orientation = value.uiVal;
          break;
        case VT_UI4:
          orientation = value.ulVal;
          break;
        case VT_I2:
          orientation = static_cast<UINT>(value.iVal);
          break;
        default:
          break;
      }
    }
    PropVariantClear(&value);
    if (orientation >= 1 && orientation <= 8) return orientation;
  }
  return 1;
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
  std::vector<unsigned char> head(1 << 20);
  DWORD bytes_read = 0;
  const BOOL ok =
      ReadFile(file, head.data(), static_cast<DWORD>(head.size()), &bytes_read, nullptr);
  CloseHandle(file);
  if (!ok) return 0;
  const auto read32 = [&head](size_t at) {
    return (static_cast<uint32_t>(head[at]) << 24) | (static_cast<uint32_t>(head[at + 1]) << 16) |
           (static_cast<uint32_t>(head[at + 2]) << 8) | static_cast<uint32_t>(head[at + 3]);
  };
  size_t offset = 8;
  while (offset + 12 <= bytes_read) {
    const uint32_t length = read32(offset);
    const std::string type(reinterpret_cast<const char*>(head.data() + offset + 4), 4);
    if (type == "acTL" && length >= 8 && offset + 12 <= bytes_read) {
      return read32(offset + 8);
    }
    if (type == "IDAT" || type == "IEND") return 0;
    offset += 12 + static_cast<size_t>(length);
  }
  return 0;
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

Outcome Encode(IWICImagingFactory* factory, const ImageJob& job, const std::wstring& output,
               const std::vector<BYTE>& premultiplied, UINT width, UINT height) {
  bool has_alpha = false;
  if (job.png) {
    for (size_t index = 3; index < premultiplied.size(); index += 4) {
      if (premultiplied[index] != 255) {
        has_alpha = true;
        break;
      }
    }
  }
  const bool keep_alpha = job.png && has_alpha;
  WICPixelFormatGUID format = keep_alpha ? GUID_WICPixelFormat32bppBGRA : GUID_WICPixelFormat24bppBGR;
  const WICPixelFormatGUID requested_format = format;
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

  ComPtr<IWICStream> stream;
  NMC_RETURN_IF_FAILED(factory->CreateStream(&stream), "Creating the output stream");
  NMC_RETURN_IF_FAILED(stream->InitializeFromFilename(output.c_str(), GENERIC_WRITE),
                       "Creating the output file");
  ComPtr<IWICBitmapEncoder> encoder;
  if (const HRESULT result = factory->CreateEncoder(
          job.png ? GUID_ContainerFormatPng : GUID_ContainerFormatJpeg, nullptr, &encoder);
      FAILED(result)) {
    return Outcome::Of(Status::kUnsupported, DescribeHresult("Finding an encoder", result));
  }
  NMC_RETURN_IF_FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache),
                       "Starting the encoder");
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> options;
  NMC_RETURN_IF_FAILED(encoder->CreateNewFrame(&frame, &options), "Creating the output frame");
  if (!job.png) {
    PROPBAG2 option = {};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value = {};
    value.vt = VT_R4;
    value.fltVal = static_cast<FLOAT>(std::clamp(job.quality, 0, 100)) / 100.0f;
    NMC_RETURN_IF_FAILED(options->Write(1, &option, &value), "Setting the JPEG quality");
  }
  NMC_RETURN_IF_FAILED(frame->Initialize(options.Get()), "Initializing the output frame");
  NMC_RETURN_IF_FAILED(frame->SetSize(width, height), "Setting the output size");
  NMC_RETURN_IF_FAILED(frame->SetPixelFormat(&format), "Setting the pixel format");
  if (format != requested_format) {
    return Outcome::Of(Status::kFailed, "The encoder rejected the pixel format");
  }
  NMC_RETURN_IF_FAILED(frame->WritePixels(height, stride, static_cast<UINT>(pixels.size()),
                                          pixels.data()),
                       "Encoding the pixels");
  NMC_RETURN_IF_FAILED(frame->Commit(), "Finishing the frame");
  NMC_RETURN_IF_FAILED(encoder->Commit(), "Finishing the file");
  return Outcome::Compressed(width, height);
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
  return Encode(factory.Get(), job, output, pixels, out_width, out_height);
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
  return info;
}

}  // namespace native_media_compressor
