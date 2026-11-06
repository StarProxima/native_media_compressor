import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_media_compressor/src/web/mp4_demuxer.dart';
import 'package:native_media_compressor/src/web/mp4_muxer.dart';

Uint8List _fixture(String name) =>
    File('example/integration_test/fixtures/$name').readAsBytesSync();

Future<Mp4Movie?> _parse(Uint8List bytes) =>
    Mp4Demuxer.parse(MemoryByteSource(bytes));

Future<Mp4Movie> _movie(String name) async => (await _parse(_fixture(name)))!;

Uint8List _join(List<Uint8List> parts) {
  final out = BytesBuilder(copy: false);
  parts.forEach(out.add);
  return out.takeBytes();
}

void main() {
  group('Mp4Demuxer', () {
    test('reads an H.264 file with AAC audio', () async {
      final bytes = _fixture('h264_aac_1080p.mp4');
      final movie = (await _parse(bytes))!;
      final video = movie.video!;

      expect((video.width, video.height), (1920, 1080));
      expect(video.rotation, 0);
      expect(video.mimeType, 'video/avc');
      expect(video.codecString, matches(RegExp(r'^avc1\.[0-9a-f]{6}$')));
      expect(video.isHdr, isFalse);
      expect(video.samples, hasLength(60));
      expect(video.samples.first.isSync, isTrue);
      expect(movie.durationMs, closeTo(2000, 100));
      expect(movie.audio.single.mimeType, 'audio/mp4a-latm');
      expect(movie.audio.single.esds, isNotNull);

      for (final sample in [...video.samples, ...movie.audio.single.samples]) {
        expect(sample.offset + sample.size, lessThanOrEqualTo(bytes.length));
      }
      final first = video.samples.first;
      final nalLength = ByteData.sublistView(bytes, first.offset).getUint32(0);
      expect(nalLength + 4, lessThanOrEqualTo(first.size));
    });

    test('orders presentation times after B-frames', () async {
      final video = (await _movie('h264_aac_1080p.mp4')).video!;
      final times = [for (final s in video.samples) s.presentationTime]..sort();

      expect(
        video.samples.map((s) => s.presentationTime),
        isNot(orderedEquals(times)),
      );
      expect(times.first, video.editMediaTime);
    });

    test('reads the rotation matrix', () async {
      final video = (await _movie('h264_rotated_90.mp4')).video!;

      expect(video.rotation, anyOf(90, 270));
      expect((video.width, video.height), (1920, 1080));
    });

    test('reads HEVC in QuickTime with its audio', () async {
      final movie = await _movie('hevc_aac_720p.mov');
      final video = movie.video!;

      expect(video.mimeType, 'video/hevc');
      expect(video.codecString, startsWith('hvc1.1.6.L'));
      expect(video.isHdr, isFalse);
      expect(movie.audio.single.isAac, isTrue);
      expect(movie.audio.single.channelCount, greaterThan(0));
    });

    test('finds HDR in colr and in the HEVC parameter sets', () async {
      for (final (name, transfer) in [
        ('hdr10_hevc.mp4', 16),
        ('hlg_hevc.mov', 18),
        ('hlg_hevc_8bit.mp4', 18),
      ]) {
        final video = (await _movie(name)).video!;

        expect(video.color?.transfer, transfer, reason: name);
        expect(video.isHdr, isTrue, reason: name);
      }
    });

    test('reads screen recordings', () async {
      final ios = (await _movie('screen_ios.mov')).video!;
      final android = await _movie('screen_android.mp4');

      expect((ios.width, ios.height, ios.mimeType), (1206, 2622, 'video/hevc'));
      expect(ios.isHdr, isFalse);
      expect(android.video!.mimeType, 'video/avc');
      expect((android.video!.width, android.video!.height), (1080, 2400));
      expect(android.audio, isEmpty);
    });

    test('names non-AAC audio and counts audio tracks', () async {
      final mp3 = await _movie('mp3_audio.mp4');
      final two = await _movie('two_audio_tracks.mp4');

      expect(mp3.audio.single.mimeType, 'audio/mpeg');
      expect(mp3.audio.single.isAac, isFalse);
      expect(two.audio, hasLength(2));
      expect(two.audio.every((track) => track.isAac), isTrue);
    });

    test('has no video track in audio-only and broken files', () async {
      expect((await _movie('audio_only.m4a')).video, isNull);
      expect(await _parse(_fixture('broken.jpg')), isNull);
      expect(await _parse(Uint8List(0)), isNull);
      final truncated = _fixture('h264_aac_1080p.mp4');
      expect(await _parse(Uint8List.sublistView(truncated, 0, 400)), isNull);
    });
  });

  group('Mp4Muxer', () {
    test('round-trips samples, timing, rotation and audio', () async {
      final bytes = _fixture('h264_aac_1080p.mp4');
      final source = (await _parse(bytes))!;
      final video = source.video!;
      final audio = source.audio.single;
      Uint8List data(Mp4Sample s) =>
          Uint8List.sublistView(bytes, s.offset, s.offset + s.size);

      final muxer =
          Mp4Muxer()..setVideo(
            width: video.width,
            height: video.height,
            timescale: video.timescale,
            avcC: video.codecConfig!,
            rotation: 90,
          );
      for (final sample in video.samples) {
        muxer.addVideoSample(
          data(sample),
          pts: sample.presentationTime - video.editMediaTime,
          duration: sample.duration,
          isSync: sample.isSync,
        );
      }
      final track = muxer.addAudio(audio);
      for (final sample in audio.samples) {
        muxer.addAudioSample(track, data(sample), sample.duration);
      }
      final output = _join(muxer.finish());
      final movie = (await _parse(output))!;
      final outVideo = movie.video!;
      final outAudio = movie.audio.single;

      expect(String.fromCharCodes(output, 4, 8), 'ftyp');
      expect(
        String.fromCharCodes(output, 36, 40),
        'moov',
        reason: 'the movie box comes before the media data',
      );
      expect(outVideo.rotation, 90);
      expect((outVideo.width, outVideo.height), (1920, 1080));
      expect(outVideo.codecString, video.codecString);
      expect(outVideo.timescale, video.timescale);
      expect(outVideo.samples, hasLength(video.samples.length));
      for (var i = 0; i < video.samples.length; i++) {
        final a = video.samples[i], b = outVideo.samples[i];
        expect(
          b.presentationTime - outVideo.editMediaTime,
          a.presentationTime - video.editMediaTime,
        );
        expect(b.isSync, a.isSync);
        expect(
          Uint8List.sublistView(output, b.offset, b.offset + b.size),
          data(a),
        );
      }
      expect(outAudio.isAac, isTrue);
      expect(outAudio.editMediaTime, audio.editMediaTime);
      expect(outAudio.samples, hasLength(audio.samples.length));
      final lastAudio = outAudio.samples.last;
      expect(
        Uint8List.sublistView(
          output,
          lastAudio.offset,
          lastAudio.offset + lastAudio.size,
        ),
        data(audio.samples.last),
      );
      expect(movie.durationMs, closeTo(source.durationMs, 50));
    });

    test('writes no composition offsets for frames in order', () async {
      final config = (await _movie('h264_aac_1080p.mp4')).video!.codecConfig!;
      final muxer =
          Mp4Muxer()..setVideo(
            width: 64,
            height: 48,
            timescale: 30,
            avcC: config,
            rotation: 0,
          );
      for (var i = 0; i < 10; i++) {
        muxer.addVideoSample(
          Uint8List(10),
          pts: i,
          duration: 1,
          isSync: i % 5 == 0,
        );
      }
      final movie = (await _parse(_join(muxer.finish())))!;
      final video = movie.video!;

      expect(video.editMediaTime, 0);
      expect(
        video.samples.map((s) => s.presentationTime),
        orderedEquals(List.generate(10, (i) => i)),
      );
      expect(
        video.samples.map((s) => s.isSync),
        orderedEquals(List.generate(10, (i) => i % 5 == 0)),
      );
      expect(movie.audio, isEmpty);
      expect(movie.durationMs, closeTo(333, 1));
    });
  });
}
