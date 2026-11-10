#include "include/native_media_compressor/native_media_compressor_plugin.h"

#include <flutter_linux/flutter_linux.h>

#include <algorithm>
#include <exception>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "image_codec.h"
#include "media_common.h"
#include "messages.g.h"
#include "video_queue.h"
#include "video_transcoder.h"

namespace nmc = native_media_compressor;

#define NATIVE_MEDIA_COMPRESSOR_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), native_media_compressor_plugin_get_type(), \
                              NativeMediaCompressorPlugin))

struct _NativeMediaCompressorPlugin {
  GObject parent_instance;
  NmcMediaCompressorFlutterApi* flutter_api;
  nmc::VideoQueue* video_queue;
};

G_DEFINE_TYPE(NativeMediaCompressorPlugin, native_media_compressor_plugin, g_object_get_type())

namespace {

template <typename T>
std::shared_ptr<T> Retain(T* object) {
  g_object_ref(object);
  return std::shared_ptr<T>(object, [](T* retained) { g_object_unref(retained); });
}

// Replies and Flutter API calls must be made on the main context, which is
// where the engine runs the platform thread. g_idle_add always queues there;
// g_main_context_invoke would run the task right here whenever the worker
// can acquire the context, such as while the main loop is not running.
void PostToMain(std::function<void()> task) {
  g_idle_add_full(
      G_PRIORITY_DEFAULT,
      [](gpointer data) -> gboolean {
        try {
          (*static_cast<std::function<void()>*>(data))();
        } catch (const std::exception& error) {
          g_warning("native_media_compressor: %s", error.what());
        }
        return G_SOURCE_REMOVE;
      },
      new std::function<void()>(std::move(task)),
      [](gpointer data) { delete static_cast<std::function<void()>*>(data); });
}

// A few full-size decodes of large photos at once can exhaust memory.
constexpr gint kMaxParallelImageWork = 2;

void RunInBackground(std::function<void()> task) {
  static GThreadPool* pool = g_thread_pool_new(
      [](gpointer data, gpointer) {
        std::unique_ptr<std::function<void()>> owned(static_cast<std::function<void()>*>(data));
        try {
          (*owned)();
        } catch (const std::exception& error) {
          g_warning("native_media_compressor: %s", error.what());
        }
      },
      nullptr, kMaxParallelImageWork, FALSE, nullptr);
  g_thread_pool_push(pool, new std::function<void()>(std::move(task)), nullptr);
}

std::optional<int64_t> Optional(const int64_t* value) {
  return value != nullptr ? std::optional<int64_t>(*value) : std::nullopt;
}

NmcCompressionReply* ToReply(const nmc::Outcome& outcome) {
  const char* message = outcome.message.empty() ? nullptr : outcome.message.c_str();
  if (outcome.status != NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) {
    return nmc_compression_reply_new(outcome.status, nullptr, nullptr, nullptr, message, nullptr);
  }
  int64_t width = outcome.width;
  int64_t height = outcome.height;
  int64_t size_bytes = outcome.size_bytes;
  const char* video_codec = outcome.video_codec.empty() ? nullptr : outcome.video_codec.c_str();
  return nmc_compression_reply_new(outcome.status, &width, &height, &size_bytes, message,
                                   video_codec);
}

void OnProgressSent(GObject* source, GAsyncResult* result, gpointer) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(NmcMediaCompressorFlutterApiOnProgressResponse) response =
      nmc_media_compressor_flutter_api_on_progress_finish(
          NMC_MEDIA_COMPRESSOR_FLUTTER_API(source), result, &error);
}

void HandleCompressVideo(int64_t task_id, NmcVideoRequest* request,
                         NmcMediaCompressorHostApiResponseHandle* response_handle,
                         gpointer user_data) {
  NativeMediaCompressorPlugin* self = NATIVE_MEDIA_COMPRESSOR_PLUGIN(user_data);
  auto task = std::make_shared<nmc::VideoQueue::Task>();
  task->id = task_id;
  task->job.source = nmc_video_request_get_source(request);
  task->job.destination = nmc_video_request_get_destination(request);
  task->job.bounds.max_short_side = Optional(nmc_video_request_get_max_short_side(request));
  task->job.bounds.max_long_side = Optional(nmc_video_request_get_max_long_side(request));
  task->job.video_bitrate = nmc_video_request_get_video_bitrate(request);
  task->job.max_frame_rate = Optional(nmc_video_request_get_max_frame_rate(request));
  task->job.max_bytes = Optional(nmc_video_request_get_max_bytes(request));
  task->job.include_audio = nmc_video_request_get_include_audio(request);
  task->job.hevc = nmc_video_request_get_codec(request) == NATIVE_MEDIA_COMPRESSOR_VIDEO_CODEC_HEVC;
  task->job.start_ms = Optional(nmc_video_request_get_start_ms(request));
  task->job.end_ms = Optional(nmc_video_request_get_end_ms(request));
  task->job.rotate_quarter_turns = nmc_video_request_get_rotate_quarter_turns(request);
  task->job.audio_bitrate = nmc_video_request_get_audio_bitrate(request);

  auto api = Retain(self->flutter_api);
  task->on_progress = [api, task_id](double progress) {
    PostToMain([api, task_id, progress] {
      nmc_media_compressor_flutter_api_on_progress(api.get(), task_id, progress, nullptr,
                                                   OnProgressSent, nullptr);
    });
  };
  auto response = Retain(response_handle);
  task->on_done = [response](const nmc::Outcome& outcome) {
    PostToMain([response, outcome] {
      g_autoptr(NmcCompressionReply) reply = ToReply(outcome);
      nmc_media_compressor_host_api_respond_compress_video(response.get(), reply);
    });
  };
  self->video_queue->Enqueue(std::move(task));
}

