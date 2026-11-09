#include "video_transcoder.h"

#include <windows.h>

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <vector>

#include "image_codec.h"

namespace native_media_compressor {
namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kVideoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kAudioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr DWORD kAllStreams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr DWORD kMediaSource = static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);
constexpr LONGLONG kTicksPerSecond = 10000000;
constexpr LONGLONG kTicksPerMillisecond = 10000;
constexpr int kSizeCheckInterval = 10;
constexpr auto kProgressInterval = std::chrono::milliseconds(100);

constexpr GUID kDolbyAc3 = {0xe06d802c, 0xdb46, 0x11cf, {0xb4, 0xd1, 0x00, 0x80, 0x5f, 0x6c, 0xbb, 0xea}};
constexpr GUID kDolbyDigitalPlus = {0xa7fb87af, 0x2d02, 0x42fb, {0xa4, 0xd4, 0x05, 0xcd, 0x93, 0x84, 0x3b, 0xdd}};
constexpr GUID kHevcFormat = {0x43564548, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
constexpr GUID kVideoEncoderCategory = {0xf79eac7d, 0xe545, 0x4387, {0xbd, 0xee, 0xd6, 0x47, 0xd7, 0xbd, 0xe4, 0x2a}};

// Windows N ships without Media Foundation unless the Media Feature Pack is
// installed. Its DLLs are delay-loaded, so the plugin still loads there; any
// MF call made without this check would take the process down.
bool IsMediaFoundationAvailable() {
  static const bool available =
      LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32) != nullptr &&
      LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32) != nullptr;
  return available;
}

