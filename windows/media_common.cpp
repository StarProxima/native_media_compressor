#include "media_common.h"

#include <objbase.h>

#include <algorithm>
#include <cstdio>
#include <utility>

namespace native_media_compressor {

Outcome Outcome::Of(Status status, std::string message) {
  Outcome outcome;
  outcome.status = status;
  outcome.message = std::move(message);
  return outcome;
}

Outcome Outcome::Failed(const char* step, HRESULT result) {
  return Of(Status::kFailed, DescribeHresult(step, result));
}

Outcome Outcome::Compressed(int64_t width, int64_t height) {
  Outcome outcome;
  outcome.status = Status::kCompressed;
  outcome.width = width;
  outcome.height = height;
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

std::wstring ToWindowsPath(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) return {};
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), length);
  std::replace(wide.begin(), wide.end(), L'/', L'\\');
  return wide;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int length =
      WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                          nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string utf8(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      utf8.data(), length, nullptr, nullptr);
  return utf8;
}

std::string DescribeHresult(const char* step, HRESULT result) {
  char text[256];
  std::snprintf(text, sizeof(text), "%s failed (HRESULT 0x%08lX)", step,
                static_cast<unsigned long>(result));
  return text;
}

int64_t FileSize(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) return -1;
  return (static_cast<int64_t>(data.nFileSizeHigh) << 32) |
         static_cast<int64_t>(data.nFileSizeLow);
}

void RemoveFile(const std::wstring& path) {
  if (path.empty()) return;
  for (int attempt = 0; attempt < 20; ++attempt) {
    if (DeleteFileW(path.c_str())) return;
    const DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return;
    if (error != ERROR_SHARING_VIOLATION && error != ERROR_ACCESS_DENIED) return;
    Sleep(50);
  }
}

ComScope::ComScope()
    : initialized_(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {}

ComScope::~ComScope() {
  if (initialized_) CoUninitialize();
}

}  // namespace native_media_compressor
