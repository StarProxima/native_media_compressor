Pod::Spec.new do |s|
  s.name             = 'native_media_compressor'
  s.version          = '1.0.0'
  s.summary          = "Compress images and videos with the platform's own codecs."
  s.description      = <<-DESC
Compress images and videos with AVFoundation and ImageIO: no ffmpeg, no bundled encoders.
                       DESC
  s.homepage         = 'https://github.com/StarProxima/native_media_compressor'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'StarProxima' => 'https://github.com/StarProxima' }
  s.source           = { :path => '.' }
  s.source_files     = 'native_media_compressor/Sources/native_media_compressor/**/*.swift'
  s.resource_bundles = { 'native_media_compressor_privacy' => ['native_media_compressor/Sources/native_media_compressor/PrivacyInfo.xcprivacy'] }
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