class MediaFoundationScope {
 public:
  MediaFoundationScope() : started_(SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {}
  ~MediaFoundationScope() {
    if (started_) MFShutdown();
  }
  MediaFoundationScope(const MediaFoundationScope&) = delete;
  MediaFoundationScope& operator=(const MediaFoundationScope&) = delete;

  bool started() const { return started_; }

 private:
  ComScope com_;
  bool started_;
};

constexpr DWORD FourCc(char a, char b, char c, char d) {
  return static_cast<DWORD>(static_cast<unsigned char>(a)) |
         (static_cast<DWORD>(static_cast<unsigned char>(b)) << 8) |
         (static_cast<DWORD>(static_cast<unsigned char>(c)) << 16) |
         (static_cast<DWORD>(static_cast<unsigned char>(d)) << 24);
}

// Most Media Foundation subtypes are a FOURCC or a WAVE_FORMAT tag placed in
// the first field of a fixed base GUID.
bool FormatCode(const GUID& subtype, DWORD* code) {
  static constexpr unsigned char kBaseTail[8] = {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71};
  if (subtype.Data2 != 0x0000 || subtype.Data3 != 0x0010 ||
      std::memcmp(subtype.Data4, kBaseTail, sizeof(kBaseTail)) != 0) {
    return false;
  }
  *code = subtype.Data1;
  return true;
}

std::string GuidText(const GUID& guid) {
  wchar_t text[40] = {};
  if (StringFromGUID2(guid, text, 40) == 0) return {};
  return WideToUtf8(text);
}

std::string VideoCodecName(const GUID& subtype) {
  DWORD code = 0;
  if (!FormatCode(subtype, &code)) return GuidText(subtype);
  switch (code) {
    case FourCc('H', '2', '6', '4'):
    case FourCc('h', '2', '6', '4'):
    case FourCc('A', 'V', 'C', '1'):
    case FourCc('a', 'v', 'c', '1'):
      return "video/avc";
    case FourCc('H', 'E', 'V', 'C'):
    case FourCc('H', 'E', 'V', 'S'):
    case FourCc('H', '2', '6', '5'):
    case FourCc('h', 'v', 'c', '1'):
    case FourCc('h', 'e', 'v', '1'):
      return "video/hevc";
    case FourCc('V', 'P', '8', '0'):
      return "video/x-vnd.on2.vp8";
    case FourCc('V', 'P', '9', '0'):
      return "video/x-vnd.on2.vp9";
    case FourCc('A', 'V', '0', '1'):
      return "video/av01";
    case FourCc('M', 'P', '4', 'V'):
      return "video/mp4v-es";
    case FourCc('H', '2', '6', '3'):
      return "video/3gpp";
    default:
      break;
  }
  std::string text;
  for (int shift = 0; shift < 32; shift += 8) {
    const char symbol = static_cast<char>((code >> shift) & 0xFF);
    if (symbol < 0x20 || symbol > 0x7E) return GuidText(subtype);
    text.push_back(symbol);
  }
  return text;
}

std::string AudioCodecName(const GUID& subtype) {
  if (subtype == kDolbyAc3) return "audio/ac3";
  if (subtype == kDolbyDigitalPlus) return "audio/eac3";
  DWORD code = 0;
  if (FormatCode(subtype, &code)) {
    switch (code) {
      case 0x1610:  // WAVE_FORMAT_MPEG_HEAAC
      case 0x1600:  // WAVE_FORMAT_MPEG_ADTS_AAC
        return "audio/mp4a-latm";
      case 0x0055:  // WAVE_FORMAT_MPEGLAYER3
      case 0x0050:  // WAVE_FORMAT_MPEG
        return "audio/mpeg";
      case 0x704F:  // WAVE_FORMAT_OPUS
        return "audio/opus";
      case 0xF1AC:  // WAVE_FORMAT_FLAC
        return "audio/flac";
      case 0x0092:  // WAVE_FORMAT_DOLBY_AC3_SPDIF
      case 0x2000:
        return "audio/ac3";
      default:
        break;
    }
  }
  return GuidText(subtype);
}

bool IsHdr(IMFMediaType* type) {
  const UINT32 transfer = MFGetAttributeUINT32(type, MF_MT_TRANSFER_FUNCTION,
                                               static_cast<UINT32>(MFVideoTransFunc_Unknown));
  return transfer == static_cast<UINT32>(MFVideoTransFunc_2084) ||
         transfer == static_cast<UINT32>(MFVideoTransFunc_HLG);
}

UINT32 NormalizeRotation(UINT32 degrees) {
  switch (degrees % 360) {
    case 90:
      return 90;
    case 180:
      return 180;
    case 270:
      return 270;
    default:
      return 0;
  }
}

UINT32 AlignDown(double value, UINT32 alignment) {
  return std::max<UINT32>(alignment, static_cast<UINT32>(value) / alignment * alignment);
}

LONGLONG Duration(IMFSourceReader* reader) {
  PROPVARIANT value;
  PropVariantInit(&value);
  LONGLONG duration = 0;
  if (SUCCEEDED(reader->GetPresentationAttribute(kMediaSource, MF_PD_DURATION, &value)) &&
      value.vt == VT_UI8) {
    duration = static_cast<LONGLONG>(value.uhVal.QuadPart);
  }
  PropVariantClear(&value);
  return duration;
}

int CountAudioStreams(IMFSourceReader* reader) {
  int count = 0;
  for (DWORD stream = 0;; ++stream) {
    ComPtr<IMFMediaType> type;
    if (FAILED(reader->GetNativeMediaType(stream, 0, &type))) return count;
    GUID major = GUID_NULL;
    if (SUCCEEDED(type->GetMajorType(&major)) && major == MFMediaType_Audio) ++count;
  }
}

HRESULT CreateVideoType(const GUID& subtype, UINT32 width, UINT32 height, UINT32 rate_numerator,
                        UINT32 rate_denominator, ComPtr<IMFMediaType>* type) {
  ComPtr<IMFMediaType> created;
  NMC_RETURN_HR_IF_FAILED(MFCreateMediaType(&created));
  NMC_RETURN_HR_IF_FAILED(created->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
  NMC_RETURN_HR_IF_FAILED(created->SetGUID(MF_MT_SUBTYPE, subtype));
  NMC_RETURN_HR_IF_FAILED(MFSetAttributeSize(created.Get(), MF_MT_FRAME_SIZE, width, height));
  NMC_RETURN_HR_IF_FAILED(
      MFSetAttributeRatio(created.Get(), MF_MT_FRAME_RATE, rate_numerator, rate_denominator));
  NMC_RETURN_HR_IF_FAILED(MFSetAttributeRatio(created.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1));
  NMC_RETURN_HR_IF_FAILED(created->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
  *type = created;
  return S_OK;
}

// Copies one plane turned clockwise by `degrees` (90, 180 or 270). A pixel is
// `pixel_bytes` wide: 1 for luma, 2 for the interleaved chroma of NV12.
void RotatePlane(const BYTE* source, LONG source_pitch, UINT32 source_width,
                 UINT32 source_height, BYTE* target, UINT32 target_pitch, UINT32 pixel_bytes,
                 UINT32 degrees) {
  const bool quarter_turn = degrees != 180;
  const UINT32 target_width = quarter_turn ? source_height : source_width;
  const UINT32 target_height = quarter_turn ? source_width : source_height;
  for (UINT32 y = 0; y < target_height; ++y) {
    BYTE* row = target + static_cast<size_t>(y) * target_pitch;
    for (UINT32 x = 0; x < target_width; ++x) {
      UINT32 source_x = 0;
      UINT32 source_y = 0;
      if (degrees == 90) {
        source_x = y;
        source_y = source_height - 1 - x;
      } else if (degrees == 180) {
        source_x = source_width - 1 - x;
        source_y = source_height - 1 - y;
      } else {
        source_x = source_width - 1 - y;
        source_y = x;
      }
      const BYTE* pixel = source + static_cast<ptrdiff_t>(source_y) * source_pitch +
                          static_cast<size_t>(source_x) * pixel_bytes;
      std::memcpy(row + static_cast<size_t>(x) * pixel_bytes, pixel, pixel_bytes);
    }
  }
}

// Bakes the rotation into an NV12 frame. The MP4 sink writer does not write
// MF_MT_VIDEO_ROTATION into the track header, so players would show the
// stored orientation.
HRESULT RotateNv12Sample(IMFSample* input, UINT32 width, UINT32 height, LONG default_stride,
                         UINT32 degrees, ComPtr<IMFSample>* output) {
  ComPtr<IMFMediaBuffer> buffer;
  NMC_RETURN_HR_IF_FAILED(input->ConvertToContiguousBuffer(&buffer));

  BYTE* source = nullptr;
  LONG pitch = 0;
  ComPtr<IMF2DBuffer> buffer_2d;
  const bool locked_2d =
      SUCCEEDED(buffer.As(&buffer_2d)) && SUCCEEDED(buffer_2d->Lock2D(&source, &pitch));
  if (!locked_2d) {
    DWORD max_length = 0;
    DWORD current_length = 0;
    NMC_RETURN_HR_IF_FAILED(buffer->Lock(&source, &max_length, &current_length));
    pitch = default_stride > 0 ? default_stride : static_cast<LONG>(width);
    const uint64_t needed = static_cast<uint64_t>(pitch) * height * 3 / 2;
    if (current_length < needed) {
      buffer->Unlock();
      return MF_E_BUFFERTOOSMALL;
    }
  }
  auto unlock = [&]() {
    if (locked_2d) {
      buffer_2d->Unlock2D();
    } else {
      buffer->Unlock();
    }
  };
  if (pitch < static_cast<LONG>(width)) {
    unlock();
    return MF_E_INVALIDMEDIATYPE;
  }

  const bool quarter_turn = degrees != 180;
  const UINT32 target_width = quarter_turn ? height : width;
  const UINT32 target_height = quarter_turn ? width : height;
  const DWORD target_size = target_width * target_height * 3 / 2;
  ComPtr<IMFMediaBuffer> rotated;
  if (const HRESULT result = MFCreateMemoryBuffer(target_size, &rotated); FAILED(result)) {
    unlock();
    return result;
  }
  BYTE* target = nullptr;
  if (const HRESULT result = rotated->Lock(&target, nullptr, nullptr); FAILED(result)) {
    unlock();
    return result;
  }
  RotatePlane(source, pitch, width, height, target, target_width, 1, degrees);
  RotatePlane(source + static_cast<ptrdiff_t>(pitch) * height, pitch, width / 2, height / 2,
              target + static_cast<size_t>(target_width) * target_height, target_width, 2,
              degrees);
  rotated->Unlock();
  unlock();
  NMC_RETURN_HR_IF_FAILED(rotated->SetCurrentLength(target_size));

  ComPtr<IMFSample> sample;
  NMC_RETURN_HR_IF_FAILED(MFCreateSample(&sample));
  NMC_RETURN_HR_IF_FAILED(sample->AddBuffer(rotated.Get()));
  LONGLONG timestamp = 0;
  if (SUCCEEDED(input->GetSampleTime(&timestamp))) sample->SetSampleTime(timestamp);
  LONGLONG duration = 0;
  if (SUCCEEDED(input->GetSampleDuration(&duration))) sample->SetSampleDuration(duration);
  *output = sample;
  return S_OK;
}

// The sink writer finds the encoder itself and fails late when there is none,
// so HEVC is requested only when an encoder is registered: Windows ships none
// without the Store extension or a GPU driver that adds one.
bool HasHevcEncoder() {
  const MFT_REGISTER_TYPE_INFO output = {MFMediaType_Video, kHevcFormat};
  IMFActivate** activates = nullptr;
  UINT32 count = 0;
  const UINT32 flags = static_cast<UINT32>(MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT |
                                           MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER);
  if (FAILED(MFTEnumEx(kVideoEncoderCategory, flags, nullptr, &output, &activates, &count))) {
    return false;
  }
  for (UINT32 index = 0; index < count; ++index) activates[index]->Release();
  CoTaskMemFree(activates);
  return count > 0;
}

// Encoder settings handed to IMFSinkWriter::SetInputMediaType. With only
// MF_MT_AVG_BITRATE the encoder stays in unconstrained VBR, which overshoots
// the target badly on short clips, and it ignores rate control changed after
// its media types are set.
HRESULT CreateEncodingParameters(eAVEncCommonRateControlMode mode, UINT32 bitrate,
                                 UINT32 gop_frames, ComPtr<IMFAttributes>* parameters) {
  ComPtr<IMFAttributes> created;
  NMC_RETURN_HR_IF_FAILED(MFCreateAttributes(&created, 4));
  NMC_RETURN_HR_IF_FAILED(
      created->SetUINT32(CODECAPI_AVEncCommonRateControlMode, static_cast<UINT32>(mode)));
  NMC_RETURN_HR_IF_FAILED(created->SetUINT32(CODECAPI_AVEncCommonMeanBitRate, bitrate));
  const uint64_t peak = static_cast<uint64_t>(bitrate) * 3 / 2;
  NMC_RETURN_HR_IF_FAILED(created->SetUINT32(
      CODECAPI_AVEncCommonMaxBitRate, static_cast<UINT32>(std::min<uint64_t>(peak, 0xFFFFFFFFull))));
  NMC_RETURN_HR_IF_FAILED(created->SetUINT32(CODECAPI_AVEncMPVGOPSize, gop_frames));
  *parameters = created;
  return S_OK;
}

// A source that cannot seek is read from its start instead; the samples before
// the wanted time are dropped either way.
void SeekTo(IMFSourceReader* reader, LONGLONG time) {
  PROPVARIANT position;
  PropVariantInit(&position);
  position.vt = VT_I8;
  position.hVal.QuadPart = time;
  reader->SetCurrentPosition(GUID_NULL, position);
  PropVariantClear(&position);
}

// Cuts a decoded PCM sample to the frames inside `range` and moves it onto the
// output timeline, which starts at `range.start`. `output` stays null when no
// frame is kept.
HRESULT CropAudioSample(IMFSample* input, LONGLONG time, const TrimRange& range,
                        UINT32 block_alignment, UINT32 sample_rate, ComPtr<IMFSample>* output) {
  output->Reset();
  if (block_alignment == 0 || sample_rate == 0) return MF_E_INVALIDMEDIATYPE;
  ComPtr<IMFMediaBuffer> buffer;
  NMC_RETURN_HR_IF_FAILED(input->ConvertToContiguousBuffer(&buffer));
  DWORD length = 0;
  NMC_RETURN_HR_IF_FAILED(buffer->GetCurrentLength(&length));
  const uint64_t frames = length / block_alignment;
  const PcmCrop crop = CropPcm(time, frames, sample_rate, range);
  if (crop.keep_frames == 0) return S_OK;

  ComPtr<IMFSample> sample;
  if (crop.skip_frames == 0 && crop.keep_frames == frames) {
    sample = input;
  } else {
    const DWORD offset = static_cast<DWORD>(crop.skip_frames * block_alignment);
    const DWORD size = static_cast<DWORD>(crop.keep_frames * block_alignment);
    ComPtr<IMFMediaBuffer> cropped;
    NMC_RETURN_HR_IF_FAILED(MFCreateMemoryBuffer(size, &cropped));
    BYTE* from = nullptr;
    NMC_RETURN_HR_IF_FAILED(buffer->Lock(&from, nullptr, nullptr));
    BYTE* to = nullptr;
    if (const HRESULT locked = cropped->Lock(&to, nullptr, nullptr); FAILED(locked)) {
      buffer->Unlock();
      return locked;
    }
    std::memcpy(to, from + offset, size);
    cropped->Unlock();
    buffer->Unlock();
    NMC_RETURN_HR_IF_FAILED(cropped->SetCurrentLength(size));
    NMC_RETURN_HR_IF_FAILED(MFCreateSample(&sample));
    NMC_RETURN_HR_IF_FAILED(sample->AddBuffer(cropped.Get()));
  }
  const LONGLONG kept_time =
      time + static_cast<LONGLONG>(crop.skip_frames) * kTicksPerSecond / sample_rate;
  NMC_RETURN_HR_IF_FAILED(sample->SetSampleTime(std::max<LONGLONG>(0, kept_time - range.start)));
  NMC_RETURN_HR_IF_FAILED(sample->SetSampleDuration(
      static_cast<LONGLONG>(crop.keep_frames) * kTicksPerSecond / sample_rate));
  *output = sample;
  return S_OK;
}

// Copies a decoded RGB32 frame into top-down BGRA rows turned clockwise by
// `degrees`. The fourth byte of RGB32 is undefined, so it is set to opaque.
HRESULT CopyRgb32Frame(IMFSample* sample, UINT32 width, UINT32 height, LONG default_stride,
                       UINT32 degrees, std::vector<uint8_t>* pixels) {
  pixels->assign(static_cast<size_t>(width) * height * 4, 0);
  ComPtr<IMFMediaBuffer> buffer;
  NMC_RETURN_HR_IF_FAILED(sample->ConvertToContiguousBuffer(&buffer));

  // Rows of RGB32 may be stored bottom-up; then the pitch is negative and the
  // first row is at the end of the buffer.
  BYTE* first_row = nullptr;
  LONG pitch = 0;
  ComPtr<IMF2DBuffer> buffer_2d;
  const bool locked_2d =
      SUCCEEDED(buffer.As(&buffer_2d)) && SUCCEEDED(buffer_2d->Lock2D(&first_row, &pitch));
  if (!locked_2d) {
    BYTE* data = nullptr;
    DWORD max_length = 0;
    DWORD current_length = 0;
    NMC_RETURN_HR_IF_FAILED(buffer->Lock(&data, &max_length, &current_length));
    pitch = default_stride != 0 ? default_stride : static_cast<LONG>(width * 4);
    const uint64_t needed = static_cast<uint64_t>(std::abs(pitch)) * height;
    if (current_length < needed) {
      buffer->Unlock();
      return MF_E_BUFFERTOOSMALL;
    }
    first_row = pitch < 0 ? data + static_cast<ptrdiff_t>(-pitch) * (height - 1) : data;
  }
  auto unlock = [&]() {
    if (locked_2d) {
      buffer_2d->Unlock2D();
    } else {
      buffer->Unlock();
    }
  };
  if (static_cast<uint64_t>(std::abs(pitch)) < static_cast<uint64_t>(width) * 4) {
    unlock();
    return MF_E_INVALIDMEDIATYPE;
  }

  if (degrees == 0) {
    for (UINT32 y = 0; y < height; ++y) {
      std::memcpy(pixels->data() + static_cast<size_t>(y) * width * 4,
                  first_row + static_cast<ptrdiff_t>(y) * pitch, static_cast<size_t>(width) * 4);
    }
  } else {
    const UINT32 target_width = degrees == 180 ? width : height;
    RotatePlane(first_row, pitch, width, height, pixels->data(), target_width * 4, 4, degrees);
  }
  unlock();
  for (size_t index = 3; index < pixels->size(); index += 4) (*pixels)[index] = 255;
  return S_OK;
}

bool IsUnsupportedSource(HRESULT result) {
  return result == MF_E_UNSUPPORTED_BYTESTREAM_TYPE || result == MF_E_UNSUPPORTED_SCHEME ||
         result == MF_E_INVALIDMEDIATYPE;
}

Outcome Run(const VideoJob& job, const std::wstring& output,
            const std::atomic<bool>& cancelled, const std::function<void(double)>& on_progress) {
  ComPtr<IMFAttributes> reader_attributes;
  NMC_RETURN_IF_FAILED(MFCreateAttributes(&reader_attributes, 2), "Creating reader attributes");
  // The source reader's own video processor scales the frame and converts the
  // frame rate to the type requested below.
  NMC_RETURN_IF_FAILED(
      reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE),
      "Enabling video processing");
  NMC_RETURN_IF_FAILED(reader_attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE),
                       "Enabling hardware decoding");
  ComPtr<IMFSourceReader> reader;
  if (const HRESULT result =
          MFCreateSourceReaderFromURL(job.source.c_str(), reader_attributes.Get(), &reader);
      FAILED(result)) {
    return Outcome::Of(IsUnsupportedSource(result) ? Status::kUnsupported : Status::kFailed,
                       DescribeHresult("Opening the source", result));
  }

  ComPtr<IMFMediaType> native_video;
  if (FAILED(reader->GetNativeMediaType(kVideoStream, 0, &native_video))) {
    return Outcome::Of(Status::kUnsupported, "The source has no video track");
  }
  UINT32 width = 0;
  UINT32 height = 0;
  NMC_RETURN_IF_FAILED(MFGetAttributeSize(native_video.Get(), MF_MT_FRAME_SIZE, &width, &height),
                       "Reading the frame size");
  if (width == 0 || height == 0) {
    return Outcome::Of(Status::kUnsupported, "The video track has no frame size");
  }
  if (IsHdr(native_video.Get())) {
    return Outcome::Of(Status::kUnsupported, "HDR video is not converted");
  }

  // MF_MT_VIDEO_ROTATION is how far the stored frame is turned
  // counter-clockwise, which equals the clockwise turn a player applies.
  const UINT32 source_rotation =
      NormalizeRotation(MFGetAttributeUINT32(native_video.Get(), MF_MT_VIDEO_ROTATION, 0));
  const bool source_quarter_turn = source_rotation == 90 || source_rotation == 270;
  const UINT32 rotation = TotalRotation(source_rotation, job.rotate_quarter_turns);
  const bool quarter_turn = rotation == 90 || rotation == 270;
  const UINT32 shown_width = quarter_turn ? height : width;
  const UINT32 shown_height = quarter_turn ? width : height;
  const double scale = FitScale(shown_width, shown_height, job.bounds);

  UINT32 rate_numerator = 0;
  UINT32 rate_denominator = 0;
  MFGetAttributeRatio(native_video.Get(), MF_MT_FRAME_RATE, &rate_numerator, &rate_denominator);
  if (rate_numerator == 0 || rate_denominator == 0) {
    rate_numerator = 30;
    rate_denominator = 1;
  }
  const LONGLONG source_frame_duration = kTicksPerSecond * rate_denominator / rate_numerator;
  LONGLONG frame_interval = 0;
  if (job.max_frame_rate && *job.max_frame_rate > 0) {
    const UINT32 limit = static_cast<UINT32>(std::min<int64_t>(*job.max_frame_rate, 1000));
    frame_interval = kTicksPerSecond / limit;
    if (static_cast<double>(rate_numerator) / rate_denominator > limit) {
      rate_numerator = limit;
      rate_denominator = 1;
    }
  }
  const LONGLONG duration = Duration(reader.Get());
  const std::optional<TrimRange> kept_range = ResolveTrim(job.start_ms, job.end_ms, duration);
  if (!kept_range) return Outcome::Of(Status::kUnsupported, "The trim range keeps nothing");
  const TrimRange trim = *kept_range;
  const bool trimmed = trim.start > 0 || trim.end != TrimRange::kOpenEnd;
  const LONGLONG kept_length = (trim.end != TrimRange::kOpenEnd ? trim.end : duration) - trim.start;

  NMC_RETURN_IF_FAILED(reader->SetStreamSelection(kAllStreams, FALSE), "Selecting streams");
  NMC_RETURN_IF_FAILED(reader->SetStreamSelection(kVideoStream, TRUE), "Selecting the video");
  const int audio_streams = job.include_audio ? CountAudioStreams(reader.Get()) : 0;
  if (audio_streams > 1) {
    return Outcome::Of(Status::kUnsupported, "Several audio tracks cannot be kept");
  }
  const bool has_audio = audio_streams == 1;
  ComPtr<IMFMediaType> decoded_audio;
  if (has_audio) {
    NMC_RETURN_IF_FAILED(reader->SetStreamSelection(kAudioStream, TRUE), "Selecting the audio");
    ComPtr<IMFMediaType> pcm;
    NMC_RETURN_IF_FAILED(MFCreateMediaType(&pcm), "Creating the PCM type");
    NMC_RETURN_IF_FAILED(pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), "Creating the PCM type");
    NMC_RETURN_IF_FAILED(pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM), "Creating the PCM type");
    NMC_RETURN_IF_FAILED(pcm->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16), "Creating the PCM type");
    if (const HRESULT result = reader->SetCurrentMediaType(kAudioStream, nullptr, pcm.Get());
        FAILED(result)) {
      return Outcome::Of(Status::kUnsupported,
                         DescribeHresult("Finding a decoder for the audio track", result));
    }
    NMC_RETURN_IF_FAILED(reader->GetCurrentMediaType(kAudioStream, &decoded_audio),
                         "Reading the decoded audio type");
  }
  const UINT32 audio_channels =
      has_audio ? MFGetAttributeUINT32(decoded_audio.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0) : 0;
  const UINT32 audio_sample_rate =
      has_audio ? MFGetAttributeUINT32(decoded_audio.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0) : 0;
  const UINT32 audio_block_alignment =
      has_audio ? MFGetAttributeUINT32(decoded_audio.Get(), MF_MT_AUDIO_BLOCK_ALIGNMENT,
                                       audio_channels * 2)
                : 0;

  ComPtr<IMFAttributes> writer_attributes;
  NMC_RETURN_IF_FAILED(MFCreateAttributes(&writer_attributes, 2), "Creating writer attributes");
  NMC_RETURN_IF_FAILED(writer_attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE),
                       "Enabling hardware encoding");
  NMC_RETURN_IF_FAILED(
      writer_attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4),
      "Choosing the MP4 container");
  const UINT32 bitrate =
      static_cast<UINT32>(std::clamp<int64_t>(job.video_bitrate, 10000, 0xFFFFFFFFLL));

  UINT32 out_width = 0;
  UINT32 out_height = 0;
  UINT32 decode_width = 0;
  UINT32 decode_height = 0;
  UINT32 frame_width = 0;
  UINT32 frame_height = 0;
  UINT32 pixel_rotation = rotation;
  LONG decoded_stride = 0;
  ComPtr<IMFSinkWriter> writer;
  DWORD video_index = 0;
  // Sets up decoding and encoding for frame sides that are multiples of
  // `alignment`. Returns a compressed Outcome when everything was accepted.
  auto set_up_video = [&](UINT32 alignment, bool hevc) -> Outcome {
    out_width = AlignDown(shown_width * scale, alignment);
    out_height = AlignDown(shown_height * scale, alignment);
    decode_width = quarter_turn ? out_height : out_width;
    decode_height = quarter_turn ? out_width : out_height;
    writer.Reset();

    ComPtr<IMFMediaType> decoded_video;
    NMC_RETURN_IF_FAILED(CreateVideoType(MFVideoFormat_NV12, decode_width, decode_height,
                                         rate_numerator, rate_denominator, &decoded_video),
                         "Creating the decoded video type");
    HRESULT decode_result = E_FAIL;
    if (source_rotation != 0) {
      // Marking the requested frames as still rotated keeps the video
      // processor from turning them on its own, so the rotation is applied
      // exactly once.
      ComPtr<IMFMediaType> still_rotated;
      if (SUCCEEDED(MFCreateMediaType(&still_rotated)) &&
          SUCCEEDED(decoded_video->CopyAllItems(still_rotated.Get())) &&
          SUCCEEDED(still_rotated->SetUINT32(MF_MT_VIDEO_ROTATION, source_rotation))) {
        decode_result = reader->SetCurrentMediaType(kVideoStream, nullptr, still_rotated.Get());
      }
    }
    if (FAILED(decode_result)) {
      decode_result = reader->SetCurrentMediaType(kVideoStream, nullptr, decoded_video.Get());
    }
    if (FAILED(decode_result)) {
      return Outcome::Of(Status::kUnsupported,
                         DescribeHresult("Finding a decoder for the video track", decode_result));
    }
    ComPtr<IMFMediaType> current_video;
    NMC_RETURN_IF_FAILED(reader->GetCurrentMediaType(kVideoStream, &current_video),
                         "Reading the decoded video type");
    NMC_RETURN_IF_FAILED(
        MFGetAttributeSize(current_video.Get(), MF_MT_FRAME_SIZE, &frame_width, &frame_height),
        "Reading the decoded frame size");
    pixel_rotation = rotation;
    bool processor_rotated = false;
    if (frame_width == decode_width && frame_height == decode_height) {
      // Frames arrive as stored; they are turned while writing.
    } else if (source_quarter_turn && frame_width == decode_height &&
               frame_height == decode_width) {
      // The video processor applied the source rotation itself; only the
      // requested quarter turns are left.
      processor_rotated = true;
      pixel_rotation = NormalizeRotation(rotation + 360 - source_rotation);
    } else {
      return Outcome::Of(Status::kFailed, "The decoder produced an unexpected frame size");
    }
    decoded_stride = static_cast<LONG>(
        MFGetAttributeUINT32(current_video.Get(), MF_MT_DEFAULT_STRIDE, frame_width));

    NMC_RETURN_IF_FAILED(MFCreateSinkWriterFromURL(output.c_str(), nullptr,
                                                   writer_attributes.Get(), &writer),
                         "Creating the output file");
    ComPtr<IMFMediaType> encoded;
    NMC_RETURN_IF_FAILED(CreateVideoType(hevc ? kHevcFormat : MFVideoFormat_H264, out_width,
                                         out_height, rate_numerator, rate_denominator, &encoded),
                         "Creating the output video type");
    NMC_RETURN_IF_FAILED(encoded->SetUINT32(MF_MT_AVG_BITRATE, bitrate), "Setting the bitrate");
    if (!hevc) {
      NMC_RETURN_IF_FAILED(
          encoded->SetUINT32(MF_MT_MPEG2_PROFILE, static_cast<UINT32>(eAVEncH264VProfile_Main)),
          "Setting the H.264 profile");
    }
    NMC_RETURN_IF_FAILED(writer->AddStream(encoded.Get(), &video_index), "Adding the video stream");
    ComPtr<IMFMediaType> encoder_input = decoded_video;
    if (pixel_rotation != 0) {
      NMC_RETURN_IF_FAILED(CreateVideoType(MFVideoFormat_NV12, out_width, out_height,
                                           rate_numerator, rate_denominator, &encoder_input),
                           "Creating the rotated video type");
      NMC_RETURN_IF_FAILED(encoder_input->SetUINT32(MF_MT_DEFAULT_STRIDE, out_width),
                           "Setting the rotated stride");
    } else if (processor_rotated) {
      // The video processor turned the frames itself, so they arrive upright
      // in the shown size and the encoder takes the reader's type as it is.
      NMC_RETURN_IF_FAILED(MFCreateMediaType(&encoder_input), "Creating the encoder input type");
      NMC_RETURN_IF_FAILED(current_video->CopyAllItems(encoder_input.Get()),
                           "Creating the encoder input type");
      NMC_RETURN_IF_FAILED(encoder_input->DeleteItem(MF_MT_VIDEO_ROTATION),
                           "Creating the encoder input type");
    }
    // A keyframe about every two seconds.
    const UINT32 gop_frames = std::max<UINT32>(
        1, static_cast<UINT32>(std::lround(2.0 * rate_numerator / rate_denominator)));
    // An encoder that rejects a rate control mode gets the next one, and in
    // the end its defaults, so the settings never cost the encoder itself.
    HRESULT input_result = E_FAIL;
    for (const eAVEncCommonRateControlMode mode :
         {eAVEncCommonRateControlMode_PeakConstrainedVBR, eAVEncCommonRateControlMode_CBR}) {
      ComPtr<IMFAttributes> parameters;
      if (FAILED(CreateEncodingParameters(mode, bitrate, gop_frames, &parameters))) continue;
      input_result = writer->SetInputMediaType(video_index, encoder_input.Get(), parameters.Get());
      if (SUCCEEDED(input_result)) break;
    }
    if (FAILED(input_result)) {
      input_result = writer->SetInputMediaType(video_index, encoder_input.Get(), nullptr);
    }
    if (FAILED(input_result)) {
      return Outcome::Of(Status::kUnsupported,
                         DescribeHresult(hevc ? "Finding an HEVC encoder" : "Finding an H.264 encoder",
                                         input_result));
    }
    return Outcome::Compressed(out_width, out_height);
  };

  DWORD audio_index = 0;
  auto add_audio = [&]() -> Outcome {
    ComPtr<IMFMediaType> aac;
    NMC_RETURN_IF_FAILED(MFCreateMediaType(&aac), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_sample_rate),
                         "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, audio_channels),
                         "Creating the AAC type");
    NMC_RETURN_IF_FAILED(
        aac->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, AacBytesPerSecond(job.audio_bitrate)),
        "Creating the AAC type");
    // The AAC encoder takes only some sample rates and channel layouts.
    if (const HRESULT result = writer->AddStream(aac.Get(), &audio_index); FAILED(result)) {
      return Outcome::Of(Status::kUnsupported, DescribeHresult("Adding the AAC stream", result));
    }
    if (const HRESULT result = writer->SetInputMediaType(audio_index, decoded_audio.Get(), nullptr);
        FAILED(result)) {
      return Outcome::Of(Status::kUnsupported,
                         DescribeHresult("Encoding this audio to AAC", result));
    }
    return Outcome::Of(Status::kCompressed);
  };

  // The Microsoft H.264 encoder takes any even size and pads it internally.
  // Some hardware encoders accept only multiples of 16; that is the fallback,
  // since it squeezes the picture a little.
  auto set_up_writer = [&](bool hevc) -> Outcome {
    Outcome video_setup = set_up_video(2, hevc);
    if (video_setup.status != Status::kCompressed &&
        (out_width % 16 != 0 || out_height % 16 != 0)) {
      video_setup = set_up_video(16, hevc);
    }
    if (video_setup.status != Status::kCompressed || !has_audio) return video_setup;
    const Outcome audio_setup = add_audio();
    return audio_setup.status == Status::kCompressed ? video_setup : audio_setup;
  };

  bool writes_hevc = job.prefer_hevc && HasHevcEncoder();
  if (writes_hevc) {
    // A hardware HEVC encoder can accept the media types and still refuse to
    // start, so H.264 remains the fallback until writing has begun.
    writes_hevc =
        set_up_writer(true).status == Status::kCompressed && SUCCEEDED(writer->BeginWriting());
  }
  if (!writes_hevc) {
    const Outcome writer_setup = set_up_writer(false);
    if (writer_setup.status != Status::kCompressed) return writer_setup;
    NMC_RETURN_IF_FAILED(writer->BeginWriting(), "Starting the encoder");
  }

  auto stream_bytes = [&](DWORD stream) -> int64_t {
    MF_SINK_WRITER_STATISTICS statistics = {};
    statistics.cb = static_cast<DWORD>(sizeof(statistics));
    if (FAILED(writer->GetStatistics(stream, &statistics))) return 0;
    return static_cast<int64_t>(statistics.qwByteCountProcessed);
  };
  // The MP4 sink may hold encoded data before it reaches the file, so the
  // sink statistics are checked along with the file size.
  auto written_bytes = [&]() {
    const int64_t total = stream_bytes(video_index) + (has_audio ? stream_bytes(audio_index) : 0);
    return std::max(total, FileSize(output));
  };

  int written_frames = 0;
  auto write_frame = [&](IMFSample* frame) -> HRESULT {
    ++written_frames;
    if (pixel_rotation == 0) return writer->WriteSample(video_index, frame);
    ComPtr<IMFSample> rotated;
    NMC_RETURN_HR_IF_FAILED(RotateNv12Sample(frame, frame_width, frame_height, decoded_stride,
                                             pixel_rotation, &rotated));
    return writer->WriteSample(video_index, rotated.Get());
  };

  // With a frame-rate cap the last kept frame waits until the next kept frame
  // or the end of the stream is known. Only when frames between them were
  // thinned out does its duration grow to cover them; otherwise the source
  // duration stays, and the final frame still reaches the end of the stream.
  ComPtr<IMFSample> held_frame;
  LONGLONG held_time = 0;
  LONGLONG held_end = 0;
  bool thinned_after_held = false;
  auto write_held_frame = [&](LONGLONG end) -> HRESULT {
    if (!held_frame) return S_OK;
    if (thinned_after_held) {
      NMC_RETURN_HR_IF_FAILED(held_frame->SetSampleDuration(end - held_time));
    }
    const HRESULT result = write_frame(held_frame.Get());
    held_frame.Reset();
    thinned_after_held = false;
    return result;
  };

  if (trim.start > 0) SeekTo(reader.Get(), trim.start);
  bool video_done = false;
  bool audio_done = !has_audio;
  bool video_started = false;
  LONGLONG video_time = 0;
  LONGLONG audio_time = 0;
  bool kept_any_frame = false;
  LONGLONG next_frame_time = 0;
  const LONGLONG frame_tolerance = frame_interval / 4;
  int written_samples = 0;
  double reported = -1.0;
  auto reported_at = std::chrono::steady_clock::now();
  while (!video_done || !audio_done) {
    if (cancelled.load()) return Outcome::Of(Status::kCancelled);
    // Reading whichever track is behind interleaves audio and video in the file.
    const bool is_video = !video_done && (audio_done || video_time <= audio_time);
    const DWORD source_stream = is_video ? kVideoStream : kAudioStream;
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    NMC_RETURN_IF_FAILED(
        reader->ReadSample(source_stream, 0, nullptr, &flags, &timestamp, &sample),
        "Reading a sample");
    if (flags & MF_SOURCE_READERF_ERROR) {
      return Outcome::Of(Status::kFailed, "The source reader reported a stream error");
    }
    const DWORD stream = is_video ? video_index : audio_index;
    bool wrote = false;
    bool ended = (flags & MF_SOURCE_READERF_ENDOFSTREAM) != 0;
    if (sample && timestamp >= trim.end) {
      // Deselecting a finished track keeps the reader from queueing its
      // samples while the other track catches up.
      sample.Reset();
      ended = true;
      reader->SetStreamSelection(source_stream, FALSE);
    }
    if ((flags & MF_SOURCE_READERF_STREAMTICK) &&
        (!trimmed || (timestamp >= trim.start && timestamp < trim.end))) {
      if (is_video && held_frame) {
        NMC_RETURN_IF_FAILED(write_held_frame(held_end), "Writing a frame");
        wrote = true;
      }
      NMC_RETURN_IF_FAILED(writer->SendStreamTick(stream, timestamp - trim.start),
                           "Writing a stream gap");
    }
    if (ended) {
      if (is_video) {
        video_done = true;
      } else {
        audio_done = true;
      }
    }
    if (is_video) {
      video_time = timestamp;
    } else {
      audio_time = timestamp;
    }

    if (sample && is_video && trim.start > 0) {
      LONGLONG sample_duration = 0;
      if (FAILED(sample->GetSampleDuration(&sample_duration)) || sample_duration <= 0) {
        sample_duration = source_frame_duration;
      }
      const LONGLONG frame_end = timestamp + sample_duration;
      if (frame_end <= trim.start) {
        sample.Reset();
      } else {
        // The first kept frame covers the output from its start, also when it
        // began before the trim start or the seek landed a little after it.
        const LONGLONG begin = video_started ? timestamp - trim.start : 0;
        video_started = true;
        NMC_RETURN_IF_FAILED(sample->SetSampleTime(begin), "Trimming the video");
        NMC_RETURN_IF_FAILED(sample->SetSampleDuration(frame_end - trim.start - begin),
                             "Trimming the video");
        timestamp = trim.start + begin;
      }
    }

    if (sample && !is_video) {
      ComPtr<IMFSample> kept = sample;
      if (trimmed) {
        NMC_RETURN_IF_FAILED(CropAudioSample(sample.Get(), timestamp, trim, audio_block_alignment,
                                             audio_sample_rate, &kept),
                             "Trimming the audio");
      }
      if (kept) {
        NMC_RETURN_IF_FAILED(writer->WriteSample(stream, kept.Get()), "Writing a sample");
        wrote = true;
      }
    } else if (sample && frame_interval == 0) {
      NMC_RETURN_IF_FAILED(write_frame(sample.Get()), "Writing a frame");
      wrote = true;
    } else if (sample) {
      LONGLONG sample_duration = 0;
      if (FAILED(sample->GetSampleDuration(&sample_duration)) || sample_duration <= 0) {
        sample_duration = source_frame_duration;
      }
      if (kept_any_frame && timestamp < next_frame_time - frame_tolerance) {
        held_end = std::max(held_end, timestamp + sample_duration);
        thinned_after_held = held_frame.Get() != nullptr;
      } else {
        next_frame_time = kept_any_frame
                              ? std::max(next_frame_time + frame_interval,
                                         timestamp + frame_interval - frame_tolerance)
                              : timestamp + frame_interval;
        kept_any_frame = true;
        if (held_frame) {
          NMC_RETURN_IF_FAILED(write_held_frame(timestamp), "Writing a frame");
          wrote = true;
        }
        held_frame = sample;
        held_time = timestamp;
        held_end = timestamp + sample_duration;
      }
    }
    if (is_video && video_done && held_frame) {
      NMC_RETURN_IF_FAILED(write_held_frame(held_end), "Writing a frame");
      wrote = true;
    }
    if (!wrote) continue;

    ++written_samples;
    if (job.max_bytes && written_samples % kSizeCheckInterval == 0 &&
        written_bytes() > *job.max_bytes) {
      return Outcome::Of(Status::kTooLarge);
    }
    if (!is_video || kept_length <= 0) continue;
    const double fraction = std::clamp(
        static_cast<double>(timestamp - trim.start) / static_cast<double>(kept_length), 0.0, 1.0);
    const auto now = std::chrono::steady_clock::now();
    if (fraction >= reported + 0.01 || (fraction > reported && now - reported_at >= kProgressInterval)) {
      reported = fraction;
      reported_at = now;
      on_progress(fraction);
    }
  }
  if (trimmed && written_frames == 0) {
    return Outcome::Of(Status::kUnsupported, "The trim range keeps no video frames");
  }
  NMC_RETURN_IF_FAILED(writer->Finalize(), "Finishing the output");
  Outcome outcome = Outcome::Compressed(out_width, out_height);
  outcome.video_codec = writes_hevc ? "video/hevc" : "video/avc";
  return outcome;
}

