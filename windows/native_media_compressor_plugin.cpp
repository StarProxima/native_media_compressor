#include "native_media_compressor_plugin.h"

#include <windows.h>

#include <algorithm>
#include <utility>

#include "image_codec.h"
#include "media_common.h"
#include "video_transcoder.h"

namespace native_media_compressor {
namespace {

std::optional<int64_t> Optional(const int64_t* value) {
  return value ? std::optional<int64_t>(*value) : std::nullopt;
}

ImageOutputFormat ToOutputFormat(ImageFormat format) {
  switch (format) {
    case ImageFormat::kPng:
      return ImageOutputFormat::kPng;
    case ImageFormat::kWebp:
      return ImageOutputFormat::kWebp;
    case ImageFormat::kHeic:
      return ImageOutputFormat::kHeic;
    case ImageFormat::kJpeg:
      break;
  }
  return ImageOutputFormat::kJpeg;
}

CompressionStatus ToCompressionStatus(Status status) {
  switch (status) {
    case Status::kCompressed:
      return CompressionStatus::kCompressed;
    case Status::kUnsupported:
      return CompressionStatus::kUnsupported;
    case Status::kTooLarge:
      return CompressionStatus::kTooLarge;
    case Status::kCancelled:
      return CompressionStatus::kCancelled;
    case Status::kInterrupted:
      return CompressionStatus::kInterrupted;
    case Status::kFailed:
      break;
  }
  return CompressionStatus::kFailed;
}

CompressionReply ToReply(const Outcome& outcome) {
  CompressionReply reply(ToCompressionStatus(outcome.status));
  if (outcome.status == Status::kCompressed) {
    reply.set_width(outcome.width);
    reply.set_height(outcome.height);
    reply.set_size_bytes(outcome.size_bytes);
    if (!outcome.video_codec.empty()) reply.set_video_codec(outcome.video_codec);
  }
  if (!outcome.message.empty()) reply.set_message(outcome.message);
  return reply;
}

}  // namespace

// static
void NativeMediaCompressorPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<NativeMediaCompressorPlugin>(registrar->messenger());
  MediaCompressorHostApi::SetUp(registrar->messenger(), plugin.get());
  registrar->AddPlugin(std::move(plugin));
}

NativeMediaCompressorPlugin::NativeMediaCompressorPlugin(flutter::BinaryMessenger* messenger)
    : messenger_(messenger), flutter_api_(messenger) {}

NativeMediaCompressorPlugin::~NativeMediaCompressorPlugin() {
  MediaCompressorHostApi::SetUp(messenger_, nullptr);
  {
    std::lock_guard<std::mutex> lock(cancel_flags_mutex_);
    for (auto& entry : cancel_flags_) entry.second->store(true);
  }
  video_worker_.Stop();
  media_workers_.Stop();
  dispatcher_.Close();
}

void NativeMediaCompressorPlugin::CompressVideo(
    int64_t task_id, const VideoRequest& request,
    std::function<void(ErrorOr<CompressionReply> reply)> result) {
  VideoJob job;
  job.source = ToWindowsPath(request.source());
  job.destination = ToWindowsPath(request.destination());
  job.bounds.max_short_side = Optional(request.max_short_side());
  job.bounds.max_long_side = Optional(request.max_long_side());
  job.video_bitrate = request.video_bitrate();
  job.max_frame_rate = Optional(request.max_frame_rate());
  job.max_bytes = Optional(request.max_bytes());
  job.include_audio = request.include_audio();
  job.prefer_hevc = request.codec() == VideoCodec::kHevc;
  job.start_ms = Optional(request.start_ms());
  job.end_ms = Optional(request.end_ms());
  job.rotate_quarter_turns = request.rotate_quarter_turns();
  job.audio_bitrate = request.audio_bitrate();

  auto cancelled = std::make_shared<std::atomic<bool>>(false);
  {
    std::lock_guard<std::mutex> lock(cancel_flags_mutex_);
    cancel_flags_[task_id] = cancelled;
  }
  video_worker_.Submit([this, task_id, job, cancelled, result] {
    const Outcome outcome = TranscodeVideo(job, *cancelled, [this, task_id](double progress) {
      dispatcher_.Post([this, task_id, progress] {
        flutter_api_.OnProgress(task_id, progress, [] {}, [](const FlutterError&) {});
      });
    });
    {
      std::lock_guard<std::mutex> lock(cancel_flags_mutex_);
      const auto found = cancel_flags_.find(task_id);
      if (found != cancel_flags_.end() && found->second == cancelled) cancel_flags_.erase(found);
    }
    const CompressionReply reply = ToReply(outcome);
    dispatcher_.Post([result, reply] { result(reply); });
  });
}

