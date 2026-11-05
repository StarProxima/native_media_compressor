#include "video_queue.h"

#include <utility>
#include <vector>

namespace native_media_compressor {

namespace {

void Finish(VideoQueue::Task& task, const Outcome& outcome) {
  if (task.on_done) task.on_done(outcome);
}

}  // namespace

VideoQueue::VideoQueue(Runner runner) : runner_(std::move(runner)) {}

VideoQueue::~VideoQueue() {
  std::deque<std::shared_ptr<Task>> dropped;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
    dropped.swap(pending_);
    if (running_) running_->cancelled = true;
  }
  wake_.notify_all();
  for (auto& task : dropped) {
    Finish(*task, Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_CANCELLED));
  }
  if (thread_.joinable()) thread_.join();
}

void VideoQueue::Enqueue(std::shared_ptr<Task> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!stopping_) {
      pending_.push_back(task);
      if (!thread_.joinable()) thread_ = std::thread(&VideoQueue::Work, this);
      task = nullptr;
    }
  }
  if (task) {
    Finish(*task, Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_CANCELLED));
    return;
  }
  wake_.notify_one();
}

void VideoQueue::Cancel(int64_t id) {
  std::shared_ptr<Task> removed;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_ && running_->id == id) {
      running_->cancelled = true;
      return;
    }
    for (auto it = pending_.begin(); it != pending_.end(); ++it) {
      if ((*it)->id == id) {
        removed = *it;
        pending_.erase(it);
        break;
      }
    }
  }
  if (removed) {
    removed->cancelled = true;
    Finish(*removed, Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_CANCELLED));
  }
}

void VideoQueue::Work() {
  while (true) {
    std::shared_ptr<Task> task;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      wake_.wait(lock, [this] { return stopping_ || !pending_.empty(); });
      if (pending_.empty()) return;
      task = pending_.front();
      pending_.pop_front();
      running_ = task;
    }
    const Outcome outcome =
        task->cancelled ? Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_CANCELLED)
                        : runner_(*task);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      running_ = nullptr;
    }
    Finish(*task, outcome);
  }
}

}  // namespace native_media_compressor
