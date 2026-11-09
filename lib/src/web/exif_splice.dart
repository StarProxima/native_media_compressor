import 'dart:typed_data';

/// Carries the EXIF segment of a source JPEG over to a re-encoded one, which
/// a canvas writes without any metadata.
abstract final class ExifSplice {
  static const _orientationTag = 0x0112;

  /// [encoded] with the EXIF of [source] inserted after its start marker and
  /// the orientation set to normal, since the pixels are already turned.
  /// Returns [encoded] as is when either one is not a JPEG or [source] has
  /// no readable EXIF.
  static Uint8List keepExif(Uint8List source, Uint8List encoded) {
    if (!_isJpeg(encoded)) return encoded;
    final segment = _exifSegment(source);
    if (segment == null) return encoded;
    return Uint8List(encoded.length + segment.length)
      ..setRange(0, 2, encoded)
      ..setRange(2, 2 + segment.length, segment)
      ..setRange(
        2 + segment.length,
        encoded.length + segment.length,
        encoded,
        2,
      );
  }

  /// A copy of the APP1 `Exif` segment of [jpeg], marker and length included,
  /// with the orientation in its first IFD set to 1, or null when there is
  /// no such segment or its IFD cannot be read.
  static Uint8List? _exifSegment(Uint8List jpeg) {
    if (!_isJpeg(jpeg)) return null;
    var offset = 2;
    while (offset + 4 <= jpeg.length) {
      if (jpeg[offset] != 0xff) return null;
      final marker = jpeg[offset + 1];
      if (marker == 0xff) {
        offset++;
        continue;
      }
      if (marker == 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) {
        offset += 2;
        continue;
      }
      if (marker == 0xd9 || marker == 0xda) return null;
      final length = (jpeg[offset + 2] << 8) | jpeg[offset + 3];
      final end = offset + 2 + length;
      if (length < 2 || end > jpeg.length) return null;
      if (marker == 0xe1 && _isExif(jpeg, offset + 4, end)) {
        final segment = Uint8List.fromList(jpeg.sublist(offset, end));
        return _normalizeOrientation(segment) ? segment : null;
      }
      offset = end;
    }
    return null;
  }

  static bool _isJpeg(Uint8List bytes) =>
      bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8;

  static bool _isExif(Uint8List bytes, int at, int end) {
    const header = [0x45, 0x78, 0x69, 0x66, 0, 0];
    if (at + header.length > end) return false;
    for (var i = 0; i < header.length; i++) {
      if (bytes[at + i] != header[i]) return false;
    }
    return true;
  }

  /// Sets the orientation of IFD0 in [segment] to 1, if it has one. False
  /// when the IFD cannot be walked: a kept tag could then turn the picture a
  /// second time.
  static bool _normalizeOrientation(Uint8List segment) {
    const tiffStart = 10;
    if (segment.length < tiffStart + 8) return false;
    final tiff = ByteData.sublistView(segment, tiffStart);
    final Endian order;
    switch ((segment[tiffStart], segment[tiffStart + 1])) {
      case (0x49, 0x49):
        order = Endian.little;
      case (0x4d, 0x4d):
        order = Endian.big;
      default:
        return false;
    }
    if (tiff.getUint16(2, order) != 42) return false;
    final ifd = tiff.getUint32(4, order);
    if (ifd + 2 > tiff.lengthInBytes) return false;
    final count = tiff.getUint16(ifd, order);
    if (ifd + 2 + count * 12 > tiff.lengthInBytes) return false;
    for (var i = 0; i < count; i++) {
      final entry = ifd + 2 + i * 12;
      if (tiff.getUint16(entry, order) != _orientationTag) continue;
      tiff
        ..setUint16(entry + 2, 3, order)
        ..setUint32(entry + 4, 1, order)
        ..setUint16(entry + 8, 1, order)
        ..setUint16(entry + 10, 0, order);
    }
    return true;
  }
}
