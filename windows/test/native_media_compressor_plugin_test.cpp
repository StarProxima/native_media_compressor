#include <gtest/gtest.h>
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "image_codec.h"
#include "media_common.h"
#include "video_transcoder.h"

namespace native_media_compressor {
namespace test {

namespace {

class TempDirectory {
 public:
  TempDirectory() {
    wchar_t base[MAX_PATH] = {};
    GetTempPathW(MAX_PATH, base);
    path_ = std::wstring(base) + L"nmc_unit_" + std::to_wstring(GetCurrentProcessId());
    CreateDirectoryW(path_.c_str(), nullptr);
  }
  ~TempDirectory() {
    for (const auto& name : Entries()) {
      const std::wstring entry = path_ + L"\\" + name;
      if (!DeleteFileW(entry.c_str())) RemoveDirectoryW(entry.c_str());
    }
    RemoveDirectoryW(path_.c_str());
  }

  std::wstring File(const std::wstring& name) const { return path_ + L"\\" + name; }

  // Names in the directory, to catch temporary files left behind.
  std::vector<std::wstring> Entries() const {
    std::vector<std::wstring> names;
    WIN32_FIND_DATAW data;
    const std::wstring pattern = path_ + L"\\*";
    HANDLE search = FindFirstFileW(pattern.c_str(), &data);
    if (search == INVALID_HANDLE_VALUE) return names;
    do {
      const std::wstring name = data.cFileName;
      if (name != L"." && name != L"..") names.push_back(name);
    } while (FindNextFileW(search, &data));
    FindClose(search);
    return names;
  }

