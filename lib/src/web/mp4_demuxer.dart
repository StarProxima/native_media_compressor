import 'dart:typed_data';

import 'bytes.dart';
import 'codec_config.dart';
import 'media_plan.dart';

/// Random access to the bytes of a media file.
abstract interface class ByteSource {
  int get length;

  Future<Uint8List> read(int offset, int length);
}

/// A [ByteSource] over bytes already in memory.
final class MemoryByteSource implements ByteSource {
  const MemoryByteSource(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async =>
      Uint8List.sublistView(bytes, offset, offset + length);
}

/// One sample of a track. Times are in the track timescale, before the edit
/// list is applied.
final class Mp4Sample {
  const Mp4Sample({
    required this.offset,
    required this.size,
    required this.decodeTime,
    required this.presentationTime,
    required this.duration,
    required this.isSync,
  });

  final int offset;
  final int size;
  final int decodeTime;
  final int presentationTime;
  final int duration;
  final bool isSync;
}

/// A track of an MP4 or QuickTime file.
final class Mp4Track {
  Mp4Track._(this.id);

  final int id;
  String handler = '';
  int timescale = 0;
  int duration = 0;
  List<int> matrix = const [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000];

  /// Media time where presentation starts, from the first non-empty edit.
  int editMediaTime = 0;

  String? sampleEntryType;
  int width = 0;
  int height = 0;

  /// The `avcC`, `hvcC`, `vpcC` or `av1C` payload of a video track.
  Uint8List? codecConfig;
  ColorInfo? _colr;
  int? audioObjectType;

  /// The complete `esds` box of an MPEG-4 audio track.
  Uint8List? esds;

  /// The `dOps` or `dfLa` payload of an Opus or FLAC track.
  Uint8List? audioConfig;
  int channelCount = 0;
  int sampleSize = 16;
  int sampleRate = 0;
  List<Mp4Sample> samples = const [];

  bool get isVideo => handler == 'vide';

  bool get isAudio => handler == 'soun';

  /// Clockwise rotation the player applies, from the track matrix.
  int get rotation {
    final a = matrix[0].sign, b = matrix[1].sign;
    final c = matrix[3].sign, d = matrix[4].sign;
    if (a == 0 && b == 1 && c == -1 && d == 0) return 90;
    if (a == -1 && b == 0 && c == 0 && d == -1) return 180;
    if (a == 0 && b == -1 && c == 1 && d == 0) return 270;
    return 0;
  }

  ColorInfo? get color =>
      _colr ?? CodecConfig.colorInfo(sampleEntryType ?? '', codecConfig);

  bool get isHdr => color?.isHdr ?? false;

  /// WebCodecs codec string of a video track.
  String? get codecString =>
      CodecConfig.codecString(sampleEntryType ?? '', codecConfig);

  /// Codec MIME type with the spellings `MediaFormat` uses.
  String? get mimeType {
    final type = sampleEntryType;
    if (type == null) return null;
    if (isVideo) {
      return switch (type) {
        'avc1' || 'avc3' => 'video/avc',
        'hvc1' || 'hev1' => 'video/hevc',
        'vp08' => 'video/x-vnd.on2.vp8',
        'vp09' => 'video/x-vnd.on2.vp9',
        'av01' => 'video/av01',
        'mp4v' => 'video/mp4v-es',
        _ => type,
      };
    }
    return switch (type) {
      'mp4a' => switch (audioObjectType) {
        0x40 || 0x66 || 0x67 || 0x68 => 'audio/mp4a-latm',
        0x69 || 0x6b => 'audio/mpeg',
        0xa5 => 'audio/ac3',
        0xa6 => 'audio/eac3',
        0xad => 'audio/opus',
        0xae => 'audio/flac',
        null => 'mp4a',
        final value => 'mp4a.${value.toRadixString(16)}',
      },
      '.mp3' => 'audio/mpeg',
      'Opus' => 'audio/opus',
      'ac-3' => 'audio/ac3',
      'ec-3' => 'audio/eac3',
      'fLaC' => 'audio/flac',
      _ => type,
    };
  }

  bool get isAac => mimeType == 'audio/mp4a-latm';

  /// Track duration in milliseconds.
  int get durationMs => timescale == 0 ? 0 : duration * 1000 ~/ timescale;

