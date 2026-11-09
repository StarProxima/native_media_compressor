import 'dart:typed_data';

import 'bytes.dart';
import 'mp4_demuxer.dart';

final class _Sample {
  _Sample(this.data, this.time, this.duration, this.isSync);

  final Uint8List data;

  /// Presentation time for video, decode time for audio.
  final int time;
  int duration;
  final bool isSync;
  int decodeTime = 0;
}

final class _Track {
  _Track.video({
    required this.width,
    required this.height,
    required this.timescale,
    required this.config,
    required this.isHevc,
    required this.rotation,
  }) : isVideo = true,
       channelCount = 0,
       sampleRate = 0,
       editMediaTime = 0;

  _Track.audio({
    required this.timescale,
    required this.config,
    required this.channelCount,
    required this.sampleRate,
    required this.editMediaTime,
  }) : isVideo = false,
       isHevc = false,
       width = 0,
       height = 0,
       rotation = 0;

  final bool isVideo;
  final bool isHevc;
  final int width;
  final int height;
  final int rotation;
  final int timescale;

  /// The `avcC` or `hvcC` payload of a video track, the complete `esds` box
  /// of audio.
  final Uint8List config;
  final int channelCount;
  final int sampleRate;
  int editMediaTime;
  final samples = <_Sample>[];
  bool hasCompositionOffsets = false;

  /// Presentation time that maps to decode time zero.
  int timeBase = 0;
  final chunks = <(int first, int count)>[];
  final chunkOffsets = <int>[];

  int get mediaDuration =>
      samples.fold(0, (total, sample) => total + sample.duration);

  /// Presented duration in milliseconds.
  int get durationMs {
    var end = mediaDuration;
    if (isVideo) {
      for (final sample in samples) {
        final sampleEnd = sample.time - timeBase + sample.duration;
        if (sampleEnd > end) end = sampleEnd;
      }
    }
    final presented = end - editMediaTime;
    return presented <= 0 ? 0 : presented * 1000 ~/ timescale;
  }
}

/// Writes H.264 or HEVC video and AAC audio samples into an MP4 file with
/// the movie box before the media data, so playback can start while loading.
final class Mp4Muxer {
  static const _movieTimescale = 1000;
  static const _chunkSeconds = 1;
  static const _maxChunkBytes = 1 << 20;

  final _tracks = <_Track>[];
  var _mediaBytes = 0;

  /// Adds the video track with its `avcC` or, for [hevc], `hvcC` payload
  /// [config]; [width] and [height] are the stored frame size and [rotation]
  /// the clockwise rotation players apply.
  void setVideo({
    required int width,
    required int height,
    required int timescale,
    required Uint8List config,
    required int rotation,
    bool hevc = false,
  }) {
    _tracks.insert(
      0,
      _Track.video(
        width: width,
        height: height,
        timescale: timescale,
        config: config,
        isHevc: hevc,
        rotation: rotation,
      ),
    );
  }

  /// Adds an audio track copied from [source], which must carry an `esds`.
  /// [editMediaTime] replaces the source's start when part of it is cut.
  /// Returns the index for [addAudioSample].
  int addAudio(Mp4Track source, {int? editMediaTime}) => addAacAudio(
    timescale: source.timescale,
    esds: source.esds!,
    channelCount: source.channelCount,
    sampleRate: source.sampleRate,
    editMediaTime: editMediaTime ?? source.editMediaTime,
  );

  /// Adds an AAC track described by the complete `esds` box [esds].
  /// Returns the index for [addAudioSample].
  int addAacAudio({
    required int timescale,
    required Uint8List esds,
    required int channelCount,
    required int sampleRate,
    int editMediaTime = 0,
  }) {
    _tracks.add(
      _Track.audio(
        timescale: timescale,
        config: esds,
        channelCount: channelCount,
        sampleRate: sampleRate,
        editMediaTime: editMediaTime,
      ),
    );
    return _tracks.length - 1;
  }

  bool get hasVideo => _tracks.isNotEmpty && _tracks.first.isVideo;

