#ifndef NATIVE_MEDIA_COMPRESSOR_TASK_QUEUES_H_
#define NATIVE_MEDIA_COMPRESSOR_TASK_QUEUES_H_

#include <windows.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace native_media_compressor {

// Runs tasks on the thread that created it (the platform thread) through a
// message-only window, since replies and Flutter API calls must be made there.
class PlatformThreadDispatcher {
 public:
  PlatformThreadDispatcher();
  ~PlatformThreadDispatcher();
  PlatformThreadDispatcher(const PlatformThreadDispatcher&) = delete;
  PlatformThreadDispatcher& operator=(const PlatformThreadDispatcher&) = delete;

  // Safe to call from any thread. Tasks run in the order they were posted.
  void Post(std::function<void()> task);

  // Drops pending tasks and ignores later posts. Call on the platform thread.
  void Close();

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  void RunPending();

  HWND window_ = nullptr;
  std::mutex mutex_;
  std::deque<std::function<void()>> pending_;
  bool closed_ = false;
};

// A fixed set of worker threads taking tasks in FIFO order.
class WorkerPool {
 public:
  explicit WorkerPool(size_t thread_count);
  ~WorkerPool();
  WorkerPool(const WorkerPool&) = delete;
  WorkerPool& operator=(const WorkerPool&) = delete;

  void Submit(std::function<void()> task);

  // Drops tasks that have not started and waits for running ones.
  void Stop();

 private:
  void Work();

  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<std::function<void()>> pending_;
  bool stopping_ = false;
  std::vector<std::thread> threads_;
};

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_TASK_QUEUES_H_
