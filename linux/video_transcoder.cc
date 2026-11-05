#include "video_transcoder.h"

#include <glib.h>

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include "gst_api.h"

namespace native_media_compressor {

std::string NormalizeVideoCodec(const std::string& caps_name) {
  if (caps_name == "video/x-h264") return "video/avc";
  if (caps_name == "video/x-h265") return "video/hevc";
  if (caps_name == "video/x-vp8") return "video/x-vnd.on2.vp8";
  if (caps_name == "video/x-vp9") return "video/x-vnd.on2.vp9";
  if (caps_name == "video/x-av1") return "video/av01";
  return caps_name;
}

std::string NormalizeAudioCodec(const std::string& caps_name, int mpeg_version) {
  if (caps_name == "audio/mpeg") {
    return mpeg_version == 2 || mpeg_version == 4 ? "audio/mp4a-latm" : "audio/mpeg";
  }
  if (caps_name == "audio/x-opus") return "audio/opus";
  if (caps_name == "audio/x-ac3" || caps_name == "audio/ac3") return "audio/ac3";
  if (caps_name == "audio/x-eac3" || caps_name == "audio/eac3") return "audio/eac3";
  if (caps_name == "audio/x-flac") return "audio/flac";
  return caps_name;
}

#ifndef NMC_HAVE_GST_HEADERS

std::optional<VideoInfo> ProbeVideoFile(const std::string&) { return std::nullopt; }

Outcome TranscodeVideo(const VideoJob& job, const std::atomic<bool>&,
                       const std::function<void(double)>&) {
  RemoveFile(job.destination);
  return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED,
                     "Built without GStreamer headers");
}

#else