void NativeMediaCompressorPlugin::CompressImage(
    const ImageRequest& request, std::function<void(ErrorOr<CompressionReply> reply)> result) {
  ImageJob job;
  job.source = ToWindowsPath(request.source());
  job.destination = ToWindowsPath(request.destination());
  job.bounds.max_short_side = Optional(request.max_short_side());
  job.bounds.max_long_side = Optional(request.max_long_side());
  job.format = ToOutputFormat(request.format());
  job.quality = static_cast<int>(std::clamp<int64_t>(request.quality(), 0, 100));
  job.keep_metadata = request.keep_metadata();
  media_workers_.Submit([this, job, result] {
    const CompressionReply reply = ToReply(CompressImageFile(job));
    dispatcher_.Post([result, reply] { result(reply); });
  });
}

std::optional<FlutterError> NativeMediaCompressorPlugin::Cancel(int64_t task_id) {
  std::lock_guard<std::mutex> lock(cancel_flags_mutex_);
  const auto found = cancel_flags_.find(task_id);
  if (found != cancel_flags_.end()) found->second->store(true);
  return std::nullopt;
}

void NativeMediaCompressorPlugin::ProbeImage(
    const std::string& source,
    std::function<void(ErrorOr<std::optional<ImageProbe>> reply)> result) {
  const std::wstring path = ToWindowsPath(source);
  media_workers_.Submit([this, path, result] {
    std::optional<ImageProbe> probe;
    try {
      if (const auto info = ProbeImageFile(path)) {
        probe.emplace(info->width, info->height, info->frame_count);
        if (info->mime_type) probe->set_mime_type(*info->mime_type);
        if (info->size_bytes) probe->set_size_bytes(*info->size_bytes);
      }
    } catch (...) {
      probe.reset();
    }
    dispatcher_.Post([result, probe] { result(probe); });
  });
}

void NativeMediaCompressorPlugin::ProbeVideo(
    const std::string& source,
    std::function<void(ErrorOr<std::optional<VideoProbe>> reply)> result) {
  const std::wstring path = ToWindowsPath(source);
  media_workers_.Submit([this, path, result] {
    std::optional<VideoProbe> probe;
    try {
      if (const auto info = ProbeVideoFile(path)) {
        probe.emplace(info->width, info->height, info->rotation_degrees, info->duration_ms,
                      info->is_hdr, info->has_audio);
        if (info->bitrate) probe->set_bitrate(*info->bitrate);
        if (info->video_codec) probe->set_video_codec(*info->video_codec);
        if (info->audio_codec) probe->set_audio_codec(*info->audio_codec);
        if (info->frame_rate) probe->set_frame_rate(*info->frame_rate);
        probe->set_audio_track_count(info->audio_track_count);
        if (info->size_bytes) probe->set_size_bytes(*info->size_bytes);
      }
    } catch (...) {
      probe.reset();
    }
    dispatcher_.Post([result, probe] { result(probe); });
  });
}

void NativeMediaCompressorPlugin::VideoThumbnail(
    const ThumbnailRequest& request, std::function<void(ErrorOr<CompressionReply> reply)> result) {
  ThumbnailJob job;
  job.source = ToWindowsPath(request.source());
  job.destination = ToWindowsPath(request.destination());
  job.position_ms = request.position_ms();
  job.bounds.max_short_side = Optional(request.max_short_side());
  job.bounds.max_long_side = Optional(request.max_long_side());
  job.format = ToOutputFormat(request.format());
  job.quality = static_cast<int>(std::clamp<int64_t>(request.quality(), 0, 100));
  media_workers_.Submit([this, job, result] {
    const CompressionReply reply = ToReply(SaveVideoFrame(job));
    dispatcher_.Post([result, reply] { result(reply); });
  });
}

// Windows does not stop a backgrounded app's work, so videos need no
// foreground service.
std::optional<FlutterError> NativeMediaCompressorPlugin::SetForegroundNotification(
    const ForegroundNotification* /*notification*/) {
  return std::nullopt;
}

}  // namespace native_media_compressor