Outcome RunThumbnail(const ThumbnailJob& job, const std::wstring& output) {
  ComPtr<IMFAttributes> reader_attributes;
  NMC_RETURN_IF_FAILED(MFCreateAttributes(&reader_attributes, 1), "Creating reader attributes");
  // The source reader's video processor converts the decoded frame to RGB32,
  // which WIC takes as it is.
  NMC_RETURN_IF_FAILED(
      reader_attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE),
      "Enabling video processing");
  ComPtr<IMFSourceReader> reader;
  if (const HRESULT result =
          MFCreateSourceReaderFromURL(job.source.c_str(), reader_attributes.Get(), &reader);
      FAILED(result)) {
    return Outcome::Of(IsUnsupportedSource(result) ? Status::kUnsupported : Status::kFailed,
                       DescribeHresult("Opening the source", result));
  }
  ComPtr<IMFMediaType> native_video;
  if (FAILED(reader->GetNativeMediaType(kVideoStream, 0, &native_video))) {
    return Outcome::Of(Status::kUnsupported, "The source has no video track");
  }
  UINT32 width = 0;
  UINT32 height = 0;
  NMC_RETURN_IF_FAILED(MFGetAttributeSize(native_video.Get(), MF_MT_FRAME_SIZE, &width, &height),
                       "Reading the frame size");
  if (width == 0 || height == 0) {
    return Outcome::Of(Status::kUnsupported, "The video track has no frame size");
  }
  const UINT32 rotation =
      NormalizeRotation(MFGetAttributeUINT32(native_video.Get(), MF_MT_VIDEO_ROTATION, 0));
  const bool quarter_turn = rotation == 90 || rotation == 270;
  UINT32 rate_numerator = 0;
  UINT32 rate_denominator = 0;
  MFGetAttributeRatio(native_video.Get(), MF_MT_FRAME_RATE, &rate_numerator, &rate_denominator);
  if (rate_numerator == 0 || rate_denominator == 0) {
    rate_numerator = 30;
    rate_denominator = 1;
  }

  NMC_RETURN_IF_FAILED(reader->SetStreamSelection(kAllStreams, FALSE), "Selecting streams");
  NMC_RETURN_IF_FAILED(reader->SetStreamSelection(kVideoStream, TRUE), "Selecting the video");
  ComPtr<IMFMediaType> rgb;
  NMC_RETURN_IF_FAILED(
      CreateVideoType(MFVideoFormat_RGB32, width, height, rate_numerator, rate_denominator, &rgb),
      "Creating the RGB type");
  HRESULT decode_result = E_FAIL;
  if (rotation != 0) {
    // As for transcoding: frames marked as still rotated are not turned by the
    // video processor, so the rotation is applied exactly once.
    ComPtr<IMFMediaType> still_rotated;
    if (SUCCEEDED(MFCreateMediaType(&still_rotated)) &&
        SUCCEEDED(rgb->CopyAllItems(still_rotated.Get())) &&
        SUCCEEDED(still_rotated->SetUINT32(MF_MT_VIDEO_ROTATION, rotation))) {
      decode_result = reader->SetCurrentMediaType(kVideoStream, nullptr, still_rotated.Get());
    }
  }
  if (FAILED(decode_result)) {
    decode_result = reader->SetCurrentMediaType(kVideoStream, nullptr, rgb.Get());
  }
  if (FAILED(decode_result)) {
    return Outcome::Of(Status::kUnsupported,
                       DescribeHresult("Finding a decoder for the video track", decode_result));
  }
  ComPtr<IMFMediaType> current_video;
  NMC_RETURN_IF_FAILED(reader->GetCurrentMediaType(kVideoStream, &current_video),
                       "Reading the decoded video type");
  UINT32 frame_width = 0;
  UINT32 frame_height = 0;
  NMC_RETURN_IF_FAILED(
      MFGetAttributeSize(current_video.Get(), MF_MT_FRAME_SIZE, &frame_width, &frame_height),
      "Reading the decoded frame size");
  UINT32 pixel_rotation = rotation;
  if (frame_width == width && frame_height == height) {
    // Frames arrive as stored and are turned after copying.
  } else if (quarter_turn && frame_width == height && frame_height == width) {
    pixel_rotation = 0;
  } else {
    return Outcome::Of(Status::kFailed, "The decoder produced an unexpected frame size");
  }
  const LONG stride =
      static_cast<LONG>(MFGetAttributeUINT32(current_video.Get(), MF_MT_DEFAULT_STRIDE, 0));

  const LONGLONG frame_duration = kTicksPerSecond * rate_denominator / rate_numerator;
  const LONGLONG target = ThumbnailTime(job.position_ms, Duration(reader.Get()), frame_duration);
  if (target > 0) SeekTo(reader.Get(), target);
  // The frame shown at the target is the last one starting at or before it;
  // the first decoded frame stands in when the seek landed after it.
  ComPtr<IMFSample> chosen;
  for (;;) {
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    NMC_RETURN_IF_FAILED(
        reader->ReadSample(kVideoStream, 0, nullptr, &flags, &timestamp, &sample),
        "Reading a frame");
    if (flags & MF_SOURCE_READERF_ERROR) {
      return Outcome::Of(Status::kFailed, "The source reader reported a stream error");
    }
    if (sample) {
      if (timestamp > target && chosen) break;
      chosen = sample;
      if (timestamp >= target) break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
  }
  if (!chosen) return Outcome::Of(Status::kFailed, "The video track has no frames");

  std::vector<uint8_t> pixels;
  NMC_RETURN_IF_FAILED(
      CopyRgb32Frame(chosen.Get(), frame_width, frame_height, stride, pixel_rotation, &pixels),
      "Copying the frame");
  chosen.Reset();
  reader.Reset();
  const bool turned = pixel_rotation == 90 || pixel_rotation == 270;
  ImageJob image;
  image.bounds = job.bounds;
  image.png = job.png;
  image.quality = job.quality;
  return WriteFrameImage(pixels, turned ? frame_height : frame_width,
                         turned ? frame_width : frame_height, image, output);
}

}  // namespace

