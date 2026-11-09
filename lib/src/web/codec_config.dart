import 'dart:typed_data';

import 'bytes.dart';

/// Colour signalling of a video track, as ISO/IEC 23091-2 code points.
final class ColorInfo {
  const ColorInfo({
    required this.primaries,
    required this.transfer,
    required this.matrix,
  });

  final int primaries;
  final int transfer;
  final int matrix;

  /// PQ (SMPTE ST 2084) or HLG (ARIB STD-B67).
  bool get isHdr => transfer == 16 || transfer == 18;
}

/// Reads decoder configuration records from MP4 sample entries.
abstract final class CodecConfig {
  /// WebCodecs codec string for the sample entry [type] with the
  /// configuration record [config], or null when it cannot be built.
  static String? codecString(String type, Uint8List? config) {
    if (config == null) return null;
    try {
      return switch (type) {
        'avc1' || 'avc3' => _avc(type, config),
        'hvc1' || 'hev1' => _hevc(type, config),
        'vp09' => _vp9(config),
        'av01' => _av1(config),
        _ => null,
      };
    } on MalformedMediaException {
      return null;
    }
  }

  static String _hex2(int value) => value.toRadixString(16).padLeft(2, '0');

  static String _avc(String type, Uint8List config) {
    if (config.length < 4) {
      throw const MalformedMediaException('avcC is too short');
    }
    return '$type.${_hex2(config[1])}${_hex2(config[2])}${_hex2(config[3])}';
  }

  static String _hevc(String type, Uint8List config) {
    final reader = ByteReader(config, 1);
    final first = reader.u8();
    final space = first >> 6;
    final tier = (first >> 5) & 1;
    final profile = first & 0x1f;
    final compatibility = reader.u32();
    final constraints = reader.view(6);
    final level = reader.u8();
    var reversed = 0;
    for (var i = 0; i < 32; i++) {
      if (compatibility & (1 << i) != 0) reversed |= 1 << (31 - i);
    }
    final parts = [
      type,
      '${space == 0 ? '' : String.fromCharCode(0x40 + space)}$profile',
      reversed.toRadixString(16).toUpperCase(),
      '${tier == 1 ? 'H' : 'L'}$level',
    ];
    var last = constraints.length;
    while (last > 0 && constraints[last - 1] == 0) {
      last--;
    }
    for (var i = 0; i < last; i++) {
      parts.add(constraints[i].toRadixString(16).toUpperCase());
    }
    return parts.join('.');
  }

  static String _vp9(Uint8List config) {
    final reader = ByteReader(config, 4);
    final profile = reader.u8();
    final level = reader.u8();
    final depth = reader.u8() >> 4;
    String two(int value) => value.toString().padLeft(2, '0');
    return 'vp09.${two(profile)}.${two(level)}.${two(depth)}';
  }

  static String _av1(Uint8List config) {
    final reader = ByteReader(config, 1);
    final first = reader.u8();
    final second = reader.u8();
    final profile = first >> 5;
    final level = first & 0x1f;
    final tier = (second & 0x80) != 0 ? 'H' : 'M';
    final high = (second & 0x40) != 0;
    final twelve = (second & 0x20) != 0;
    final depth = high ? (twelve ? 12 : 10) : 8;
    return 'av01.$profile.${level.toString().padLeft(2, '0')}$tier.'
        '${depth.toString().padLeft(2, '0')}';
  }

  /// Colour signalling carried inside the codec configuration: the VUI of an
  /// HEVC sequence parameter set or the fields of `vpcC`.
  static ColorInfo? colorInfo(String type, Uint8List? config) {
    if (config == null) return null;
    try {
      return switch (type) {
        'hvc1' || 'hev1' => _hevcColor(config),
        'vp09' => _vp9Color(config),
        _ => null,
      };
    } on MalformedMediaException {
      return null;
    }
  }

  static ColorInfo? _vp9Color(Uint8List config) {
    if (config[0] < 1) return null;
    final reader = ByteReader(config, 7);
    return ColorInfo(
      primaries: reader.u8(),
      transfer: reader.u8(),
      matrix: reader.u8(),
    );
  }

  static ColorInfo? _hevcColor(Uint8List config) {
    final reader = ByteReader(config, 22);
    final arrays = reader.u8();
    for (var i = 0; i < arrays; i++) {
      final nalType = reader.u8() & 0x3f;
      final count = reader.u16();
      for (var j = 0; j < count; j++) {
        final nal = reader.view(reader.u16());
        if (nalType == 33) return HevcSps.colorInfo(nal);
      }
    }
    return null;
  }
}

/// Reads the colour description from the VUI of an HEVC sequence parameter
/// set (ITU-T H.265 7.3.2.2).
abstract final class HevcSps {
  static ColorInfo? colorInfo(Uint8List nal) {
    final bits = BitReader.nal(Uint8List.sublistView(nal, 2));
    bits.skip(4);
    final maxSubLayersMinus1 = bits.bits(3);
    bits.skip(1);
    _profileTierLevel(bits, maxSubLayersMinus1);
    bits.ue();
    if (bits.ue() == 3) bits.skip(1);
    bits.ue();
    bits.ue();
    if (bits.flag()) {
      for (var i = 0; i < 4; i++) {
        bits.ue();
      }
    }
    bits.ue();
    bits.ue();
    final log2MaxPocLsb = bits.ue() + 4;
    final orderingInfo = bits.flag();
    for (
      var i = orderingInfo ? 0 : maxSubLayersMinus1;
      i <= maxSubLayersMinus1;
      i++
    ) {
      bits.ue();
      bits.ue();
      bits.ue();
    }
    for (var i = 0; i < 6; i++) {
      bits.ue();
    }
    if (bits.flag() && bits.flag()) _scalingListData(bits);
    bits.skip(2);
    if (bits.flag()) {
      bits.skip(8);
      bits.ue();
      bits.ue();
      bits.skip(1);
    }
    final shortTermSets = bits.ue();
    final deltaPocs = <int>[];
    for (var i = 0; i < shortTermSets; i++) {
      deltaPocs.add(_shortTermRefPicSet(bits, i, deltaPocs));
    }
    if (bits.flag()) {
      final longTerm = bits.ue();
      for (var i = 0; i < longTerm; i++) {
        bits.skip(log2MaxPocLsb + 1);
      }
    }
    bits.skip(2);
    if (!bits.flag()) return null;
    if (bits.flag() && bits.bits(8) == 255) bits.skip(32);
    if (bits.flag()) bits.skip(1);
    if (!bits.flag()) return null;
    bits.skip(4);
    if (!bits.flag()) return null;
    return ColorInfo(
      primaries: bits.bits(8),
      transfer: bits.bits(8),
      matrix: bits.bits(8),
    );
  }