  /// Average frames per second, from the sample count and the sample
  /// durations: the media duration also counts the delay that B-frames add
  /// before the first frame.
  double? get frameRate {
    final total = samples.fold(0, (sum, sample) => sum + sample.duration);
    return MediaPlan.frameRate(
      samples.length,
      total > 0 ? total : duration,
      timescale,
    );
  }
}

/// The movie box of an MP4 or QuickTime file.
final class Mp4Movie {
  const Mp4Movie({
    required this.timescale,
    required this.duration,
    required this.tracks,
  });

  final int timescale;
  final int duration;
  final List<Mp4Track> tracks;

  /// The first video track with a sample description.
  Mp4Track? get video {
    for (final track in tracks) {
      if (track.isVideo && track.sampleEntryType != null) return track;
    }
    return null;
  }

  List<Mp4Track> get audio => [
    for (final track in tracks)
      if (track.isAudio && track.sampleEntryType != null) track,
  ];

  int get durationMs {
    if (timescale > 0 && duration > 0) return duration * 1000 ~/ timescale;
    var longest = 0;
    for (final track in tracks) {
      if (track.durationMs > longest) longest = track.durationMs;
    }
    return longest;
  }
}

/// Parses the `moov` box of MP4 and QuickTime files.
abstract final class Mp4Demuxer {
  static final _boxType = RegExp(r'^[\x20-\x7e\xa9]{4}$');

  /// Returns null when [source] is not an MP4 or QuickTime file or its
  /// sample tables are inconsistent.
  static Future<Mp4Movie?> parse(ByteSource source) async {
    var offset = 0;
    var first = true;
    while (offset + 8 <= source.length) {
      final header = await source.read(
        offset,
        (source.length - offset).clamp(8, 16),
      );
      final reader = ByteReader(header);
      var size = reader.u32();
      final type = reader.fourCc();
      if (!_boxType.hasMatch(type)) return null;
      var headerSize = 8;
      if (size == 1) {
        if (header.length < 16) return null;
        size = reader.u64();
        headerSize = 16;
      } else if (size == 0) {
        size = source.length - offset;
      }
      if (size < headerSize) return null;
      if (first && type != 'ftyp' && type != 'moov' && !_quickTime(type)) {
        return null;
      }
      first = false;
      if (type == 'moov') {
        if (offset + size > source.length) return null;
        final moov = await source.read(offset + headerSize, size - headerSize);
        try {
          return _movie(moov);
        } on MalformedMediaException {
          return null;
        } on RangeError {
          return null;
        }
      }
      offset += size;
    }
    return null;
  }

  static bool _quickTime(String type) =>
      const {'wide', 'free', 'skip', 'mdat', 'pnot'}.contains(type);

  static Iterable<(String, ByteReader)> _children(ByteReader parent) sync* {
    while (parent.remaining >= 8) {
      final start = parent.offset;
      var size = parent.u32();
      final type = parent.fourCc();
      if (size == 1) {
        size = parent.u64();
      } else if (size == 0) {
        size = parent.end - start;
      }
      final bodyStart = parent.offset;
      final end = start + size;
      if (size < bodyStart - start || end > parent.end) {
        throw MalformedMediaException('box $type overruns its parent');
      }
      parent.offset = end;
      yield (type, ByteReader(parent.bytes, bodyStart, end));
    }
  }

  static Mp4Movie _movie(Uint8List moov) {
    var timescale = 0, duration = 0;
    final tracks = <Mp4Track>[];
    for (final (type, box) in _children(ByteReader(moov))) {
      if (type == 'mvhd') {
        final version = box.u8();
        box.skip(3);
        if (version == 1) {
          box.skip(16);
          timescale = box.u32();
          duration = box.u64();
        } else {
          box.skip(8);
          timescale = box.u32();
          duration = box.u32();
        }
      } else if (type == 'trak') {
        final track = _track(box);
        if (track != null) tracks.add(track);
      }
    }
    return Mp4Movie(timescale: timescale, duration: duration, tracks: tracks);
  }

  static Mp4Track? _track(ByteReader trak) {
    Mp4Track? track;
    ByteReader? mdia, edts;
    for (final (type, box) in _children(trak)) {
      switch (type) {
        case 'tkhd':
          final version = box.u8();
          box.skip(3 + (version == 1 ? 16 : 8));
          track = Mp4Track._(box.u32());
          box.skip(4 + (version == 1 ? 8 : 4) + 16);
          track.matrix = [for (var i = 0; i < 9; i++) box.i32()];
        case 'mdia':
          mdia = box;
        case 'edts':
          edts = box;
      }
    }
    if (track == null || mdia == null) return null;
    if (edts != null) _edits(track, edts);
    ByteReader? stbl;
    for (final (type, box) in _children(mdia)) {
      switch (type) {
        case 'mdhd':
          final version = box.u8();
          box.skip(3 + (version == 1 ? 16 : 8));
          track.timescale = box.u32();
          track.duration = version == 1 ? box.u64() : box.u32();
        case 'hdlr':
          box.skip(8);
          track.handler = box.fourCc();
        case 'minf':
          for (final (childType, child) in _children(box)) {
            if (childType == 'stbl') stbl = child;
          }
      }
    }
    if (stbl != null) _sampleTable(track, stbl);
    return track;
  }