namespace {

constexpr const char* kAacMime = "audio/mp4a-latm";

struct Discovery {
  enum class Result { kOk, kNoVideo, kUnreadable };
  Result result = Result::kUnreadable;
  std::string error;
  VideoInfo info;
  GstVideoOrientationMethod orientation = GST_VIDEO_ORIENTATION_IDENTITY;
  std::vector<std::string> audio_codecs;
  // Owned; parsed caps of the video stream, for finding a decoder.
  GstCaps* video_caps = nullptr;
};

struct OrientationTag {
  const char* tag;
  int64_t degrees;
  GstVideoOrientationMethod method;
};

constexpr OrientationTag kOrientations[] = {
    {"rotate-0", 0, GST_VIDEO_ORIENTATION_IDENTITY},
    {"rotate-90", 90, GST_VIDEO_ORIENTATION_90R},
    {"rotate-180", 180, GST_VIDEO_ORIENTATION_180},
    {"rotate-270", 270, GST_VIDEO_ORIENTATION_90L},
    {"flip-rotate-0", 0, GST_VIDEO_ORIENTATION_HORIZ},
    {"flip-rotate-90", 90, GST_VIDEO_ORIENTATION_UL_LR},
    {"flip-rotate-180", 180, GST_VIDEO_ORIENTATION_VERT},
    {"flip-rotate-270", 270, GST_VIDEO_ORIENTATION_UR_LL},
};

const OrientationTag* FindOrientation(const GstApi* g, const GstTagList* tags) {
  if (tags == nullptr) return nullptr;
  gchar* value = nullptr;
  if (!g->gst_tag_list_get_string(tags, GST_TAG_IMAGE_ORIENTATION, &value)) return nullptr;
  const OrientationTag* found = nullptr;
  for (const auto& orientation : kOrientations) {
    if (strcmp(value, orientation.tag) == 0) found = &orientation;
  }
  g_free(value);
  return found;
}

bool IsHdr(const GstApi* g, const GstStructure* structure) {
  const gchar* colorimetry = g->gst_structure_get_string(structure, "colorimetry");
  if (colorimetry == nullptr) {
    return g->gst_structure_has_field(structure, "mastering-display-info");
  }
  GstVideoColorimetry parsed;
  if (g->gst_video_colorimetry_from_string != nullptr &&
      g->gst_video_colorimetry_from_string(&parsed, colorimetry)) {
    return parsed.transfer == GST_VIDEO_TRANSFER_SMPTE2084 ||
           parsed.transfer == GST_VIDEO_TRANSFER_ARIB_STD_B67;
  }
  return strstr(colorimetry, "pq") != nullptr || strstr(colorimetry, "hlg") != nullptr;
}

std::string CapsName(const GstApi* g, const GstCaps* caps, int* mpeg_version = nullptr) {
  if (caps == nullptr || g->gst_caps_get_size(caps) == 0) return {};
  const GstStructure* structure = g->gst_caps_get_structure(caps, 0);
  if (mpeg_version != nullptr) {
    *mpeg_version = 0;
    g->gst_structure_get_int(structure, "mpegversion", mpeg_version);
  }
  return g->gst_structure_get_name(structure);
}

Discovery Discover(const GstApi* g, const std::string& path) {
  Discovery discovery;
  GError* error = nullptr;
  GstDiscoverer* discoverer = g->gst_discoverer_new(15 * GST_SECOND, &error);
  gchar* uri = discoverer != nullptr ? g->gst_filename_to_uri(path.c_str(), &error) : nullptr;
  GstDiscovererInfo* info =
      uri != nullptr ? g->gst_discoverer_discover_uri(discoverer, uri, &error) : nullptr;
  g_free(uri);
  if (discoverer != nullptr) g_object_unref(discoverer);
  if (error != nullptr) {
    discovery.error = error->message;
    g_clear_error(&error);
  }
  if (info == nullptr) return discovery;

  const GstDiscovererResult result = g->gst_discoverer_info_get_result(info);
  if (result != GST_DISCOVERER_OK && result != GST_DISCOVERER_MISSING_PLUGINS) {
    g_object_unref(info);
    if (discovery.error.empty()) discovery.error = "The file could not be read";
    return discovery;
  }

  GList* videos = g->gst_discoverer_info_get_video_streams(info);
  GstDiscovererStreamInfo* video = nullptr;
  for (GList* item = videos; item != nullptr; item = item->next) {
    auto* candidate = static_cast<GstDiscovererVideoInfo*>(item->data);
    if (!g->gst_discoverer_video_info_is_image(candidate)) {
      video = reinterpret_cast<GstDiscovererStreamInfo*>(candidate);
      break;
    }
  }
  if (video == nullptr) {
    g->gst_discoverer_stream_info_list_free(videos);
    g_object_unref(info);
    discovery.result = Discovery::Result::kNoVideo;
    return discovery;
  }

  auto* video_info = reinterpret_cast<GstDiscovererVideoInfo*>(video);
  const int64_t coded_width = g->gst_discoverer_video_info_get_width(video_info);
  const int64_t coded_height = g->gst_discoverer_video_info_get_height(video_info);
  const OrientationTag* orientation = FindOrientation(g, g->gst_discoverer_stream_info_get_tags(video));
  if (orientation == nullptr) orientation = FindOrientation(g, g->gst_discoverer_info_get_tags(info));
  const bool swapped = orientation != nullptr && orientation->degrees % 180 != 0;
  discovery.info.width = swapped ? coded_height : coded_width;
  discovery.info.height = swapped ? coded_width : coded_height;
  if (orientation != nullptr) {
    discovery.info.rotation_degrees = orientation->degrees;
    discovery.orientation = orientation->method;
  }

  discovery.video_caps = g->gst_discoverer_stream_info_get_caps(video);
  discovery.info.video_codec = NormalizeVideoCodec(CapsName(g, discovery.video_caps));
  if (discovery.video_caps != nullptr && g->gst_caps_get_size(discovery.video_caps) > 0) {
    discovery.info.is_hdr = IsHdr(g, g->gst_caps_get_structure(discovery.video_caps, 0));
  }
  g->gst_discoverer_stream_info_list_free(videos);

  const GstClockTime duration = g->gst_discoverer_info_get_duration(info);
  discovery.info.duration_ms =
      GST_CLOCK_TIME_IS_VALID(duration) ? static_cast<int64_t>(duration / GST_MSECOND) : 0;

  GList* audios = g->gst_discoverer_info_get_audio_streams(info);
  for (GList* item = audios; item != nullptr; item = item->next) {
    GstCaps* caps = g->gst_discoverer_stream_info_get_caps(static_cast<GstDiscovererStreamInfo*>(item->data));
    int mpeg_version = 0;
    const std::string name = CapsName(g, caps, &mpeg_version);
    g->Unref(caps);
    discovery.audio_codecs.push_back(NormalizeAudioCodec(name, mpeg_version));
  }
  g->gst_discoverer_stream_info_list_free(audios);
  g_object_unref(info);

  discovery.info.has_audio = !discovery.audio_codecs.empty();
  if (discovery.info.has_audio) discovery.info.audio_codec = discovery.audio_codecs.front();
  const int64_t size = FileSize(path);
  if (size > 0 && discovery.info.duration_ms > 0) {
    discovery.info.bitrate = size * 8 * 1000 / discovery.info.duration_ms;
  }
  discovery.result = Discovery::Result::kOk;
  return discovery;
}

struct DiscoveryHolder {
  const GstApi* g;
  Discovery discovery;
  ~DiscoveryHolder() { g->Unref(discovery.video_caps); }
};

bool HasDecoder(const GstApi* g, const GstCaps* caps) {
  if (caps == nullptr) return false;
  GList* decoders = g->gst_element_factory_list_get_elements(
      GST_ELEMENT_FACTORY_TYPE_DECODER | GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO, GST_RANK_MARGINAL);
  GList* usable = g->gst_element_factory_list_filter(decoders, caps, GST_PAD_SINK, FALSE);
  const bool found = usable != nullptr;
  g->gst_plugin_feature_list_free(usable);
  g->gst_plugin_feature_list_free(decoders);
  return found;
}

bool HasProperty(GstElement* element, const char* name) {
  return g_object_class_find_property(G_OBJECT_GET_CLASS(element), name) != nullptr;
}

void ConfigureEncoder(const GstApi* g, GstElement* encoder, const std::string& factory,
                      int64_t bitrate) {
  bitrate = std::clamp<int64_t>(bitrate, 10000, 1000000000);
  g_autofree gchar* bps = g_strdup_printf("%" G_GINT64_FORMAT, bitrate);
  g_autofree gchar* kbps = g_strdup_printf("%" G_GINT64_FORMAT, bitrate / 1000);
  if (factory == "x264enc") {
    g->gst_util_set_object_arg(G_OBJECT(encoder), "bitrate", kbps);
    g->gst_util_set_object_arg(G_OBJECT(encoder), "speed-preset", "faster");
  } else if (factory == "openh264enc") {
    g->gst_util_set_object_arg(G_OBJECT(encoder), "bitrate", bps);
    if (HasProperty(encoder, "rate-control")) {
      g->gst_util_set_object_arg(G_OBJECT(encoder), "rate-control", "bitrate");
    }
  } else if (factory == "v4l2h264enc") {
    g_autofree gchar* controls = g_strdup_printf("controls,video_bitrate=%s", bps);
    g->gst_util_set_object_arg(G_OBJECT(encoder), "extra-controls", controls);
  } else if (HasProperty(encoder, "bitrate")) {
    g->gst_util_set_object_arg(G_OBJECT(encoder), "bitrate", kbps);
  }
}

// Owns the transcoding pipeline. Pad callbacks run on GStreamer streaming
// threads, so the linking state is guarded by `mutex`.
struct Graph {
  struct AudioBranch {
    GstElement* queue = nullptr;
    GstPad* mux_pad = nullptr;
    bool used = false;
  };