 private:
  std::wstring path_;
};

// Writes a 24-bit bottom-up BMP filled with one colour.
void WriteBmp(const std::wstring& path, int width, int height) {
  const int row_bytes = (width * 3 + 3) / 4 * 4;
  BITMAPFILEHEADER file_header = {};
  BITMAPINFOHEADER info_header = {};
  file_header.bfType = 0x4D42;
  file_header.bfOffBits = static_cast<DWORD>(sizeof(file_header) + sizeof(info_header));
  file_header.bfSize = file_header.bfOffBits + static_cast<DWORD>(row_bytes * height);
  info_header.biSize = static_cast<DWORD>(sizeof(info_header));
  info_header.biWidth = width;
  info_header.biHeight = height;
  info_header.biPlanes = 1;
  info_header.biBitCount = 24;
  info_header.biCompression = BI_RGB;
  std::vector<char> pixels(static_cast<size_t>(row_bytes) * height);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      char* pixel = pixels.data() + static_cast<size_t>(y) * row_bytes + static_cast<size_t>(x) * 3;
      pixel[0] = static_cast<char>(40);
      pixel[1] = static_cast<char>(120);
      pixel[2] = static_cast<char>(200);
    }
  }
  std::ofstream out(path, std::ios::binary);
  out.write(reinterpret_cast<const char*>(&file_header), sizeof(file_header));
  out.write(reinterpret_cast<const char*>(&info_header), sizeof(info_header));
  out.write(pixels.data(), static_cast<std::streamsize>(pixels.size()));
}

void WriteText(const std::wstring& path, const char* text) {
  std::ofstream out(path, std::ios::binary);
  out << text;
}

std::string ReadText(const std::wstring& path) {
  std::ifstream in(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

}  // namespace

TEST(FitScale, UsesTheTighterBound) {
  SizeBounds bounds;
  bounds.max_short_side = 300;
  bounds.max_long_side = 1000;
  EXPECT_DOUBLE_EQ(FitScale(1200, 1600, bounds), 0.25);
}

TEST(FitScale, NeverScalesUp) {
  SizeBounds bounds;
  bounds.max_long_side = 4000;
  EXPECT_DOUBLE_EQ(FitScale(1200, 800, bounds), 1.0);
  EXPECT_DOUBLE_EQ(FitScale(1200, 800, SizeBounds{}), 1.0);
}

TEST(FitScale, IgnoresAbsentAndNonPositiveBounds) {
  SizeBounds bounds;
  bounds.max_short_side = 0;
  bounds.max_long_side = 960;
  EXPECT_DOUBLE_EQ(FitScale(1920, 1080, bounds), 0.5);
}

TEST(ToWindowsPath, ConvertsUtf8AndSeparators) {
  EXPECT_EQ(ToWindowsPath("C:/tmp/\xD1\x84.jpg"), std::wstring(L"C:\\tmp\\\x0444.jpg"));
  EXPECT_EQ(ToWindowsPath(""), std::wstring());
}

TEST(CompressImageFile, ScalesAndWritesJpeg) {
  TempDirectory directory;
  const auto source = directory.File(L"source.bmp");
  const auto destination = directory.File(L"out.jpg");
  WriteBmp(source, 40, 20);

  ImageJob job;
  job.source = source;
  job.destination = destination;
  job.bounds.max_long_side = 20;
  job.quality = 80;
  const Outcome outcome = CompressImageFile(job);

  ASSERT_EQ(outcome.status, Status::kCompressed) << outcome.message;
  EXPECT_EQ(outcome.width, 20);
  EXPECT_EQ(outcome.height, 10);
  EXPECT_EQ(outcome.size_bytes, FileSize(destination));
  const auto probe = ProbeImageFile(destination);
  ASSERT_TRUE(probe.has_value());
  EXPECT_EQ(probe->width, 20);
  EXPECT_EQ(probe->height, 10);
  EXPECT_EQ(probe->frame_count, 1);
  EXPECT_EQ(probe->mime_type.value_or(""), "image/jpeg");
}

TEST(CompressImageFile, WritesPngWithoutScalingUp) {
  TempDirectory directory;
  const auto source = directory.File(L"source.bmp");
  const auto destination = directory.File(L"out.png");
  WriteBmp(source, 30, 50);

  ImageJob job;
  job.source = source;
  job.destination = destination;
  job.bounds.max_long_side = 4000;
  job.png = true;
  const Outcome outcome = CompressImageFile(job);

  ASSERT_EQ(outcome.status, Status::kCompressed) << outcome.message;
  EXPECT_EQ(outcome.width, 30);
  EXPECT_EQ(outcome.height, 50);
  EXPECT_EQ(ProbeImageFile(destination)->mime_type.value_or(""), "image/png");
}

TEST(CompressImageFile, BrokenInputKeepsTheDestination) {
  TempDirectory directory;
  const auto source = directory.File(L"broken.jpg");
  const auto destination = directory.File(L"out.jpg");
  WriteText(source, "not a media file\n");
  WriteText(destination, "stale");

  ImageJob job;
  job.source = source;
  job.destination = destination;
  const Outcome outcome = CompressImageFile(job);

  EXPECT_TRUE(outcome.status == Status::kFailed || outcome.status == Status::kUnsupported);
  EXPECT_EQ(ReadText(destination), "stale");
  EXPECT_EQ(directory.Entries().size(), 2u);
  EXPECT_FALSE(ProbeImageFile(source).has_value());
}

TEST(CompressImageFile, CompressesInPlace) {
  TempDirectory directory;
  const auto path = directory.File(L"photo.bmp");
  WriteBmp(path, 80, 40);

  ImageJob job;
  job.source = path;
  job.destination = path;
  job.bounds.max_long_side = 40;
  const Outcome outcome = CompressImageFile(job);

  ASSERT_EQ(outcome.status, Status::kCompressed) << outcome.message;
  EXPECT_EQ(outcome.size_bytes, FileSize(path));
  const auto probe = ProbeImageFile(path);
  ASSERT_TRUE(probe.has_value());
  EXPECT_EQ(probe->width, 40);
  EXPECT_EQ(probe->height, 20);
  EXPECT_EQ(probe->mime_type.value_or(""), "image/jpeg");
  EXPECT_EQ(directory.Entries().size(), 1u);
}

TEST(CompressImageFile, DirectoryDestinationIsUntouched) {
  TempDirectory directory;
  const auto source = directory.File(L"source.bmp");
  const auto folder = directory.File(L"folder");
  WriteBmp(source, 20, 20);
  CreateDirectoryW(folder.c_str(), nullptr);

  ImageJob job;
  job.source = source;
  job.destination = folder;
  const Outcome outcome = CompressImageFile(job);

  EXPECT_EQ(outcome.status, Status::kFailed);
  EXPECT_TRUE(IsDirectory(folder));
  EXPECT_EQ(directory.Entries().size(), 2u);
}

TEST(ProbeImageFile, ReadsBmpHeader) {
  TempDirectory directory;
  const auto source = directory.File(L"source.bmp");
  WriteBmp(source, 64, 48);

  const auto probe = ProbeImageFile(source);

  ASSERT_TRUE(probe.has_value());
  EXPECT_EQ(probe->width, 64);
  EXPECT_EQ(probe->height, 48);
  EXPECT_EQ(probe->mime_type.value_or(""), "image/bmp");
}

TEST(TranscodeVideo, CancelledBeforeStartKeepsTheDestination) {
  TempDirectory directory;
  const auto source = directory.File(L"source.bmp");
  const auto destination = directory.File(L"out.mp4");
  WriteBmp(source, 16, 16);
  WriteText(destination, "stale");
  std::atomic<bool> cancelled{true};

  VideoJob job;
  job.source = source;
  job.destination = destination;
  job.video_bitrate = 500000;
  const Outcome outcome = TranscodeVideo(job, cancelled, [](double) {});

  EXPECT_EQ(outcome.status, Status::kCancelled);
  EXPECT_EQ(ReadText(destination), "stale");
  EXPECT_EQ(directory.Entries().size(), 2u);
}

TEST(TranscodeVideo, NonVideoInputIsRejected) {
  TempDirectory directory;
  const auto source = directory.File(L"source.bmp");
  const auto destination = directory.File(L"out.mp4");
  WriteBmp(source, 16, 16);
  std::atomic<bool> cancelled{false};

  VideoJob job;
  job.source = source;
  job.destination = destination;
  job.video_bitrate = 500000;
  const Outcome outcome = TranscodeVideo(job, cancelled, [](double) {});

  EXPECT_TRUE(outcome.status == Status::kFailed || outcome.status == Status::kUnsupported);
  EXPECT_EQ(FileSize(destination), -1);
  EXPECT_EQ(directory.Entries().size(), 1u);
  EXPECT_FALSE(ProbeVideoFile(source).has_value());
}

TEST(SaveVideoFrame, NonVideoInputLeavesNoOutput) {
  TempDirectory directory;
  const auto source = directory.File(L"source.bmp");
  const auto destination = directory.File(L"frame.jpg");
  WriteBmp(source, 16, 16);
  WriteText(destination, "stale");

  ThumbnailJob job;
  job.source = source;
  job.destination = destination;
  job.position_ms = 1000;
  const Outcome outcome = SaveVideoFrame(job);

  EXPECT_TRUE(outcome.status == Status::kFailed || outcome.status == Status::kUnsupported);
  EXPECT_EQ(ReadText(destination), "stale");
  EXPECT_EQ(directory.Entries().size(), 2u);
}

TEST(ResolveTrim, ConvertsMillisecondsToTicks) {
  const auto range = ResolveTrim(2000, 5000, 80000000);
  ASSERT_TRUE(range.has_value());
  EXPECT_EQ(range->start, int64_t{20000000});
  EXPECT_EQ(range->end, int64_t{50000000});
}

TEST(ResolveTrim, AnEndPastTheDurationKeepsToTheEnd) {
  const auto range = ResolveTrim(1000, 30000, 20000000);
  ASSERT_TRUE(range.has_value());
  EXPECT_EQ(range->start, int64_t{10000000});
  EXPECT_EQ(range->end, TrimRange::kOpenEnd);
}

TEST(ResolveTrim, NoBoundsKeepEverything) {
  const auto range = ResolveTrim(std::nullopt, std::nullopt, 0);
  ASSERT_TRUE(range.has_value());
  EXPECT_EQ(range->start, int64_t{0});
  EXPECT_EQ(range->end, TrimRange::kOpenEnd);
  EXPECT_EQ(ResolveTrim(-500, std::nullopt, 0)->start, int64_t{0});
}

TEST(ResolveTrim, AnEmptyRangeKeepsNothing) {
  EXPECT_FALSE(ResolveTrim(3000, 3000, 0).has_value());
  EXPECT_FALSE(ResolveTrim(4000, 1000, 80000000).has_value());
  EXPECT_FALSE(ResolveTrim(9000, std::nullopt, 80000000).has_value());
  EXPECT_FALSE(ResolveTrim(std::nullopt, 0, 80000000).has_value());
}

TEST(CropPcm, KeepsABufferInsideTheRange) {
  TrimRange range;
  range.start = 10000000;
  range.end = 20000000;
  const PcmCrop crop = CropPcm(12000000, 1024, 48000, range);
  EXPECT_EQ(crop.skip_frames, 0u);
  EXPECT_EQ(crop.keep_frames, 1024u);
}

TEST(CropPcm, CutsBothEdgesToTheFrame) {
  TrimRange range;
  range.start = 10000000;
  range.end = 10100000;
  // 48 kHz, 4800 frames from 0.99 s: 480 frames lie before the start and
  // 480 after it fit in the 10 ms range.
  const PcmCrop crop = CropPcm(9900000, 4800, 48000, range);
  EXPECT_EQ(crop.skip_frames, 480u);
  EXPECT_EQ(crop.keep_frames, 480u);
}

TEST(CropPcm, DropsBuffersOutsideTheRange) {
  TrimRange range;
  range.start = 10000000;
  range.end = 20000000;
  EXPECT_EQ(CropPcm(0, 1024, 48000, range).keep_frames, 0u);
  EXPECT_EQ(CropPcm(20000000, 1024, 48000, range).keep_frames, 0u);
  EXPECT_EQ(CropPcm(12000000, 1024, 0, range).keep_frames, 0u);
}

TEST(CropPcm, AnOpenEndKeepsTheTail) {
  TrimRange range;
  range.start = 10000000;
  const PcmCrop crop = CropPcm(9990000, 960, 48000, range);
  EXPECT_EQ(crop.skip_frames, 48u);
  EXPECT_EQ(crop.keep_frames, 912u);
}

TEST(TotalRotation, AddsClockwiseQuarterTurns) {
  EXPECT_EQ(TotalRotation(0, 0), 0u);
  EXPECT_EQ(TotalRotation(0, 1), 90u);
  EXPECT_EQ(TotalRotation(90, 1), 180u);
  EXPECT_EQ(TotalRotation(270, 1), 0u);
  EXPECT_EQ(TotalRotation(180, 3), 90u);
  EXPECT_EQ(TotalRotation(90, -1), 0u);
}

TEST(AacBytesPerSecond, PicksTheNearestAllowedRate) {
  EXPECT_EQ(AacBytesPerSecond(128000), 16000u);
  EXPECT_EQ(AacBytesPerSecond(96000), 12000u);
  EXPECT_EQ(AacBytesPerSecond(160000), 20000u);
  EXPECT_EQ(AacBytesPerSecond(192000), 24000u);
  EXPECT_EQ(AacBytesPerSecond(320000), 24000u);
  EXPECT_EQ(AacBytesPerSecond(64000), 12000u);
  EXPECT_EQ(AacBytesPerSecond(144000), 16000u);
}

TEST(ThumbnailTime, ClampsToTheLastFrame) {
  EXPECT_EQ(ThumbnailTime(1000, 20000000, 333333), int64_t{10000000});
  EXPECT_EQ(ThumbnailTime(30000, 20000000, 333333), int64_t{19666667});
  EXPECT_EQ(ThumbnailTime(-5, 20000000, 333333), int64_t{0});
  EXPECT_EQ(ThumbnailTime(30000, 0, 333333), int64_t{300000000});
}

TEST(PendingOutput, KeepsTheExtensionAndCleansUp) {
  TempDirectory directory;
  const auto destination = directory.File(L"clip.mp4");
  std::wstring temporary;
  {
    PendingOutput output(destination);
    temporary = output.path();
    WriteText(temporary, "partial");
    EXPECT_EQ(temporary.substr(temporary.size() - 4), L".mp4");
    EXPECT_EQ(temporary.substr(0, temporary.rfind(L'\\')),
              destination.substr(0, destination.rfind(L'\\')));
  }
  EXPECT_EQ(FileSize(temporary), -1);
  EXPECT_EQ(FileSize(destination), -1);
}

TEST(PendingOutput, CommitReplacesTheDestination) {
  TempDirectory directory;
  const auto destination = directory.File(L"clip.mp4");
  WriteText(destination, "old");
  {
    PendingOutput output(destination);
    WriteText(output.path(), "new");
    EXPECT_TRUE(output.Commit());
  }
  EXPECT_EQ(ReadText(destination), "new");
  EXPECT_EQ(directory.Entries().size(), 1u);
}

}  // namespace test
}  // namespace native_media_compressor