  static void _profileTierLevel(BitReader bits, int maxSubLayersMinus1) {
    bits.skip(96);
    final profilePresent = <bool>[];
    final levelPresent = <bool>[];
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      profilePresent.add(bits.flag());
      levelPresent.add(bits.flag());
    }
    if (maxSubLayersMinus1 > 0) bits.skip(2 * (8 - maxSubLayersMinus1));
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      if (profilePresent[i]) bits.skip(88);
      if (levelPresent[i]) bits.skip(8);
    }
  }

  static void _scalingListData(BitReader bits) {
    for (var size = 0; size < 4; size++) {
      for (var matrix = 0; matrix < 6; matrix += size == 3 ? 3 : 1) {
        if (!bits.flag()) {
          bits.ue();
          continue;
        }
        final coefficients = 1 << (4 + (size << 1));
        if (size > 1) bits.se();
        for (var i = 0; i < (coefficients > 64 ? 64 : coefficients); i++) {
          bits.se();
        }
      }
    }
  }

  static int _shortTermRefPicSet(BitReader bits, int index, List<int> sets) {
    if (index != 0 && bits.flag()) {
      bits.skip(1);
      bits.ue();
      var count = 0;
      for (var j = 0; j <= sets[index - 1]; j++) {
        final used = bits.flag();
        if (used || bits.flag()) count++;
      }
      return count;
    }
    final negative = bits.ue();
    final positive = bits.ue();
    for (var i = 0; i < negative + positive; i++) {
      bits.ue();
      bits.skip(1);
    }
    return negative + positive;
  }
}

/// Configuration records for re-encoding audio to AAC.
abstract final class AudioConfig {
  /// WebCodecs codec string and decoder description for audio with the MIME
  /// type [mimeType] and the `dOps` or `dfLa` payload [config], or null when
  /// there is no decoder to ask for.
  static (String, Uint8List?)? decoder(String? mimeType, Uint8List? config) {
    try {
      return switch (mimeType) {
        'audio/mpeg' => ('mp3', null),
        'audio/ac3' => ('ac-3', null),
        'audio/eac3' => ('ec-3', null),
        'audio/opus' when config != null => ('opus', opusHead(config)),
        'audio/flac' when config != null && config.length > 4 => (
          'flac',
          Uint8List.fromList([...'fLaC'.codeUnits, ...config.skip(4)]),
        ),
        _ => null,
      };
    } on MalformedMediaException {
      return null;
    }
  }

  /// The Ogg `OpusHead` header WebCodecs takes as the Opus description, from
  /// the big-endian `dOps` payload of MP4.
  static Uint8List opusHead(Uint8List dOps) {
    final reader = ByteReader(dOps, 1);
    final channels = reader.u8();
    final preSkip = reader.u16();
    final sampleRate = reader.u32();
    final gain = reader.u16();
    final family = reader.u8();
    final head =
        ByteData(19)
          ..setUint8(8, 1)
          ..setUint8(9, channels)
          ..setUint16(10, preSkip, Endian.little)
          ..setUint32(12, sampleRate, Endian.little)
          ..setUint16(16, gain, Endian.little)
          ..setUint8(18, family);
    final bytes = head.buffer.asUint8List()..setAll(0, 'OpusHead'.codeUnits);
    if (family == 0) return bytes;
    return Uint8List.fromList([...bytes, ...reader.view(2 + channels)]);
  }

  /// A complete `esds` box for AAC with the AudioSpecificConfig [asc] the
  /// encoder reported.
  static Uint8List esds(Uint8List asc, {required int bitrate}) {
    final decoderConfig = _descriptor(0x04, [
      0x40,
      // Audio stream, upstream flag clear, reserved bit set.
      0x15,
      0, 0, 0,
      ..._u32(bitrate),
      ..._u32(bitrate),
      ..._descriptor(0x05, asc),
    ]);
    final elementary = _descriptor(0x03, [
      0,
      0,
      0,
      ...decoderConfig,
      ..._descriptor(0x06, const [0x02]),
    ]);
    final writer =
        ByteWriter()..fullBox('esds', 0, 0, (w) => w.bytes(elementary));
    return writer.takeBytes();
  }

  static List<int> _u32(int value) => [
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ];

  /// An MPEG-4 descriptor: tag, size in 7-bit groups, body.
  static List<int> _descriptor(int tag, List<int> body) {
    final size = <int>[body.length & 0x7f];
    for (var rest = body.length >> 7; rest > 0; rest >>= 7) {
      size.insert(0, 0x80 | (rest & 0x7f));
    }
    return [tag, ...size, ...body];
  }
}