Outcome TranscodeVideo(const VideoJob& job, const std::atomic<bool>& cancelled,
                       const std::function<void(double)>& on_progress) {
  if (cancelled.load()) return Outcome::Of(Status::kCancelled);
  if (IsDirectory(job.destination)) {
    return Outcome::Of(Status::kFailed, "The destination is a directory");
  }
  if (!IsMediaFoundationAvailable()) {
    return Outcome::Of(Status::kUnsupported, "Media Foundation is not installed");
  }
  // Unwinding releases Media Foundation and deletes the temporary file, so an
  // exception ends only this operation instead of the app.
  try {
    PendingOutput output(job.destination);
    if (!output.reserved()) {
      return Outcome::Of(Status::kFailed, "Cannot create a file next to the destination");
    }
    Outcome outcome;
    {
      MediaFoundationScope scope;
      if (!scope.started()) {
        return Outcome::Of(Status::kUnsupported, "Media Foundation failed to start");
      }
      outcome = Run(job, output.path(), cancelled, on_progress);
    }
    if (outcome.status != Status::kCompressed) return outcome;
    outcome.size_bytes = FileSize(output.path());
    if (outcome.size_bytes <= 0) return Outcome::Of(Status::kFailed, "The encoder wrote no output");
    if (job.max_bytes && outcome.size_bytes > *job.max_bytes) return Outcome::Of(Status::kTooLarge);
    if (!output.Commit()) {
      return Outcome::Of(Status::kFailed,
                         DescribeHresult("Replacing the destination",
                                         HRESULT_FROM_WIN32(GetLastError())));
    }
    // The destination is already replaced, so a failed progress delivery must
    // not turn the result into a failure.
    try {
      on_progress(1.0);
    } catch (...) {
    }
    return outcome;
  } catch (...) {
    return Outcome::Of(Status::kFailed, kUnexpectedError);
  }
}

