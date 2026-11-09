import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../types.dart';
import 'browser.dart';
import 'exif_splice.dart';
import 'image_headers.dart';
import 'media_plan.dart';

/// Image probing and compression with `createImageBitmap` and
/// `OffscreenCanvas`.
abstract final class WebImage {
  /// Formats without a header parser here; the browser decodes them or not.
  static const _browserOnly = {
    'image/heic',
    'image/heif',
    'image/avif',
    'image/tiff',
  };

  /// The MIME type `convertToBlob` is asked for to write [format].
  static String mimeTypeOf(ImageFormat format) => switch (format) {
    ImageFormat.jpeg => 'image/jpeg',
    ImageFormat.png => 'image/png',
    ImageFormat.webp => 'image/webp',
    ImageFormat.heic => 'image/heic',
  };

  static Future<ImageMetadata?> probe(String source) async {
    final blob = await Browser.fetchBlob(source);
    if (blob == null) return null;
    final bytes = await Browser.bytesOf(blob);
    final header = ImageHeaders.parse(bytes);
    if (header != null) {
      return ImageMetadata(
        width: header.width,
        height: header.height,
        frameCount: header.frameCount,
        mimeType: header.mimeType,
      );
    }
    final mimeType = ImageHeaders.sniffMimeType(bytes);
    if (mimeType == null || await Browser.cannotDecodeImage(mimeType)) {
      return null;
    }
    final size = await _decodedSize(blob);
    if (size == null) return null;
    return ImageMetadata(
      width: size.$1,
      height: size.$2,
      frameCount: await Browser.frameCount(blob, mimeType) ?? 1,
      mimeType: mimeType,
    );
  }

  static Future<(int, int)?> _decodedSize(web.Blob blob) async {
    try {
      final bitmap =
          await web.window
              .createImageBitmap(
                blob,
                web.ImageBitmapOptions(imageOrientation: 'from-image'),
              )
              .toDart;
      final size = (bitmap.width, bitmap.height);
      bitmap.close();
      return size;
    } on Object {
      return null;
    }
  }

  static Future<CompressionResult> compress(
    String source,
    ImageOptions options,
  ) async {
    final blob = await Browser.fetchBlob(source);
    if (blob == null) {
      return _result(CompressionStatus.failed, 'cannot read $source');
    }
    final bytes = await Browser.bytesOf(blob);
    final mimeType = ImageHeaders.sniffMimeType(bytes);
    if (mimeType == null) {
      return _result(CompressionStatus.failed, 'unknown image format');
    }
    final decodeFailure =
        _browserOnly.contains(mimeType)
            ? CompressionStatus.unsupported
            : CompressionStatus.failed;

    final header = ImageHeaders.parse(bytes);
    final size =
        header != null
            ? (header.width, header.height)
            : await _decodedSize(blob);
    if (size == null) {
      return _result(decodeFailure, 'the browser cannot decode $mimeType');
    }
    final (width, height) = MediaPlan.imageSize(
      size.$1,
      size.$2,
      options.maxShortSide,
      options.maxLongSide,
    );

    web.ImageBitmap bitmap;
    try {
      bitmap = await _bitmap(blob, width, height);
      // Some engines apply the resize before the EXIF rotation.
      if (width != height && bitmap.width == height && bitmap.height == width) {
        bitmap.close();
        bitmap = await _bitmap(blob, height, width);
      }
    } on Object catch (error) {
      return _result(
        decodeFailure,
        'the browser cannot decode $mimeType: $error',
      );
    }

    final type = mimeTypeOf(options.format);
    web.Blob output;
    try {
      final canvas = web.OffscreenCanvas(width, height);
      final context =
          canvas.getContext('2d')! as web.OffscreenCanvasRenderingContext2D;
      if (type == 'image/jpeg') {
        context.fillStyle = 'white'.toJS;
        context.fillRect(0, 0, width, height);
      }
      context.drawImage(bitmap, 0, 0, width, height);
      output =
          await canvas
              .convertToBlob(
                web.ImageEncodeOptions(
                  type: type,
                  quality: options.quality / 100,
                ),
              )
              .toDart;
    } on Object catch (error) {
      return _result(CompressionStatus.failed, 'encoding failed: $error');
    } finally {
      bitmap.close();
    }
    // Browsers fall back to PNG for types they cannot encode.
    if (output.type != type) {
      return _result(
        CompressionStatus.unsupported,
        'the browser cannot encode $type',
      );
    }
    if (options.keepMetadata &&
        type == 'image/jpeg' &&
        mimeType == 'image/jpeg') {
      output = web.Blob(
        [ExifSplice.keepExif(bytes, await Browser.bytesOf(output)).toJS].toJS,
        web.BlobPropertyBag(type: type),
      );
    }
    return CompressionResult(
      status: CompressionStatus.compressed,
      path: web.URL.createObjectURL(output),
      width: width,
      height: height,
      sizeBytes: output.size,
    );
  }

  static Future<web.ImageBitmap> _bitmap(
    web.Blob blob,
    int width,
    int height,
  ) =>
      web.window
          .createImageBitmap(
            blob,
            web.ImageBitmapOptions(
              imageOrientation: 'from-image',
              resizeWidth: width,
              resizeHeight: height,
              resizeQuality: 'high',
            ),
          )
          .toDart;

  static CompressionResult _result(CompressionStatus status, String message) =>
      CompressionResult(status: status, message: message);
}
