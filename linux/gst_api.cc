#include "gst_api.h"

#ifdef NMC_HAVE_GST_HEADERS

#include <dlfcn.h>

namespace native_media_compressor {

namespace {

template <typename T>
bool Resolve(void* library, const char* name, T* slot) {
  *slot = reinterpret_cast<T>(dlsym(library, name));
  return *slot != nullptr;
}

const GstApi* Load() {
  void* core = dlopen("libgstreamer-1.0.so.0", RTLD_NOW | RTLD_LOCAL);
  if (core == nullptr) return nullptr;
  void* pbutils = dlopen("libgstpbutils-1.0.so.0", RTLD_NOW | RTLD_LOCAL);
  if (pbutils == nullptr) return nullptr;
  void* video = dlopen("libgstvideo-1.0.so.0", RTLD_NOW | RTLD_LOCAL);

  auto* api = new GstApi();
  bool complete = true;
#define NMC_GST_RESOLVE(name) complete = Resolve(core, #name, &api->name) && complete;
  NMC_GST_CORE_FUNCTIONS(NMC_GST_RESOLVE)
#undef NMC_GST_RESOLVE
#define NMC_GST_RESOLVE(name) complete = Resolve(pbutils, #name, &api->name) && complete;
  NMC_GST_PBUTILS_FUNCTIONS(NMC_GST_RESOLVE)
#undef NMC_GST_RESOLVE
  if (video != nullptr) {
#define NMC_GST_RESOLVE(name) Resolve(video, #name, &api->name);
    NMC_GST_VIDEO_FUNCTIONS(NMC_GST_RESOLVE)
#undef NMC_GST_RESOLVE
  }
  if (!complete) {
    delete api;
    return nullptr;
  }

  GError* error = nullptr;
  if (!api->gst_init_check(nullptr, nullptr, &error)) {
    if (error != nullptr) {
      g_warning("native_media_compressor: GStreamer init failed: %s", error->message);
      g_error_free(error);
    }
    delete api;
    return nullptr;
  }
  return api;
}

}  // namespace

const GstApi* LoadGstApi() {
  // Never freed: GStreamer cannot be safely deinitialized while plugins it
  // loaded may still be referenced.
  static const GstApi* api = Load();
  return api;
}

}  // namespace native_media_compressor

#endif  // NMC_HAVE_GST_HEADERS
