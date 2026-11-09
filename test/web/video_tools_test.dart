import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_media_compressor/src/web/codec_config.dart';
import 'package:native_media_compressor/src/web/media_plan.dart';
import 'package:native_media_compressor/src/web/mp4_demuxer.dart';
import 'package:native_media_compressor/src/web/mp4_muxer.dart';
import 'package:native_media_compressor/src/web/trim_range.dart';

Future<Mp4Movie> _movie(String name) async =>
    (await Mp4Demuxer.parse(
      MemoryByteSource(
        File('example/integration_test/fixtures/$name').readAsBytesSync(),
      ),
    ))!;

Uint8List _join(List<Uint8List> parts) {
  final out = BytesBuilder(copy: false);
  parts.forEach(out.add);
  return out.takeBytes();
}

int _audioTime(Mp4Track track, Mp4Sample sample) =>
    sample.presentationTime - track.editMediaTime;

void main() {
  group('frame rate', () {
    test('is the sample count over the duration', () async {
      final video = (await _movie('h264_aac_1080p.mp4')).video!;

      expect(video.frameRate, closeTo(30, 0.01));
      expect(MediaPlan.frameRate(240, 8000, 1000), 30);
      expect(MediaPlan.frameRate(0, 8000, 1000), isNull);
      expect(MediaPlan.frameRate(10, 0, 1000), isNull);
    });
  });

  group('HEVC', () {
    test('picks a Main profile level that fits the frame', () {
      expect(MediaPlan.hevcLevel(640, 360, 30), 63);
      expect(MediaPlan.hevcLevel(1280, 720, 30), 93);
      expect(MediaPlan.hevcLevel(1920, 1080, 30), 120);
      expect(MediaPlan.hevcLevel(1920, 1080, 60), 123);
      expect(MediaPlan.hevcCodecs(1280, 720, 30), [
        'hvc1.1.6.L93.B0',
        'hev1.1.6.L93.B0',
      ]);
    });

    test('the muxer writes hvc1 with the hvcC it is given', () async {
      final source = (await _movie('hevc_aac_720p.mov')).video!;
      final muxer =
          Mp4Muxer()..setVideo(
            width: source.width,
            height: source.height,
            timescale: 30,
            config: source.codecConfig!,
            hevc: true,
            rotation: 270,
          );
      for (var i = 0; i < 4; i++) {
        muxer.addVideoSample(Uint8List(8), pts: i, duration: 1, isSync: i == 0);
      }
      final video =
          (await Mp4Demuxer.parse(
            MemoryByteSource(_join(muxer.finish())),
          ))!.video!;

      expect(video.sampleEntryType, 'hvc1');
      expect(video.mimeType, 'video/hevc');
      expect(video.codecConfig, source.codecConfig);
      expect(video.codecString, source.codecString);
      expect(video.rotation, 270);
    });
  });

  group('AAC re-encoding', () {
    test(
      'esds carries the AudioSpecificConfig and reads back as AAC',
      () async {
        // AAC-LC, 48 kHz, mono.
        final asc = Uint8List.fromList([0x11, 0x88]);
        final esds = AudioConfig.esds(asc, bitrate: 128000);
        final muxer =
            Mp4Muxer()..setVideo(
              width: 64,
              height: 48,
              timescale: 30,
              config: (await _movie('h264_aac_1080p.mp4')).video!.codecConfig!,
              rotation: 0,
            );
        muxer.addVideoSample(Uint8List(8), pts: 0, duration: 1, isSync: true);
        final index = muxer.addAacAudio(
          timescale: 48000,
          esds: esds,
          channelCount: 1,
          sampleRate: 48000,
        );
        for (var i = 0; i < 3; i++) {
          muxer.addAudioSample(index, Uint8List(6), 1024);
        }
        final audio =
            (await Mp4Demuxer.parse(
              MemoryByteSource(_join(muxer.finish())),
            ))!.audio.single;

        expect(String.fromCharCodes(esds, 4, 8), 'esds');
        expect(audio.isAac, isTrue);
        expect(audio.esds, esds);
        expect(audio.sampleRate, 48000);
        expect(audio.samples, hasLength(3));
        final tail = esds.sublist(esds.length - 7);
        expect(tail, [0x05, 0x02, 0x11, 0x88, 0x06, 0x01, 0x02]);
      },
    );

    test('names a decoder for the audio it can re-encode', () {
      expect(AudioConfig.decoder('audio/mpeg', null), ('mp3', null));
      expect(AudioConfig.decoder('audio/ac3', null)?.$1, 'ac-3');
      expect(AudioConfig.decoder('audio/opus', null), isNull);
      expect(AudioConfig.decoder('audio/mp4a-latm', null), isNull);
      final dfLa = Uint8List.fromList([0, 0, 0, 0, 0x80, 0, 0, 34]);
      final flac = AudioConfig.decoder('audio/flac', dfLa)!;
      expect(flac.$1, 'flac');
      expect(flac.$2, [0x66, 0x4c, 0x61, 0x43, 0x80, 0, 0, 34]);
    });

    test('turns dOps into a little-endian OpusHead', () {
      final dOps = Uint8List.fromList([
        0,
        2,
        0x01,
        0x38,
        0x00,
        0x00,
        0xbb,
        0x80,
        0x00,
        0x00,
        0,
      ]);
      final head = AudioConfig.opusHead(dOps);

      expect(String.fromCharCodes(head, 0, 8), 'OpusHead');
      expect(head.sublist(8), [
        1,
        2,
        0x38,
        0x01,
        0x80,
        0xbb,
        0x00,
        0x00,
        0x00,
        0x00,
        0,
      ]);
      expect(AudioConfig.decoder('audio/opus', dOps)!.$1, 'opus');
    });
  });

  group('TrimRange', () {
    test('clamps the end and rejects ranges that keep nothing', () {
      const second = Duration(seconds: 1);
      final whole = TrimRange.of(null, null, 2000000)!;
      expect((whole.startUs, whole.endUs, whole.toEnd), (0, 2000000, true));
      final tail = TrimRange.of(second, second * 30, 2000000)!;
      expect((tail.startUs, tail.endUs, tail.toEnd), (1000000, 2000000, false));
      expect(TrimRange.of(second * 3, null, 2000000), isNull);
      expect(TrimRange.of(second, second, 2000000), isNull);
    });

    test('decodes from a sync sample and covers every kept frame', () async {
      final video = (await _movie('long_1080p.mp4')).video!;
      const range = TrimRange(2000000, 5000000);
      final (first, end) = range.videoSamples(video);
      int time(int i) => TrimRange.presentationUs(video, video.samples[i]);

      expect(video.samples[first].isSync, isTrue);
      expect(time(first), lessThanOrEqualTo(range.startUs));
      final kept = [
        for (var i = 0; i < video.samples.length; i++)
          if (range.keeps(time(i))) i,
      ];
      expect(kept, hasLength(90));
      expect(kept.every((i) => i >= first && i < end), isTrue);
      for (var i = end; i < video.samples.length; i++) {
        expect(time(i), greaterThanOrEqualTo(range.endUs));
      }
      for (var i = first + 1; i < video.samples.length; i++) {
        if (video.samples[i].isSync) {
          expect(time(i), greaterThan(range.startUs));
        }
      }
    });

    test('keeps the whole video when nothing is trimmed', () async {
      final video = (await _movie('h264_aac_1080p.mp4')).video!;
      final range = TrimRange.of(null, null, TrimRange.videoEndUs(video))!;

      expect(range.videoSamples(video), (0, video.samples.length));
      expect(range.durationUs, closeTo(2000000, 1));
    });

    test('keeps audio overlapping the range with one sample before', () async {
      final audio = (await _movie('long_1080p.mp4')).audio.single;
      const range = TrimRange(2000000, 5000000);
      final (first, end, skip) = range.audioSamples(audio);
      final scale = audio.timescale / 1e6;
      final start = (range.startUs * scale).round();
      final stop = (range.endUs * scale).round();
      final samples = audio.samples;

      expect(_audioTime(audio, samples[first]), lessThan(start));
      expect(_audioTime(audio, samples[first + 1]), lessThanOrEqualTo(start));
      expect(
        _audioTime(audio, samples[first + 1]) + samples[first + 1].duration,
        greaterThan(start),
      );
      expect(skip, start - _audioTime(audio, samples[first]));
      expect(_audioTime(audio, samples[end - 1]), lessThan(stop));
      expect(_audioTime(audio, samples[end]), greaterThanOrEqualTo(stop));
    });

    test(
      'copies all audio with its own start when nothing is trimmed',
      () async {
        final movie = await _movie('h264_aac_1080p.mp4');
        final audio = movie.audio.single;
        final range =
            TrimRange.of(null, null, TrimRange.videoEndUs(movie.video!))!;

        expect(range.audioSamples(audio), (
          0,
          audio.samples.length,
          audio.editMediaTime,
        ));
      },
    );

    test('finds the frame shown at a position', () async {
      final video = (await _movie('h264_aac_1080p.mp4')).video!;
      final times = [
        for (final sample in video.samples)
          TrimRange.presentationUs(video, sample),
      ]..sort();

      expect(TrimRange.frameAt(video, 0), times.first);
      expect(TrimRange.frameAt(video, -5), times.first);
      expect(TrimRange.frameAt(video, 30000000), times.last);
      expect(TrimRange.frameAt(video, times[10] + 1), times[10]);
      expect(TrimRange.frameAt(video, times[10]), times[10]);
    });
  });
}
