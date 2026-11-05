#ifndef FLUTTER_PLUGIN_NATIVE_MEDIA_COMPRESSOR_PLUGIN_H_
#define FLUTTER_PLUGIN_NATIVE_MEDIA_COMPRESSOR_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace native_media_compressor {

class NativeMediaCompressorPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  NativeMediaCompressorPlugin();

  virtual ~NativeMediaCompressorPlugin();

  // Disallow copy and assign.
  NativeMediaCompressorPlugin(const NativeMediaCompressorPlugin&) = delete;
  NativeMediaCompressorPlugin& operator=(const NativeMediaCompressorPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace native_media_compressor

#endif  // FLUTTER_PLUGIN_NATIVE_MEDIA_COMPRESSOR_PLUGIN_H_
