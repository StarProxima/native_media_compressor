#ifndef NATIVE_MEDIA_COMPRESSOR_GST_API_H_
#define NATIVE_MEDIA_COMPRESSOR_GST_API_H_

#ifdef NMC_HAVE_GST_HEADERS

#include <gst/gst.h>
#include <gst/pbutils/pbutils.h>
#include <gst/video/video.h>

namespace native_media_compressor {

// GStreamer is reached only through these pointers, filled by dlopen, so that
// an app using the plugin starts on a system without GStreamer. Inline helpers
// and type-checked casts from the GStreamer headers (gst_caps_unref,
// GST_ELEMENT(), ...) reference library symbols directly and must not be used;
// the plugin is linked with --no-undefined to catch them.
#define NMC_GST_CORE_FUNCTIONS(X)           \
  X(gst_init_check)                         \
  X(gst_pipeline_new)                       \
  X(gst_element_factory_make)               \
  X(gst_element_factory_list_get_elements)  \
  X(gst_element_factory_list_filter)        \
  X(gst_plugin_feature_list_free)           \
  X(gst_bin_add)                            \
  X(gst_element_link)                       \
  X(gst_element_set_state)                  \
  X(gst_element_get_bus)                    \
  X(gst_element_get_static_pad)             \
  X(gst_element_request_pad_simple)         \
  X(gst_element_release_request_pad)        \
  X(gst_element_sync_state_with_parent)     \
  X(gst_element_send_event)                 \
  X(gst_bus_timed_pop_filtered)             \
  X(gst_message_parse_error)                \
  X(gst_structure_get_name)                 \
  X(gst_structure_get_int)                  \
  X(gst_structure_get_string)               \
  X(gst_structure_has_field)                \
  X(gst_caps_from_string)                   \
  X(gst_caps_get_structure)                 \
  X(gst_caps_get_size)                      \
  X(gst_pad_link)                           \
  X(gst_pad_add_probe)                      \
  X(gst_pad_get_current_caps)               \
  X(gst_pad_query_caps)                     \
  X(gst_pad_remove_probe)                   \
  X(gst_pad_send_event)                     \
  X(gst_event_new_eos)                      \
  X(gst_event_new_seek)                     \
  X(gst_event_new_segment)                  \
  X(gst_event_parse_segment)                \
  X(gst_segment_init)                       \
  X(gst_segment_to_stream_time)             \
  X(gst_buffer_get_size)                    \
  X(gst_buffer_map)                         \
  X(gst_buffer_unmap)                       \
  X(gst_mini_object_ref)                    \
  X(gst_mini_object_make_writable)          \
  X(gst_mini_object_unref)                  \
  X(gst_object_ref)                         \
  X(gst_object_unref)                       \
  X(gst_tag_list_get_string)                \
  X(gst_util_set_object_arg)                \
  X(gst_filename_to_uri)                    \
  X(gst_core_error_quark)                   \
  X(gst_stream_error_quark)

#define NMC_GST_PBUTILS_FUNCTIONS(X)               \
  X(gst_discoverer_new)                            \
  X(gst_discoverer_discover_uri)                   \
  X(gst_discoverer_info_get_result)                \
  X(gst_discoverer_info_get_duration)              \
  X(gst_discoverer_info_get_tags)                  \
  X(gst_discoverer_info_get_video_streams)         \
  X(gst_discoverer_info_get_audio_streams)         \
  X(gst_discoverer_stream_info_list_free)          \
  X(gst_discoverer_stream_info_get_caps)           \
  X(gst_discoverer_stream_info_get_tags)           \
  X(gst_discoverer_video_info_get_width)           \
  X(gst_discoverer_video_info_get_height)          \
  X(gst_discoverer_video_info_get_framerate_num)   \
  X(gst_discoverer_video_info_get_framerate_denom) \
  X(gst_discoverer_video_info_is_image)

#define NMC_GST_VIDEO_FUNCTIONS(X) X(gst_video_colorimetry_from_string)

struct GstApi {
#define NMC_GST_DECLARE(name) decltype(&::name) name = nullptr;
  NMC_GST_CORE_FUNCTIONS(NMC_GST_DECLARE)
  NMC_GST_PBUTILS_FUNCTIONS(NMC_GST_DECLARE)
  // Optional: HDR detection falls back to parsing the caps string without it.
  NMC_GST_VIDEO_FUNCTIONS(NMC_GST_DECLARE)
#undef NMC_GST_DECLARE

  void Unref(gpointer mini_object) const {
    if (mini_object != nullptr) gst_mini_object_unref(GST_MINI_OBJECT_CAST(mini_object));
  }
};

// Loads and initializes GStreamer on first use. Null when the libraries are
// missing or gst_init fails. Thread-safe.
const GstApi* LoadGstApi();

}  // namespace native_media_compressor

#endif  // NMC_HAVE_GST_HEADERS

#endif  // NATIVE_MEDIA_COMPRESSOR_GST_API_H_
