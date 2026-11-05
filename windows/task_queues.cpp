#include "task_queues.h"

#include <utility>

extern "C" IMAGE_DOS_HEADER __ImageBase;

namespace native_media_compressor {
namespace {

constexpr UINT kRunPendingMessage = WM_APP + 1;
constexpr wchar_t kWindowClass[] = L"NativeMediaCompressorDispatcher";

// The class is registered against this module rather than the executable, so
// its window procedure always points into the code that registered it.
HINSTANCE ModuleInstance() { return reinterpret_cast<HINSTANCE>(&__ImageBase); }

}  // namespace

PlatformThreadDispatcher::PlatformThreadDispatcher() {
  static std::once_flag registered;
  std::call_once(registered, [] {
    WNDCLASSEXW window_class = {};
    window_class.cbSize = static_cast<UINT>(sizeof(window_class));
    window_class.lpfnWndProc = WindowProc;
    window_class.hInstance = ModuleInstance();
    window_class.lpszClassName = kWindowClass;
    RegisterClassExW(&window_class);
  });
  window_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                            ModuleInstance(), this);
}

PlatformThreadDispatcher::~PlatformThreadDispatcher() { Close(); }

void PlatformThreadDispatcher::Post(std::function<void()> task) {
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_ || !window_) return;
    pending_.push_back(std::move(task));
    window = window_;
  }
  PostMessageW(window, kRunPendingMessage, 0, 0);
}

void PlatformThreadDispatcher::Close() {
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    pending_.clear();
    window = window_;
    window_ = nullptr;
  }
  if (window) DestroyWindow(window);
}

LRESULT CALLBACK PlatformThreadDispatcher::WindowProc(HWND window, UINT message, WPARAM wparam,
                                                      LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* creation = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(creation->lpCreateParams));
  }
  if (message == kRunPendingMessage) {
    auto* dispatcher =
        reinterpret_cast<PlatformThreadDispatcher*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (dispatcher) dispatcher->RunPending();
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void PlatformThreadDispatcher::RunPending() {
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return;
    tasks.swap(pending_);
  }
  for (auto& task : tasks) task();
}

WorkerPool::WorkerPool(size_t thread_count) {
  for (size_t index = 0; index < thread_count; ++index) {
    threads_.emplace_back([this] { Work(); });
  }
}

WorkerPool::~WorkerPool() { Stop(); }

void WorkerPool::Submit(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) return;
    pending_.push_back(std::move(task));
  }
  wake_.notify_one();
}

void WorkerPool::Stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
    pending_.clear();
  }
  wake_.notify_all();
  for (auto& thread : threads_) {
    if (thread.joinable()) thread.join();
  }
  threads_.clear();
}

void WorkerPool::Work() {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait(lock, [this] { return stopping_ || !pending_.empty(); });
      if (stopping_) return;
      task = std::move(pending_.front());
      pending_.pop_front();
    }
    task();
  }
}

}  // namespace native_media_compressor
