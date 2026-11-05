import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_media_compressor/src/web/image_headers.dart';

Uint8List _fixture(String name) =>
    File('example/integration_test/fixtures/$name').readAsBytesSync();

(String, int, int, int)? _parse(Uint8List bytes) {
  final header = ImageHeaders.parse(bytes);
  if (header == null) return null;
  return (header.mimeType, header.width, header.height, header.frameCount);
}

Uint8List _png({int? frames}) {
  final out = BytesBuilder();
  void chunk(String type, List<int> data) {
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(type.codeUnits)
      ..add(data)
      ..add(Uint8List(4));
  }

  out.add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  chunk('IHDR', [0, 0, 1, 0, 0, 0, 0, 200, 8, 6, 0, 0, 0]);
  if (frames != null) chunk('acTL', [0, 0, 0, frames, 0, 0, 0, 0]);
  chunk('IDAT', [0]);
  chunk('IEND', []);
  return out.takeBytes();
}

void main() {
  test('applies EXIF orientation to JPEG size', () {
    expect(_parse(_fixture('photo_exif_rotated.jpg')), (
      'image/jpeg',
      1200,
      1600,
      1,
    ));
  });

  test('reads PNG and counts APNG frames', () {
    expect(_parse(_fixture('alpha.png')), ('image/png', 1200, 800, 1));
    expect(_parse(_png()), ('image/png', 256, 200, 1));
    expect(_parse(_png(frames: 4)), ('image/png', 256, 200, 4));
    expect(_parse(_fixture('animated.png')), ('image/png', 320, 240, 3));
  });

  test('counts GIF and WebP frames', () {
    expect(_parse(_fixture('animated.gif')), ('image/gif', 320, 240, 3));
    expect(_parse(_fixture('animated.webp')), ('image/webp', 320, 240, 3));
    expect(_parse(_fixture('photo.webp')), ('image/webp', 1600, 1200, 1));
  });

  test('reads BMP', () {
    final bmp =
        Uint8List(54)
          ..setAll(0, 'BM'.codeUnits)
          ..[14] = 40;
    ByteData.sublistView(bmp)
      ..setInt32(18, 640, Endian.little)
      ..setInt32(22, -480, Endian.little);

    expect(_parse(bmp), ('image/bmp', 640, 480, 1));
  });

  test('sniffs formats it leaves to the browser', () {
    expect(ImageHeaders.sniffMimeType(_fixture('photo.heic')), 'image/heic');
    expect(ImageHeaders.parse(_fixture('photo.heic')), isNull);
    final avif = Uint8List.fromList([
      0, 0, 0, 20, ...'ftypavif'.codeUnits, 0, 0, 0, 0, ...'mif1'.codeUnits, //
    ]);
    expect(ImageHeaders.sniffMimeType(avif), 'image/avif');
  });

  test('rejects broken and truncated files', () {
    expect(ImageHeaders.sniffMimeType(_fixture('broken.jpg')), isNull);
    expect(ImageHeaders.parse(_fixture('broken.jpg')), isNull);
    final jpeg = _fixture('photo_exif_rotated.jpg');
    expect(ImageHeaders.parse(Uint8List.sublistView(jpeg, 0, 20)), isNull);
    expect(ImageHeaders.parse(Uint8List(0)), isNull);
  });
}