  static void _edits(Mp4Track track, ByteReader edts) {
    for (final (type, box) in _children(edts)) {
      if (type != 'elst') continue;
      final version = box.u8();
      box.skip(3);
      final count = box.u32();
      for (var i = 0; i < count; i++) {
        final int mediaTime;
        if (version == 1) {
          box.skip(8);
          final high = box.i32();
          final low = box.u32();
          mediaTime = high * 0x100000000 + low;
        } else {
          box.skip(4);
          mediaTime = box.i32();
        }
        box.skip(4);
        if (mediaTime >= 0) {
          track.editMediaTime = mediaTime;
          return;
        }
      }
    }
  }

  static void _sampleTable(Mp4Track track, ByteReader stbl) {
    List<(int, int)> timeToSample = const [];
    List<(int, int)> compositionOffsets = const [];
    List<(int, int)> sampleToChunk = const [];
    List<int> sizes = const [];
    List<int> chunkOffsets = const [];
    Set<int>? syncSamples;
    for (final (type, box) in _children(stbl)) {
      switch (type) {
        case 'stsd':
          box.skip(4);
          if (box.u32() > 0) {
            final (entryType, entry) = _children(box).first;
            _sampleEntry(track, entryType, entry);
          }
        case 'stts':
          timeToSample = _pairs(box);
        case 'ctts':
          compositionOffsets = _pairs(box, signedSecond: true);
        case 'stsc':
          box.skip(4);
          final entries = box.u32();
          sampleToChunk = [];
          for (var i = 0; i < entries; i++) {
            sampleToChunk.add((box.u32(), box.u32()));
            box.skip(4);
          }
        case 'stsz':
          box.skip(4);
          final fixed = box.u32();
          final count = box.u32();
          sizes =
              fixed != 0
                  ? List.filled(count, fixed)
                  : [for (var i = 0; i < count; i++) box.u32()];
        case 'stz2':
          box.skip(7);
          final field = box.u8();
          final count = box.u32();
          sizes = List.filled(count, 0);
          for (var i = 0; i < count; i++) {
            sizes[i] = switch (field) {
              4 => i.isEven ? box.bytes[box.offset] >> 4 : box.u8() & 0xf,
              8 => box.u8(),
              16 => box.u16(),
              _ => throw const MalformedMediaException('bad stz2 field size'),
            };
          }
        case 'stco':
          box.skip(4);
          chunkOffsets = [for (var i = box.u32(); i > 0; i--) box.u32()];
        case 'co64':
          box.skip(4);
          chunkOffsets = [for (var i = box.u32(); i > 0; i--) box.u64()];
        case 'stss':
          box.skip(4);
          syncSamples = {for (var i = box.u32(); i > 0; i--) box.u32()};
      }
    }
    if (sizes.isEmpty) return;
    track.samples = _samples(
      sizes: sizes,
      chunkOffsets: chunkOffsets,
      sampleToChunk: sampleToChunk,
      timeToSample: timeToSample,
      compositionOffsets: compositionOffsets,
      syncSamples: syncSamples,
    );
  }

  static List<(int, int)> _pairs(ByteReader box, {bool signedSecond = false}) {
    box.skip(4);
    return [
      for (var i = box.u32(); i > 0; i--)
        (box.u32(), signedSecond ? box.i32() : box.u32()),
    ];
  }

