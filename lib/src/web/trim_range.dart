import 'mp4_demuxer.dart';

/// The part of the source timeline a compression keeps, in microseconds of
/// presentation time. Output timestamps are relative to [startUs].
final class TrimRange {
  const TrimRange(this.startUs, this.endUs, {this.toEnd = false});

  final int startUs;
  final int endUs;

  /// Whether no end was asked for, so audio that runs past the video stays.
  final bool toEnd;

  int get durationUs => endUs - startUs;

  /// The range from [start] to [end] of a video presented for [durationUs],
  /// or null when it keeps nothing. An [end] past the video keeps up to its
  /// end.
  static TrimRange? of(Duration? start, Duration? end, int durationUs) {
    final from = start == null || start.isNegative ? 0 : start.inMicroseconds;
    final to =
        end == null || end.inMicroseconds > durationUs
            ? durationUs
            : end.inMicroseconds;
    return to > from ? TrimRange(from, to, toEnd: end == null) : null;
  }

  bool keeps(int timestampUs) => timestampUs >= startUs && timestampUs < endUs;

  /// Presentation time of [sample] in microseconds, after the edit list.
  static int presentationUs(Mp4Track track, Mp4Sample sample) =>
      ((sample.presentationTime - track.editMediaTime) * 1e6 / track.timescale)
          .round();

  /// Presentation time in microseconds of the [video] frame shown at
  /// [positionUs]: the last one that starts at or before it, or the first
  /// frame for a position before the video starts.
  static int frameAt(Mp4Track video, int positionUs) {
    int? atOrBefore;
    int? earliest;
    for (final sample in video.samples) {
      final time = presentationUs(video, sample);
      if (time <= positionUs && (atOrBefore == null || time > atOrBefore)) {
        atOrBefore = time;
      }
      if (earliest == null || time < earliest) earliest = time;
    }
    return atOrBefore ?? earliest ?? 0;
  }

  /// End of the last frame of [video] in microseconds, after the edit list.
  static int videoEndUs(Mp4Track video) {
    var end = 0;
    for (final sample in video.samples) {
      final sampleEnd = sample.presentationTime + sample.duration;
      if (sampleEnd > end) end = sampleEnd;
    }
    return ((end - video.editMediaTime) * 1e6 / video.timescale).round();
  }

  /// Decode-order range of [video] samples that yields every frame presented
  /// in this range: from the last sync sample presented at or before the
  /// start, through the last sample presented before the end. Frames that
  /// the decoder needs only as references come out too and are dropped.
  (int, int) videoSamples(Mp4Track video) {
    final samples = video.samples;
    var first = -1;
    var end = 0;
    for (var i = 0; i < samples.length; i++) {
      final sample = samples[i];
      final time = presentationUs(video, sample);
      if (sample.isSync && (first < 0 || time <= startUs)) first = i;
      if (time < endUs) end = i + 1;
    }
    if (first < 0 || end <= first) return (0, 0);
    return (first, end);
  }

  /// Decode-order range of [audio] samples that overlap this range, starting
  /// one sample early because AAC and MP3 frames need the one before them to
  /// decode cleanly, and the ticks at the start of the first sample that
  /// fall before the range.
  (int, int, int) audioSamples(Mp4Track audio) {
    final samples = audio.samples;
    final scale = audio.timescale / 1e6;
    final start = (startUs * scale).round();
    final end = toEnd ? null : (endUs * scale).round();
    var first = samples.length;
    for (var i = 0; i < samples.length; i++) {
      final time = samples[i].presentationTime - audio.editMediaTime;
      if (time + samples[i].duration > start) {
        first = i;
        break;
      }
    }
    if (first == samples.length) return (first, first, 0);
    if (first > 0) first--;
    var last = samples.length;
    if (end != null) {
      for (var i = first; i < samples.length; i++) {
        if (samples[i].presentationTime - audio.editMediaTime >= end) {
          last = i;
          break;
        }
      }
    }
    final skip =
        start - (samples[first].presentationTime - audio.editMediaTime);
    return (first, last, skip > 0 ? skip : 0);
  }
}