  explicit Graph(const GstApi* api) : g(api), pipeline(api->gst_pipeline_new(nullptr)) {}

  ~Graph() {
    if (pipeline == nullptr) return;
    g->gst_element_set_state(pipeline, GST_STATE_NULL);
    for (GstPad* pad : mux_pads) g->gst_object_unref(pad);
    g->gst_object_unref(pipeline);
  }

  GstElement* Add(const char* factory) {
    GstElement* element = g->gst_element_factory_make(factory, nullptr);
    if (element == nullptr) {
      if (!missing.empty()) missing += ", ";
      missing += factory;
      return nullptr;
    }
    g->gst_bin_add(GST_BIN_CAST(pipeline), element);
    return element;
  }

  GstPad* LinkToMux(GstElement* upstream, const char* pad_template) {
    GstPad* mux_pad = g->gst_element_request_pad_simple(mux, pad_template);
    if (mux_pad == nullptr) return nullptr;
    mux_pads.push_back(mux_pad);
    GstPad* source = g->gst_element_get_static_pad(upstream, "src");
    const bool linked = g->gst_pad_link(source, mux_pad) == GST_PAD_LINK_OK;
    g->gst_object_unref(source);
    return linked ? mux_pad : nullptr;
  }

  bool LinkPad(GstPad* pad, GstElement* target) {
    GstPad* sink = g->gst_element_get_static_pad(target, "sink");
    const bool linked = g->gst_pad_link(pad, sink) == GST_PAD_LINK_OK;
    g->gst_object_unref(sink);
    return linked;
  }