std::optional<VideoInfo> ProbeVideoFile(const std::wstring& source) {
  if (!IsMediaFoundationAvailable()) return std::nullopt;
  MediaFoundationScope scope;
  if (!scope.started()) return std::nullopt;
  ComPtr<IMFSourceReader> reader;
  if (FAILED(MFCreateSourceReaderFromURL(source.c_str(), nullptr, &reader))) return std::nullopt;
  ComPtr<IMFMediaType> video;
  if (FAILED(reader->GetNativeMediaType(kVideoStream, 0, &video))) return std::nullopt;
  UINT32 width = 0;
  UINT32 height = 0;
  if (FAILED(MFGetAttributeSize(video.Get(), MF_MT_FRAME_SIZE, &width, &height)) || width == 0 ||
      height == 0) {
    return std::nullopt;
  }

  VideoInfo info;
  const UINT32 rotation =
      NormalizeRotation(MFGetAttributeUINT32(video.Get(), MF_MT_VIDEO_ROTATION, 0));
  const bool quarter_turn = rotation == 90 || rotation == 270;
  info.width = quarter_turn ? height : width;
  info.height = quarter_turn ? width : height;
  info.rotation_degrees = rotation;
  info.is_hdr = IsHdr(video.Get());
  info.duration_ms = Duration(reader.Get()) / 10000;
  GUID video_subtype = GUID_NULL;
  if (SUCCEEDED(video->GetGUID(MF_MT_SUBTYPE, &video_subtype))) {
    info.video_codec = VideoCodecName(video_subtype);
  }
  ComPtr<IMFMediaType> audio;
  if (SUCCEEDED(reader->GetNativeMediaType(kAudioStream, 0, &audio))) {
    info.has_audio = true;
    GUID audio_subtype = GUID_NULL;
    if (SUCCEEDED(audio->GetGUID(MF_MT_SUBTYPE, &audio_subtype))) {
      info.audio_codec = AudioCodecName(audio_subtype);
    }
  }
  UINT32 rate_numerator = 0;
  UINT32 rate_denominator = 0;
  if (SUCCEEDED(MFGetAttributeRatio(video.Get(), MF_MT_FRAME_RATE, &rate_numerator,
                                    &rate_denominator)) &&
      rate_numerator > 0 && rate_denominator > 0) {
    info.frame_rate = static_cast<double>(rate_numerator) / rate_denominator;
  }
  const int64_t size = FileSize(source);
  if (size > 0 && info.duration_ms > 0) info.bitrate = size * 8 * 1000 / info.duration_ms;
  return info;
}

