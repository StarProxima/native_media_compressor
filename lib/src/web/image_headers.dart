import 'dart:convert';
import 'dart:typed_data';

import 'bytes.dart';

/// Size and frame count read from an image header.
final class ImageHeader {
  const ImageHeader({
    required this.mimeType,
    required this.width,
    required this.height,
    this.frameCount = 1,
  });

  final String mimeType;

  /// Width after EXIF orientation.
  final int width;

  /// Height after EXIF orientation.
  final int height;

  final int frameCount;
}

/// Image format detection and header parsers that need no decoder.
abstract final class ImageHeaders {
  /// Detects the format from the magic bytes, or returns null.
  static String? sniffMimeType(Uint8List bytes) {
    bool starts(List<int> magic, [int at = 0]) {
      if (bytes.length < at + magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[at + i] != magic[i]) return false;
      }
      return true;
    }

    String ascii(int at, int length) =>
        bytes.length < at + length
            ? ''
            : latin1.decode(Uint8List.sublistView(bytes, at, at + length));

    if (starts([0xff, 0xd8, 0xff])) return 'image/jpeg';
    if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      return 'image/png';
    }
    if (ascii(0, 6) == 'GIF87a' || ascii(0, 6) == 'GIF89a') return 'image/gif';
    if (ascii(0, 4) == 'RIFF' && ascii(8, 4) == 'WEBP') return 'image/webp';
    if (ascii(0, 2) == 'BM' && bytes.length >= 26) return 'image/bmp';
    if (starts([0x49, 0x49, 0x2a, 0x00]) || starts([0x4d, 0x4d, 0x00, 0x2a])) {
      return 'image/tiff';
    }
    if (ascii(4, 4) == 'ftyp') return _isobmffImageType(bytes);
    return null;
  }

  static String? _isobmffImageType(Uint8List bytes) {
    final reader = ByteReader(bytes);
    try {
      final size = reader.u32();
      reader.skip(4);
      final end = size.clamp(16, bytes.length);
      final brands = <String>[reader.fourCc()];
      reader.skip(4);
      while (reader.offset + 4 <= end) {
        brands.add(reader.fourCc());
      }
      const heic = {'heic', 'heix', 'heim', 'heis', 'hevc', 'hevx'};
      if (brands.first == 'avif' || brands.first == 'avis') return 'image/avif';
      if (heic.contains(brands.first)) return 'image/heic';
      if (brands.any((brand) => brand == 'avif' || brand == 'avis')) {
        return 'image/avif';
      }
      if (brands.any(heic.contains)) return 'image/heic';
      if (brands.any((brand) => brand == 'mif1' || brand == 'msf1')) {
        return 'image/heif';
      }
    } on MalformedMediaException {
      return null;
    }
    return null;
  }

  /// Parses JPEG, PNG, GIF, WebP and BMP headers. Returns null for other
  /// formats and for headers it cannot read.
  static ImageHeader? parse(Uint8List bytes) {
    final mimeType = sniffMimeType(bytes);
    try {
      return switch (mimeType) {
        'image/jpeg' => _jpeg(bytes),
        'image/png' => _png(bytes),
        'image/gif' => _gif(bytes),
        'image/webp' => _webp(bytes),
        'image/bmp' => _bmp(bytes),
        _ => null,
      };
    } on MalformedMediaException {
      return null;
    }
  }

  static ImageHeader? _jpeg(Uint8List bytes) {
    final reader = ByteReader(bytes, 2);
    var orientation = 1;
    while (reader.remaining >= 4) {
      if (reader.u8() != 0xff) return null;
      var marker = reader.u8();
      while (marker == 0xff) {
        marker = reader.u8();
      }
      if (marker == 0xd8 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (marker == 0xd9 || marker == 0xda) return null;
      final length = reader.u16();
      if (length < 2) return null;
      final segment = ByteReader(
        bytes,
        reader.offset,
        reader.offset + length - 2,
      );
      reader.skip(length - 2);
      if (marker == 0xe1) {
        orientation = _exifOrientation(segment) ?? orientation;
      }
      final isFrame =
          marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc;
      if (isFrame) {
        segment.skip(1);
        final height = segment.u16();
        final width = segment.u16();
        if (width == 0 || height == 0) return null;
        final swap = orientation >= 5 && orientation <= 8;
        return ImageHeader(
          mimeType: 'image/jpeg',
          width: swap ? height : width,
          height: swap ? width : height,
        );
      }
    }
    return null;
  }

  static int? _exifOrientation(ByteReader segment) {
    if (segment.remaining < 14) return null;
    if (latin1.decode(segment.view(6)) != 'Exif\u0000\u0000') return null;
    final tiff = segment.offset;
    final bytes = segment.bytes;
    final order = latin1.decode(segment.view(2));
    if (order != 'II' && order != 'MM') return null;
    final little = order == 'II';
    final data = ByteData.sublistView(bytes, tiff, segment.end);
    int u16(int at) => data.getUint16(at, little ? Endian.little : Endian.big);
    int u32(int at) => data.getUint32(at, little ? Endian.little : Endian.big);
    if (data.lengthInBytes < 8) return null;
    final ifd = u32(4);
    if (ifd + 2 > data.lengthInBytes) return null;
    final count = u16(ifd);
    for (var i = 0; i < count; i++) {
      final entry = ifd + 2 + i * 12;
      if (entry + 12 > data.lengthInBytes) return null;
      if (u16(entry) == 0x0112) {
        final value = u16(entry + 8);
        return value >= 1 && value <= 8 ? value : null;
      }
    }
    return null;
  }

  static ImageHeader? _png(Uint8List bytes) {
    final reader = ByteReader(bytes, 8);
    int? width, height;
    var frames = 1;
    while (reader.remaining >= 12) {
      final length = reader.u32();
      final type = reader.fourCc();
      if (type == 'IHDR') {
        width = reader.u32();
        height = reader.u32();
        reader.skip(length - 8 + 4);
      } else if (type == 'acTL') {
        frames = reader.u32();
        reader.skip(length - 4 + 4);
      } else if (type == 'IDAT' || type == 'IEND') {
        break;
      } else {
        reader.skip(length + 4);
      }
    }
    if (width == null || height == null || width == 0 || height == 0) {
      return null;
    }
    return ImageHeader(
      mimeType: 'image/png',
      width: width,
      height: height,
      frameCount: frames < 1 ? 1 : frames,
    );
  }

  static ImageHeader? _gif(Uint8List bytes) {
    final reader = ByteReader(bytes, 6);
    final width = reader.u8() | (reader.u8() << 8);
    final height = reader.u8() | (reader.u8() << 8);
    final flags = reader.u8();
    reader.skip(2);
    if (flags & 0x80 != 0) reader.skip(3 << ((flags & 7) + 1));

    void skipSubBlocks() {
      for (var size = reader.u8(); size != 0; size = reader.u8()) {
        reader.skip(size);
      }
    }

    var frames = 0;
    while (reader.remaining > 0) {
      final block = reader.u8();
      if (block == 0x3b) break;
      if (block == 0x21) {
        reader.skip(1);
        skipSubBlocks();
      } else if (block == 0x2c) {
        frames++;
        reader.skip(8);
        final local = reader.u8();
        if (local & 0x80 != 0) reader.skip(3 << ((local & 7) + 1));
        reader.skip(1);
        skipSubBlocks();
      } else {
        break;
      }
    }
    if (width == 0 || height == 0 || frames == 0) return null;
    return ImageHeader(
      mimeType: 'image/gif',
      width: width,
      height: height,
      frameCount: frames,
    );
  }

  static ImageHeader? _webp(Uint8List bytes) {
    final reader = ByteReader(bytes, 12);
    int? width, height;
    var animated = false;
    var frames = 0;
    while (reader.remaining >= 8) {
      final type = reader.fourCc();
      final size = ByteData.sublistView(
        reader.view(4),
      ).getUint32(0, Endian.little);
      final chunk = ByteReader(
        bytes,
        reader.offset,
        (reader.offset + size).clamp(0, bytes.length),
      );
      switch (type) {
        case 'VP8X':
          final flags = chunk.u8();
          animated = flags & 0x02 != 0;
          chunk.skip(3);
          width = _u24le(chunk) + 1;
          height = _u24le(chunk) + 1;
        case 'VP8 ' when width == null:
          chunk.skip(3);
          if (chunk.u8() != 0x9d || chunk.u8() != 0x01 || chunk.u8() != 0x2a) {
            return null;
          }
          width = (chunk.u8() | (chunk.u8() << 8)) & 0x3fff;
          height = (chunk.u8() | (chunk.u8() << 8)) & 0x3fff;
        case 'VP8L' when width == null:
          if (chunk.u8() != 0x2f) return null;
          final bits =
              chunk.u8() |
              (chunk.u8() << 8) |
              (chunk.u8() << 16) |
              (chunk.u8() << 24);
          width = (bits & 0x3fff) + 1;
          height = ((bits >> 14) & 0x3fff) + 1;
        case 'ANMF':
          frames++;
      }
      if (!animated && width != null) break;
      reader.offset += size + (size & 1);
      if (reader.offset > reader.end) break;
    }
    if (width == null || height == null || width == 0 || height == 0) {
      return null;
    }
    return ImageHeader(
      mimeType: 'image/webp',
      width: width,
      height: height,
      frameCount: animated && frames > 0 ? frames : 1,
    );
  }

  static int _u24le(ByteReader reader) =>
      reader.u8() | (reader.u8() << 8) | (reader.u8() << 16);

  static ImageHeader? _bmp(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final headerSize = data.getUint32(14, Endian.little);
    final int width, height;
    if (headerSize == 12) {
      width = data.getUint16(18, Endian.little);
      height = data.getUint16(20, Endian.little);
    } else {
      width = data.getInt32(18, Endian.little).abs();
      height = data.getInt32(22, Endian.little).abs();
    }
    if (width == 0 || height == 0) return null;
    return ImageHeader(mimeType: 'image/bmp', width: width, height: height);
  }
}