void HandleCompressImage(NmcImageRequest* request,
                         NmcMediaCompressorHostApiResponseHandle* response_handle, gpointer) {
  nmc::ImageJob job;
  job.source = nmc_image_request_get_source(request);
  job.destination = nmc_image_request_get_destination(request);
  job.bounds.max_short_side = Optional(nmc_image_request_get_max_short_side(request));
  job.bounds.max_long_side = Optional(nmc_image_request_get_max_long_side(request));
  job.format = nmc_image_request_get_format(request);
  job.quality = nmc_image_request_get_quality(request);
  job.keep_metadata = nmc_image_request_get_keep_metadata(request);
  auto response = Retain(response_handle);
  RunInBackground([job, response] {
    const nmc::Outcome outcome = nmc::CompressImageFile(job);
    PostToMain([response, outcome] {
      g_autoptr(NmcCompressionReply) reply = ToReply(outcome);
      nmc_media_compressor_host_api_respond_compress_image(response.get(), reply);
    });
  });
}

NmcMediaCompressorHostApiCancelResponse* HandleCancel(int64_t task_id, gpointer user_data) {
  NATIVE_MEDIA_COMPRESSOR_PLUGIN(user_data)->video_queue->Cancel(task_id);
  return nmc_media_compressor_host_api_cancel_response_new();
}

void HandleProbeImage(const gchar* source,
                      NmcMediaCompressorHostApiResponseHandle* response_handle, gpointer) {
  auto response = Retain(response_handle);
  RunInBackground([path = std::string(source), response] {
    const std::optional<nmc::ImageInfo> info = nmc::ProbeImageFile(path);
    PostToMain([response, info] {
      int64_t size_bytes = info ? info->size_bytes.value_or(0) : 0;
      g_autoptr(NmcImageProbe) probe =
          info ? nmc_image_probe_new(info->width, info->height, info->frame_count,
                                     info->mime_type.c_str(),
                                     info->size_bytes ? &size_bytes : nullptr)
               : nullptr;
      nmc_media_compressor_host_api_respond_probe_image(response.get(), probe);
    });
  });
}

void HandleProbeVideo(const gchar* source,
                      NmcMediaCompressorHostApiResponseHandle* response_handle, gpointer) {
  auto response = Retain(response_handle);
  RunInBackground([path = std::string(source), response] {
    const std::optional<nmc::VideoInfo> info = nmc::ProbeVideoFile(path);
    PostToMain([response, info] {
      g_autoptr(NmcVideoProbe) probe = nullptr;
      if (info) {
        int64_t bitrate = info->bitrate.value_or(0);
        double frame_rate = info->frame_rate.value_or(0);
        int64_t audio_track_count = info->audio_track_count;
        int64_t size_bytes = info->size_bytes.value_or(0);
        probe = nmc_video_probe_new(info->width, info->height, info->rotation_degrees,
                                    info->duration_ms, info->bitrate ? &bitrate : nullptr,
                                    info->video_codec.c_str(), info->is_hdr, info->has_audio,
                                    info->has_audio ? info->audio_codec.c_str() : nullptr,
                                    info->frame_rate ? &frame_rate : nullptr, &audio_track_count,
                                    info->size_bytes ? &size_bytes : nullptr);
      }
      nmc_media_compressor_host_api_respond_probe_video(response.get(), probe);
    });
  });
}

void HandleVideoThumbnail(NmcThumbnailRequest* request,
                          NmcMediaCompressorHostApiResponseHandle* response_handle, gpointer) {
  nmc::ThumbnailJob job;
  job.source = nmc_thumbnail_request_get_source(request);
  job.destination = nmc_thumbnail_request_get_destination(request);
  job.position_ms = nmc_thumbnail_request_get_position_ms(request);
  job.bounds.max_short_side = Optional(nmc_thumbnail_request_get_max_short_side(request));
  job.bounds.max_long_side = Optional(nmc_thumbnail_request_get_max_long_side(request));
  job.format = nmc_thumbnail_request_get_format(request);
  job.quality = nmc_thumbnail_request_get_quality(request);
  auto response = Retain(response_handle);
  RunInBackground([job, response] {
    const nmc::Outcome outcome = nmc::VideoThumbnail(job);
    PostToMain([response, outcome] {
      g_autoptr(NmcCompressionReply) reply = ToReply(outcome);
      nmc_media_compressor_host_api_respond_video_thumbnail(response.get(), reply);
    });
  });
}

