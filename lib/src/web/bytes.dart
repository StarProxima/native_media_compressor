import 'dart:convert';
import 'dart:typed_data';

/// Thrown when a header is truncated or malformed.
class MalformedMediaException implements Exception {
  const MalformedMediaException(this.message);

  final String message;

  @override
  String toString() => 'MalformedMediaException: $message';
}

/// Big-endian cursor over a byte buffer.
class ByteReader {
  ByteReader(this.bytes, [this.offset = 0, int? end])
    : end = end ?? bytes.length,
      _data = ByteData.sublistView(bytes);

  final Uint8List bytes;

  int offset;

  final int end;

  final ByteData _data;

  int get remaining => end - offset;

  void _need(int count) {
    if (count < 0 || offset + count > end) {
      throw const MalformedMediaException('unexpected end of data');
    }
  }

  void skip(int count) {
    _need(count);
    offset += count;
  }

  int u8() {
    _need(1);
    return bytes[offset++];
  }

  int u16() {
    _need(2);
    final value = _data.getUint16(offset);
    offset += 2;
    return value;
  }

  int u24() => (u16() << 8) | u8();

  int u32() {
    _need(4);
    final value = _data.getUint32(offset);
    offset += 4;
    return value;
  }

  int i32() {
    _need(4);
    final value = _data.getInt32(offset);
    offset += 4;
    return value;
  }

  /// Reads an unsigned 64-bit integer that fits in a Dart number.
  int u64() {
    final high = u32();
    final low = u32();
    return high * 0x100000000 + low;
  }

  Uint8List view(int count) {
    _need(count);
    final result = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return result;
  }

  String fourCc() => latin1.decode(view(4));
}

/// Reads bits most significant first, as H.264 and HEVC parameter sets need.
class BitReader {
  BitReader(this.bytes);

  /// Creates a reader over a NAL unit payload with the emulation prevention
  /// bytes (`00 00 03`) removed.
  factory BitReader.nal(Uint8List nal) {
    final out = BytesBuilder(copy: false);
    var zeros = 0;
    for (final byte in nal) {
      if (zeros >= 2 && byte == 3) {
        zeros = 0;
        continue;
      }
      zeros = byte == 0 ? zeros + 1 : 0;
      out.addByte(byte);
    }
    return BitReader(out.takeBytes());
  }

  final Uint8List bytes;

  var _bit = 0;

  int bits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      final index = _bit >> 3;
      if (index >= bytes.length) {
        throw const MalformedMediaException('parameter set is truncated');
      }
      value = (value << 1) | ((bytes[index] >> (7 - (_bit & 7))) & 1);
      _bit++;
    }
    return value;
  }

  bool flag() => bits(1) == 1;

  void skip(int count) {
    _bit += count;
    if (_bit > bytes.length * 8) {
      throw const MalformedMediaException('parameter set is truncated');
    }
  }

  int ue() {
    var zeros = 0;
    while (bits(1) == 0) {
      if (++zeros > 31) {
        throw const MalformedMediaException('bad Exp-Golomb code');
      }
    }
    return (1 << zeros) - 1 + bits(zeros);
  }

  int se() {
    final code = ue();
    return code.isOdd ? (code + 1) >> 1 : -(code >> 1);
  }
}

/// Big-endian writer with nested ISO BMFF boxes.
class ByteWriter {
  final _out = BytesBuilder();

  int get length => _out.length;

  void u8(int value) => _out.addByte(value & 0xff);

  void u16(int value) {
    u8(value >> 8);
    u8(value);
  }

  void u24(int value) {
    u8(value >> 16);
    u16(value);
  }

  void u32(int value) {
    u16((value >> 16) & 0xffff);
    u16(value & 0xffff);
  }

  void u64(int value) {
    u32(value ~/ 0x100000000);
    u32(value % 0x100000000);
  }

  void zeros(int count) {
    for (var i = 0; i < count; i++) {
      _out.addByte(0);
    }
  }

  void bytes(List<int> value) => _out.add(value);

  void fourCc(String value) => _out.add(latin1.encode(value));

  void box(String type, void Function(ByteWriter body) body) {
    final inner = ByteWriter();
    body(inner);
    final payload = inner.takeBytes();
    u32(payload.length + 8);
    fourCc(type);
    bytes(payload);
  }

  void fullBox(
    String type,
    int version,
    int flags,
    void Function(ByteWriter body) body,
  ) => box(type, (w) {
    w.u8(version);
    w.u24(flags);
    body(w);
  });

  Uint8List takeBytes() => _out.takeBytes();
}