  /// Adds an encoded frame in decode order. [pts] is the presentation time
  /// in the video timescale; [duration] is used for the last frame.
  void addVideoSample(
    Uint8List data, {
    required int pts,
    required int duration,
    required bool isSync,
  }) {
    _tracks.first.samples.add(_Sample(data, pts, duration, isSync));
    _mediaBytes += data.length;
  }

  void addAudioSample(int track, Uint8List data, int duration) {
    _tracks[track].samples.add(_Sample(data, 0, duration, true));
    _mediaBytes += data.length;
  }

  /// Bytes of media data added so far.
  int get mediaBytes => _mediaBytes;

  /// Builds the file. The parts concatenated in order are the MP4 file.
  List<Uint8List> finish() {
    for (final track in _tracks) {
      if (track.isVideo) {
        _videoTiming(track);
      } else {
        var time = 0;
        for (final sample in track.samples) {
          sample.decodeTime = time;
          time += sample.duration;
        }
      }
      _chunk(track);
    }

    final order = <(int track, int chunk)>[];
    for (var t = 0; t < _tracks.length; t++) {
      for (var c = 0; c < _tracks[t].chunks.length; c++) {
        order.add((t, c));
      }
    }
    double start((int, int) entry) {
      final track = _tracks[entry.$1];
      final sample = track.samples[track.chunks[entry.$2].$1];
      return sample.decodeTime / track.timescale;
    }

    order.sort((a, b) => start(a).compareTo(start(b)));

    final ftyp = _ftyp();
    final largeMdat = _mediaBytes + 8 > 0xffffffff;
    final mdatHeader = largeMdat ? 16 : 8;
    final use64 =
        ftyp.length + _mediaBytes + mdatHeader + 0x100000 > 0xffffffff;

    void layout(int base) {
      var offset = base;
      for (final track in _tracks) {
        track.chunkOffsets
          ..clear()
          ..addAll(List.filled(track.chunks.length, 0));
      }
      for (final (t, c) in order) {
        final track = _tracks[t];
        track.chunkOffsets[c] = offset;
        final (first, count) = track.chunks[c];
        for (var i = first; i < first + count; i++) {
          offset += track.samples[i].data.length;
        }
      }
    }

    layout(0);
    final moovSize = _moov(use64).length;
    layout(ftyp.length + moovSize + mdatHeader);
    final moov = _moov(use64);

    final header =
        ByteWriter()
          ..bytes(ftyp)
          ..bytes(moov);
    if (largeMdat) {
      header
        ..u32(1)
        ..fourCc('mdat')
        ..u64(_mediaBytes + 16);
    } else {
      header
        ..u32(_mediaBytes + 8)
        ..fourCc('mdat');
    }
    final parts = <Uint8List>[header.takeBytes()];
    for (final (t, c) in order) {
      final track = _tracks[t];
      final (first, count) = track.chunks[c];
      for (var i = first; i < first + count; i++) {
        parts.add(track.samples[i].data);
      }
    }
    return parts;
  }

  /// Derives decode times from presentation times in decode order: the
  /// encoder reports only presentation timestamps.
  static void _videoTiming(_Track track) {
    final samples = track.samples;
    if (samples.isEmpty) return;
    final sorted = [for (final sample in samples) sample.time]..sort();
    var shift = 0;
    for (var i = 0; i < samples.length; i++) {
      final ahead = sorted[i] - samples[i].time;
      if (ahead > shift) shift = ahead;
    }
    final base = sorted.first - shift;
    track.timeBase = base;
    for (var i = 0; i < samples.length; i++) {
      samples[i].decodeTime = sorted[i] - shift - base;
    }
    for (var i = 0; i + 1 < samples.length; i++) {
      final delta = samples[i + 1].decodeTime - samples[i].decodeTime;
      samples[i].duration = delta > 0 ? delta : 1;
    }
    if (samples.last.duration <= 0) {
      samples.last.duration =
          samples.length > 1 ? samples[samples.length - 2].duration : 1;
    }
    track.editMediaTime = sorted.first - base;
    track.hasCompositionOffsets = samples.any(
      (sample) => sample.time - base != sample.decodeTime,
    );
  }