  static List<Mp4Sample> _samples({
    required List<int> sizes,
    required List<int> chunkOffsets,
    required List<(int, int)> sampleToChunk,
    required List<(int, int)> timeToSample,
    required List<(int, int)> compositionOffsets,
    required Set<int>? syncSamples,
  }) {
    final count = sizes.length;
    final offsets = List.filled(count, 0);
    var sample = 0;
    for (var entry = 0; entry < sampleToChunk.length; entry++) {
      final (firstChunk, perChunk) = sampleToChunk[entry];
      final lastChunk =
          entry + 1 < sampleToChunk.length
              ? sampleToChunk[entry + 1].$1 - 1
              : chunkOffsets.length;
      for (var chunk = firstChunk; chunk <= lastChunk; chunk++) {
        if (chunk < 1 || chunk > chunkOffsets.length) {
          throw const MalformedMediaException('bad chunk index');
        }
        var offset = chunkOffsets[chunk - 1];
        for (var i = 0; i < perChunk && sample < count; i++) {
          offsets[sample] = offset;
          offset += sizes[sample];
          sample++;
        }
      }
    }
    if (sample != count) {
      throw const MalformedMediaException('chunks do not cover all samples');
    }

    final durations = <int>[];
    for (final (repeat, delta) in timeToSample) {
      for (var i = 0; i < repeat && durations.length < count; i++) {
        durations.add(delta);
      }
    }
    if (durations.length < count) {
      throw const MalformedMediaException('stts does not cover all samples');
    }
    final shifts = <int>[];
    for (final (repeat, shift) in compositionOffsets) {
      for (var i = 0; i < repeat && shifts.length < count; i++) {
        shifts.add(shift);
      }
    }

    final samples = <Mp4Sample>[];
    var time = 0;
    for (var i = 0; i < count; i++) {
      samples.add(
        Mp4Sample(
          offset: offsets[i],
          size: sizes[i],
          decodeTime: time,
          presentationTime: time + (i < shifts.length ? shifts[i] : 0),
          duration: durations[i],
          isSync: syncSamples?.contains(i + 1) ?? true,
        ),
      );
      time += durations[i];
    }
    return samples;
  }

  static void _sampleEntry(Mp4Track track, String type, ByteReader entry) {
    track.sampleEntryType = type;
    final start = entry.offset;
    if (track.isVideo) {
      entry.skip(24);
      track.width = entry.u16();
      track.height = entry.u16();
      entry.offset = start + 78;
      for (final (childType, child) in _children(entry)) {
        final payload = child.view(child.remaining);
        switch (childType) {
          case 'avcC' || 'hvcC' || 'vpcC' || 'av1C':
            track.codecConfig = payload;
          case 'colr':
            track._colr = _colr(payload) ?? track._colr;
        }
      }
    } else if (track.isAudio) {
      entry.skip(8);
      final version = entry.u16();
      entry.skip(6);
      track.channelCount = entry.u16();
      track.sampleSize = entry.u16();
      entry.skip(4);
      track.sampleRate = entry.u32() >> 16;
      if (version == 1) entry.skip(16);
      if (version == 2) {
        entry.skip(4);
        track.sampleRate =
            ByteData.sublistView(entry.view(8)).getFloat64(0).round();
        track.channelCount = entry.u32();
        entry.skip(20);
      }
      _audioChildren(track, entry);
    }
  }

  static void _audioChildren(Mp4Track track, ByteReader parent) {
    for (final (type, child) in _children(parent)) {
      if (type == 'esds') {
        track.esds = Uint8List.fromList(
          Uint8List.sublistView(child.bytes, child.offset - 8, child.end),
        );
        track.audioObjectType = _objectType(child);
      } else if (type == 'dOps' || type == 'dfLa') {
        track.audioConfig = Uint8List.fromList(child.view(child.remaining));
      } else if (type == 'wave') {
        _audioChildren(track, child);
      }
    }
  }

  static int? _objectType(ByteReader esds) {
    esds.skip(4);
    int descriptor(int tag) {
      if (esds.u8() != tag) {
        throw const MalformedMediaException('unexpected descriptor');
      }
      var size = 0;
      for (var i = 0; i < 4; i++) {
        final byte = esds.u8();
        size = (size << 7) | (byte & 0x7f);
        if (byte & 0x80 == 0) break;
      }
      return size;
    }

    try {
      descriptor(3);
      esds.skip(2);
      final flags = esds.u8();
      if (flags & 0x80 != 0) esds.skip(2);
      if (flags & 0x40 != 0) esds.skip(esds.u8());
      if (flags & 0x20 != 0) esds.skip(2);
      descriptor(4);
      return esds.u8();
    } on MalformedMediaException {
      return null;
    }
  }

  static ColorInfo? _colr(Uint8List payload) {
    if (payload.length < 10) return null;
    final reader = ByteReader(payload);
    final kind = reader.fourCc();
    if (kind != 'nclx' && kind != 'nclc') return null;
    return ColorInfo(
      primaries: reader.u16(),
      transfer: reader.u16(),
      matrix: reader.u16(),
    );
  }
}