  // Unused streams still need a sink, or the demuxer stops with not-linked.
  void Discard(GstPad* pad) {
    GstElement* sink = g->gst_element_factory_make("fakesink", nullptr);
    if (sink == nullptr) return;
    g_object_set(sink, "sync", FALSE, "async", FALSE, nullptr);
    g->gst_bin_add(GST_BIN_CAST(pipeline), sink);
    g->gst_element_sync_state_with_parent(sink);
    LinkPad(pad, sink);
  }

  const GstApi* g;
  GstElement* pipeline;
  GstElement* mux = nullptr;
  GstElement* video_queue = nullptr;
  GstElement* video_rate = nullptr;
  std::vector<AudioBranch> audio;
  std::vector<GstPad*> mux_pads;
  std::string missing;

  std::mutex mutex;
  bool video_linked = false;
  bool raw_linked = false;

  int64_t max_bytes = 0;
  std::atomic<int64_t> bytes{0};
  std::atomic<int64_t> video_position{0};
  std::atomic<bool> too_large{false};
};

std::string PadMediaType(const GstApi* g, GstPad* pad) {
  GstCaps* caps = g->gst_pad_get_current_caps(pad);
  if (caps == nullptr) caps = g->gst_pad_query_caps(pad, nullptr);
  std::string name = CapsName(g, caps);
  g->Unref(caps);
  return name;
}

void OnParsedPad(GstElement*, GstPad* pad, gpointer data) {
  auto* graph = static_cast<Graph*>(data);
  const std::string media = PadMediaType(graph->g, pad);
  std::lock_guard<std::mutex> lock(graph->mutex);
  GstElement* target = nullptr;
  if (g_str_has_prefix(media.c_str(), "video/") && !graph->video_linked) {
    graph->video_linked = true;
    target = graph->video_queue;
  } else if (g_str_has_prefix(media.c_str(), "audio/")) {
    for (auto& branch : graph->audio) {
      if (branch.used) continue;
      branch.used = true;
      target = branch.queue;
      break;
    }
  }
  if (target == nullptr || !graph->LinkPad(pad, target)) graph->Discard(pad);
}

void OnParsedPadsDone(GstElement*, gpointer data) {
  auto* graph = static_cast<Graph*>(data);
  std::lock_guard<std::mutex> lock(graph->mutex);
  // The muxer waits for data on every pad before writing anything.
  for (auto& branch : graph->audio) {
    if (!branch.used) graph->g->gst_element_release_request_pad(graph->mux, branch.mux_pad);
  }
}

void OnDecodedPad(GstElement*, GstPad* pad, gpointer data) {
  auto* graph = static_cast<Graph*>(data);
  const std::string media = PadMediaType(graph->g, pad);
  std::lock_guard<std::mutex> lock(graph->mutex);
  if (media == "video/x-raw" && !graph->raw_linked && graph->LinkPad(pad, graph->video_rate)) {
    graph->raw_linked = true;
    return;
  }
  graph->Discard(pad);
}

GstPadProbeReturn CountMuxInput(Graph* graph, GstPadProbeInfo* info, bool video) {
  if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER) {
    GstBuffer* buffer = GST_PAD_PROBE_INFO_BUFFER(info);
    const int64_t total = graph->bytes += static_cast<int64_t>(graph->g->gst_buffer_get_size(buffer));
    if (graph->max_bytes > 0 && total > graph->max_bytes) {
      graph->too_large = true;
      return GST_PAD_PROBE_DROP;
    }
    if (video && GST_BUFFER_PTS_IS_VALID(buffer)) {
      const auto pts = static_cast<int64_t>(GST_BUFFER_PTS(buffer));
      int64_t seen = graph->video_position.load();
      while (pts > seen && !graph->video_position.compare_exchange_weak(seen, pts)) {
      }
    }
    return GST_PAD_PROBE_OK;
  }
  // Orientation is baked into the pixels; a rotation tag reaching the muxer
  // would make players rotate the frame a second time. Other tags are
  // metadata, which is not copied either.
  GstEvent* event = GST_PAD_PROBE_INFO_EVENT(info);
  return GST_EVENT_TYPE(event) == GST_EVENT_TAG ? GST_PAD_PROBE_DROP : GST_PAD_PROBE_OK;
}

