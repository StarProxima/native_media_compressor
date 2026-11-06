#ifndef NATIVE_MEDIA_COMPRESSOR_VIDEO_QUEUE_H_
#define NATIVE_MEDIA_COMPRESSOR_VIDEO_QUEUE_H_

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>

#include "media_common.h"
#include "video_transcoder.h"

namespace native_media_compressor {

// Runs video tasks one at a time, in order, on a single worker thread.
class VideoQueue {
 public:
  struct Task {
    int64_t id = 0;
    VideoJob job;
    std::atomic<bool> cancelled{false};
    // Called on the worker thread.
    std::function<void(double)> on_progress;
    // Called once, on the worker thread or on the thread that cancelled a
    // task that had not started.
    std::function<void(const Outcome&)> on_done;
  };

  using Runner = std::function<Outcome(Task&)>;

  explicit VideoQueue(Runner runner);
  // Cancels pending and running tasks and waits for the worker.
  ~VideoQueue();
  VideoQueue(const VideoQueue&) = delete;
  VideoQueue& operator=(const VideoQueue&) = delete;

  void Enqueue(std::shared_ptr<Task> task);

  // A pending task ends cancelled right away without running; a running one
  // is asked to stop. Unknown or finished ids are ignored.
  void Cancel(int64_t id);

 private:
  void Work();

  Runner runner_;
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<std::shared_ptr<Task>> pending_;
  std::shared_ptr<Task> running_;
  bool stopping_ = false;
  std::thread thread_;
};

}  // namespace native_media_compressor

#endif  // NATIVE_MEDIA_COMPRESSOR_VIDEO_QUEUE_H_
