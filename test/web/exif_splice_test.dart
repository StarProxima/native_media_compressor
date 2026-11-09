import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_media_compressor/src/web/exif_splice.dart';
import 'package:native_media_compressor/src/web/image_headers.dart';

Uint8List _fixture(String name) =>
    File('example/integration_test/fixtures/$name').readAsBytesSync();

List<int> _segment(int marker, List<int> payload) => [
  0xff,
  marker,
  (payload.length + 2) >> 8,
  (payload.length + 2) & 0xff,
  ...payload,
];

/// A 3x2 JPEG header as a canvas writes it: JFIF, then the frame.
Uint8List _encoded() => Uint8List.fromList([
  0xff, 0xd8, //
  ..._segment(0xe0, [...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
  ..._segment(0xc0, [8, 0, 2, 0, 3, 1, 1, 0x11, 0]),
  ..._segment(0xda, [1, 1, 0, 0, 0x3f, 0]),
  0xff, 0xd9,
]);

/// A big-endian EXIF segment whose IFD0 holds [entries] of (tag, value).
List<int> _exif(List<(int, int)> entries) {
  final ifd = BytesBuilder()..add([entries.length >> 8, entries.length & 0xff]);
  for (final (tag, value) in entries) {
    ifd.add([
      tag >> 8, tag & 0xff, 0, 3, 0, 0, 0, 1, value >> 8, value & 0xff, 0, 0, //
    ]);
  }
  ifd.add([0, 0, 0, 0]);
  return _segment(0xe1, [
    ...ascii.encode('Exif'),
    0,
    0,
    ...ascii.encode('MM'),
    0,
    42,
    0,
    0,
    0,
    8,
    ...ifd.takeBytes(),
  ]);
}

Uint8List _jpegWith(List<int> exif) => Uint8List.fromList([
  0xff,
  0xd8,
  ...exif,
  ..._segment(0xc0, [8, 0, 2, 0, 3, 1, 1, 0x11, 0]),
  0xff,
  0xd9,
]);

(int, int) _size(Uint8List jpeg) {
  final header = ImageHeaders.parse(jpeg)!;
  return (header.width, header.height);
}

void main() {
  test('keeps little-endian EXIF and resets the orientation', () {
    final source = _fixture('photo_exif_full.jpg');
    expect(_size(source), (1200, 1600));

    final output = ExifSplice.keepExif(source, _encoded());

    expect(output.sublist(0, 4), [0xff, 0xd8, 0xff, 0xe1]);
    expect(latin1.decode(output), contains('NMCTestCamera'));
    expect(_size(output), (3, 2));
  });

  test('keeps big-endian EXIF that follows JFIF', () {
    final source = _fixture('photo_exif_rotated.jpg');
    final encoded = _encoded();
    expect(_size(source), (1200, 1600));

    final output = ExifSplice.keepExif(source, encoded);

    expect(output.sublist(0, 4), [0xff, 0xd8, 0xff, 0xe1]);
    expect(_size(output), (3, 2));
    expect(
      output.sublist(output.length - encoded.length + 2),
      encoded.sublist(2),
    );
  });

  test('copies EXIF without an orientation as it is', () {
    final exif = _exif([(0x0100, 640)]);

    final output = ExifSplice.keepExif(_jpegWith(exif), _encoded());

    expect(output.sublist(2, 2 + exif.length), exif);
    expect(output.length, _encoded().length + exif.length);
  });

  test('leaves the output alone without EXIF', () {
    final encoded = _encoded();

    expect(ExifSplice.keepExif(_jpegWith([]), encoded), same(encoded));
    expect(ExifSplice.keepExif(encoded, encoded), same(encoded));
  });

  test('leaves the output alone when the source is not a JPEG', () {
    final encoded = _encoded();
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);

    expect(ExifSplice.keepExif(png, encoded), same(encoded));
  });

  test('leaves a non-JPEG output alone', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);

    expect(
      ExifSplice.keepExif(_fixture('photo_exif_full.jpg'), png),
      same(png),
    );
  });

  test('drops a truncated segment', () {
    final encoded = _encoded();
    final source = _fixture('photo_exif_full.jpg');

    expect(
      ExifSplice.keepExif(Uint8List.sublistView(source, 0, 100), encoded),
      same(encoded),
    );
  });

  test('drops EXIF whose IFD runs past the segment', () {
    final encoded = _encoded();
    final exif = _exif([(0x0112, 6)]);
    // Claims a second entry that is not there.
    exif[19] = 2;

    expect(ExifSplice.keepExif(_jpegWith(exif), encoded), same(encoded));
  });

  test('drops EXIF with an unknown byte order', () {
    final encoded = _encoded();
    final exif = _exif([(0x0112, 6)]);
    exif[10] = 0x58;
    exif[11] = 0x58;

    expect(ExifSplice.keepExif(_jpegWith(exif), encoded), same(encoded));
  });
}
