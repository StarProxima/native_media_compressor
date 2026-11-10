#include "video_transcoder.h"

#include <glib.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <initializer_list>
#include <memory>
#include <mutex>
#include <vector>

#include "gst_api.h"
#include "image_codec.h"

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

std::vector<VideoEncoderChoice> VideoEncoderCandidates(bool hevc) {
  std::vector<VideoEncoderChoice> choices;
  if (hevc) {
    // mp4mux also takes hev1, which Apple players do not play. h265parse is
    // what turns the encoders' byte stream into hvc1.
    for (const char* encoder : {"x265enc", "vah265enc"}) {
      choices.push_back(
          {encoder, "h265parse", true, "video/x-h265,stream-format=hvc1,alignment=au", "video/hevc"});
    }
  }
  for (const char* encoder :
       {"x264enc", "openh264enc", "vah264enc", "vaapih264enc", "v4l2h264enc"}) {
    choices.push_back({encoder, "h264parse", false, nullptr, "video/avc"});
  }
  return choices;
}

std::vector<const char*> AacEncoderCandidates() { return {"avenc_aac", "voaacenc", "fdkaacenc"}; }

int CombineVideoOrientation(int method, int64_t quarter_turns) {
  // Each method as an optional horizontal flip followed by clockwise quarter
  // turns, indexed by its GstVideoOrientationMethod value.
  struct Transform {
    bool flip;
    int turns;
  };
  static constexpr Transform kTransforms[] = {
      {false, 0}, {false, 1}, {false, 2}, {false, 3},
      {true, 0},  {true, 2},  {true, 3},  {true, 1},
  };
  constexpr int kCount = static_cast<int>(sizeof kTransforms / sizeof kTransforms[0]);
  if (method < 0 || method >= kCount) method = kOrientationIdentity;
  const Transform& base = kTransforms[method];
  const int turns = static_cast<int>(((base.turns + quarter_turns) % 4 + 4) % 4);
  for (int candidate = 0; candidate < kCount; candidate++) {
    if (kTransforms[candidate].flip == base.flip && kTransforms[candidate].turns == turns) {
      return candidate;
    }
  }
  return kOrientationIdentity;
}

std::optional<KeptRange> ResolveKeptRange(std::optional<int64_t> start_ms,
                                          std::optional<int64_t> end_ms, int64_t duration_ms) {
  KeptRange range;
  range.start_ms = std::max<int64_t>(0, start_ms.value_or(0));
  if (end_ms) {
    range.end_ms = duration_ms > 0 ? std::min(*end_ms, duration_ms) : *end_ms;
  } else if (duration_ms > 0) {
    range.end_ms = duration_ms;
  }
  if (range.end_ms && *range.end_ms <= range.start_ms) return std::nullopt;
  range.partial =
      range.start_ms > 0 || (end_ms.has_value() && (duration_ms <= 0 || *end_ms < duration_ms));
  return range;
}

TrimStep TrimSample(int64_t time_ns, int64_t start_ns, int64_t end_ns) {
  if (time_ns < 0) return TrimStep::kDrop;
  if (end_ns >= 0 && time_ns >= end_ns) return TrimStep::kEnd;
  return time_ns < start_ns ? TrimStep::kDrop : TrimStep::kKeep;
}

FramePick PickThumbnailFrame(int64_t time_ns, int64_t position_ns, bool have_frame) {
  if (time_ns < 0 || time_ns <= position_ns) return FramePick::kTake;
  return have_frame ? FramePick::kStop : FramePick::kTakeAndStop;
}

int64_t ThumbnailSeekMs(int64_t position_ms, int64_t duration_ms) {
  if (position_ms <= 0) return -1;
  if (duration_ms > 0) return std::min(position_ms, std::max<int64_t>(0, duration_ms - 1));
  return position_ms;
}

int RgbRowStride(int width, int height, size_t size) {
  if (width <= 0 || height <= 0) return 0;
  const size_t packed = static_cast<size_t>(width) * 3;
  // GStreamer's default layout pads RGB rows to 4 bytes.
  const size_t padded = (packed + 3) & ~size_t{3};
  const auto rows = static_cast<size_t>(height);
  if (size >= padded * rows) return static_cast<int>(padded);
  if (size >= packed * rows) return static_cast<int>(packed);
  return 0;
}

#ifndef NMC_HAVE_GST_HEADERS

std::optional<VideoInfo> ProbeVideoFile(const std::string&) { return std::nullopt; }

Outcome TranscodeVideo(const VideoJob&, const std::atomic<bool>&,
                       const std::function<void(double)>&) {
  return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED,
                     "Built without GStreamer headers");
}

Outcome VideoThumbnail(const ThumbnailJob&) {
  return Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_UNSUPPORTED,
                     "Built without GStreamer headers");
}

#else

