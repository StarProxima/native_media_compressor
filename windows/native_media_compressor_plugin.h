#ifndef FLUTTER_PLUGIN_NATIVE_MEDIA_COMPRESSOR_PLUGIN_H_
#define FLUTTER_PLUGIN_NATIVE_MEDIA_COMPRESSOR_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

#include "messages.g.h"
#include "task_queues.h"

namespace native_media_compressor {

class NativeMediaCompressorPlugin : public flutter::Plugin, public MediaCompressorHostApi {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit NativeMediaCompressorPlugin(flutter::BinaryMessenger* messenger);
  ~NativeMediaCompressorPlugin() override;

  NativeMediaCompressorPlugin(const NativeMediaCompressorPlugin&) = delete;
  NativeMediaCompressorPlugin& operator=(const NativeMediaCompressorPlugin&) = delete;

  void CompressVideo(int64_t task_id, const VideoRequest& request,
                     std::function<void(ErrorOr<CompressionReply> reply)> result) override;
  void CompressImage(const ImageRequest& request,
                     std::function<void(ErrorOr<CompressionReply> reply)> result) override;
  std::optional<FlutterError> Cancel(int64_t task_id) override;
  void ProbeImage(const std::string& source,
                  std::function<void(ErrorOr<std::optional<ImageProbe>> reply)> result) override;
  void ProbeVideo(const std::string& source,
                  std::function<void(ErrorOr<std::optional<VideoProbe>> reply)> result) override;
  void VideoThumbnail(const ThumbnailRequest& request,
                      std::function<void(ErrorOr<CompressionReply> reply)> result) override;
  std::optional<FlutterError> SetForegroundNotification(
      const ForegroundNotification* notification) override;

 private:
  flutter::BinaryMessenger* messenger_;
  MediaCompressorFlutterApi flutter_api_;
  PlatformThreadDispatcher dispatcher_;
  std::mutex cancel_flags_mutex_;
  std::map<int64_t, std::shared_ptr<std::atomic<bool>>> cancel_flags_;
  // Videos run one at a time: the hardware encoder is shared, and the API
  // promises a FIFO queue.
  WorkerPool video_worker_{1};
  WorkerPool media_workers_{2};
};

}  // namespace native_media_compressor

#endif  // FLUTTER_PLUGIN_NATIVE_MEDIA_COMPRESSOR_PLUGIN_H_