  static int _compositionOffset(_Track track, _Sample sample) =>
      sample.time - track.timeBase - sample.decodeTime;

  static void _chunk(_Track track) {
    track.chunks.clear();
    final limit = track.timescale * _chunkSeconds;
    var first = 0;
    var bytes = 0;
    for (var i = 0; i < track.samples.length; i++) {
      final sample = track.samples[i];
      final span = sample.decodeTime - track.samples[first].decodeTime;
      if (i > first && (span >= limit || bytes >= _maxChunkBytes)) {
        track.chunks.add((first, i - first));
        first = i;
        bytes = 0;
      }
      bytes += sample.data.length;
    }
    if (first < track.samples.length) {
      track.chunks.add((first, track.samples.length - first));
    }
  }

  static Uint8List _ftyp() {
    final writer =
        ByteWriter()..box('ftyp', (w) {
          w
            ..fourCc('isom')
            ..u32(0x200)
            ..fourCc('isom')
            ..fourCc('iso2')
            ..fourCc('avc1')
            ..fourCc('mp41');
        });
    return writer.takeBytes();
  }

  static const _identity = [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000];

  static List<int> _matrix(int rotation) => switch (rotation) {
    90 => const [0, 0x10000, 0, -0x10000, 0, 0, 0, 0, 0x40000000],
    180 => const [-0x10000, 0, 0, 0, -0x10000, 0, 0, 0, 0x40000000],
    270 => const [0, -0x10000, 0, 0x10000, 0, 0, 0, 0, 0x40000000],
    _ => _identity,
  };

  static void _writeMatrix(ByteWriter w, List<int> matrix) {
    for (final value in matrix) {
      w.u32(value & 0xffffffff);
    }
  }

  Uint8List _moov(bool use64) {
    final duration = _tracks.fold(
      0,
      (longest, track) =>
          track.durationMs > longest ? track.durationMs : longest,
    );
    final writer =
        ByteWriter()..box('moov', (w) {
          w.fullBox('mvhd', 0, 0, (w) {
            w
              ..u32(0)
              ..u32(0)
              ..u32(_movieTimescale)
              ..u32(duration)
              ..u32(0x10000)
              ..u16(0x100)
              ..zeros(10);
            _writeMatrix(w, _identity);
            w
              ..zeros(24)
              ..u32(_tracks.length + 1);
          });
          for (var i = 0; i < _tracks.length; i++) {
            _trak(w, _tracks[i], i + 1, use64);
          }
        });
    return writer.takeBytes();
  }

  static void _trak(ByteWriter w, _Track track, int id, bool use64) {
    w.box('trak', (w) {
      w.fullBox('tkhd', 0, 3, (w) {
        w
          ..u32(0)
          ..u32(0)
          ..u32(id)
          ..u32(0)
          ..u32(track.durationMs)
          ..zeros(8)
          ..u16(0)
          ..u16(0)
          ..u16(track.isVideo ? 0 : 0x100)
          ..u16(0);
        _writeMatrix(w, _matrix(track.rotation));
        w
          ..u32(track.width << 16)
          ..u32(track.height << 16);
      });
      if (track.editMediaTime > 0) {
        w.box('edts', (w) {
          w.fullBox('elst', 0, 0, (w) {
            w
              ..u32(1)
              ..u32(track.durationMs)
              ..u32(track.editMediaTime)
              ..u32(0x10000);
          });
        });
      }
      w.box('mdia', (w) {
        w.fullBox('mdhd', 0, 0, (w) {
          w
            ..u32(0)
            ..u32(0)
            ..u32(track.timescale)
            ..u32(track.mediaDuration)
            ..u16(0x55c4)
            ..u16(0);
        });
        w.fullBox('hdlr', 0, 0, (w) {
          w
            ..u32(0)
            ..fourCc(track.isVideo ? 'vide' : 'soun')
            ..zeros(12)
            ..bytes(
              (track.isVideo ? 'VideoHandler\u0000' : 'SoundHandler\u0000')
                  .codeUnits,
            );
        });
        w.box('minf', (w) {
          if (track.isVideo) {
            w.fullBox('vmhd', 0, 1, (w) => w.zeros(8));
          } else {
            w.fullBox('smhd', 0, 0, (w) => w.zeros(4));
          }
          w.box('dinf', (w) {
            w.fullBox('dref', 0, 0, (w) {
              w
                ..u32(1)
                ..fullBox('url ', 0, 1, (_) {});
            });
          });
          _stbl(w, track, use64);
        });
      });
    });
  }