GstPadProbeReturn OnVideoMuxInput(GstPad*, GstPadProbeInfo* info, gpointer data) {
  return CountMuxInput(static_cast<Graph*>(data), info, true);
}

GstPadProbeReturn OnAudioMuxInput(GstPad*, GstPadProbeInfo* info, gpointer data) {
  return CountMuxInput(static_cast<Graph*>(data), info, false);
}

constexpr GstPadProbeType kMuxProbeMask =
    static_cast<GstPadProbeType>(GST_PAD_PROBE_TYPE_BUFFER | GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM);

Outcome Unsupported(std::string message) {
  return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED, std::move(message));
}

Outcome Failed(std::string message) {
  return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_FAILED, std::move(message));
}

Outcome Cancelled() { return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_CANCELLED); }

Outcome ClassifyError(const GstApi* g, GstMessage* message) {
  GError* error = nullptr;
  gchar* debug = nullptr;
  g->gst_message_parse_error(message, &error, &debug);
  const bool missing_codec =
      error != nullptr &&
      ((error->domain == g->gst_core_error_quark() && error->code == GST_CORE_ERROR_MISSING_PLUGIN) ||
       (error->domain == g->gst_stream_error_quark() &&
        error->code == GST_STREAM_ERROR_CODEC_NOT_FOUND));
  std::string text = error != nullptr ? error->message : "GStreamer error";
  if (debug != nullptr) text = text + " (" + debug + ")";
  g_clear_error(&error);
  g_free(debug);
  return missing_codec ? Unsupported(text) : Failed(text);
}

class ProgressThrottle {
 public:
  explicit ProgressThrottle(const std::function<void(double)>& sink) : sink_(sink) {}

  void Report(double value) {
    value = std::clamp(value, 0.0, 0.99);
    if (value <= last_) return;
    const gint64 now = g_get_monotonic_time();
    if (value - last_ < 0.01 && now - last_time_ < 100000) return;
    last_ = value;
    last_time_ = now;
    if (sink_) sink_(value);
  }

  void Finish() {
    if (sink_) sink_(1.0);
  }

 private:
  const std::function<void(double)>& sink_;
  double last_ = 0;
  gint64 last_time_ = 0;
};