namespace {

static_assert(static_cast<int>(GST_VIDEO_ORIENTATION_IDENTITY) == kOrientationIdentity &&
                  static_cast<int>(GST_VIDEO_ORIENTATION_90R) == kOrientation90R &&
                  static_cast<int>(GST_VIDEO_ORIENTATION_180) == kOrientation180 &&
                  static_cast<int>(GST_VIDEO_ORIENTATION_90L) == kOrientation90L &&
                  static_cast<int>(GST_VIDEO_ORIENTATION_HORIZ) == kOrientationHoriz &&
                  static_cast<int>(GST_VIDEO_ORIENTATION_VERT) == kOrientationVert &&
                  static_cast<int>(GST_VIDEO_ORIENTATION_UL_LR) == kOrientationUlLr &&
                  static_cast<int>(GST_VIDEO_ORIENTATION_UR_LL) == kOrientationUrLl,
              "VideoOrientation must match GstVideoOrientationMethod");

constexpr const char* kAacMime = "audio/mp4a-latm";

// How long pads stay blocked for the trim seek when the parser never reports
// that all its streams are exposed.
constexpr gint64 kTrimSeekWaitUs = 10 * G_USEC_PER_SEC;

// A thumbnail decodes from the keyframe before the position; this bounds a
// pipeline that stalls instead of failing.
constexpr gint64 kThumbnailTimeoutUs = 120 * G_USEC_PER_SEC;

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
  // Demuxers report 0/1 for a variable frame rate they cannot average.
  const guint rate_num = g->gst_discoverer_video_info_get_framerate_num(video_info);
  const guint rate_den = g->gst_discoverer_video_info_get_framerate_denom(video_info);
  if (rate_num > 0 && rate_den > 0) {
    discovery.info.frame_rate = static_cast<double>(rate_num) / static_cast<double>(rate_den);
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
  if (factory == "x264enc" || factory == "x265enc") {
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

std::string PadCaps(const GstApi* g, GstPad* pad, int* mpeg_version = nullptr) {
  GstCaps* caps = g->gst_pad_get_current_caps(pad);
  if (caps == nullptr) caps = g->gst_pad_query_caps(pad, nullptr);
  std::string name = CapsName(g, caps, mpeg_version);
  g->Unref(caps);
  return name;
}

// Owns a pipeline. Pad callbacks run on GStreamer streaming threads, so the
// linking state of the graphs below is guarded by `mutex`.
struct Pipeline {
  explicit Pipeline(const GstApi* api) : g(api), pipeline(api->gst_pipeline_new(nullptr)) {}

  ~Pipeline() {
    if (pipeline == nullptr) return;
    g->gst_element_set_state(pipeline, GST_STATE_NULL);
    g->gst_object_unref(pipeline);
  }

  Pipeline(const Pipeline&) = delete;
  Pipeline& operator=(const Pipeline&) = delete;

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
  std::string missing;
  std::mutex mutex;
};

struct Graph;

// Cuts one stream to the kept range and shifts its timestamps so the range
// starts at 0. Touched only by that stream's streaming thread.
struct TrimPoint {
  Graph* graph = nullptr;
  GstSegment segment{};
  bool has_segment = false;
  bool ended = false;
};

// The transcoding pipeline.
struct Graph : Pipeline {
  struct AudioBranch {
    Graph* graph = nullptr;
    // AAC is copied; anything else is decoded and re-encoded to AAC.
    bool copy = true;
    GstElement* queue = nullptr;
    // Where decoded audio enters a re-encoded branch.
    GstElement* raw_head = nullptr;
    GstPad* mux_pad = nullptr;
    bool used = false;
    bool raw_linked = false;
  };

  struct BlockedPad {
    GstPad* pad;
    gulong probe;
  };

  using Pipeline::Pipeline;

  ~Graph() {
    if (pipeline == nullptr) return;
    g->gst_element_set_state(pipeline, GST_STATE_NULL);
    for (const BlockedPad& blocked_pad : blocked) g->gst_object_unref(blocked_pad.pad);
    for (GstPad* pad : mux_pads) g->gst_object_unref(pad);
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

  GstElement* mux = nullptr;
  GstElement* video_queue = nullptr;
  GstElement* video_rate = nullptr;
  // Stable addresses: decodebin callbacks hold pointers to the branches.
  std::vector<std::unique_ptr<AudioBranch>> audio;
  std::vector<std::unique_ptr<TrimPoint>> trim_points;
  std::vector<GstPad*> mux_pads;

  bool video_linked = false;
  bool raw_linked = false;

  bool trimming = false;
  int64_t trim_start_ns = 0;
  // Negative keeps to the end.
  int64_t trim_end_ns = -1;
  // Parsed pads stay blocked until the demuxer has seeked to the kept range,
  // so nothing before it is decoded or reaches the muxer.
  bool seek_pending = false;
  std::vector<BlockedPad> blocked;
  std::atomic<bool> pads_done{false};

  int64_t max_bytes = 0;
  std::atomic<int64_t> bytes{0};
  std::atomic<int64_t> video_position{0};
  std::atomic<bool> too_large{false};
};

GstPadProbeReturn KeepBlocked(GstPad*, GstPadProbeInfo*, gpointer) { return GST_PAD_PROBE_OK; }

// Called with the graph mutex held.
void BlockForTrimSeek(Graph* graph, GstPad* pad) {
  if (!graph->seek_pending) return;
  const GstApi* g = graph->g;
  const gulong probe =
      g->gst_pad_add_probe(pad, GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, KeepBlocked, nullptr, nullptr);
  if (probe == 0) return;
  g->gst_object_ref(pad);
  graph->blocked.push_back({pad, probe});
}

// Seeks the demuxer to the kept range, then lets the parsed streams flow.
void ReleaseForTrim(Graph* graph, bool seek) {
  std::vector<Graph::BlockedPad> blocked;
  {
    std::lock_guard<std::mutex> lock(graph->mutex);
    if (!graph->seek_pending) return;
    graph->seek_pending = false;
    blocked.swap(graph->blocked);
  }
  const GstApi* g = graph->g;
  if (seek && !blocked.empty()) {
    const bool bounded = graph->trim_end_ns >= 0;
    GstEvent* event = g->gst_event_new_seek(
        1.0, GST_FORMAT_TIME, static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE),
        GST_SEEK_TYPE_SET, graph->trim_start_ns, bounded ? GST_SEEK_TYPE_SET : GST_SEEK_TYPE_NONE,
        bounded ? graph->trim_end_ns : -1);
    // A refused seek only costs decoding time: the trim points still cut the
    // range out of a stream that starts at 0.
    if (event != nullptr) g->gst_pad_send_event(blocked.front().pad, event);
  }
  for (const Graph::BlockedPad& entry : blocked) {
    g->gst_pad_remove_probe(entry.pad, entry.probe);
    g->gst_object_unref(entry.pad);
  }
}

int64_t StreamTime(const GstApi* g, const TrimPoint* point, GstClockTime position) {
  if (!GST_CLOCK_TIME_IS_VALID(position)) return -1;
  if (!point->has_segment) return static_cast<int64_t>(position);
  const guint64 time = g->gst_segment_to_stream_time(&point->segment, GST_FORMAT_TIME, position);
  return GST_CLOCK_TIME_IS_VALID(time) ? static_cast<int64_t>(time) : -1;
}

GstPadProbeReturn Trim(TrimPoint* point, GstPad* pad, GstPadProbeInfo* info) {
  const Graph* graph = point->graph;
  const GstApi* g = graph->g;
  if (GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER) {
    if (point->ended) return GST_PAD_PROBE_DROP;
    GstBuffer* buffer = GST_PAD_PROBE_INFO_BUFFER(info);
    const int64_t time = StreamTime(g, point, GST_BUFFER_PTS(buffer));
    switch (TrimSample(time, graph->trim_start_ns, graph->trim_end_ns)) {
      case TrimStep::kDrop:
        return GST_PAD_PROBE_DROP;
      case TrimStep::kEnd:
        point->ended = true;
        // Ends the stream here instead of decoding the rest of the source;
        // the demuxer stops once every stream answers EOS.
        g->gst_pad_send_event(pad, g->gst_event_new_eos());
        return GST_PAD_PROBE_DROP;
      case TrimStep::kKeep:
        break;
    }
    const int64_t decode_time =
        GST_BUFFER_DTS_IS_VALID(buffer) ? StreamTime(g, point, GST_BUFFER_DTS(buffer)) : -1;
    buffer = GST_BUFFER_CAST(g->gst_mini_object_make_writable(GST_MINI_OBJECT_CAST(buffer)));
    GST_PAD_PROBE_INFO_DATA(info) = buffer;
    GST_BUFFER_PTS(buffer) = static_cast<GstClockTime>(time - graph->trim_start_ns);
    GST_BUFFER_DTS(buffer) = decode_time >= graph->trim_start_ns
                                 ? static_cast<GstClockTime>(decode_time - graph->trim_start_ns)
                                 : GST_CLOCK_TIME_NONE;
    return GST_PAD_PROBE_OK;
  }

  GstEvent* event = GST_PAD_PROBE_INFO_EVENT(info);
  if (GST_EVENT_TYPE(event) == GST_EVENT_FLUSH_STOP) {
    point->ended = false;
    return GST_PAD_PROBE_OK;
  }
  if (GST_EVENT_TYPE(event) != GST_EVENT_SEGMENT) return GST_PAD_PROBE_OK;
  const GstSegment* segment = nullptr;
  g->gst_event_parse_segment(event, &segment);
  if (segment == nullptr || segment->format != GST_FORMAT_TIME) return GST_PAD_PROBE_OK;
  point->segment = *segment;
  point->has_segment = true;
  // Buffers leave with kept-range timestamps, so downstream gets a segment
  // whose running time equals them.
  GstSegment kept;
  g->gst_segment_init(&kept, GST_FORMAT_TIME);
  GstEvent* replacement = g->gst_event_new_segment(&kept);
  if (replacement == nullptr) return GST_PAD_PROBE_OK;
  g->Unref(event);
  GST_PAD_PROBE_INFO_DATA(info) = replacement;
  return GST_PAD_PROBE_OK;
}

GstPadProbeReturn OnTrimPoint(GstPad* pad, GstPadProbeInfo* info, gpointer data) {
  return Trim(static_cast<TrimPoint*>(data), pad, info);
}

constexpr GstPadProbeType kTrimProbeMask =
    static_cast<GstPadProbeType>(GST_PAD_PROBE_TYPE_BUFFER | GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM |
                                 GST_PAD_PROBE_TYPE_EVENT_FLUSH);

void AddTrimPoint(Graph* graph, GstElement* element) {
  const GstApi* g = graph->g;
  GstPad* pad = g->gst_element_get_static_pad(element, "sink");
  if (pad == nullptr) return;
  auto point = std::make_unique<TrimPoint>();
  point->graph = graph;
  g->gst_pad_add_probe(pad, kTrimProbeMask, OnTrimPoint, point.get(), nullptr);
  g->gst_object_unref(pad);
  graph->trim_points.push_back(std::move(point));
}

void LinkParsedPad(Graph* graph, GstPad* pad) {
  int mpeg_version = 0;
  const std::string media = PadCaps(graph->g, pad, &mpeg_version);
  std::lock_guard<std::mutex> lock(graph->mutex);
  BlockForTrimSeek(graph, pad);
  GstElement* target = nullptr;
  if (g_str_has_prefix(media.c_str(), "video/") && !graph->video_linked) {
    graph->video_linked = true;
    target = graph->video_queue;
  } else if (g_str_has_prefix(media.c_str(), "audio/")) {
    const bool aac = NormalizeAudioCodec(media, mpeg_version) == kAacMime;
    for (auto& branch : graph->audio) {
      if (branch->used || branch->copy != aac) continue;
      branch->used = true;
      target = branch->queue;
      break;
    }
  }
  if (target == nullptr || !graph->LinkPad(pad, target)) graph->Discard(pad);
}

// Exceptions must not unwind into GStreamer's C frames; an unlinked pad then
// ends the pipeline with a not-linked error, reported as failed.
void OnParsedPad(GstElement*, GstPad* pad, gpointer data) {
  try {
    LinkParsedPad(static_cast<Graph*>(data), pad);
  } catch (const std::exception&) {
  }
}

void OnParsedPadsDone(GstElement*, gpointer data) {
  auto* graph = static_cast<Graph*>(data);
  {
    std::lock_guard<std::mutex> lock(graph->mutex);
    // The muxer waits for data on every pad before writing anything.
    for (auto& branch : graph->audio) {
      if (!branch->used) graph->g->gst_element_release_request_pad(graph->mux, branch->mux_pad);
    }
  }
  graph->pads_done = true;
}

void LinkDecodedPad(Graph* graph, GstPad* pad) {
  const std::string media = PadCaps(graph->g, pad);
  std::lock_guard<std::mutex> lock(graph->mutex);
  if (media == "video/x-raw" && !graph->raw_linked && graph->LinkPad(pad, graph->video_rate)) {
    graph->raw_linked = true;
    return;
  }
  graph->Discard(pad);
}

void OnDecodedPad(GstElement*, GstPad* pad, gpointer data) {
  try {
    LinkDecodedPad(static_cast<Graph*>(data), pad);
  } catch (const std::exception&) {
  }
}

void LinkDecodedAudioPad(Graph::AudioBranch* branch, GstPad* pad) {
  Graph* graph = branch->graph;
  const std::string media = PadCaps(graph->g, pad);
  std::lock_guard<std::mutex> lock(graph->mutex);
  if (media == "audio/x-raw" && !branch->raw_linked && graph->LinkPad(pad, branch->raw_head)) {
    branch->raw_linked = true;
    return;
  }
  graph->Discard(pad);
}

void OnDecodedAudioPad(GstElement*, GstPad* pad, gpointer data) {
  try {
    LinkDecodedAudioPad(static_cast<Graph::AudioBranch*>(data), pad);
  } catch (const std::exception&) {
  }
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

struct VideoEncoder {
  VideoEncoderChoice choice{};
  GstElement* encoder = nullptr;
  GstElement* parser = nullptr;
  GstElement* output_filter = nullptr;
};

// Adds the encoder of `choice` with its parser to the pipeline, or nothing
// when one of the elements it needs is not installed.
bool AddVideoEncoder(Graph* graph, const VideoEncoderChoice& choice, VideoEncoder* out) {
  const GstApi* g = graph->g;
  GstElement* encoder = g->gst_element_factory_make(choice.encoder, nullptr);
  if (encoder == nullptr) return false;
  GstElement* parser = g->gst_element_factory_make(choice.parser, nullptr);
  GstElement* filter = choice.output_caps != nullptr && parser != nullptr
                           ? g->gst_element_factory_make("capsfilter", nullptr)
                           : nullptr;
  const bool complete = (parser != nullptr || !choice.parser_required) &&
                        (choice.output_caps == nullptr || filter != nullptr);
  if (!complete) {
    for (GstElement* element : {encoder, parser, filter}) {
      if (element != nullptr) g->gst_object_unref(element);
    }
    return false;
  }
  for (GstElement* element : {encoder, parser, filter}) {
    if (element != nullptr) g->gst_bin_add(GST_BIN_CAST(graph->pipeline), element);
  }
  if (filter != nullptr) {
    GstCaps* caps = g->gst_caps_from_string(choice.output_caps);
    g_object_set(filter, "caps", caps, nullptr);
    g->Unref(caps);
  }
  out->choice = choice;
  out->encoder = encoder;
  out->parser = parser;
  out->output_filter = filter;
  return true;
}

GstElement* AddAacEncoder(Graph* graph, int64_t bitrate) {
  const GstApi* g = graph->g;
  for (const char* name : AacEncoderCandidates()) {
    GstElement* encoder = g->gst_element_factory_make(name, nullptr);
    if (encoder == nullptr) continue;
    g->gst_bin_add(GST_BIN_CAST(graph->pipeline), encoder);
    if (HasProperty(encoder, "bitrate")) {
      // voaacenc tops out at 320 kbit/s; an out-of-range value would be
      // ignored with a warning.
      g_autofree gchar* bps =
          g_strdup_printf("%" G_GINT64_FORMAT, std::clamp<int64_t>(bitrate, 8000, 320000));
      g->gst_util_set_object_arg(G_OBJECT(encoder), "bitrate", bps);
    }
    return encoder;
  }
  return nullptr;
}

Outcome Run(const GstApi* g, const VideoJob& job, const Discovery& discovery,
            const KeptRange& range, const std::atomic<bool>& cancelled,
            const std::function<void(double)>& on_progress) {
  const VideoInfo& info = discovery.info;
  const double scale = FitScale(info.width, info.height, job.bounds);
  const bool turned = job.rotate_quarter_turns % 2 != 0;
  const int64_t scaled_width = ScaledEvenSide(info.width, scale);
  const int64_t scaled_height = ScaledEvenSide(info.height, scale);
  const int64_t width = turned ? scaled_height : scaled_width;
  const int64_t height = turned ? scaled_width : scaled_height;

  Graph graph(g);
  if (graph.pipeline == nullptr) return Failed("Could not create a pipeline");
  graph.max_bytes = job.max_bytes.value_or(0);
  if (range.partial) {
    graph.trimming = true;
    graph.trim_start_ns = range.start_ms * GST_MSECOND;
    graph.trim_end_ns = range.end_ms ? *range.end_ms * GST_MSECOND : -1;
    graph.seek_pending = true;
  }

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

  VideoEncoder video;
  for (const VideoEncoderChoice& choice : VideoEncoderCandidates(job.hevc)) {
    if (AddVideoEncoder(&graph, choice, &video)) break;
  }
  if (video.encoder == nullptr) return Unsupported("No H.264 encoder in GStreamer");
  ConfigureEncoder(g, video.encoder, video.choice.encoder, job.video_bitrate);

  g_object_set(source, "location", job.source.c_str(), nullptr);
  g_object_set(sink, "location", job.destination.c_str(), nullptr);
  g_object_set(graph.mux, "faststart", TRUE, nullptr);
  g_object_set(scaler, "add-borders", FALSE, nullptr);
  g_object_set(flip, "video-direction",
               static_cast<GstVideoOrientationMethod>(
                   CombineVideoOrientation(discovery.orientation, job.rotate_quarter_turns)),
               nullptr);
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

  GstElement* video_tail = video.output_filter != nullptr ? video.output_filter
                           : video.parser != nullptr      ? video.parser
                                                          : video.encoder;
  bool linked = g->gst_element_link(source, parser) &&
                g->gst_element_link(graph.video_queue, decoder) &&
                g->gst_element_link(graph.video_rate, convert) && g->gst_element_link(convert, scaler) &&
                g->gst_element_link(scaler, flip) && g->gst_element_link(flip, filter) &&
                g->gst_element_link(filter, video.encoder) &&
                (video.parser == nullptr || g->gst_element_link(video.encoder, video.parser)) &&
                (video.output_filter == nullptr ||
                 g->gst_element_link(video.parser, video.output_filter)) &&
                g->gst_element_link(graph.mux, sink);
  GstPad* video_pad = linked ? graph.LinkToMux(video_tail, "video_%u") : nullptr;
  if (video_pad == nullptr) return Failed("Could not link the video branch");
  g->gst_pad_add_probe(video_pad, kMuxProbeMask, OnVideoMuxInput, &graph, nullptr);
  if (graph.trimming) AddTrimPoint(&graph, graph.video_rate);

  if (job.include_audio) {
    for (const std::string& codec : discovery.audio_codecs) {
      auto branch = std::make_unique<Graph::AudioBranch>();
      branch->graph = &graph;
      branch->copy = codec == kAacMime;
      branch->queue = graph.Add("queue");
      GstElement* aac_parser = graph.Add("aacparse");
      GstElement* audio_decoder = branch->copy ? nullptr : graph.Add("decodebin");
      branch->raw_head = branch->copy ? nullptr : graph.Add("audioconvert");
      GstElement* resample = branch->copy ? nullptr : graph.Add("audioresample");
      if (!graph.missing.empty()) return Unsupported("Missing GStreamer elements: " + graph.missing);
      // Audio runs far ahead of the encoder's lookahead; a bounded queue would
      // block the demuxer and starve the video branch.
      g_object_set(branch->queue, "max-size-buffers", 0u, "max-size-bytes", 0u, "max-size-time",
                   guint64{0}, nullptr);
      bool audio_linked;
      if (branch->copy) {
        audio_linked = g->gst_element_link(branch->queue, aac_parser);
      } else {
        GstElement* encoder = AddAacEncoder(&graph, job.audio_bitrate);
        if (encoder == nullptr) return Unsupported("No AAC encoder in GStreamer for " + codec);
        audio_linked = g->gst_element_link(branch->queue, audio_decoder) &&
                       g->gst_element_link(branch->raw_head, resample) &&
                       g->gst_element_link(resample, encoder) &&
                       g->gst_element_link(encoder, aac_parser);
        g_signal_connect(audio_decoder, "pad-added", G_CALLBACK(OnDecodedAudioPad), branch.get());
      }
      GstPad* audio_pad = audio_linked ? graph.LinkToMux(aac_parser, "audio_%u") : nullptr;
      if (audio_pad == nullptr) return Failed("Could not link an audio branch");
      g->gst_pad_add_probe(audio_pad, kMuxProbeMask, OnAudioMuxInput, &graph, nullptr);
      branch->mux_pad = audio_pad;
      // Decoded audio is cut, so the decoder still sees the frames before the
      // range that the first kept samples depend on.
      if (graph.trimming) AddTrimPoint(&graph, branch->copy ? branch->queue : branch->raw_head);
      graph.audio.push_back(std::move(branch));
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
  const double kept_ns =
      range.end_ms ? static_cast<double>(*range.end_ms - range.start_ms) * GST_MSECOND : 0.0;
  const gint64 started = g_get_monotonic_time();
  bool released = !graph.trimming;
  std::optional<Outcome> outcome;
  while (!outcome) {
    // Missing-plugin element messages are not fatal on their own: parsebin
    // posts them for side streams (timecode, metadata) that are discarded.
    GstMessage* message = g->gst_bus_timed_pop_filtered(
        bus, 50 * GST_MSECOND, static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
    if (message != nullptr) {
      outcome = GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS
                    ? Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_COMPRESSED)
                    : ClassifyError(g, message);
      g->Unref(message);
    }
    if (outcome) break;
    if (!released && (graph.pads_done || g_get_monotonic_time() - started > kTrimSeekWaitUs)) {
      ReleaseForTrim(&graph, graph.pads_done);
      released = true;
    }
    if (cancelled) {
      outcome = Cancelled();
    } else if (graph.too_large) {
      outcome = Outcome::Of(NATIVE_MEDIA_COMPRESSOR_COMPRESSION_STATUS_TOO_LARGE);
    } else if (kept_ns > 0) {
      progress.Report(static_cast<double>(graph.video_position.load()) / kept_ns);
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
    outcome->video_codec = video.choice.mime;
  }
  return *outcome;
}

Outcome Transcode(const GstApi* g, const VideoJob& job, const std::atomic<bool>& cancelled,
                  const std::function<void(double)>& on_progress) {
  DiscoveryHolder holder{g, Discover(g, job.source)};
  const Discovery& discovery = holder.discovery;
  if (discovery.result == Discovery::Result::kUnreadable) return Failed(discovery.error);
  if (discovery.result == Discovery::Result::kNoVideo) return Unsupported("No video track");
  if (discovery.info.is_hdr) return Unsupported("HDR video is not converted on Linux");
  const std::optional<KeptRange> range =
      ResolveKeptRange(job.start_ms, job.end_ms, discovery.info.duration_ms);
  if (!range) return Unsupported("The trim range keeps nothing of the video");
  if (!HasDecoder(g, discovery.video_caps)) {
    return Unsupported("No GStreamer decoder for " + discovery.info.video_codec);
  }
  if (cancelled) return Cancelled();
  return Run(g, job, discovery, *range, cancelled, on_progress);
}

// Decodes the video stream into RGB frames and keeps the one a thumbnail
// shows.
struct FrameGraph : Pipeline {
  using Pipeline::Pipeline;

  ~FrameGraph() {
    if (pipeline != nullptr) g->gst_element_set_state(pipeline, GST_STATE_NULL);
    g->Unref(frame);
    g->Unref(frame_caps);
  }

  GstElement* decoder = nullptr;
  GstElement* convert = nullptr;
  bool video_linked = false;
  bool raw_linked = false;
  int64_t position_ns = 0;

  // Separate from `mutex`, which pad-added callbacks hold while linking.
  std::mutex frame_mutex;
  GstSegment segment{};
  bool has_segment = false;
  GstBuffer* frame = nullptr;
  GstCaps* frame_caps = nullptr;
  std::atomic<bool> done{false};
};

void LinkFrameParsedPad(FrameGraph* graph, GstPad* pad) {
  const std::string media = PadCaps(graph->g, pad);
  std::lock_guard<std::mutex> lock(graph->mutex);
  if (g_str_has_prefix(media.c_str(), "video/") && !graph->video_linked &&
      graph->LinkPad(pad, graph->decoder)) {
    graph->video_linked = true;
    return;
  }
  graph->Discard(pad);
}

void OnFrameParsedPad(GstElement*, GstPad* pad, gpointer data) {
  try {
    LinkFrameParsedPad(static_cast<FrameGraph*>(data), pad);
  } catch (const std::exception&) {
  }
}

void LinkFrameDecodedPad(FrameGraph* graph, GstPad* pad) {
  const std::string media = PadCaps(graph->g, pad);
  std::lock_guard<std::mutex> lock(graph->mutex);
  if (media == "video/x-raw" && !graph->raw_linked && graph->LinkPad(pad, graph->convert)) {
    graph->raw_linked = true;
    return;
  }
  graph->Discard(pad);
}

void OnFrameDecodedPad(GstElement*, GstPad* pad, gpointer data) {
  try {
    LinkFrameDecodedPad(static_cast<FrameGraph*>(data), pad);
  } catch (const std::exception&) {
  }
}

GstPadProbeReturn KeepFrame(FrameGraph* graph, GstPad* pad, GstPadProbeInfo* info) {
  const GstApi* g = graph->g;
  std::lock_guard<std::mutex> lock(graph->frame_mutex);
  if (!(GST_PAD_PROBE_INFO_TYPE(info) & GST_PAD_PROBE_TYPE_BUFFER)) {
    GstEvent* event = GST_PAD_PROBE_INFO_EVENT(info);
    if (GST_EVENT_TYPE(event) == GST_EVENT_SEGMENT) {
      const GstSegment* segment = nullptr;
      g->gst_event_parse_segment(event, &segment);
      if (segment != nullptr && segment->format == GST_FORMAT_TIME) {
        graph->segment = *segment;
        graph->has_segment = true;
      }
    }
    return GST_PAD_PROBE_OK;
  }
  if (graph->done) return GST_PAD_PROBE_DROP;
  GstBuffer* buffer = GST_PAD_PROBE_INFO_BUFFER(info);
  int64_t time = -1;
  const GstClockTime pts = GST_BUFFER_PTS(buffer);
  if (GST_CLOCK_TIME_IS_VALID(pts)) {
    const guint64 stream_time =
        graph->has_segment ? g->gst_segment_to_stream_time(&graph->segment, GST_FORMAT_TIME, pts)
                           : pts;
    if (GST_CLOCK_TIME_IS_VALID(stream_time)) time = static_cast<int64_t>(stream_time);
  }
  const FramePick pick = PickThumbnailFrame(time, graph->position_ns, graph->frame != nullptr);
  if (pick == FramePick::kStop) {
    graph->done = true;
    return GST_PAD_PROBE_DROP;
  }
  GstCaps* caps = g->gst_pad_get_current_caps(pad);
  if (caps == nullptr) return GST_PAD_PROBE_OK;
  g->Unref(graph->frame);
  g->Unref(graph->frame_caps);
  graph->frame = GST_BUFFER_CAST(g->gst_mini_object_ref(GST_MINI_OBJECT_CAST(buffer)));
  graph->frame_caps = caps;
  if (pick == FramePick::kTakeAndStop) graph->done = true;
  return GST_PAD_PROBE_OK;
}

GstPadProbeReturn OnFrame(GstPad* pad, GstPadProbeInfo* info, gpointer data) {
  try {
    return KeepFrame(static_cast<FrameGraph*>(data), pad, info);
  } catch (const std::exception&) {
    return GST_PAD_PROBE_OK;
  }
}

Outcome WriteFrame(const GstApi* g, const ThumbnailJob& job, GstBuffer* frame, GstCaps* caps,
                   const std::string& output) {
  if (frame == nullptr || caps == nullptr || g->gst_caps_get_size(caps) == 0) {
    return Failed("No video frame was decoded");
  }
  const GstStructure* structure = g->gst_caps_get_structure(caps, 0);
  gint width = 0;
  gint height = 0;
  if (!g->gst_structure_get_int(structure, "width", &width) ||
      !g->gst_structure_get_int(structure, "height", &height)) {
    return Failed("The decoded frame has no size");
  }
  GstMapInfo map;
  if (!g->gst_buffer_map(frame, &map, GST_MAP_READ)) return Failed("Could not read the frame");
  const int stride = RgbRowStride(width, height, map.size);
  Outcome outcome = stride > 0 ? WriteRgbFrame(RgbFrame{map.data, width, height, stride},
                                               job.bounds, job.format, job.quality, output)
                               : Failed("The decoded frame is truncated");
  g->gst_buffer_unmap(frame, &map);
  return outcome;
}

Outcome ExtractFrame(const GstApi* g, const ThumbnailJob& job, const Discovery& discovery,
                     const std::string& output) {
  FrameGraph graph(g);
  if (graph.pipeline == nullptr) return Failed("Could not create a pipeline");
  graph.position_ns = std::max<int64_t>(0, job.position_ms) * GST_MSECOND;

  GstElement* source = graph.Add("filesrc");
  GstElement* parser = graph.Add("parsebin");
  graph.decoder = graph.Add("decodebin");
  graph.convert = graph.Add("videoconvert");
  GstElement* filter = graph.Add("capsfilter");
  GstElement* flip = graph.Add("videoflip");
  GstElement* sink = graph.Add("fakesink");
  if (!graph.missing.empty()) return Unsupported("Missing GStreamer elements: " + graph.missing);

  g_object_set(source, "location", job.source.c_str(), nullptr);
  g_object_set(flip, "video-direction", discovery.orientation, nullptr);
  g_object_set(sink, "sync", FALSE, "enable-last-sample", FALSE, nullptr);
  GstCaps* caps = g->gst_caps_from_string("video/x-raw,format=RGB");
  g_object_set(filter, "caps", caps, nullptr);
  g->Unref(caps);
  if (!g->gst_element_link(source, parser) || !g->gst_element_link(graph.convert, filter) ||
      !g->gst_element_link(filter, flip) || !g->gst_element_link(flip, sink)) {
    return Failed("Could not link the frame pipeline");
  }
  GstPad* sink_pad = g->gst_element_get_static_pad(sink, "sink");
  g->gst_pad_add_probe(sink_pad,
                       static_cast<GstPadProbeType>(GST_PAD_PROBE_TYPE_BUFFER |
                                                    GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM),
                       OnFrame, &graph, nullptr);
  g->gst_object_unref(sink_pad);
  g_signal_connect(parser, "pad-added", G_CALLBACK(OnFrameParsedPad), &graph);
  g_signal_connect(graph.decoder, "pad-added", G_CALLBACK(OnFrameDecodedPad), &graph);

  if (g->gst_element_set_state(graph.pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
    return Failed("Could not start the pipeline");
  }

  GstBus* bus = g->gst_element_get_bus(graph.pipeline);
  const int64_t seek_ms = ThumbnailSeekMs(job.position_ms, discovery.info.duration_ms);
  bool seeked = seek_ms < 0;
  bool ended = false;
  const gint64 deadline = g_get_monotonic_time() + kThumbnailTimeoutUs;
  std::optional<Outcome> outcome;
  while (!outcome && !ended && !graph.done) {
    GstMessage* message = g->gst_bus_timed_pop_filtered(
        bus, 50 * GST_MSECOND,
        static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR | GST_MESSAGE_ASYNC_DONE));
    if (message != nullptr) {
      switch (GST_MESSAGE_TYPE(message)) {
        case GST_MESSAGE_EOS:
          ended = true;
          break;
        case GST_MESSAGE_ERROR:
          outcome = ClassifyError(g, message);
          break;
        default:
          // Seeking needs a prerolled pipeline. Snapping to the keyframe
          // before the position decodes every frame up to it, and up to the
          // last one for a position past the end.
          if (!seeked && !graph.done) {
            seeked = true;
            GstEvent* seek = g->gst_event_new_seek(
                1.0, GST_FORMAT_TIME,
                static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT |
                                          GST_SEEK_FLAG_SNAP_BEFORE),
                GST_SEEK_TYPE_SET, seek_ms * GST_MSECOND, GST_SEEK_TYPE_NONE, -1);
            if (seek != nullptr) g->gst_element_send_event(sink, seek);
          }
          break;
      }
      g->Unref(message);
    }
    if (!outcome && g_get_monotonic_time() > deadline) outcome = Failed("Decoding the frame timed out");
  }
  g->gst_object_unref(bus);
  g->gst_element_set_state(graph.pipeline, GST_STATE_NULL);
  if (outcome) return *outcome;
  return WriteFrame(g, job, graph.frame, graph.frame_caps, output);
}

Outcome Thumbnail(const GstApi* g, const ThumbnailJob& job, const std::string& output) {
  DiscoveryHolder holder{g, Discover(g, job.source)};
  const Discovery& discovery = holder.discovery;
  if (discovery.result == Discovery::Result::kUnreadable) return Failed(discovery.error);
  if (discovery.result == Discovery::Result::kNoVideo) return Unsupported("No video track");
  if (!HasDecoder(g, discovery.video_caps)) {
    return Unsupported("No GStreamer decoder for " + discovery.info.video_codec);
  }
  return ExtractFrame(g, job, discovery, output);
}

}  // namespace

std::optional<VideoInfo> ProbeVideoFile(const std::string& path) {
  try {
    const GstApi* g = LoadGstApi();
    if (g == nullptr) return std::nullopt;
    DiscoveryHolder holder{g, Discover(g, path)};
    if (holder.discovery.result != Discovery::Result::kOk) return std::nullopt;
    return holder.discovery.info;
  } catch (const std::exception&) {
    return std::nullopt;
  }
}

Outcome TranscodeVideo(const VideoJob& job, const std::atomic<bool>& cancelled,
                       const std::function<void(double)>& on_progress) {
  try {
    // Unwinding deletes the temporary file too.
    PendingOutput output(job.destination);
    if (output.destination_is_directory()) return Failed("The destination is a directory");
    const GstApi* g = LoadGstApi();
    if (g == nullptr) return Unsupported("GStreamer 1.20 or newer is not installed");
    if (cancelled) return Cancelled();
    VideoJob pending = job;
    pending.destination = output.path();
    return output.Finish(Transcode(g, pending, cancelled, on_progress));
  } catch (const std::exception& error) {
    return Failed(error.what());
  }
}

Outcome VideoThumbnail(const ThumbnailJob& job) {
  try {
    // Unwinding deletes the temporary file too.
    PendingOutput output(job.destination);
    if (output.destination_is_directory()) return Failed("The destination is a directory");
    const GstApi* g = LoadGstApi();
    if (g == nullptr) return Unsupported("GStreamer 1.20 or newer is not installed");
    return output.Finish(Thumbnail(g, job, output.path()));
  } catch (const std::exception& error) {
    return Failed(error.what());
  }
}

#endif  // NMC_HAVE_GST_HEADERS

}  // namespace native_media_compressor
