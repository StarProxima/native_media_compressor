#include "include/native_media_compressor/native_media_compressor_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "native_media_compressor_plugin.h"

void NativeMediaCompressorPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  native_media_compressor::NativeMediaCompressorPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