Outcome SaveVideoFrame(const ThumbnailJob& job) {
  if (IsDirectory(job.destination)) {
    return Outcome::Of(Status::kFailed, "The destination is a directory");
  }
  if (!IsMediaFoundationAvailable()) {
    return Outcome::Of(Status::kUnsupported, "Media Foundation is not installed");
  }
  try {
    PendingOutput output(job.destination);
    if (!output.reserved()) {
      return Outcome::Of(Status::kFailed, "Cannot create a file next to the destination");
    }
    Outcome outcome;
    {
      MediaFoundationScope scope;
      if (!scope.started()) {
        return Outcome::Of(Status::kUnsupported, "Media Foundation failed to start");
      }
      outcome = RunThumbnail(job, output.path());
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

std::optional<TrimRange> ResolveTrim(std::optional<int64_t> start_ms,
                                     std::optional<int64_t> end_ms, int64_t duration) {
  constexpr int64_t kMaxMs = INT64_MAX / kTicksPerMillisecond - 1;
  TrimRange range;
  if (start_ms && *start_ms > 0) range.start = std::min(*start_ms, kMaxMs) * kTicksPerMillisecond;
  if (end_ms) range.end = std::clamp<int64_t>(*end_ms, 0, kMaxMs) * kTicksPerMillisecond;
  if (duration > 0 && range.end >= duration) range.end = TrimRange::kOpenEnd;
  if (range.end <= range.start) return std::nullopt;
  if (duration > 0 && range.start >= duration) return std::nullopt;
  return range;
}

PcmCrop CropPcm(int64_t time, uint64_t frames, uint32_t sample_rate, const TrimRange& range) {
  // Frames from the start of the buffer up to `moment`, rounded to the
  // nearest frame and limited to the buffer.
  auto frames_before = [&](int64_t moment) -> uint64_t {
    if (moment == TrimRange::kOpenEnd) return frames;
    if (moment <= time || sample_rate == 0) return 0;
    const double offset =
        static_cast<double>(moment - time) * sample_rate / static_cast<double>(kTicksPerSecond);
    if (offset >= static_cast<double>(frames)) return frames;
    return static_cast<uint64_t>(std::llround(offset));
  };
  PcmCrop crop;
  crop.skip_frames = frames_before(range.start);
  const uint64_t end_frames = frames_before(range.end);
  crop.keep_frames = end_frames > crop.skip_frames ? end_frames - crop.skip_frames : 0;
  return crop;
}

uint32_t TotalRotation(uint32_t source_degrees, int64_t quarter_turns) {
  const int64_t turns = ((quarter_turns % 4) + 4) % 4;
  return static_cast<uint32_t>((source_degrees % 360 + turns * 90) % 360);
}

uint32_t AacBytesPerSecond(int64_t bitrate) {
  constexpr uint32_t kAllowed[] = {12000, 16000, 20000, 24000};
  const int64_t wanted = bitrate / 8;
  uint32_t best = kAllowed[0];
  for (const uint32_t allowed : kAllowed) {
    if (std::llabs(wanted - allowed) < std::llabs(wanted - best)) best = allowed;
  }
  return best;
}

int64_t ThumbnailTime(int64_t position_ms, int64_t duration, int64_t frame_duration) {
  constexpr int64_t kMaxMs = INT64_MAX / kTicksPerMillisecond - 1;
  int64_t time = std::clamp<int64_t>(position_ms, 0, kMaxMs) * kTicksPerMillisecond;
  if (duration > 0) time = std::min(time, std::max<int64_t>(0, duration - frame_duration));
  return time;
}

}  // namespace native_media_compressor
