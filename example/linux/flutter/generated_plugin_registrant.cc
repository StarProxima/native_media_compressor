//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <native_media_compressor/native_media_compressor_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) native_media_compressor_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "NativeMediaCompressorPlugin");
  native_media_compressor_plugin_register_with_registrar(native_media_compressor_registrar);
}