Outcome Run(const GstApi* g, const VideoJob& job, const Discovery& discovery,
            const std::atomic<bool>& cancelled, const std::function<void(double)>& on_progress) {
  const VideoInfo& info = discovery.info;
  const double scale = FitScale(info.width, info.height, job.bounds);
  const int64_t width = ScaledEvenSide(info.width, scale);
  const int64_t height = ScaledEvenSide(info.height, scale);

  Graph graph(g);
  if (graph.pipeline == nullptr) return Failed("Could not create a pipeline");
  graph.max_bytes = job.max_bytes.value_or(0);

  GstElement* source = graph.Add("filesrc");
  GstElement* parser = graph.Add("parsebin");
  graph.video_queue = graph.Add("queue");
  GstElement* decoder = graph.Add("decodebin");
  graph.video_rate = graph.Add("videorate");
  GstElement* convert = graph.Add("videoconvert");
  GstElement* scaler = graph.Add("videoscale");
  GstElement* flip = graph.Add("videoflip");
  GstElement* filter = graph.Add("capsfilter");
  graph.mux = graph.Add("mp4mux");
  GstElement* sink = graph.Add("filesink");
  if (!graph.missing.empty()) return Unsupported("Missing GStreamer elements: " + graph.missing);

  GstElement* encoder = nullptr;
  std::string encoder_name;
  for (const char* name : {"x264enc", "openh264enc", "vah264enc", "vaapih264enc", "v4l2h264enc"}) {
    encoder = g->gst_element_factory_make(name, nullptr);
    if (encoder != nullptr) {
      encoder_name = name;
      g->gst_bin_add(GST_BIN_CAST(graph.pipeline), encoder);
      break;
    }
  }
  if (encoder == nullptr) return Unsupported("No H.264 encoder in GStreamer");
  ConfigureEncoder(g, encoder, encoder_name, job.video_bitrate);
  GstElement* h264_parser = g->gst_element_factory_make("h264parse", nullptr);
  if (h264_parser != nullptr) g->gst_bin_add(GST_BIN_CAST(graph.pipeline), h264_parser);

  g_object_set(source, "location", job.source.c_str(), nullptr);
  g_object_set(sink, "location", job.destination.c_str(), nullptr);
  g_object_set(graph.mux, "faststart", TRUE, nullptr);
  g_object_set(scaler, "add-borders", FALSE, nullptr);
  g_object_set(flip, "video-direction", discovery.orientation, nullptr);
  g_object_set(graph.video_rate, "drop-only", TRUE, nullptr);
  if (job.max_frame_rate && *job.max_frame_rate > 0) {
    g_object_set(graph.video_rate, "max-rate", static_cast<gint>(*job.max_frame_rate), nullptr);
  }
  g_autofree gchar* raw_caps = g_strdup_printf(
      "video/x-raw,format=I420,width=%" G_GINT64_FORMAT ",height=%" G_GINT64_FORMAT
      ",pixel-aspect-ratio=1/1",
      width, height);
  GstCaps* caps = g->gst_caps_from_string(raw_caps);
  g_object_set(filter, "caps", caps, nullptr);
  g->Unref(caps);

  GstElement* video_tail = h264_parser != nullptr ? h264_parser : encoder;
  bool linked = g->gst_element_link(source, parser) &&
                g->gst_element_link(graph.video_queue, decoder) &&
                g->gst_element_link(graph.video_rate, convert) && g->gst_element_link(convert, scaler) &&
                g->gst_element_link(scaler, flip) && g->gst_element_link(flip, filter) &&
                g->gst_element_link(filter, encoder) &&
                (h264_parser == nullptr || g->gst_element_link(encoder, h264_parser)) &&
                g->gst_element_link(graph.mux, sink);
  GstPad* video_pad = linked ? graph.LinkToMux(video_tail, "video_%u") : nullptr;
  if (video_pad == nullptr) return Failed("Could not link the video branch");
  g->gst_pad_add_probe(video_pad, kMuxProbeMask, OnVideoMuxInput, &graph, nullptr);

  if (job.include_audio) {
    for (size_t i = 0; i < discovery.audio_codecs.size(); i++) {
      GstElement* queue = graph.Add("queue");
      GstElement* aac_parser = graph.Add("aacparse");
      if (queue == nullptr || aac_parser == nullptr) {
        return Unsupported("Missing GStreamer elements: " + graph.missing);
      }
      // Audio runs far ahead of the encoder's lookahead; a bounded queue would
      // block the demuxer and starve the video branch.
      g_object_set(queue, "max-size-buffers", 0u, "max-size-bytes", 0u, "max-size-time",
                   guint64{0}, nullptr);
      GstPad* audio_pad =
          g->gst_element_link(queue, aac_parser) ? graph.LinkToMux(aac_parser, "audio_%u") : nullptr;
      if (audio_pad == nullptr) return Failed("Could not link an audio branch");
      g->gst_pad_add_probe(audio_pad, kMuxProbeMask, OnAudioMuxInput, &graph, nullptr);
      graph.audio.push_back({queue, audio_pad, false});
    }
  }

  g_signal_connect(parser, "pad-added", G_CALLBACK(OnParsedPad), &graph);
  g_signal_connect(parser, "no-more-pads", G_CALLBACK(OnParsedPadsDone), &graph);
  g_signal_connect(decoder, "pad-added", G_CALLBACK(OnDecodedPad), &graph);

  if (g->gst_element_set_state(graph.pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
    return Failed("Could not start the pipeline");
  }

  GstBus* bus = g->gst_element_get_bus(graph.pipeline);
  ProgressThrottle progress(on_progress);
  const auto duration_ns = static_cast<double>(info.duration_ms) * GST_MSECOND;
  std::optional<Outcome> outcome;
  while (!outcome) {
    GstMessage* message = g->gst_bus_timed_pop_filtered(
        bus, 50 * GST_MSECOND,
        static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR | GST_MESSAGE_ELEMENT));
    if (message != nullptr) {
      switch (GST_MESSAGE_TYPE(message)) {
        case GST_MESSAGE_EOS:
          outcome = Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED);
          break;
        case GST_MESSAGE_ERROR:
          outcome = ClassifyError(g, message);
          break;
        case GST_MESSAGE_ELEMENT: {
          const GstStructure* structure = g->gst_message_get_structure(message);
          if (structure != nullptr && g->gst_structure_has_name(structure, "missing-plugin")) {
            outcome = Unsupported("A GStreamer plugin is missing for this file");
          }
          break;
        }
        default:
          break;
      }
      g->Unref(message);
    }
    if (outcome) break;
    if (cancelled) {
      outcome = Cancelled();
    } else if (graph.too_large) {
      outcome = Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_TOO_LARGE);
    } else if (duration_ns > 0) {
      progress.Report(static_cast<double>(graph.video_position.load()) / duration_ns);
    }
  }
  g->gst_object_unref(bus);
  g->gst_element_set_state(graph.pipeline, GST_STATE_NULL);

  if (outcome->status == NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) {
    const int64_t size = FileSize(job.destination);
    if (size <= 0) return Failed("The muxer wrote no output");
    if (graph.max_bytes > 0 && size > graph.max_bytes) {
      return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_TOO_LARGE);
    }
    progress.Finish();
    outcome->width = width;
    outcome->height = height;
    outcome->size_bytes = size;
  }
  return *outcome;
}

}  // namespace