  static void _stbl(ByteWriter w, _Track track, bool use64) {
    final samples = track.samples;
    w.box('stbl', (w) {
      w.fullBox('stsd', 0, 0, (w) {
        w.u32(1);
        if (track.isVideo) {
          w.box(track.isHevc ? 'hvc1' : 'avc1', (w) {
            w
              ..zeros(6)
              ..u16(1)
              ..zeros(16)
              ..u16(track.width)
              ..u16(track.height)
              ..u32(0x480000)
              ..u32(0x480000)
              ..u32(0)
              ..u16(1)
              ..zeros(32)
              ..u16(0x18)
              ..u16(0xffff)
              ..box(
                track.isHevc ? 'hvcC' : 'avcC',
                (w) => w.bytes(track.config),
              );
          });
        } else {
          w.box('mp4a', (w) {
            w
              ..zeros(6)
              ..u16(1)
              ..zeros(8)
              ..u16(track.channelCount)
              ..u16(16)
              ..u32(0)
              ..u32((track.sampleRate > 0xffff ? 0 : track.sampleRate) << 16)
              ..bytes(track.config);
          });
        }
      });

      final runs = <(int, int)>[];
      for (final sample in samples) {
        if (runs.isNotEmpty && runs.last.$2 == sample.duration) {
          runs.last = (runs.last.$1 + 1, sample.duration);
        } else {
          runs.add((1, sample.duration));
        }
      }
      w.fullBox('stts', 0, 0, (w) {
        w.u32(runs.length);
        for (final (count, delta) in runs) {
          w
            ..u32(count)
            ..u32(delta);
        }
      });

      if (track.hasCompositionOffsets) {
        final offsets = <(int, int)>[];
        for (final sample in samples) {
          final offset = _compositionOffset(track, sample);
          if (offsets.isNotEmpty && offsets.last.$2 == offset) {
            offsets.last = (offsets.last.$1 + 1, offset);
          } else {
            offsets.add((1, offset));
          }
        }
        w.fullBox('ctts', 0, 0, (w) {
          w.u32(offsets.length);
          for (final (count, offset) in offsets) {
            w
              ..u32(count)
              ..u32(offset);
          }
        });
      }

      if (track.isVideo && samples.any((sample) => !sample.isSync)) {
        final sync = [
          for (var i = 0; i < samples.length; i++)
            if (samples[i].isSync) i + 1,
        ];
        w.fullBox('stss', 0, 0, (w) {
          w.u32(sync.length);
          sync.forEach(w.u32);
        });
      }

      final chunkRuns = <(int, int)>[];
      for (var c = 0; c < track.chunks.length; c++) {
        final count = track.chunks[c].$2;
        if (chunkRuns.isEmpty || chunkRuns.last.$2 != count) {
          chunkRuns.add((c + 1, count));
        }
      }
      w.fullBox('stsc', 0, 0, (w) {
        w.u32(chunkRuns.length);
        for (final (first, count) in chunkRuns) {
          w
            ..u32(first)
            ..u32(count)
            ..u32(1);
        }
      });

      w.fullBox('stsz', 0, 0, (w) {
        w
          ..u32(0)
          ..u32(samples.length);
        for (final sample in samples) {
          w.u32(sample.data.length);
        }
      });

      w.fullBox(use64 ? 'co64' : 'stco', 0, 0, (w) {
        w.u32(track.chunkOffsets.length);
        for (final offset in track.chunkOffsets) {
          use64 ? w.u64(offset) : w.u32(offset);
        }
      });
    });
  }
}
