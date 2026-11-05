#ifndef NATIVE_MEDIA_COMPRESSOR_MEDIA_COMMON_H_
#define NATIVE_MEDIA_COMPRESSOR_MEDIA_COMMON_H_

#include <windows.h>

#include <cstdint>
#include <optional>
#include <string>

namespace native_media_compressor {

enum class Status {
  kCompressed,
  kUnsupported,
  kTooLarge,
  kCancelled,
  kInterrupted,
  kFailed,
};

struct Outcome {
  Status status = Status::kFailed;
  int64_t width = 0;
  int64_t height = 0;
  int64_t size_bytes = 0;
  std::string message;

  static Outcome Of(Status status, std::string message = {});
  static Outcome Failed(const char* step, HRESULT result);
  static Outcome Compressed(int64_t width, int64_t height);
};

// Message for an operation stopped by a C++ exception, in practice an
// allocation that failed on a huge frame or image.
inline constexpr char kUnexpectedError[] =
    "Stopped by an unexpected error, such as running out of memory";

struct SizeBounds {
  std::optional<int64_t> max_short_side;
  std::optional<int64_t> max_long_side;
};

// Factor that fits a displayed width x height into the bounds. Never above 1;
// absent or non-positive bounds are ignored.
double FitScale(int64_t width, int64_t height, const SizeBounds& bounds);

// Converts a UTF-8 path from Dart to a Windows path. Dart code often joins
// paths with forward slashes; they become backslashes so that Media
// Foundation's URL resolver sees a plain file path rather than a URL.
std::wstring ToWindowsPath(const std::string& utf8);

std::string WideToUtf8(const std::wstring& wide);

std::string DescribeHresult(const char* step, HRESULT result);

// File size in bytes, or -1 when the file does not exist.
int64_t FileSize(const std::wstring& path);

bool IsDirectory(const std::wstring& path);

// Deletes the file if it exists. Retries briefly, because a just released
// encoder can keep its handle open for a moment.
void RemoveFile(const std::wstring& path);

// A temporary file next to the destination that receives the output. The
// destination is replaced only by Commit, so a failed run leaves it as it was
// and the source may be the destination itself. The temporary file keeps the
// destination's extension and is deleted unless committed.
class PendingOutput {
 public:
  explicit PendingOutput(const std::wstring& destination);
  ~PendingOutput();
  PendingOutput(const PendingOutput&) = delete;
  PendingOutput& operator=(const PendingOutput&) = delete;

  const std::wstring& path() const { return path_; }

  // Moves the output over the destination. False when that fails.
  bool Commit();

 private:
  std::wstring destination_;
  std::wstring path_;
  bool committed_ = false;
};

// Initializes COM on the calling thread for the lifetime of the scope.
class ComScope {
 public:
  ComScope();
  ~ComScope();
  ComScope(const ComScope&) = delete;
  ComScope& operator=(const ComScope&) = delete;

 private:
  bool initialized_;
};

}  // namespace native_media_compressor

// Returns a failed Outcome from the enclosing function when a COM call fails.
#define NMC_RETURN_IF_FAILED(expression, step)                    \
  if (const HRESULT nmc_result = (expression); FAILED(nmc_result)) \
  return ::native_media_compressor::Outcome::Failed(step, nmc_result)

// Returns the HRESULT from the enclosing function when a COM call fails.
#define NMC_RETURN_HR_IF_FAILED(expression)                       \
  if (const HRESULT nmc_result = (expression); FAILED(nmc_result)) \
  return nmc_result

#endif  // NATIVE_MEDIA_COMPRESSOR_MEDIA_COMMON_H_