std::optional<VideoInfo> ProbeVideoFile(const std::string& path) {
  const GstApi* g = LoadGstApi();
  if (g == nullptr) return std::nullopt;
  DiscoveryHolder holder{g, Discover(g, path)};
  if (holder.discovery.result != Discovery::Result::kOk) return std::nullopt;
  return holder.discovery.info;
}

Outcome TranscodeVideo(const VideoJob& job, const std::atomic<bool>& cancelled,
                       const std::function<void(double)>& on_progress) {
  RemoveFile(job.destination);
  const GstApi* g = LoadGstApi();
  if (g == nullptr) return Unsupported("GStreamer is not installed");
  if (cancelled) return Cancelled();

  DiscoveryHolder holder{g, Discover(g, job.source)};
  const Discovery& discovery = holder.discovery;
  if (discovery.result == Discovery::Result::kUnreadable) return Failed(discovery.error);
  if (discovery.result == Discovery::Result::kNoVideo) return Unsupported("No video track");
  if (discovery.info.is_hdr) return Unsupported("HDR video is not converted on Linux");
  if (job.include_audio) {
    for (const std::string& codec : discovery.audio_codecs) {
      if (codec != kAacMime) return Unsupported("Audio track is not AAC: " + codec);
    }
  }
  if (!HasDecoder(g, discovery.video_caps)) {
    return Unsupported("No GStreamer decoder for " + discovery.info.video_codec);
  }
  if (cancelled) return Cancelled();

  Outcome outcome = Run(g, job, discovery, cancelled, on_progress);
  if (outcome.status != NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED) {
    RemoveFile(job.destination);
  }
  return outcome;
}

#endif  // NMC_HAVE_GST_HEADERS

}  // namespace native_media_compressor
