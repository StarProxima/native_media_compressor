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
#include <cstring>

namespace native_media_compressor {
namespace {

using Microsoft::WRL::ComPtr;

constexpr DWORD kVideoStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
constexpr DWORD kAudioStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
constexpr DWORD kAllStreams = static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS);
constexpr DWORD kMediaSource = static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE);
constexpr LONGLONG kTicksPerSecond = 10000000;
constexpr UINT32 kAudioBytesPerSecond = 16000;  // 128 kbit/s
constexpr int kSizeCheckInterval = 10;
constexpr auto kProgressInterval = std::chrono::milliseconds(100);

constexpr GUID kDolbyAc3 = {0xe06d802c, 0xdb46, 0x11cf, {0xb4, 0xd1, 0x00, 0x80, 0x5f, 0x6c, 0xbb, 0xea}};
constexpr GUID kDolbyDigitalPlus = {0xa7fb87af, 0x2d02, 0x42fb, {0xa4, 0xd4, 0x05, 0xcd, 0x93, 0x84, 0x3b, 0xdd}};

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

// Hardware H.264 encoders reliably accept only frame sizes that are
// multiples of 16.
UINT32 AlignDown16(double value) {
  return std::max<UINT32>(16, static_cast<UINT32>(value) / 16 * 16);
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
  const UINT32 rotation =
      NormalizeRotation(MFGetAttributeUINT32(native_video.Get(), MF_MT_VIDEO_ROTATION, 0));
  const bool quarter_turn = rotation == 90 || rotation == 270;
  const UINT32 shown_width = quarter_turn ? height : width;
  const UINT32 shown_height = quarter_turn ? width : height;
  const double scale = FitScale(shown_width, shown_height, job.bounds);
  const UINT32 out_width = AlignDown16(shown_width * scale);
  const UINT32 out_height = AlignDown16(shown_height * scale);
  const UINT32 decode_width = quarter_turn ? out_height : out_width;
  const UINT32 decode_height = quarter_turn ? out_width : out_height;

  UINT32 rate_numerator = 0;
  UINT32 rate_denominator = 0;
  MFGetAttributeRatio(native_video.Get(), MF_MT_FRAME_RATE, &rate_numerator, &rate_denominator);
  if (rate_numerator == 0 || rate_denominator == 0) {
    rate_numerator = 30;
    rate_denominator = 1;
  }
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

  NMC_RETURN_IF_FAILED(reader->SetStreamSelection(kAllStreams, FALSE), "Selecting streams");
  NMC_RETURN_IF_FAILED(reader->SetStreamSelection(kVideoStream, TRUE), "Selecting the video");
  ComPtr<IMFMediaType> decoded_video;
  NMC_RETURN_IF_FAILED(CreateVideoType(MFVideoFormat_NV12, decode_width, decode_height,
                                       rate_numerator, rate_denominator, &decoded_video),
                       "Creating the decoded video type");
  HRESULT decode_result = E_FAIL;
  if (rotation != 0) {
    // Marking the requested frames as still rotated keeps the video processor
    // from turning them on its own, so the rotation is applied exactly once.
    ComPtr<IMFMediaType> still_rotated;
    if (SUCCEEDED(MFCreateMediaType(&still_rotated)) &&
        SUCCEEDED(decoded_video->CopyAllItems(still_rotated.Get())) &&
        SUCCEEDED(still_rotated->SetUINT32(MF_MT_VIDEO_ROTATION, rotation))) {
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
  UINT32 current_width = 0;
  UINT32 current_height = 0;
  NMC_RETURN_IF_FAILED(
      MFGetAttributeSize(current_video.Get(), MF_MT_FRAME_SIZE, &current_width, &current_height),
      "Reading the decoded frame size");
  UINT32 pixel_rotation = rotation;
  if (current_width == decode_width && current_height == decode_height) {
    // Frames arrive as stored; they are turned below.
  } else if (quarter_turn && current_width == out_width && current_height == out_height) {
    pixel_rotation = 0;
  } else {
    return Outcome::Of(Status::kFailed, "The decoder produced an unexpected frame size");
  }
  const LONG decoded_stride = static_cast<LONG>(
      MFGetAttributeUINT32(current_video.Get(), MF_MT_DEFAULT_STRIDE, decode_width));

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

  ComPtr<IMFAttributes> writer_attributes;
  NMC_RETURN_IF_FAILED(MFCreateAttributes(&writer_attributes, 2), "Creating writer attributes");
  NMC_RETURN_IF_FAILED(writer_attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE),
                       "Enabling hardware encoding");
  NMC_RETURN_IF_FAILED(
      writer_attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4),
      "Choosing the MP4 container");
  ComPtr<IMFSinkWriter> writer;
  NMC_RETURN_IF_FAILED(MFCreateSinkWriterFromURL(output.c_str(), nullptr,
                                                 writer_attributes.Get(), &writer),
                       "Creating the output file");

  ComPtr<IMFMediaType> h264;
  NMC_RETURN_IF_FAILED(CreateVideoType(MFVideoFormat_H264, out_width, out_height, rate_numerator,
                                       rate_denominator, &h264),
                       "Creating the H.264 type");
  const UINT32 bitrate =
      static_cast<UINT32>(std::clamp<int64_t>(job.video_bitrate, 10000, 0xFFFFFFFFLL));
  NMC_RETURN_IF_FAILED(h264->SetUINT32(MF_MT_AVG_BITRATE, bitrate), "Setting the bitrate");
  NMC_RETURN_IF_FAILED(
      h264->SetUINT32(MF_MT_MPEG2_PROFILE, static_cast<UINT32>(eAVEncH264VProfile_Main)),
                       "Setting the H.264 profile");
  DWORD video_index = 0;
  NMC_RETURN_IF_FAILED(writer->AddStream(h264.Get(), &video_index), "Adding the video stream");
  ComPtr<IMFMediaType> encoder_input = decoded_video;
  if (pixel_rotation != 0) {
    NMC_RETURN_IF_FAILED(CreateVideoType(MFVideoFormat_NV12, out_width, out_height,
                                         rate_numerator, rate_denominator, &encoder_input),
                         "Creating the rotated video type");
    NMC_RETURN_IF_FAILED(encoder_input->SetUINT32(MF_MT_DEFAULT_STRIDE, out_width),
                         "Setting the rotated stride");
  }
  if (const HRESULT result = writer->SetInputMediaType(video_index, encoder_input.Get(), nullptr);
      FAILED(result)) {
    return Outcome::Of(Status::kUnsupported, DescribeHresult("Finding an H.264 encoder", result));
  }

  DWORD audio_index = 0;
  if (has_audio) {
    const UINT32 channels = MFGetAttributeUINT32(decoded_audio.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
    const UINT32 sample_rate =
        MFGetAttributeUINT32(decoded_audio.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
    ComPtr<IMFMediaType> aac;
    NMC_RETURN_IF_FAILED(MFCreateMediaType(&aac), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate),
                         "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels), "Creating the AAC type");
    NMC_RETURN_IF_FAILED(aac->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAudioBytesPerSecond),
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

  NMC_RETURN_IF_FAILED(writer->BeginWriting(), "Starting the encoder");
  bool video_done = false;
  bool audio_done = !has_audio;
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
    DWORD flags = 0;
    LONGLONG timestamp = 0;
    ComPtr<IMFSample> sample;
    NMC_RETURN_IF_FAILED(reader->ReadSample(is_video ? kVideoStream : kAudioStream, 0, nullptr,
                                            &flags, &timestamp, &sample),
                         "Reading a sample");
    if (flags & MF_SOURCE_READERF_ERROR) {
      return Outcome::Of(Status::kFailed, "The source reader reported a stream error");
    }
    const DWORD stream = is_video ? video_index : audio_index;
    if (flags & MF_SOURCE_READERF_STREAMTICK) {
      NMC_RETURN_IF_FAILED(writer->SendStreamTick(stream, timestamp), "Writing a stream gap");
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
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
    if (!sample) continue;

    if (is_video) {
      if (frame_interval > 0) {
        if (kept_any_frame && timestamp < next_frame_time - frame_tolerance) continue;
        next_frame_time = kept_any_frame
                              ? std::max(next_frame_time + frame_interval,
                                         timestamp + frame_interval - frame_tolerance)
                              : timestamp + frame_interval;
        kept_any_frame = true;
        sample->SetSampleDuration(frame_interval);
      }
      if (pixel_rotation != 0) {
        ComPtr<IMFSample> rotated;
        NMC_RETURN_IF_FAILED(RotateNv12Sample(sample.Get(), decode_width, decode_height,
                                              decoded_stride, pixel_rotation, &rotated),
                             "Rotating a frame");
        sample = rotated;
      }
    }
    NMC_RETURN_IF_FAILED(writer->WriteSample(stream, sample.Get()), "Writing a sample");

    ++written_samples;
    if (job.max_bytes && written_samples % kSizeCheckInterval == 0 &&
        written_bytes() > *job.max_bytes) {
      return Outcome::Of(Status::kTooLarge);
    }
    if (!is_video || duration <= 0) continue;
    const double fraction =
        std::clamp(static_cast<double>(timestamp) / static_cast<double>(duration), 0.0, 1.0);
    const auto now = std::chrono::steady_clock::now();
    if (fraction >= reported + 0.01 || (fraction > reported && now - reported_at >= kProgressInterval)) {
      reported = fraction;
      reported_at = now;
      on_progress(fraction);
    }
  }
  NMC_RETURN_IF_FAILED(writer->Finalize(), "Finishing the output");
  return Outcome::Compressed(out_width, out_height);
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
    on_progress(1.0);
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
  const int64_t size = FileSize(source);
  if (size > 0 && info.duration_ms > 0) info.bitrate = size * 8 * 1000 / info.duration_ms;
  return info;
}

}  // namespace native_media_compressor
