#include <gtest/gtest.h>
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <fstream>
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
    for (const auto& file : files_) DeleteFileW(file.c_str());
    RemoveDirectoryW(path_.c_str());
  }

  std::wstring File(const std::wstring& name) {
    files_.push_back(path_ + L"\\" + name);
    return files_.back();
  }

 private:
  std::wstring path_;
  std::vector<std::wstring> files_;
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

TEST(CompressImageFile, BrokenInputLeavesNoOutput) {
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
  EXPECT_EQ(FileSize(destination), -1);
  EXPECT_FALSE(ProbeImageFile(source).has_value());
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

TEST(TranscodeVideo, CancelledBeforeStartLeavesNoOutput) {
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
  EXPECT_EQ(FileSize(destination), -1);
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
  EXPECT_FALSE(ProbeVideoFile(source).has_value());
}

}  // namespace test
}  // namespace native_media_compressor