// The generated channel code is C: exceptions must not unwind into it.
NmcCompressionReply* FailureReply(const std::exception& error) {
  return nmc_compression_reply_new(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, nullptr,
                                   nullptr, nullptr, error.what(), nullptr);
}

void GuardedCompressVideo(int64_t task_id, NmcVideoRequest* request,
                          NmcMediaCompressorHostApiResponseHandle* response_handle,
                          gpointer user_data) {
  try {
    HandleCompressVideo(task_id, request, response_handle, user_data);
  } catch (const std::exception& error) {
    g_autoptr(NmcCompressionReply) reply = FailureReply(error);
    nmc_media_compressor_host_api_respond_compress_video(response_handle, reply);
  }
}

void GuardedCompressImage(NmcImageRequest* request,
                          NmcMediaCompressorHostApiResponseHandle* response_handle,
                          gpointer user_data) {
  try {
    HandleCompressImage(request, response_handle, user_data);
  } catch (const std::exception& error) {
    g_autoptr(NmcCompressionReply) reply = FailureReply(error);
    nmc_media_compressor_host_api_respond_compress_image(response_handle, reply);
  }
}

NmcMediaCompressorHostApiCancelResponse* GuardedCancel(int64_t task_id, gpointer user_data) {
  try {
    return HandleCancel(task_id, user_data);
  } catch (const std::exception&) {
    return nmc_media_compressor_host_api_cancel_response_new();
  }
}

void GuardedProbeImage(const gchar* source,
                       NmcMediaCompressorHostApiResponseHandle* response_handle,
                       gpointer user_data) {
  try {
    HandleProbeImage(source, response_handle, user_data);
  } catch (const std::exception&) {
    nmc_media_compressor_host_api_respond_probe_image(response_handle, nullptr);
  }
}

void GuardedProbeVideo(const gchar* source,
                       NmcMediaCompressorHostApiResponseHandle* response_handle,
                       gpointer user_data) {
  try {
    HandleProbeVideo(source, response_handle, user_data);
  } catch (const std::exception&) {
    nmc_media_compressor_host_api_respond_probe_video(response_handle, nullptr);
  }
}

void GuardedVideoThumbnail(NmcThumbnailRequest* request,
                           NmcMediaCompressorHostApiResponseHandle* response_handle,
                           gpointer user_data) {
  try {
    HandleVideoThumbnail(request, response_handle, user_data);
  } catch (const std::exception& error) {
    g_autoptr(NmcCompressionReply) reply = FailureReply(error);
    nmc_media_compressor_host_api_respond_video_thumbnail(response_handle, reply);
  }
}

// Linux has no background execution limits to work around.
NmcMediaCompressorHostApiSetForegroundNotificationResponse* HandleSetForegroundNotification(
    NmcForegroundNotification*, gpointer) {
  return nmc_media_compressor_host_api_set_foreground_notification_response_new();
}

const NmcMediaCompressorHostApiVTable kHostApi = {
    GuardedCompressVideo, GuardedCompressImage, GuardedCancel,
    GuardedProbeImage,    GuardedProbeVideo,    GuardedVideoThumbnail,
    HandleSetForegroundNotification,
};

}  // namespace

static void native_media_compressor_plugin_dispose(GObject* object) {
  NativeMediaCompressorPlugin* self = NATIVE_MEDIA_COMPRESSOR_PLUGIN(object);
  delete self->video_queue;
  self->video_queue = nullptr;
  g_clear_object(&self->flutter_api);
  G_OBJECT_CLASS(native_media_compressor_plugin_parent_class)->dispose(object);
}

static void native_media_compressor_plugin_class_init(NativeMediaCompressorPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = native_media_compressor_plugin_dispose;
}

static void native_media_compressor_plugin_init(NativeMediaCompressorPlugin* self) {
  self->flutter_api = nullptr;
  self->video_queue = new nmc::VideoQueue([](nmc::VideoQueue::Task& task) {
    return nmc::TranscodeVideo(task.job, task.cancelled, task.on_progress);
  });
}

void native_media_compressor_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  NativeMediaCompressorPlugin* plugin = NATIVE_MEDIA_COMPRESSOR_PLUGIN(
      g_object_new(native_media_compressor_plugin_get_type(), nullptr));
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  plugin->flutter_api = nmc_media_compressor_flutter_api_new(messenger, nullptr);
  nmc_media_compressor_host_api_set_method_handlers(messenger, nullptr, &kHostApi,
                                                    g_object_ref(plugin), g_object_unref);
  g_object_unref(plugin);
}
